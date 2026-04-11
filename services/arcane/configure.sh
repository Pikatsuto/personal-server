#!/usr/bin/env bash
# Generates /etc/personal-server/arcane.env on first boot with secure random
# secrets, then enables the service. Required env vars verified 2026-04-11
# against getarcane.app/docs/setup/installation.
set -euo pipefail

DOMAIN=$(yq -r '.domain' /etc/personal-server/domain.yaml)
ENV_FILE=/etc/personal-server/arcane.env

if [[ ! -f $ENV_FILE ]]; then
  install -d -m 0755 /etc/personal-server
  umask 077
  cat > "$ENV_FILE" <<EOF
APP_URL=https://docker.${DOMAIN}
ENCRYPTION_KEY=$(openssl rand -hex 32)
JWT_SECRET=$(openssl rand -hex 32)
PUID=0
PGID=0
EOF
fi

install -d -m 0755 /var/lib/personal-server/arcane
docker network create coolify 2>/dev/null || true
systemctl enable --now personal-server-arcane.service
