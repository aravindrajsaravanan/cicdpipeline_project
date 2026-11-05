#!/bin/bash
# EC2 user-data for the Jenkins + SonarQube server (Ubuntu 24.04).
# Installs: Java 21, Jenkins LTS, Docker, Trivy, AWS CLI v2, sonar-scanner, Python venv,
# and runs SonarQube + Postgres with Docker Compose.
# Log: /var/log/jenkins-setup.log    Done marker: /var/lib/cicd-setup-done
set -euxo pipefail
exec > >(tee -a /var/log/jenkins-setup.log) 2>&1
export DEBIAN_FRONTEND=noninteractive
# On any failure, leave a marker with the failing line so it's visible immediately
trap 'echo "FAILED at line $LINENO: $BASH_COMMAND" | tee /var/lib/cicd-setup-failed' ERR

SONAR_SCANNER_VERSION="8.3.1.16491"
PLUGIN_MANAGER_VERSION="2.16.0"
JENKINS_PLUGINS="configuration-as-code job-dsl workflow-aggregator git sonar timestamper junit credentials-binding plain-credentials pipeline-stage-view"
SONARQUBE_IMAGE="sonarqube:26.10.0.133078-community"
POSTGRES_IMAGE="postgres:17.11-alpine"

# ---------- base packages ----------
apt-get update
apt-get install -y ca-certificates curl gnupg unzip jq git openssl \
  python3-venv python3-pip fontconfig openjdk-21-jre-headless \
  docker.io docker-compose-v2

# ---------- apt repos: Jenkins LTS + Trivy ----------
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key -o /etc/apt/keyrings/jenkins-keyring.asc
echo "deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" \
  > /etc/apt/sources.list.d/jenkins.list

curl -fsSL https://get.trivy.dev/deb/public.key | gpg --dearmor -o /etc/apt/keyrings/trivy.gpg
echo "deb [signed-by=/etc/apt/keyrings/trivy.gpg] https://get.trivy.dev/deb generic main" \
  > /etc/apt/sources.list.d/trivy.list

apt-get update
apt-get install -y jenkins trivy
systemctl stop jenkins   # configured below, started at the end

# ---------- Docker access for Jenkins ----------
systemctl enable --now docker
usermod -aG docker jenkins

# ---------- AWS CLI v2 ----------
curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscliv2.zip
unzip -q -o /tmp/awscliv2.zip -d /tmp
/tmp/aws/install --update
rm -rf /tmp/aws /tmp/awscliv2.zip

# ---------- sonar-scanner CLI ----------
curl -fsSL "https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-${SONAR_SCANNER_VERSION}-linux-x64.zip" -o /tmp/sonar-scanner.zip
unzip -q -o /tmp/sonar-scanner.zip -d /opt
ln -sfn "/opt/sonar-scanner-${SONAR_SCANNER_VERSION}-linux-x64" /opt/sonar-scanner
ln -sf /opt/sonar-scanner/bin/sonar-scanner /usr/local/bin/sonar-scanner
rm -f /tmp/sonar-scanner.zip

# ---------- kernel settings SonarQube (Elasticsearch) needs ----------
cat > /etc/sysctl.d/99-sonarqube.conf <<'EOF'
vm.max_map_count=524288
fs.file-max=131072
EOF
sysctl --system

# ---------- SonarQube + Postgres ----------
install -d -m 0750 /opt/sonarqube
if [ ! -f /opt/sonarqube/.env ]; then
  echo "POSTGRES_PASSWORD=$(openssl rand -hex 24)" > /opt/sonarqube/.env
  chmod 600 /opt/sonarqube/.env
fi

cat > /opt/sonarqube/compose.yaml <<EOF
services:
  db:
    image: ${POSTGRES_IMAGE}
    restart: unless-stopped
    environment:
      POSTGRES_USER: sonar
      POSTGRES_DB: sonar
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
    volumes:
      - pgdata:/var/lib/postgresql/data

  sonarqube:
    image: ${SONARQUBE_IMAGE}
    restart: unless-stopped
    depends_on:
      - db
    environment:
      SONAR_JDBC_URL: jdbc:postgresql://db:5432/sonar
      SONAR_JDBC_USERNAME: sonar
      SONAR_JDBC_PASSWORD: \${POSTGRES_PASSWORD}
      # allow the webhook to Jenkins on the Docker host (172.17.0.1, a private address)
      SONAR_VALIDATEWEBHOOKS: "false"
    ports:
      - "9000:9000"
    # lets the SonarQube webhook reach Jenkins on the host: http://host.docker.internal:8080
    extra_hosts:
      - "host.docker.internal:host-gateway"
    ulimits:
      nofile: { soft: 131072, hard: 131072 }
      nproc: { soft: 8192, hard: 8192 }
    volumes:
      - sonar_data:/opt/sonarqube/data
      - sonar_extensions:/opt/sonarqube/extensions
      - sonar_logs:/opt/sonarqube/logs

volumes:
  pgdata:
  sonar_data:
  sonar_extensions:
  sonar_logs:
EOF

docker compose --project-directory /opt/sonarqube --env-file /opt/sonarqube/.env up -d

# ---------- instance metadata (IMDSv2) ----------
set +x   # keep the IMDS token out of the log
IMDS_TOKEN=$(curl -sf -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
imds() { curl -sf -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" "http://169.254.169.254/latest/meta-data/$1"; }
REGION=$(imds placement/region)
PUBLIC_IP=$(imds public-ipv4)

# ======================================================================
# Secrets section: xtrace OFF so no secret ever reaches the log.
# Values live only in Parameter Store (/cicd/*) and root/jenkins-only files.
# ======================================================================
set +x
get_param() { aws ssm get-parameter --region "$REGION" --name "$1" --with-decryption --query Parameter.Value --output text 2>/dev/null; }
put_param() { aws ssm put-parameter --region "$REGION" --name "$1" --type SecureString --overwrite --value "$2" >/dev/null; }

# ---------- SonarQube: admin password, analysis token, webhook ----------
SONAR=http://localhost:9000
echo "Waiting for SonarQube..."
for _ in $(seq 1 90); do
  [ "$(curl -s "$SONAR/api/system/status" | jq -r .status 2>/dev/null)" = "UP" ] && break
  sleep 10
done

if curl -s -u admin:admin "$SONAR/api/authentication/validate" | jq -e '.valid' >/dev/null; then
  echo "SonarQube: replacing default admin password"
  SONAR_PW="Sq1!$(openssl rand -hex 16)"   # meets SonarQube complexity rules
  curl -sf -u admin:admin -X POST "$SONAR/api/users/change_password" \
    --data-urlencode login=admin --data-urlencode previousPassword=admin \
    --data-urlencode "password=$SONAR_PW"
  put_param /cicd/sonarqube-admin-password "$SONAR_PW"
else
  SONAR_PW=$(get_param /cicd/sonarqube-admin-password)
fi

curl -s -u "admin:$SONAR_PW" -X POST "$SONAR/api/user_tokens/revoke" --data-urlencode name=jenkins >/dev/null || true
SONAR_TOKEN=$(curl -sf -u "admin:$SONAR_PW" -X POST "$SONAR/api/user_tokens/generate" \
  --data-urlencode name=jenkins --data-urlencode type=GLOBAL_ANALYSIS_TOKEN | jq -r .token)
echo "SonarQube: analysis token created"

if ! curl -sf -u "admin:$SONAR_PW" "$SONAR/api/webhooks/list" | jq -e '.webhooks[] | select(.name=="jenkins")' >/dev/null; then
  curl -sf -u "admin:$SONAR_PW" -X POST "$SONAR/api/webhooks/create" \
    --data-urlencode name=jenkins \
    --data-urlencode url=http://host.docker.internal:8080/sonarqube-webhook/ >/dev/null
  echo "SonarQube: webhook to Jenkins created"
fi

# ---------- Jenkins admin password (reused across rebuilds) ----------
JENKINS_PW=$(get_param /cicd/jenkins-admin-password || true)
if [ -z "$JENKINS_PW" ]; then
  JENKINS_PW=$(openssl rand -base64 24 | tr -d '/+=')
  put_param /cicd/jenkins-admin-password "$JENKINS_PW"
  echo "Jenkins: admin password generated and stored in Parameter Store"
fi

# ---------- GitHub deploy token (created by the user in Parameter Store) ----------
GITHUB_TOKEN=$(get_param /cicd/github-deploy-token || true)
if [ -z "$GITHUB_TOKEN" ]; then
  echo "WARNING: /cicd/github-deploy-token not found - the 'Update Deployment Repo' stage will fail"
  GITHUB_TOKEN="MISSING"
fi

# ---------- JCasC secret files ----------
SECRETS_DIR=/var/lib/jenkins/casc-secrets
install -d -m 0700 -o jenkins -g jenkins "$SECRETS_DIR"
write_secret() { ( umask 077; printf '%s' "$2" > "$SECRETS_DIR/$1" ); chown jenkins:jenkins "$SECRETS_DIR/$1"; }
write_secret JENKINS_ADMIN_PASSWORD "$JENKINS_PW"
write_secret SONAR_TOKEN "$SONAR_TOKEN"
write_secret GITHUB_DEPLOY_TOKEN "$GITHUB_TOKEN"
write_secret JENKINS_URL "http://${PUBLIC_IP}:8080/"
unset SONAR_PW SONAR_TOKEN JENKINS_PW GITHUB_TOKEN
set -x
# ======================= end of secrets section =======================

# ---------- Jenkins plugins ----------
curl -fsSL "https://github.com/jenkinsci/plugin-installation-manager-tool/releases/download/${PLUGIN_MANAGER_VERSION}/jenkins-plugin-manager-${PLUGIN_MANAGER_VERSION}.jar" \
  -o /opt/jenkins-plugin-manager.jar
install -d -o jenkins -g jenkins /var/lib/jenkins/plugins
# shellcheck disable=SC2086
java -jar /opt/jenkins-plugin-manager.jar --war /usr/share/java/jenkins.war \
  --plugin-download-directory /var/lib/jenkins/plugins --plugins $JENKINS_PLUGINS
chown -R jenkins:jenkins /var/lib/jenkins/plugins

# ---------- JCasC file (injected by Terraform from devops/jenkins/casc.yaml) ----------
echo "__CASC_B64__" | base64 -d > /var/lib/jenkins/casc.yaml
chown jenkins:jenkins /var/lib/jenkins/casc.yaml

# ---------- Jenkins service: no setup wizard, load JCasC ----------
install -d /etc/systemd/system/jenkins.service.d
cat > /etc/systemd/system/jenkins.service.d/override.conf <<'EOF'
[Service]
Environment="JAVA_OPTS=-Djava.awt.headless=true -Djenkins.install.runSetupWizard=false"
Environment="CASC_JENKINS_CONFIG=/var/lib/jenkins/casc.yaml"
Environment="SECRETS=/var/lib/jenkins/casc-secrets"
EOF

# ---------- helper scripts (run via SSM; they read the password on the server) ----------
cat > /usr/local/bin/cicd-jenkins-api <<'EOF'
#!/bin/bash
# Usage: cicd-jenkins-api GET|POST <path>   e.g. cicd-jenkins-api POST /job/cicd-app/build
set -euo pipefail
PW=$(cat /var/lib/jenkins/casc-secrets/JENKINS_ADMIN_PASSWORD)
J=http://localhost:8080
JAR=$(mktemp); trap 'rm -f "$JAR"' EXIT
CRUMB=$(curl -sf -c "$JAR" -u "admin:$PW" "$J/crumbIssuer/api/json" | jq -r '.crumbRequestField + ":" + .crumb')
curl -sS -b "$JAR" -u "admin:$PW" -H "$CRUMB" -X "$1" "$J$2"
EOF
chmod 0700 /usr/local/bin/cicd-jenkins-api

# ---------- start Jenkins ----------
systemctl daemon-reload
systemctl enable jenkins
systemctl restart jenkins
for _ in $(seq 1 60); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/login)" = "200" ] && break
  sleep 5
done

# ---------- summary ----------
{
  echo "java:          $(java -version 2>&1 | head -1)"
  echo "jenkins:       $(dpkg-query -W -f='${Version}' jenkins)"
  echo "docker:        $(docker --version)"
  echo "trivy:         $(trivy --version | head -1)"
  echo "aws:           $(aws --version)"
  echo "sonar-scanner: ${SONAR_SCANNER_VERSION}"
  echo "python:        $(python3 --version)"
} | tee /var/lib/cicd-setup-done
