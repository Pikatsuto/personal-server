#!/usr/bin/env bash
# Pure verifier. Checks the Pangolin compose stack (pangolin + gerbil +
# traefik) is running via systemd and the API endpoint responds.
set -uo pipefail
source /var/lib/personal-server/tests/lib.sh

systemctl is-active --quiet personal-server-pangolin.service \
  || tests_fail "personal-server-pangolin.service is not running"
tests_log "pangolin unit active"

# Pangolin API (inside pangolin container, port 3001)
wait_for_http_in_container pangolin 3001 /api/v1/ any 60

# Gerbil + Traefik should also be running (compose brings all 3)
for cname in pangolin gerbil traefik; do
  state=$(docker inspect -f '{{.State.Status}}' "$cname" 2>/dev/null || echo missing)
  [[ $state == running ]] || tests_fail "$cname container is $state"
  tests_log "$cname container running"
done
