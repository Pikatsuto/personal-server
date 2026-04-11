#!/usr/bin/env bash
# Non-interactive Incus init via `incus admin init --preseed`. The preseed YAML
# is the official method (verified 2026-04-11 on linuxcontainers.org/incus/docs
# /main/howto/initialize/) and lets us defer storage_pools entirely when no
# ZFS pool was selected at first-boot — the user can run
# `personal-server move incus <pool>` later.
set -euo pipefail

systemctl enable --now incus.socket incus.service

# Wait for the daemon to be reachable.
for _ in $(seq 1 30); do
  incus info >/dev/null 2>&1 && break
  sleep 1
done

# If init has already run, just make sure the HTTPS UI is exposed and exit.
if incus storage list -f csv 2>/dev/null | grep -q .; then
  incus config set core.https_address ":8443" || true
  exit 0
fi

POOL=${PS_POOL:-}
PRESEED=$(mktemp)
trap 'rm -f "$PRESEED"' EXIT

{
  echo "config:"
  echo "  core.https_address: \":8443\""
  if [[ -n $POOL ]]; then
    DATASET="$POOL/personal-server/incus"
    zfs list -H -o name "$DATASET" >/dev/null 2>&1 || zfs create -p "$DATASET"
    cat <<YAML
storage_pools:
  - name: default
    driver: zfs
    config:
      source: $DATASET
YAML
  fi
  cat <<'YAML'
networks:
  - name: incusbr0
    type: bridge
    config:
      ipv4.address: auto
      ipv6.address: none
profiles:
  - name: default
    devices:
      eth0:
        type: nic
        nictype: bridged
        parent: incusbr0
YAML
  if [[ -n $POOL ]]; then
    cat <<'YAML'
      root:
        path: /
        pool: default
        type: disk
YAML
  fi
} > "$PRESEED"

incus admin init --preseed < "$PRESEED"

if [[ -n $POOL ]]; then
  yq -i ".incus = \"$DATASET\"" /etc/personal-server/storage.yaml
fi
