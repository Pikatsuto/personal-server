#!/usr/bin/env bash
# Pangolin configure.sh — called by the wizard at first-boot.
#
# render-all-units.sh (which runs at every boot BEFORE services) handles
# rendering the compose + config .tmpl files with IMAGE_*_REF, PS_DOMAIN,
# PS_PANGOLIN_SECRET, etc. So configure.sh only needs to:
#   1. Create acme.env from the DNS provider credentials
#   2. Ensure the letsencrypt storage directory exists
#   3. Enable + start the systemd unit
set -euo pipefail

PANGOLIN_DIR=/var/lib/personal-server/pangolin
CONF_DIR=/etc/personal-server

# Render acme.env from the credentials file (written by the wizard's
# secret_map question collection).
ACME_ENV=$PANGOLIN_DIR/acme.env
: > "$ACME_ENV"
chmod 600 "$ACME_ENV"
CREDS_FILE=$CONF_DIR/acme-credentials.yaml
if [[ -f $CREDS_FILE ]] && [[ $(yq 'length' "$CREDS_FILE") -gt 0 ]]; then
  yq -r 'to_entries[] | "\(.key)=\(.value)"' "$CREDS_FILE" >> "$ACME_ENV"
fi

install -d -m 0755 \
  "$PANGOLIN_DIR/config/letsencrypt" \
  "$PANGOLIN_DIR/config/traefik/logs"
touch "$PANGOLIN_DIR/config/letsencrypt/acme.json"
chmod 600 "$PANGOLIN_DIR/config/letsencrypt/acme.json"

systemctl daemon-reload
systemctl enable --now personal-server-pangolin.service

# Wait until Pangolin's API responds.
for _ in $(seq 1 60); do
  curl -fsS http://localhost:3001/api/v1/ >/dev/null 2>&1 && break
  sleep 2
done
