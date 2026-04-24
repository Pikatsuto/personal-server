#!/usr/bin/env bash
# Pure verifier. Keycloak container is up, health endpoint responds,
# and the configured realm exists.
set -uo pipefail
source /var/lib/personal-server/tests/lib.sh

systemctl is-active --quiet personal-server-keycloak.service \
  || tests_fail "personal-server-keycloak.service is not running"
tests_log "keycloak unit active"

curl -fsS http://localhost:9180/health/ready >/dev/null \
  || tests_fail "keycloak /health/ready not responding"
tests_log "keycloak /health/ready OK"

REALM=$(yq -r '.config.realm' /etc/personal-server/services/keycloak/service.yaml)
[[ -n $REALM && $REALM != null ]] || tests_fail "keycloak realm not declared in service.yaml"

REALM_URL="http://localhost:8180/realms/${REALM}/.well-known/openid-configuration"
curl -fsS "$REALM_URL" >/dev/null \
  || tests_fail "keycloak realm '$REALM' not found"
tests_log "keycloak realm $REALM exists"
