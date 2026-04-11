#!/usr/bin/env bash
# Pre-pulls the watchtower image into the local Docker store at first run
# (deferred to configure.sh; nothing to bake into the image itself).
set -euo pipefail
echo "watchtower: install (no-op at build time, runs at first-boot)"
