# =============================================================================
# OPENCLAW RAILWAY TEMPLATE
# Simple, secure deployment - uses official npm package
# =============================================================================

FROM node:22-bookworm

ARG OPENCLAW_VERSION=2026.5.3-1

# Install minimal runtime dependencies
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    procps \
  && rm -rf /var/lib/apt/lists/*

# Install the pinned OpenClaw runtime. Version bumps must go through the
# validation pipeline. Bun global installs currently place the binary outside
# this image's runtime PATH and block OpenClaw postinstalls, so the runtime
# package install stays on npm until OpenClaw supports Bun global installs here.
RUN npm install -g "openclaw@${OPENCLAW_VERSION}" \
  && openclaw --version

# Create non-root user
RUN groupadd -g 1001 openclaw \
  && useradd -u 1001 -g openclaw -m -s /bin/bash openclaw

# Create data directory structure
RUN mkdir -p /data/.openclaw /data/workspace \
  && chmod 700 /data/.openclaw \
  && chown -R openclaw:openclaw /data

# App directory for health server
WORKDIR /app

# Copy app files (health server, config builder, scripts)
COPY --chown=openclaw:openclaw package.json ./
COPY --chown=openclaw:openclaw src ./src
COPY --chown=openclaw:openclaw config ./config
COPY --chown=openclaw:openclaw docs ./docs
COPY --chown=openclaw:openclaw workspace ./workspace-templates
COPY --chown=openclaw:openclaw config-watcher.sh ./

# Entrypoint stays root-owned (runs as root, then switches to openclaw)
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh /app/config-watcher.sh

# Environment
ENV OPENCLAW_STATE_DIR=/data/.openclaw
ENV OPENCLAW_WORKSPACE_DIR=/data/workspace
ENV PORT=8080

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD curl -sf http://localhost:8080/healthz || exit 1

EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]
