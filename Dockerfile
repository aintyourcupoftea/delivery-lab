# syntax=docker/dockerfile:1.7
#
# Multi-stage build.
#   builder -> resolves and compiles wheels into a self-contained virtualenv
#   runtime -> copies only that virtualenv onto a clean slim base
#
# Why: build toolchains (gcc, pip cache, source trees) never reach the runtime
# image, so the attack surface and the image size both stay small.

########## builder ##########
FROM python:3.12-slim AS builder

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /build

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Dependencies are copied and installed BEFORE application source, so the
# expensive layer is only invalidated when requirements.txt actually changes.
COPY requirements.txt .

# BuildKit cache mount: pip's HTTP cache survives between builds without ever
# being baked into a layer.
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install -r requirements.txt

########## runtime ##########
FROM python:3.12-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH" \
    PORT=8080

# Dedicated unprivileged account. Fixed uid/gid so the same numeric identity
# is used whether or not /etc/passwd is readable (e.g. distroless-style hosts,
# or a Pod that overrides runAsUser).
RUN groupadd --system --gid 10001 app \
 && useradd --system --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app

COPY --from=builder /opt/venv /opt/venv

WORKDIR /app
COPY --chown=app:app app.py ./

USER 10001:10001

EXPOSE 8080

# No secrets are baked in. Anything sensitive arrives at runtime via env vars
# sourced from a Secret; anything needed at BUILD time would use
# `RUN --mount=type=secret,...` so it never lands in a layer.
#
# HEALTHCHECK is declared for plain `docker run`; Compose overrides it and
# Kubernetes ignores it entirely in favour of the probes in k8s/deployment.yaml.
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request,os,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:'+os.getenv('PORT','8080')+'/health/live', timeout=2).status==200 else 1)"

# Exec form: uvicorn becomes PID 1 and therefore receives SIGTERM directly.
CMD ["python", "app.py"]
