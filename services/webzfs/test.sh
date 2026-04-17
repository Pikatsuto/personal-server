#!/usr/bin/env bash
# Pure verifier. Checks WebZFS is running via systemd and the HTTP login
# page responds (may 200 or 307 redirect — both prove gunicorn is alive).
set -uo pipefail
source /var/lib/personal-server/tests/lib.sh

systemctl is-active --quiet webzfs.service \
  || tests_fail "webzfs.service is not running"
tests_log "webzfs.service active"

wait_for_http "http://localhost:26619/" any 30
