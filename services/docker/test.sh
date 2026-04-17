#!/usr/bin/env bash
# Pure verifier. Checks docker engine is installed and the daemon is running.
set -uo pipefail
source /var/lib/personal-server/tests/lib.sh

command -v docker  >/dev/null || tests_fail "docker binary missing"
command -v dockerd >/dev/null || tests_fail "dockerd binary missing"
docker --version || tests_fail "docker --version failed"

systemctl is-active --quiet docker.service \
  || tests_fail "docker.service is not running"
tests_log "docker.service active"

[[ -f /etc/docker/daemon.json ]] && {
  jq -e . /etc/docker/daemon.json >/dev/null || tests_fail "daemon.json invalid"
  tests_log "daemon.json valid"
}
