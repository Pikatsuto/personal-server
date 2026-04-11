#!/usr/bin/env bash
# If the wizard has assigned a pool to docker, create the dataset and rewrite
# data-root to point at it. Otherwise leave docker on the rootfs (the user can
# migrate later with `personal-server move docker <pool>`).
set -euo pipefail

POOL=${PS_POOL:-}
if [[ -z $POOL ]]; then
  systemctl enable --now docker.service docker.socket
  exit 0
fi

DATASET="$POOL/personal-server/docker"
zfs list -H -o name "$DATASET" >/dev/null 2>&1 || \
  zfs create -p -o mountpoint=/var/lib/docker "$DATASET"

cat > /etc/docker/daemon.json <<JSON
{
  "log-driver": "journald",
  "live-restore": true,
  "data-root": "/var/lib/docker",
  "storage-driver": "overlay2"
}
JSON

systemctl enable --now docker.service docker.socket
yq -i ".docker = \"$DATASET\"" /etc/personal-server/storage.yaml
