#!/usr/bin/env bash
# storage.sh — generic ZFS helpers used by bin/move-service-storage and the
# first-boot configure scripts. Pure bash + zfs/rsync, no per-service logic.

set -euo pipefail

storage_dataset_exists() {
  zfs list -H -o name "$1" >/dev/null 2>&1
}

storage_pool_exists() {
  zpool list -H -o name "$1" >/dev/null 2>&1
}

storage_create_dataset() {
  # storage_create_dataset <pool>/<path> <mountpoint>
  local dataset=$1 mountpoint=$2
  if storage_dataset_exists "$dataset"; then
    return 0
  fi
  zfs create -p -o "mountpoint=$mountpoint" "$dataset"
}

storage_is_zfs_dataset() {
  # storage_is_zfs_dataset <path> — returns 0 if path is a mountpoint of a zfs dataset.
  local path=$1
  local fstype
  fstype=$(stat -f -c %T "$path" 2>/dev/null || echo "")
  [[ $fstype == zfs ]]
}

storage_zfs_send_recv() {
  # storage_zfs_send_recv <src_dataset> <dst_dataset>
  local src=$1 dst=$2
  local snap="migrate-$(date -u +%Y%m%dT%H%M%SZ)"
  zfs snapshot "${src}@${snap}"
  zfs send -R "${src}@${snap}" | zfs recv -F "$dst"
  printf '%s' "$snap"
}

storage_rsync_copy() {
  # storage_rsync_copy <src_path> <dst_path>
  local src=$1 dst=$2
  rsync -aHAX --numeric-ids --info=progress2 "${src%/}/" "${dst%/}/"
}

storage_write_mount_unit() {
  # storage_write_mount_unit <service> <dataset> <mountpoint>
  # Writes a persistent .mount unit so the dataset is bind-mounted at the
  # service's data_path on every boot. We let zfs own the mount but record it
  # so a future migration knows where to look.
  local service=$1 dataset=$2 mountpoint=$3
  zfs set "mountpoint=$mountpoint" "$dataset"
  zfs mount "$dataset" 2>/dev/null || true
  install -d -m 0755 /etc/personal-server
  yq -i ".[\"$service\"] = \"$dataset\"" /etc/personal-server/storage.yaml
}

storage_resolve_pool_for() {
  # storage_resolve_pool_for <service_name>
  # Reads /etc/personal-server/storage.yaml and returns the dataset for service,
  # or empty if unset (meaning data still lives on rootfs).
  local svc=$1
  local f=/etc/personal-server/storage.yaml
  [[ -f $f ]] || { printf ''; return 0; }
  yq -r ".[\"$svc\"] // \"\"" "$f"
}
