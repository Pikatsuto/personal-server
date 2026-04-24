#!/usr/bin/env bash
set -uo pipefail
source /var/lib/personal-server/tests/lib.sh

systemctl is-active --quiet personal-server-traefik.service \
  || tests_fail "personal-server-traefik.service is not running"
tests_log "traefik unit active"

state=$(docker inspect -f '{{.State.Status}}' traefik 2>/dev/null || echo missing)
[[ $state == running ]] || tests_fail "traefik container is $state"
tests_log "traefik container running"

# forward-auth and filebrowser both do OIDC discovery at startup, which
# requires the Keycloak issuer to be reachable via public DNS + a valid
# TLS cert. In the QEMU test environment there's no real DNS nor ACME
# cert, so both will crash-loop. That's fine — we just verify the
# containers exist. In production they start cleanly once the operator's
# DNS is configured and Let's Encrypt issues certs.
for cname in traefik-forward-auth filebrowser; do
  state=$(docker inspect -f '{{.State.Status}}' "$cname" 2>/dev/null || echo missing)
  [[ $state != missing ]] || tests_fail "$cname container is missing"
  tests_log "$cname container exists (state=$state)"
done

curl -fsS http://localhost:8080/ping >/dev/null \
  || tests_fail "traefik /ping not responding"
tests_log "traefik /ping OK"
