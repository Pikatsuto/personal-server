#!/usr/bin/env bash
# Renders /etc/personal-server/pocketid.env from wizard answers and starts
# the container. Env var names verified 2026-04-11 against
# github.com/pocket-id/pocket-id .env.example.
#
# OIDC client creation for Pangolin is intentionally NOT done here:
# PocketID's first admin (and the API key needed to call POST /api/oidc/clients
# with the X-API-Key header) must be created via the web UI. The wizard's
# checklist tells the operator to do that, then run
# `personal-server reconfigure` which re-runs apply-domain.sh.
set -euo pipefail

DOMAIN=$(yq -r '.domain' /etc/personal-server/domain.yaml)
ENV_FILE=/etc/personal-server/pocketid.env

if [[ ! -f $ENV_FILE ]]; then
  install -d -m 0700 /etc/personal-server
  umask 077
  cat > "$ENV_FILE" <<EOF
APP_URL=https://pocketid.${DOMAIN}
ENCRYPTION_KEY=$(openssl rand -base64 32)
TRUST_PROXY=true
PUID=0
PGID=0
EOF
fi

install -d -m 0755 /var/lib/personal-server/pocketid
docker network create coolify 2>/dev/null || true
systemctl enable --now personal-server-pocketid.service
