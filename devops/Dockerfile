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

RUN groupadd --gid 10001 app \
 && useradd --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app

WORKDIR /code
COPY --from=build /install /usr/local
COPY --chown=app:app main.py form.html ./

USER 10001
EXPOSE 8000

# Runs on Kubernetes, so liveness/readiness probes replace a Docker HEALTHCHECK.
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
