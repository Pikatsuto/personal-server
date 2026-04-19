#!/usr/bin/env bash
# Pangolin configure.sh — called by the wizard at first-boot.
#
# render-all-units.sh (which runs at every boot BEFORE services) handles
# rendering the compose + config .tmpl files with IMAGE_*_REF, PS_DOMAIN,
# PS_PANGOLIN_SECRET, PS_BADGER_VERSION, etc. So configure.sh only needs to:
#   1. Create acme.env from the DNS provider credentials
#   2. Ensure the letsencrypt storage directory exists
#   3. Enable + start the systemd unit
#   4. Display the setup token for initial admin creation
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

# Create the Docker network if it doesn't exist (Pangolin compose expects it)
docker network create coolify 2>/dev/null || true

systemctl daemon-reload
systemctl enable --now personal-server-pangolin.service

# Wait until Pangolin's API responds (inside the container)
for _ in $(seq 1 60); do
  docker exec pangolin curl -fsS http://localhost:3001/api/v1/ >/dev/null 2>&1 && break
  sleep 2
done

# Save the setup token so the checklist can display it
SETUP_TOKEN=$(docker logs pangolin 2>&1 | grep -A1 "SETUP TOKEN" | grep "Token:" | awk '{print $2}')
if [[ -n $SETUP_TOKEN ]]; then
  echo "$SETUP_TOKEN" > /etc/personal-server/pangolin-setup-token
  chmod 600 /etc/personal-server/pangolin-setup-token
fi
