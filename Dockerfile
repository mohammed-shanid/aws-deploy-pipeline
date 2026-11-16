# syntax=docker/dockerfile:1
# App image. Release tag = full git SHA (deployment.md §1); the deploy passes
# GIT_SHA, APP_ENV and DEMO_SECRET at run time. Nothing secret is baked in.
#
# Base: python:3.12.14-slim-trixie, pinned by digest (checked 2026-11-13).
# To update: docker pull the tag, read the new digest, rebuild, re-run Trivy.
ARG PYTHON_IMAGE=python:3.12.14-slim-trixie@sha256:f77ac9e44ae96ef2c90b8053ea08c31f8be030f824196b0ae4db6d462c84e51f

# ---- build stage: install pinned dependencies into a virtualenv
FROM ${PYTHON_IMAGE} AS build
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
RUN python -m venv /opt/venv
COPY requirements.txt /tmp/requirements.txt
RUN /opt/venv/bin/pip install --no-deps -r /tmp/requirements.txt \
    && /opt/venv/bin/pip check \
    # pip is not needed at run time; removing it shrinks the attack surface.
    && /opt/venv/bin/pip uninstall -y pip

# ---- runtime stage: the virtualenv and the app, nothing else
FROM ${PYTHON_IMAGE}
# Security fixes Debian has published since the base image was built. This makes
# the OS layer depend on the build date; the trade-off is recorded in
# docs/architecture/security.md §6. The system pip is unused (the app runs from
# the virtualenv), so it is removed.
RUN apt-get update \
    && apt-get upgrade -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/* \
    && python -m pip uninstall -y pip
RUN groupadd --system --gid 10001 app \
    && useradd --system --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app
COPY --from=build /opt/venv /opt/venv
WORKDIR /srv
COPY app/ ./app/

# `python` on PATH is the virtualenv's. HOST must be 0.0.0.0 inside a container
# so the published port works; the host publishes it on 127.0.0.1 only.
ENV PATH=/opt/venv/bin:$PATH \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    HOST=0.0.0.0 \
    PORT=8000
EXPOSE 8000
USER 10001:10001

# 200 = healthy; a 503 (still starting), 500 or timeout raises and exits 1.
HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=3 \
    CMD ["python", "-c", "import os, urllib.request; urllib.request.urlopen('http://127.0.0.1:' + os.environ.get('PORT', '8000') + '/health', timeout=2)"]

# Exec form: the app is PID 1 and receives SIGTERM directly (10 s graceful window).
STOPSIGNAL SIGTERM
ENTRYPOINT ["python", "-m", "app"]
