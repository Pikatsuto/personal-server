#!/usr/bin/env bash
# Pure verifier. Coolify is NOT runtime-tested (it manages its own
# auto-update). We verify the compose.override.yml is valid and the
# watchtower opt-out labels are present on the 4 stack services.
set -uo pipefail
source /var/lib/personal-server/tests/lib.sh

OVERRIDE=/opt/personal-server/coolify/compose.override.yml
[[ -f $OVERRIDE ]] || tests_fail "$OVERRIDE missing"
yq -e . "$OVERRIDE" >/dev/null || tests_fail "$OVERRIDE not valid YAML"
tests_log "compose.override.yml valid"

for svc in coolify postgres redis soketi; do
  val=$(yq -r ".services.$svc.labels[\"com.centurylinklabs.watchtower.enable\"]" "$OVERRIDE")
  [[ $val == "false" ]] || tests_fail "$svc missing watchtower opt-out label (got: $val)"
done
tests_log "watchtower opt-out labels OK on all 4 stack services"

bash -n /etc/personal-server/services/coolify/configure.sh \
  || tests_fail "coolify configure.sh syntax error"
tests_log "coolify configure.sh syntax OK"

# Verify the service is actually running and responds
systemctl is-active --quiet personal-server-coolify.service \
  || tests_fail "personal-server-coolify.service is not running"
tests_log "coolify unit active"

for cname in coolify coolify-db coolify-redis; do
  state=$(docker inspect -f '{{.State.Status}}' "$cname" 2>/dev/null || echo missing)
  [[ $state == running ]] || tests_fail "$cname container is $state"
done
tests_log "coolify stack containers running"

wait_for_http_in_container coolify 8080 /api/health any 60
