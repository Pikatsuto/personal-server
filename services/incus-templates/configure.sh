#!/usr/bin/env bash
# First-boot: run the refresh script (which discovers + copies the
# 4 templates), create the 2 cloud-init profiles, then enable the
# weekly refresh timer.
set -euo pipefail

# Incus client tries to mkdir $HOME on first run; inside a bootc container
# /root already exists → "mkdir /root: file exists". Pre-create the config dir.
export HOME=${HOME:-/root}
mkdir -p "$HOME/.config/incus" 2>/dev/null || true

ASSETS=/etc/personal-server/services/incus-templates/files
CLOUD_INIT_DIR=$ASSETS/cloud-init

chmod +x "$ASSETS/refresh.sh"

# ── Initial template fetch ───────────────────────────────────────────
"$ASSETS/refresh.sh"

# ── Cloud-init profiles ──────────────────────────────────────────────
declare -a PROFILES=(
  "auto-update-almalinux $CLOUD_INIT_DIR/almalinux.yaml"
  "auto-update-debian    $CLOUD_INIT_DIR/debian.yaml"
)

for entry in "${PROFILES[@]}"; do
  # shellcheck disable=SC2086
  set -- $entry
  pname=$1; pfile=$2
  if ! incus profile show "$pname" >/dev/null 2>&1; then
    incus profile create "$pname" \
      --description "Auto-apply security updates inside instances launched from this profile"
  fi
  incus profile set "$pname" user.user-data - < "$pfile"
done

# ── Weekly timer (Mon 04:00) ─────────────────────────────────────────
systemctl daemon-reload
systemctl enable --now personal-server-incus-template-refresh.timer

cat <<EOF

incus-templates: ready.

  Aliases (always pointing to current stable, refreshed weekly):
    almalinux-cloud-lxc, almalinux-cloud-vm
    debian-cloud-lxc,    debian-cloud-vm
  Cloud-init profiles:
    auto-update-almalinux, auto-update-debian

  Launch examples:
    incus launch local:almalinux-cloud-lxc myapp     --profile default --profile auto-update-almalinux
    incus launch local:debian-cloud-vm     debianvm  --vm --profile default --profile auto-update-debian

EOF
