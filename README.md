# cicdpipeline_project

A small FastAPI app used to learn an end-to-end CI/CD pipeline on AWS.

```
git push ──► Jenkins (EC2) ──► SonarQube ──► Docker build ──► Trivy ──► ECR
                                                                      │
             EKS ◄── Argo CD sync ◄── cicdpipeline_deployment ◄───────┘ (Jenkins commits new image tag)
```

## Layout

```
main.py, form.html          app source
requirements.txt            runtime dependencies
requirements-dev.txt        test / lint tools
tests/                      pytest tests
devops/
  Dockerfile                multi-stage, non-root, port 8000
  Dockerfile.dockerignore
  Jenkinsfile               the CI pipeline (Script Path: devops/Jenkinsfile)
  sonar-project.properties
```

Kubernetes manifests live in the separate GitOps repo
[cicdpipeline_deployment](https://github.com/aravindrajsaravanan/cicdpipeline_deployment).

## Run locally

```bash
python -m venv .venv
.venv\Scripts\activate          # Windows (Linux/macOS: source .venv/bin/activate)
pip install -r requirements.txt -r requirements-dev.txt
uvicorn main:app --reload        # http://localhost:8000
pytest --cov=.
```

## Run in Docker

```bash
docker build -f devops/Dockerfile -t cicd-app:dev .
docker run --rm -p 8000:8000 cicd-app:dev
```

## Pipeline stages (devops/Jenkinsfile)

| Stage | What it does |
|---|---|
| Checkout | Pulls code, sets image tag `<build>-<git sha>` |
| Lint & Test | `ruff` + `pytest` with coverage |
| SonarQube Analysis | Sends code + coverage to SonarQube |
| Quality Gate | Waits for SonarQube's verdict, fails the build if the gate fails |
| Docker Build | Builds the image from `devops/Dockerfile` |
| Trivy Scan | Fails on fixable HIGH/CRITICAL vulnerabilities |
| Push to ECR | Pushes using the EC2 instance role (no stored AWS keys) |
| Update Deployment Repo | Commits the new tag to the GitOps repo; Argo CD deploys it |
