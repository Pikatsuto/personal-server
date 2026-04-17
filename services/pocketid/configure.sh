#!/usr/bin/env bash
# PocketID configure.sh — called by the wizard.
# The ENCRYPTION_KEY comes from service.yaml's secrets: block, auto-generated
# by render-all-units.sh and available as PS_POCKETID_ENCRYPTION_KEY in env.
set -euo pipefail

DOMAIN=${PS_DOMAIN:?PS_DOMAIN must be set by the wizard}
ENCRYPTION_KEY=${PS_POCKETID_ENCRYPTION_KEY:?must be set by render-all-units}
ENV_FILE=/etc/personal-server/pocketid.env

if [[ ! -f $ENV_FILE ]]; then
  install -d -m 0700 /etc/personal-server
  umask 077
  cat > "$ENV_FILE" <<EOF
APP_URL=https://pocketid.${DOMAIN}
ENCRYPTION_KEY=${ENCRYPTION_KEY}
TRUST_PROXY=true
PUID=0
PGID=0
EOF
fi

install -d -m 0755 /var/lib/personal-server/pocketid
# Network `coolify` is created by pangolin's compose (depends_on: pangolin).
systemctl enable --now personal-server-pocketid.service
