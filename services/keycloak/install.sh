#!/usr/bin/env bash
# Stage the compose template, systemd units and lib/ for render-all-units.sh
set -euo pipefail
install -d -m 0755 /opt/personal-server/keycloak
cp -a "$(dirname "$0")/files/." /opt/personal-server/keycloak/
cp -a "$(dirname "$0")/lib" /opt/personal-server/keycloak/
