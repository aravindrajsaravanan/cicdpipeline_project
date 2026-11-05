# Build from the repo root:  docker build -f devops/Dockerfile -t cicd-app:dev .

# ---- build stage: install dependencies ----
FROM python:3.12.16-slim-trixie AS build
WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# ---- runtime stage ----
FROM python:3.12.16-slim-trixie

LABEL org.opencontainers.image.source="https://github.com/aravindrajsaravanan/cicdpipeline_project" \
      org.opencontainers.image.title="cicd-app"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Security patch: CVE-2026-109518 (apt 3.0.3, HIGH). Upgrade only the affected packages
# until the official python image ships apt >= 3.0.4. Remove this line once it does.
RUN apt-get update \
 && apt-get install -y --no-install-recommends --only-upgrade apt libapt-pkg7.0 \
 && rm -rf /var/lib/apt/lists/*

RUN groupadd --gid 10001 app \
 && useradd --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app

WORKDIR /code
COPY --from=build /install /usr/local
COPY --chown=app:app main.py form.html ./

USER 10001
EXPOSE 8000

# Runs on Kubernetes, so liveness/readiness probes replace a Docker HEALTHCHECK.
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
