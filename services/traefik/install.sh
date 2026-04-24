#!/usr/bin/env bash
set -euo pipefail
install -d -m 0755 /opt/personal-server/traefik
cp -a "$(dirname "$0")/files/." /opt/personal-server/traefik/
