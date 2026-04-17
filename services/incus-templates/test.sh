#!/usr/bin/env bash
# Pure verifier. Checks the incus-templates refresh timer is enabled and
# the upstream discovery sources are reachable.
set -uo pipefail
source /var/lib/personal-server/tests/lib.sh

systemctl is-enabled --quiet personal-server-incus-template-refresh.timer \
  || tests_fail "incus-template-refresh timer not enabled"
tests_log "incus-template-refresh timer enabled"

REFRESH=/etc/personal-server/services/incus-templates/files/refresh.sh
[[ -f $REFRESH ]] || tests_fail "$REFRESH missing"
bash -n "$REFRESH" || tests_fail "$REFRESH syntax error"
tests_log "refresh.sh syntax OK"

curl -fsSL https://images.linuxcontainers.org/streams/v1/index.json >/dev/null \
  || tests_fail "linuxcontainers streams index unreachable"
tests_log "linuxcontainers streams index reachable"

DEB_RELEASE=$(mktemp)
curl -fsSL https://deb.debian.org/debian/dists/stable/Release -o "$DEB_RELEASE" \
  || tests_fail "debian stable Release unreachable"
grep -q '^Codename:' "$DEB_RELEASE" \
  || tests_fail "debian stable Release missing Codename"
rm -f "$DEB_RELEASE"
tests_log "debian stable Release reachable"
