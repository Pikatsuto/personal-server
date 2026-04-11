#!/usr/bin/env bash
# Renders Pangolin templates from the wizard answers and brings up the stack.
# Does NOT attempt to create an admin or API key automatically — Pangolin's
# bootstrap is interactive, the wizard's checklist tells the operator what to
# do once Pangolin is up.
#
# Versions pinned 2026-04-11 from upstream releases:
#   pangolin=1.17.0  gerbil=1.3.1  badger=v1.4.0  traefik=v3.6
set -euo pipefail

PANGOLIN_DIR=/opt/personal-server/pangolin
CONF_DIR=/etc/personal-server

PS_PANGOLIN_VERSION=${PS_PANGOLIN_VERSION:-1.17.0}
PS_GERBIL_VERSION=${PS_GERBIL_VERSION:-1.3.1}
PS_BADGER_VERSION=${PS_BADGER_VERSION:-v1.4.0}

PS_DOMAIN=$(yq -r '.domain' "$CONF_DIR/domain.yaml")
PS_ACME_EMAIL=$(yq -r '.acme_email' "$CONF_DIR/domain.yaml")
PS_ACME_DNS_PROVIDER=$(yq -r '.acme_dns_provider' "$CONF_DIR/domain.yaml")
export PS_DOMAIN PS_ACME_EMAIL PS_ACME_DNS_PROVIDER \
       PS_PANGOLIN_VERSION PS_GERBIL_VERSION PS_BADGER_VERSION

# Persist server.secret across reboots.
SECRET_FILE=$CONF_DIR/pangolin-server-secret
if [[ ! -f $SECRET_FILE ]]; then
  umask 077
  openssl rand -hex 32 > "$SECRET_FILE"
fi
PS_PANGOLIN_SECRET=$(<"$SECRET_FILE")
export PS_PANGOLIN_SECRET

# Render every .tmpl in /opt/personal-server/pangolin into the matching file
# (drop the .tmpl suffix). Fully generic — no service name hardcoded.
while IFS= read -r tmpl; do
  out=${tmpl%.tmpl}
  install -d -m 0755 "$(dirname "$out")"
  envsubst < "$tmpl" > "$out"
done < <(find "$PANGOLIN_DIR" -type f -name '*.tmpl')

# Render acme.env from /etc/personal-server/acme.yaml — every key:value
# becomes a docker env var Lego will read for the dnsChallenge.
ACME_ENV=$PANGOLIN_DIR/acme.env
: > "$ACME_ENV"
chmod 600 "$ACME_ENV"
yq -r 'to_entries | .[] | "\(.key)=\(.value)"' "$CONF_DIR/acme.yaml" >> "$ACME_ENV"

install -d -m 0755 \
  "$PANGOLIN_DIR/config/letsencrypt" \
  "$PANGOLIN_DIR/config/traefik/logs"
touch "$PANGOLIN_DIR/config/letsencrypt/acme.json"
chmod 600 "$PANGOLIN_DIR/config/letsencrypt/acme.json"

systemctl daemon-reload
systemctl enable --now personal-server-pangolin.service

# Wait until Pangolin's API responds. Healthcheck endpoint verified
# 2026-04-11 in upstream install/config/docker-compose.yml.
for _ in $(seq 1 60); do
  curl -fsS http://localhost:3001/api/v1/ >/dev/null 2>&1 && break
  sleep 2
done
