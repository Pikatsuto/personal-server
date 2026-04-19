#!/usr/bin/env bash
# Build-time stage: stage the compose.override.yml so the systemd unit can
# load it. The Coolify installer itself runs at first-boot via configure.sh.
set -euo pipefail
install -d -m 0755 /opt/personal-server/coolify
install -m 0644 "$(dirname "$0")/files/compose.override.yml" \
  /opt/personal-server/coolify/compose.override.yml

# Coolify hardcodes /data which is read-only on bootc. Symlink to /var/lib.
install -d -m 0755 /var/lib/coolify
ln -sfn /var/lib/coolify /data
