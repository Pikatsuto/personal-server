#!/usr/bin/env bash
# Pure verifier. Checks PocketID container is running via systemd and its
# HTTP endpoint responds.
set -uo pipefail
source /var/lib/personal-server/tests/lib.sh

systemctl is-active --quiet personal-server-pocketid.service \
  || tests_fail "personal-server-pocketid.service is not running"
tests_log "pocketid unit active"

wait_for_http_in_container personal-server-pocketid 1411 / any 60
