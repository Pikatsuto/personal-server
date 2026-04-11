#!/usr/bin/env bash
# Build-time stage: nothing to do. The official Coolify installer cannot run
# during a Docker build (it expects Docker daemon + systemd live), so we
# defer the actual install to first-boot via configure.sh.
set -euo pipefail
install -d -m 0755 /opt/personal-server/coolify
