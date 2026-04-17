#!/usr/bin/env bash
# Pure verifier. Checks Arcane container is running via systemd and its
# HTTP endpoint responds.
set -uo pipefail
source /var/lib/personal-server/tests/lib.sh

systemctl is-active --quiet personal-server-arcane.service \
  || tests_fail "personal-server-arcane.service is not running"
tests_log "arcane unit active"

wait_for_http_in_container personal-server-arcane 3552 / any 60
