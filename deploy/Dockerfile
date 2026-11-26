# syntax=docker/dockerfile:1
FROM node:24-alpine AS frontend
WORKDIR /web
COPY frontend/package*.json ./
RUN --mount=type=secret,id=build_ca \
    if [ -f /run/secrets/build_ca ]; then export NODE_EXTRA_CA_CERTS=/run/secrets/build_ca; fi; \
    npm ci --no-audit --no-fund
COPY frontend/ ./
RUN npm run build

FROM python:3.12-slim AS python-builder
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends pkg-config build-essential libcairo2-dev \
    && rm -rf /var/lib/apt/lists/*
RUN --mount=type=secret,id=build_ca \
    if [ -f /run/secrets/build_ca ]; then export PIP_CERT=/run/secrets/build_ca; fi; \
    pip install --no-cache-dir uv
ENV UV_PROJECT_ENVIRONMENT=/opt/venv
COPY pyproject.toml uv.lock ./
RUN --mount=type=secret,id=build_ca \
    if [ -f /run/secrets/build_ca ]; then export SSL_CERT_FILE=/run/secrets/build_ca; fi; \
    uv sync --no-cache --frozen

FROM python:3.12-slim
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends libcairo2 nginx supervisor \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -m appuser
COPY --from=python-builder /opt/venv /opt/venv
COPY . .
COPY --from=frontend /web/dist /usr/share/nginx/html
COPY deploy/nginx.conf /etc/nginx/nginx.conf
COPY deploy/supervisord.conf /etc/supervisor/chatdev.conf
RUN mkdir -p /app/data /app/WareHouse /app/logs /app/temp \
    && chown -R appuser:appuser /app \
    && chmod 644 /etc/nginx/nginx.conf /etc/supervisor/chatdev.conf \
    && chmod -R a+rX /usr/share/nginx/html
ENV PATH="/opt/venv/bin:${PATH}" PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
USER appuser
EXPOSE 8080
HEALTHCHECK --interval=15s --timeout=6s --start-period=30s --retries=8 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/health/ready', timeout=5)"
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/chatdev.conf"]
