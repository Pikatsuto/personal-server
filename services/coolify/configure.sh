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

# SELinux: label the real Coolify data tree BEFORE the installer runs.
# install.sh symlinks /data → /var/lib/coolify (bootc /data is read-only),
# so /data/coolify resolves canonically to /var/lib/coolify/coolify.
# The installer mounts /data/coolify/ssh/keys into a container to generate
# SSH keys; without container_file_t on the real path the write is denied.
# semanage fcontext rules apply to canonical paths, so we label the symlink
# target, not the symlink itself.
semanage fcontext -a -t container_file_t '/var/lib/coolify(/.*)?' 2>/dev/null || true
restorecon -Rv /var/lib/coolify 2>/dev/null || true

if [[ ! -f /data/coolify/source/.env ]]; then
  # The Coolify installer (step 8/9) runs ssh-keygen to write to
  # /data/coolify/ssh/keys/id.$USER@host.docker.internal. That fails
  # silently in the wizard's systemd context (initrc_t): ssh-keygen
  # transitions to ssh_keygen_t domain whose policy forbids writing
  # container_file_t files — and the rule is dontaudit, so nothing
  # logs. Verified via `openssl genpkey` + plain `touch` etc. all
  # succeed in the same context; only ssh-keygen's transitioned domain
  # fails.
  #
  # Work around by generating the key in /tmp (ssh_keygen_tmp_t domain
  # is allowed there), moving it, and relabeling. Pre-create the
  # coolify-db docker volume so install.sh (~line 895) skips its own
  # keygen attempt (which would hit the same failure).
  export USER=root  # systemd strips $USER; installer uses it for the keyname
  install -d -m 0700 -o 9999 -g 0 /var/lib/coolify/coolify/ssh/keys
  COOLIFY_SSH_KEY=/var/lib/coolify/coolify/ssh/keys/id.${USER}@host.docker.internal
  if [[ ! -f $COOLIFY_SSH_KEY ]]; then
    TMPKEY=$(mktemp -u /tmp/ps-coolify-keygen.XXXXXX)
    ssh-keygen -t ed25519 -a 100 -f "$TMPKEY" -q -N "" -C coolify
    mv "$TMPKEY" "$COOLIFY_SSH_KEY"
    mv "${TMPKEY}.pub" "${COOLIFY_SSH_KEY}.pub"
    restorecon "$COOLIFY_SSH_KEY" "${COOLIFY_SSH_KEY}.pub"
    chown 9999:root "$COOLIFY_SSH_KEY" "${COOLIFY_SSH_KEY}.pub"
    chmod 600 "$COOLIFY_SSH_KEY"
    chmod 644 "${COOLIFY_SSH_KEY}.pub"
  fi
  install -d -m 0700 /root/.ssh
  [[ -f /root/.ssh/authorized_keys ]] || install -m 0600 /dev/null /root/.ssh/authorized_keys
  sed -i '/coolify/d' /root/.ssh/authorized_keys
  cat "${COOLIFY_SSH_KEY}.pub" >> /root/.ssh/authorized_keys
  docker volume create coolify-db >/dev/null

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

# Re-apply labels in case the installer created new files/dirs
restorecon -Rv /var/lib/coolify 2>/dev/null || true

systemctl daemon-reload
systemctl enable --now personal-server-coolify.service
