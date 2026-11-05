#!/bin/bash
# EC2 user-data for the Jenkins + SonarQube server (Ubuntu 24.04).
# Installs: Java 21, Jenkins LTS, Docker, Trivy, AWS CLI v2, sonar-scanner, Python venv,
# and runs SonarQube + Postgres with Docker Compose.
# Log: /var/log/jenkins-setup.log    Done marker: /var/lib/cicd-setup-done
set -euxo pipefail
exec > >(tee -a /var/log/jenkins-setup.log) 2>&1
export DEBIAN_FRONTEND=noninteractive

SONAR_SCANNER_VERSION="8.3.1.16491"
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

# ---------- start Jenkins (restart so the docker group applies) ----------
systemctl enable jenkins
systemctl restart jenkins

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
