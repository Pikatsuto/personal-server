#!/usr/bin/env bash
# Coolify first-boot configure. The Coolify installer at
# https://cdn.coollabs.io/coolify/install.sh accepts only env vars (no flags),
# verified 2026-04-11 from the installer source. Useful env vars:
#   ROOT_USERNAME / ROOT_USER_EMAIL / ROOT_USER_PASSWORD  → pre-create admin
#   AUTOUPDATE=false                                       → we run watchtower
#   REGISTRY_URL                                           → ghcr.io default OK
#
# We rely on the shared `coolify` Docker network being already created by
# the Pangolin configure.sh (it names its compose network `coolify`). Coolify
# detects the existing network on first boot and joins it. After first boot,
# the operator must flip Server → Proxy → None in the UI (Coolify has no env
# var or installer flag for that — verified 2026-04-11).
set -euo pipefail

DOMAIN=$(yq -r '.domain' /etc/personal-server/domain.yaml)
ACME_EMAIL=$(yq -r '.acme_email' /etc/personal-server/domain.yaml)

# Pre-create the admin user so the operator can log in straight away.
COOLIFY_ROOT_FILE=/etc/personal-server/coolify-root.txt
if [[ ! -f $COOLIFY_ROOT_FILE ]]; then
  install -d -m 0700 /etc/personal-server
  umask 077
  ROOT_PASS=$(openssl rand -base64 24)
  cat > "$COOLIFY_ROOT_FILE" <<EOF
COOLIFY_ROOT_USERNAME=admin
COOLIFY_ROOT_USER_EMAIL=${ACME_EMAIL}
COOLIFY_ROOT_USER_PASSWORD=${ROOT_PASS}
EOF
fi
# shellcheck disable=SC1090
source "$COOLIFY_ROOT_FILE"

# Make sure the shared network exists before Coolify boots and tries to
# create one with the same name (Docker would dedup, but be explicit).
docker network create coolify 2>/dev/null || true

if [[ ! -f /data/coolify/source/.env ]]; then
  # Coolify manages its own updates (DB schema migrations between versions
  # need its own runner; watchtower would corrupt state). We therefore
  # leave AUTOUPDATE=true and exclude Coolify's containers from watchtower
  # via labels — see services/watchtower/files/systemd/.
  ROOT_USERNAME=$COOLIFY_ROOT_USERNAME \
  ROOT_USER_EMAIL=$COOLIFY_ROOT_USER_EMAIL \
  ROOT_USER_PASSWORD=$COOLIFY_ROOT_USER_PASSWORD \
  AUTOUPDATE=true \
    bash -c 'curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash'
fi

# Patch APP_URL to match the operator's domain (the installer leaves a default).
sed -i "s|^APP_URL=.*|APP_URL=https://coolify.${DOMAIN}|" /data/coolify/source/.env

systemctl daemon-reload
systemctl enable --now personal-server-coolify.service
