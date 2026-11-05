# End-to-end CI/CD Pipeline on AWS: Project Document

**Owner:** Aravind Raj (`aravindrajsaravanan`)
**Built:** 5 November 2026, with Claude Code
**Region:** `ap-south-1` (Mumbai) · **AWS account:** `718460151470`
**Status:** Built, verified end-to-end (live demo passed), then **destroyed** to stop billing. Everything is code, so it can be rebuilt in about 20 minutes (see [Rebuild from scratch](#9-rebuild-from-scratch)).

---

## Table of contents

1. [What this project does](#1-what-this-project-does)
2. [Architecture](#2-architecture)
3. [Tools and versions](#3-tools-and-versions)
4. [Repositories and file layout](#4-repositories-and-file-layout)
5. [AWS resources](#5-aws-resources)
6. [IAM: user policy and roles](#6-iam-user-policy-and-roles)
7. [The pipeline, stage by stage](#7-the-pipeline-stage-by-stage)
8. [Secrets: where every credential lives](#8-secrets-where-every-credential-lives)
9. [Rebuild from scratch](#9-rebuild-from-scratch)
10. [Day-to-day operations](#10-day-to-day-operations)
11. [Teardown (order matters)](#11-teardown-order-matters)
12. [Problems we hit and how they were fixed](#12-problems-we-hit-and-how-they-were-fixed)
13. [Cost](#13-cost)
14. [Security notes and next improvements](#14-security-notes-and-next-improvements)
15. [Leftovers outside this project](#15-leftovers-outside-this-project)
16. [Reusable prompts for Claude](#16-reusable-prompts-for-claude)

---

## 1. What this project does

A small FastAPI web app (`main.py` + `form.html`) goes from `git push` to running on Kubernetes with **no manual steps**:

1. You push code to GitHub.
2. **Jenkins** notices the change (Poll SCM, every ~2 min), runs lint + tests, sends the code to **SonarQube** and waits for the quality gate, builds a Docker image, scans it with **Trivy**, and pushes it to **Amazon ECR**.
3. Jenkins commits the new image tag to a separate **deployment (GitOps) repo**.
4. **Argo CD** running inside **Amazon EKS** sees the commit and rolls the new version out with zero downtime.
5. The app is served through an AWS **LoadBalancer** URL.

**Verified result:** the live demo changed `form.html` and the new page was live about **4 minutes after `git push`**, with no one touching Jenkins, AWS or Kubernetes.

---

## 2. Architecture

```
 Developer (Windows PC)
      │  git push
      ▼
 ┌──────────────────────────────┐          ┌───────────────────────────────────┐
 │ GitHub: cicdpipeline_project │          │ GitHub: cicdpipeline_deployment   │
 │  app code + devops/          │          │  k8s/kustomization.yaml (tag)     │
 └──────────────┬───────────────┘          └───────────────▲───────────┬───────┘
                │ Poll SCM (H/2 * * * *)                   │ 4. commit │ 5. Argo CD polls
                ▼                                          │  new tag  │    (~3 min)
 ┌───────────────────────────────────────────────┐         │           ▼
 │ EC2 "cicd-dev-jenkins" (t3.large, Ubuntu 24.04)│         │  ┌──────────────────────────┐
 │  Jenkins LTS (config as code, JCasC)          │─────────┘  │ EKS "cicd-eks" (1.37)    │
 │  SonarQube + Postgres (Docker Compose)        │            │  node group: 2 x t3.large│
 │  Docker, Trivy, AWS CLI, sonar-scanner        │            │  Argo CD v3.6.1          │
 │                                               │            │  ns cicd-app: 2 pods     │
 │ 1. lint+test  2. Sonar + quality gate         │            │  Service: LoadBalancer ──┼──► public URL
 │ 3. build → Trivy → push ─────────┐            │            └────────────▲─────────────┘
 └──────────────────────────────────┼────────────┘                         │ image pull
                                    ▼                                      │
                         ┌────────────────────────┐                        │
                         │ ECR "cicd-app"         │────────────────────────┘
                         │ immutable tags, scan   │
                         └────────────────────────┘

 Secrets: AWS Systems Manager Parameter Store (/cicd/*), read by the Jenkins EC2 role.
 Access:  Jenkins :8080, SonarQube :9000 and the EKS API only from the admin IP (/32).
          Server access through SSM Session Manager (no SSH keys, no port 22).
```

### Design decisions

| Decision | Why |
|---|---|
| **GitOps with Argo CD**: Jenkins never touches the cluster | Jenkins needs no Kubernetes credentials; Git is the single source of truth; rollback = `git revert` |
| **Two repos** (app + deployment) | Clear split between building code and what's deployed; Jenkins can push only to the deployment repo |
| **EC2 instance role** for Jenkins (no AWS keys) | No long-lived keys stored in Jenkins |
| **Secrets in Parameter Store** | Nothing secret in Git, chat or logs; survives rebuilds |
| **Jenkins configured as code (JCasC)** | A fresh server sets itself up: plugins, credentials, SonarQube link, job |
| **Public subnets, no NAT Gateway** | Learning setup; saves about $33/month. Production would use private subnets + NAT |
| **Kustomize** in the deployment repo | Jenkins changes one line (`newTag`) instead of editing YAML with `sed` |
| **Immutable ECR tags** `<build>-<git sha>` | A tag always means the same image; easy to trace back to a commit |

---

## 3. Tools and versions

| Component | Version |
|---|---|
| Python (app image) | `python:3.12.16-slim-trixie` |
| FastAPI / uvicorn / Jinja2 | 0.162.0 / 0.54.0 / 3.1.6 |
| pytest / pytest-cov / httpx / ruff | 9.2.0 / 7.1.0 / 0.28.1 / 0.17.3 |
| Terraform / AWS provider | 1.16.6 / `~> 6.72` |
| EKS (Kubernetes) | 1.37, AL2023 nodes |
| Jenkins | LTS 2.580.2 on Java 21 |
| Jenkins plugin manager | 2.16.0 |
| SonarQube / Postgres | `26.10.0.133078-community` / `17.11-alpine` |
| sonar-scanner CLI | 8.3.1.16491 |
| Trivy | 0.76.1 |
| Argo CD | v3.6.1 |
| Local PC tools | Git 2.53, gh 2.103, AWS CLI 2.39, kubectl 1.34, Python 3.11 |

---

## 4. Repositories and file layout

| Repo | Purpose |
|---|---|
| https://github.com/aravindrajsaravanan/cicdpipeline_project | App code + everything DevOps (`devops/`) |
| https://github.com/aravindrajsaravanan/cicdpipeline_deployment | GitOps repo watched by Argo CD |

Local folders: `C:\Devops\cicdpipeline_project`, `C:\Devops\cicdpipeline_deployment`.

### App repo: `cicdpipeline_project`

```
main.py                       FastAPI app: "/" renders form.html, "/health" for probes
form.html                     the page
requirements.txt              runtime deps (pinned)
requirements-dev.txt          pytest, pytest-cov, httpx, ruff
tests/test_main.py            3 tests (page renders, /health, 404) - 100% coverage
.gitignore / .gitattributes   LF line endings enforced (shell scripts break with CRLF)
docs/CICD-PIPELINE-PROJECT.md this document
devops/
  Dockerfile                  multi-stage, non-root (UID 10001), port 8000, apt CVE patch
  Dockerfile.dockerignore
  Jenkinsfile                 the pipeline (Script Path: devops/Jenkinsfile)
  sonar-project.properties
  jenkins/casc.yaml           Jenkins Configuration as Code (users, credentials, Sonar, job)
  scripts/jenkins-setup.sh    EC2 user-data: installs and configures everything
  terraform/
    versions.tf providers.tf backend.tf variables.tf locals.tf
    network.tf                VPC 10.20.0.0/16, 2 public subnets, IGW
    ecr.tf                    ECR cicd-app (immutable, scan on push, keep last 10)
    eks.tf                    cluster, node group, IAM roles, console viewer access
    jenkins.tf                Jenkins EC2, SG, instance role, Parameter Store access
    outputs.tf                URLs, IDs, kubeconfig command
    README.md
    cicd.auto.tfvars          (git-ignored) admin_cidr = "<your-ip>/32"
```

### Deployment repo: `cicdpipeline_deployment`

```
k8s/kustomization.yaml   namespace cicd-app, image name + newTag (Jenkins updates newTag)
k8s/deployment.yaml      2 replicas, probes on /health, non-root, read-only rootfs, RollingUpdate maxUnavailable 0
k8s/service.yaml         type LoadBalancer, port 80 -> 8000
k8s/pdb.yaml             minAvailable 1
argocd/application.yaml  auto-sync, prune, self-heal, CreateNamespace, deletion finalizer
README.md                Argo CD install + UI access
```

---

## 5. AWS resources

All created by Terraform in `devops/terraform` (about 30 resources):

| Resource | Name / detail |
|---|---|
| VPC | `cicd-dev-vpc` `10.20.0.0/16`, DNS on |
| Subnets | 2 public (`ap-south-1a`, `ap-south-1b`), tagged `kubernetes.io/role/elb=1` |
| Internet gateway + route table | `cicd-dev-igw`, `cicd-dev-public-rt` |
| ECR | `cicd-app`: IMMUTABLE tags, scan on push, AES256, lifecycle keep 10, `force_delete` |
| EKS cluster | `cicd-eks` v1.37, auth mode `API`, public endpoint limited to admin IP, private endpoint on |
| Node group | `cicd-nodes`: 2 x `t3.large`, 30 GB, `AL2023_x86_64_STANDARD`, on-demand |
| EKS access entries | `claude_user` (cluster admin, creator), account root (read-only `AmazonEKSAdminViewPolicy`) |
| EC2 | `cicd-dev-jenkins`: `t3.large`, Ubuntu 24.04, 30 GB gp3 encrypted, IMDSv2 required |
| Security group | `cicd-dev-jenkins-sg`: 8080 + 9000 from admin IP only, all egress |
| Terraform state | S3 `cicd-tfstate-718460151470` (versioned, encrypted, public access blocked, `use_lockfile`), **kept after destroy** |
| Parameter Store | `/cicd/github-deploy-token`, `/cicd/jenkins-admin-password`, `/cicd/sonarqube-admin-password`, **kept after destroy** |

Created by Kubernetes, not Terraform: the app's **Classic Load Balancer** and its `k8s-elb-*` security group. Delete them through Kubernetes before `terraform destroy` (see [Teardown](#11-teardown-order-matters)).

---

## 6. IAM: user policy and roles

### IAM user `claude_user` (used by Claude via CLI profile `cicd`)

**AWS managed policies:**
- `AmazonEC2FullAccess`
- `AmazonEC2ContainerRegistryFullAccess`

**Inline policy `cicd-project-extra`** (final version; fits the 2,048-character inline limit):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "EKS", "Effect": "Allow", "Action": "eks:*", "Resource": "*" },
    {
      "Sid": "ProjectRoles",
      "Effect": "Allow",
      "Action": ["iam:*Role*", "iam:*InstanceProfile*"],
      "Resource": [
        "arn:aws:iam::*:role/cicd-*",
        "arn:aws:iam::*:instance-profile/cicd-*"
      ]
    },
    {
      "Sid": "ReadPolicies",
      "Effect": "Allow",
      "Action": ["iam:GetPolicy*", "iam:ListPolicies"],
      "Resource": "*"
    },
    {
      "Sid": "EksServiceLinkedRoles",
      "Effect": "Allow",
      "Action": "iam:CreateServiceLinkedRole",
      "Resource": "*",
      "Condition": { "StringLike": { "iam:AWSServiceName": "eks*.amazonaws.com" } }
    },
    {
      "Sid": "ReadServiceLinkedRoles",
      "Effect": "Allow",
      "Action": "iam:GetRole",
      "Resource": "arn:aws:iam::*:role/aws-service-role/*"
    },
    {
      "Sid": "TfState",
      "Effect": "Allow",
      "Action": "s3:*",
      "Resource": ["arn:aws:s3:::cicd-tfstate-*", "arn:aws:s3:::cicd-tfstate-*/*"]
    },
    {
      "Sid": "SSM",
      "Effect": "Allow",
      "Action": [
        "ssm:*Session*", "ssm:GetConnectionStatus", "ssm:DescribeInstanceInformation",
        "ssm:SendCommand", "ssm:*CommandInvocation*", "ssm:GetParameter*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "SelfCheck",
      "Effect": "Allow",
      "Action": ["iam:GetUser", "iam:List*UserPolicies", "iam:GetUserPolicy", "iam:SimulatePrincipalPolicy"],
      "Resource": "arn:aws:iam::*:user/claude_user"
    }
  ]
}
```

> **Note:** `claude_user` can create `cicd-*` roles and pass them to EC2/EKS, so in theory it could give itself more access through such a role. That's acceptable for a short-lived learning account, but don't reuse this policy in production.

### Roles Terraform creates

| Role | Used by | Permissions |
|---|---|---|
| `cicd-eks-cluster-role` | EKS control plane | `AmazonEKSClusterPolicy` |
| `cicd-eks-node-role` | worker nodes | `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`, `AmazonEC2ContainerRegistryReadOnly` |
| `cicd-jenkins-role` (+ profile `cicd-jenkins-profile`) | Jenkins EC2 | `AmazonSSMManagedInstanceCore`; inline: ECR login + push to `cicd-app` only; read `/cicd/*` params; write only the 2 generated password params |

---

## 7. The pipeline, stage by stage

`devops/Jenkinsfile`: declarative pipeline, `timeout 30m`, no concurrent builds, keep 20 builds, `pollSCM('H/2 * * * *')`.

| # | Stage | What it does | Fails when |
|---|---|---|---|
| 1 | Checkout | `checkout scm`; tag = `${BUILD_NUMBER}-${short sha}` | - |
| 2 | Lint & Test | venv → `ruff check .` → `pytest --cov --junitxml` | lint error or failing test |
| 3 | SonarQube Analysis | `sonar-scanner -Dproject.settings=devops/sonar-project.properties` | scanner error |
| 4 | Quality Gate | `waitForQualityGate abortPipeline: true` (SonarQube webhook → Jenkins) | gate fails |
| 5 | Docker Build | `docker build -f devops/Dockerfile` + OCI labels | build error |
| 6 | Trivy Scan | `trivy image --ignore-unfixed --severity HIGH,CRITICAL --exit-code 1` | fixable HIGH/CRITICAL CVE |
| 7 | Push to ECR | login with the instance role, `docker push` | - |
| 8 | Update Deployment Repo | clone deploy repo, set `newTag`, commit `[skip ci]`, push (token through a credential helper, never in a URL or log) | bad token or no push access |
| post | always | remove local image, `deleteDir()` | - |

Argo CD then syncs `k8s/` (auto-sync, prune, self-heal). Rolling update with `maxUnavailable: 0` means no downtime.

### Builds during the project

| Build | Trigger | Result | Note |
|---|---|---|---|
| #1 | manual | ❌ Trivy | caught CVE-2026-109518 (apt 3.0.3, HIGH) in the base image |
| #2, #3 | Poll SCM | ❌ Update Deployment Repo | Parameter Store held the repo name instead of the token |
| #4 | manual | ✅ | first fully green run; Argo CD deployed `4-192ff5f` |
| #5 | Poll SCM | ✅ | **live demo**: `form.html` change live ~4 min after push |
| #6 | Poll SCM | ✅ | Terraform-only change (still rebuilds; see improvements) |

---

## 8. Secrets: where every credential lives

| Secret | Where | Who creates it | How to read it |
|---|---|---|---|
| GitHub token (push to deploy repo) | Parameter Store `/cicd/github-deploy-token` (SecureString) | **You**, in the console | Console → Show decrypted value |
| Jenkins `admin` password | `/cicd/jenkins-admin-password` | generated on the server at first boot, reused on rebuild | same |
| SonarQube `admin` password | `/cicd/sonarqube-admin-password` | generated on the server (replaces `admin/admin`) | same |
| SonarQube analysis token | only on the Jenkins server (`/var/lib/jenkins/casc-secrets/`) | generated on the server through the SonarQube API | not needed by humans |
| Postgres password (SonarQube DB) | `/opt/sonarqube/.env` on the server | generated on the server | not needed by humans |
| Argo CD `admin` password | Kubernetes secret `argocd-initial-admin-secret` | Argo CD | `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" \| base64 -d` |
| AWS keys for `claude_user` | your PC, `~/.aws/credentials` profile `cicd` | **You** (`aws configure --profile cicd`) | - |

Rules followed throughout: no secret in Git, chat or Jenkins logs; Claude never read or typed a password or token. The setup script turns off shell tracing (`set +x`) around everything secret.

---

## 9. Rebuild from scratch

About 20 minutes plus your one-time checks. Run from `C:\Devops\cicdpipeline_project` (Git Bash).

### Before you start (one time / check)

- [ ] `aws sts get-caller-identity --profile cicd` shows `user/claude_user`
- [ ] `gh auth status` is logged in
- [ ] Parameter Store `/cicd/github-deploy-token` holds a **valid** token (`github_pat_...` with *Contents: Read and write* on `cicdpipeline_deployment`)
- [ ] Your current IP: `curl https://checkip.amazonaws.com`

> **Git Bash tip:** Git Bash rewrites arguments starting with `/` (like `/cicd/...`) into Windows paths. Run `export MSYS_NO_PATHCONV=1` before any `aws ssm ... /cicd/...` command.

### Steps

```bash
# 1. Infrastructure (~15 min, EKS is the slow part)
cd devops/terraform
echo 'admin_cidr = "<YOUR-IP>/32"' > cicd.auto.tfvars
terraform init
terraform plan -out=tfplan
terraform apply tfplan
terraform output                       # Jenkins/SonarQube URLs, kubeconfig command

# 2. kubectl
aws eks update-kubeconfig --name cicd-eks --region ap-south-1 --profile cicd
kubectl get nodes                      # 2 x Ready

# 3. Argo CD + the app
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.6.1/manifests/install.yaml
kubectl -n argocd rollout status deploy --timeout=300s
kubectl apply -f ../../../cicdpipeline_deployment/argocd/application.yaml

# 4. Jenkins sets itself up (~8-10 min after the EC2 starts). Check:
#    EC2 -> cicd-dev-jenkins -> Connect -> Session Manager:
#      cat /var/lib/cicd-setup-done      (success)   or
#      cat /var/lib/cicd-setup-failed    (shows the failing line)

# 5. First build: open Jenkins -> cicd-app -> Build Now
#    (Poll SCM switches on after the first build has read the Jenkinsfile)

# 6. App URL
kubectl get svc cicd-app -n cicd-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

**Expected after a rebuild:**
- Until the first build, the pods show `ImagePullBackOff`. `newTag` in the deploy repo points at an image that was deleted with ECR. The first green build fixes it.
- Jenkins, SonarQube and the LoadBalancer get **new** addresses.
- The Jenkins admin password stays the same (reused from Parameter Store). The SonarQube password is regenerated.

---

## 10. Day-to-day operations

| Task | How |
|---|---|
| Ship a change | edit code → `git commit -am "..." && git push` → wait ~4-5 min |
| Watch a build | Jenkins → `cicd-app` → build → *Console Output* / Stage View |
| See code quality | SonarQube → project `cicd-app` |
| See deployment status | `kubectl port-forward svc/argocd-server -n argocd 8443:443` → https://localhost:8443 |
| **Roll back** | in `cicdpipeline_deployment`: `git revert <jenkins commit> && git push`; Argo CD rolls back within ~3 min, no rebuild |
| Force an Argo CD sync | Argo CD UI → `cicd-app` → *Sync*, or `kubectl -n argocd annotate application cicd-app argocd.argoproj.io/refresh=hard --overwrite` |
| Your IP changed | update `cicd.auto.tfvars` → `terraform plan -out=tfplan && terraform apply tfplan` (only the SG + EKS CIDR change) |
| Rotate the GitHub token | update `/cicd/github-deploy-token`, then on the server: rewrite `/var/lib/jenkins/casc-secrets/GITHUB_DEPLOY_TOKEN` from Parameter Store and `POST /configuration-as-code/reload` (or just rebuild the EC2) |
| Shell on the Jenkins server | EC2 console → Connect → Session Manager (no SSH) |
| Setup log | `/var/log/jenkins-setup.log` on the server |
| See pods/nodes in the AWS console | the account root already has read-only view; add other ARNs to `console_viewer_arns` |

---

## 11. Teardown (order matters)

The app's load balancer is created **by Kubernetes**, not Terraform. If Terraform goes first, the ELB is left behind, keeps billing and blocks the VPC from being deleted.

```bash
# 1. Make sure Jenkins is idle (no build running)
# 2. Remove the app; Argo CD's finalizer deletes the Service, and so the ELB
kubectl delete application cicd-app -n argocd --wait=true
kubectl get svc -A | grep LoadBalancer                    # must print nothing
aws elb describe-load-balancers --profile cicd --region ap-south-1 \
  --query 'length(LoadBalancerDescriptions)'              # 0

# 3. Everything else
cd devops/terraform
terraform destroy

# 4. Check nothing is left billing
aws eks list-clusters --profile cicd --region ap-south-1
aws ec2 describe-instances --profile cicd --region ap-south-1 \
  --filters Name=instance-state-name,Values=running,pending,stopped \
  --query 'Reservations[].Instances[].InstanceId'
```

**Kept on purpose:** S3 state bucket (cents/month) and the 3 Parameter Store parameters (standard tier, free). Delete them manually if you're finished for good.

---

## 12. Problems we hit and how they were fixed

| # | Symptom | Root cause | Fix |
|---|---|---|---|
| 1 | IAM console: *"policy exceeds the non-whitespace character limit of 2048"* | The limit covers **all inline policies** on a user together | Compacted with wildcards (`iam:*Role*` etc.); for more room use a **customer managed** policy (6,144 chars) |
| 2 | Node group: *"Failed to validate if SLR AWSServiceRoleForAmazonEKSNodegroup already exists due to missing permissions for iam:GetRole"* | Policy only allowed role actions on `role/cicd-*`; service-linked roles live under `role/aws-service-role/` | Added `ReadServiceLinkedRoles` (`iam:GetRole` on `role/aws-service-role/*`) |
| 3 | `aws ssm get-parameter --name /cicd/...` → *ParameterNotFound* from Git Bash | Git Bash (MSYS) turns `/cicd/x` into `C:/Program Files/Git/cicd/x` | `export MSYS_NO_PATHCONV=1` |
| 4 | Jenkins setup script stopped; Jenkins never started | SonarQube rejects webhook URLs on private IPs (`172.17.0.1`, the Docker host) as SSRF protection | `SONAR_VALIDATEWEBHOOKS=false` in the SonarQube container (it's reachable only from the admin IP) |
| 5 | That failure went unnoticed for a long time | The script only wrote a success marker; the wait loop never saw a failure | `trap ... ERR` writes `/var/lib/cicd-setup-failed` with the failing line; wait loops stop on success **or** failure, with a time limit |
| 6 | Build #1: Trivy failed (2 HIGH) | CVE-2026-109518 in `apt`/`libapt-pkg7.0` 3.0.3 in the official python base image; fix 3.0.4 was in Debian but not yet in the image | Upgrade just those two packages in the Dockerfile (comment says to remove once the base image includes it) |
| 7 | `devops/jenkins/casc.yaml` missing from Git | `.gitignore` rule `jenkins/` (meant for an old root folder) matched every `jenkins/` folder | Changed to `/jenkins/` (root only) |
| 8 | Builds #2/#3: *"Invalid username or token"* on push to the deploy repo | Parameter Store value was the **repo name**, not the token (spotted because Jenkins masked the repo name in the log, which only happens for secret values) | Saved the real token, reloaded JCasC; build #4 green |
| 9 | AWS console → EKS → Pods/Nodes: *"Data unavailable"* | Console user (root) had no **EKS access entry**; only the cluster creator had Kubernetes access | Terraform `aws_eks_access_entry` + `AmazonEKSAdminViewPolicy` for root (read-only) |
| 10 | AWS CLI on Windows: *"'charmap' codec can't encode character"* | Trivy's box-drawing characters vs the Windows console code page | `export PYTHONIOENCODING=utf-8 PYTHONUTF8=1` |

---

## 13. Cost

| Item | ~USD/hour |
|---|---|
| EKS control plane | 0.10 |
| 2 x t3.large nodes | 0.18 |
| 1 x t3.large Jenkins/SonarQube | 0.09 |
| Classic Load Balancer | 0.03 |
| EBS 3 x 30 GB gp3 | ~0.01 |
| **Total while running** | **~0.40 / hour (~$10/day)** |

Not free tier. Destroy after each session. The project ran for roughly 3 hours; check **Billing → Cost Explorer** for the exact amount. Set an **AWS Budget alert** (for example $20) from the root account.

---

## 14. Security notes and next improvements

**Already in place:** non-root containers, read-only root filesystem, dropped capabilities, seccomp; IMDSv2; no SSH; Jenkins, SonarQube and EKS API limited to one IP; instance role instead of keys; secrets in Parameter Store; ECR immutable tags + scan on push; Trivy gate; SonarQube quality gate; least-privilege ECR push (one repo); state bucket encrypted and private.

**Do next:**
1. **Replace the GitHub token.** The one used was a *classic* token with admin rights. Create a fine-grained one (only `cicdpipeline_deployment`, Contents: Read and write) and **revoke the classic one** on GitHub.
2. **Reduce the `gh` CLI token scopes.** It had `delete_repo`, `admin:org`, `admin:enterprise`. Re-login with `repo`, `read:org`, `workflow` only.
3. Skip CI for non-app changes: add a `when { changeset ... }` / path filter so Terraform or doc commits don't rebuild the image.
4. Private subnets + NAT Gateway (or VPC endpoints) for nodes in a real environment.
5. HTTPS for the app: AWS Load Balancer Controller + ALB + ACM certificate.
6. Run builds on agents instead of the built-in node; back up `JENKINS_HOME`.
7. Argo CD: change the initial admin password, or connect SSO.
8. AWS Budget alarm and EKS control-plane logging.

---

## 15. Leftovers outside this project

Found during the project, left untouched (not created by it):

- Security group `sg-00289cfdb84802e4c` (`k8s-elb-aecd2ace...`) in the **default VPC**, tagged for an old cluster `alpha-eks` / service `lwm-alpha-svc`. It's free; delete it from the EC2 console if that old project is gone.
- Old GitHub repos `sourcecoderepo` and `deploymentrepo`.
- Local: branch `master` and remote `old-origin` in `C:\Devops\cicdpipeline_project`, and the old `jenkins/` folder (git-ignored).

---

## 16. Reusable prompts for Claude

### A. Rebuild *this* project

```text
Rebuild my CI/CD learning project from code. Everything is already in Git.

Repos (local + GitHub, public):
- C:\Devops\cicdpipeline_project  (app + devops/: Dockerfile, Jenkinsfile, JCasC, setup script, Terraform)
- C:\Devops\cicdpipeline_deployment (k8s/ Kustomize manifests + argocd/application.yaml)
Read docs/CICD-PIPELINE-PROJECT.md first; follow its "Rebuild from scratch" section.

Environment: Windows + Git Bash. AWS CLI profile "cicd" (IAM user claude_user), region ap-south-1.
GitHub CLI is logged in as aravindrajsaravanan. The GitHub token for Jenkins is already in
Parameter Store /cicd/github-deploy-token (never read or print its value).

You may run terraform plan/apply/destroy for this project. Before apply, show me the
plan summary and call out anything destroyed or replaced.

Steps: confirm aws/gh identity and my current IP, update cicd.auto.tfvars, terraform apply,
kubeconfig, install Argo CD v3.6.1, apply the Argo CD Application, wait for the Jenkins
setup marker (stop on /var/lib/cicd-setup-failed and show the line), trigger the first build
through SSM + /usr/local/bin/cicd-jenkins-api, follow it to green, wait for Argo CD
Synced/Healthy, and curl the LoadBalancer URL. Report every URL at the end.
Remind me of cost (~$0.40/hour) and offer teardown (Argo CD app first, then terraform destroy).
```

### B. Build a *new* project the same way

```text
Build a complete CI/CD pipeline for my app at <C:\path\to\project> for learning.
First give me a plan and the list of access you need from me; wait for my OK before creating anything.

Stack (same as my previous project, see C:\Devops\cicdpipeline_project\docs\CICD-PIPELINE-PROJECT.md):
- 2 new PUBLIC GitHub repos: <app-repo> (code + devops/ folder) and <app>-deployment (GitOps)
- Jenkins + SonarQube (Docker) on one EC2 t3.large, Ubuntu 24.04, configured fully as code (JCasC):
  plugins, admin user, credentials, SonarQube server + webhook, pipeline job; Poll SCM
- Pipeline: lint -> tests with coverage -> SonarQube + quality gate -> Docker build ->
  Trivy (fail on fixable HIGH/CRITICAL) -> push to ECR (tag <build>-<sha>) -> commit new tag to deployment repo
- Argo CD in EKS watches the deployment repo (auto-sync, prune, self-heal); Service type LoadBalancer
- EKS: managed node group <N> x <instance type>, <disk> GB; public subnets, no NAT (learning)
- Terraform for everything (S3 backend with native locking), region ap-south-1 (Mumbai)
- Secrets only in Parameter Store /<project>/*; I add the GitHub token myself. Never ask me
  for passwords or tokens in chat. Jenkins uses an EC2 instance role, not AWS keys.
- Access: Jenkins/SonarQube/EKS API only from my IP; SSM Session Manager, no SSH.
- Give my AWS console root user read-only EKS view (access entry).

Rules: you may run terraform apply/destroy for this project (show the plan summary first).
Pin exact versions (check the latest first). Tell me about issues before they happen
(cost, IAM gaps, limits). Keep a task list, verify each step, and at the end write a document
like docs/CICD-PIPELINE-PROJECT.md, then offer teardown (Kubernetes LoadBalancer first,
then terraform destroy).

Known gotchas to handle up front: IAM inline-policy 2,048-char limit; EKS node group needs
iam:GetRole on role/aws-service-role/*; Git Bash needs MSYS_NO_PATHCONV=1 for /paths;
SonarQube needs SONAR_VALIDATEWEBHOOKS=false for a Docker-host webhook; Jenkins setup must
write a failure marker; .gitignore patterns must not match devops/ subfolders.
```

### C. Just tear it down

```text
Tear down my CI/CD learning project (C:\Devops\cicdpipeline_project, AWS profile cicd, ap-south-1).
Check Jenkins is idle, delete the Argo CD Application cicd-app and confirm the Kubernetes
LoadBalancer and its ELB are gone, then terraform destroy in devops/terraform. Verify no EKS,
EC2, ELB, ECR or VPC from the project remains. Keep the S3 state bucket and /cicd/* parameters.
```
