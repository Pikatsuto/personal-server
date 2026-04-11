#!/usr/bin/env bash
set -euo pipefail
install -d -m 0755 /etc/docker /etc/docker/daemon.json.d
# Minimal daemon.json — data-root will be patched by configure.sh once a pool
# is chosen via the first-boot wizard or move-service-storage.
cat > /etc/docker/daemon.json <<'JSON'
{
  "log-driver": "journald",
  "live-restore": true
}
JSON
systemctl enable docker.service docker.socket
