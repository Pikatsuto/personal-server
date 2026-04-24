#!/usr/bin/env bash
# Coolify first-boot configure. The Coolify installer at
# https://cdn.coollabs.io/coolify/install.sh accepts only env vars (no flags),
# verified 2026-04-11 from the installer source. Useful env vars:
#   ROOT_USERNAME / ROOT_USER_EMAIL / ROOT_USER_PASSWORD  → pre-create admin
#   AUTOUPDATE=false                                       → we run watchtower
#   REGISTRY_URL                                           → ghcr.io default OK
#
# Joins the shared `coolify` Docker network. Our Traefik discovers Coolify-
# deployed apps via traefik.* labels on this network.
set -euo pipefail

DOMAIN=${PS_DOMAIN:?PS_DOMAIN must be set by the wizard}
ADMIN_USER=${PS_ADMIN_USERNAME:?PS_ADMIN_USERNAME must be set by the wizard}
ADMIN_EMAIL=${PS_ADMIN_EMAIL:?PS_ADMIN_EMAIL must be set by the wizard}
ADMIN_PASS=${PS_ADMIN_PASSWORD:?PS_ADMIN_PASSWORD must be set by the wizard}

# Record the Coolify URL + admin username for the wizard summary.
# Password is the one the operator entered — we don't re-log it.
install -d -m 0700 /etc/personal-server
umask 077
cat > /etc/personal-server/coolify-root.txt <<EOF
COOLIFY_URL=https://coolify.${DOMAIN}
COOLIFY_USERNAME=${ADMIN_USER}
COOLIFY_EMAIL=${ADMIN_EMAIL}
EOF

docker network create coolify 2>/dev/null || true

if [[ ! -f /data/coolify/source/.env ]]; then
  # Coolify manages its own updates (DB schema migrations between versions
  # need its own runner; watchtower would corrupt state). We therefore
  # leave AUTOUPDATE=true and exclude Coolify's containers from watchtower
  # via labels — see services/watchtower/files/systemd/.
  ROOT_USERNAME="$ADMIN_USER" \
  ROOT_USER_EMAIL="$ADMIN_EMAIL" \
  ROOT_USER_PASSWORD="$ADMIN_PASS" \
  AUTOUPDATE=true \
    bash -c 'curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash'
fi

# Patch APP_URL to match the operator's domain (the installer leaves a default).
sed -i "s|^APP_URL=.*|APP_URL=https://coolify.${DOMAIN}|" /data/coolify/source/.env

# SELinux: label /var/lib/coolify so systemd can chdir into it
semanage fcontext -a -t container_file_t '/var/lib/coolify(/.*)?' 2>/dev/null || true
restorecon -Rv /var/lib/coolify 2>/dev/null || true

systemctl daemon-reload
systemctl enable --now personal-server-coolify.service
