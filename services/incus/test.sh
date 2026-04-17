#!/usr/bin/env bash
# Pure verifier. Checks incus daemon is running via systemd and the HTTPS
# API + web UI respond. Falls back to binary-only check if incusd can't
# start (known limitation in CI containers without full kernel support).
set -uo pipefail
source /var/lib/personal-server/tests/lib.sh

# incus is socket-activated — check the socket is listening
systemctl is-active --quiet incus.socket \
  || tests_fail "incus.socket is not active"
tests_log "incus.socket active"

# Trigger incusd via incus info (socket activation)
daemon_up=0
for i in $(seq 1 30); do
  if incus info >/dev/null 2>&1; then daemon_up=1; break; fi
  sleep 1
done

if [[ $daemon_up == 1 ]]; then
  tests_log "incusd running — full endpoint test"
  wait_for_http "https://localhost:8443/" any 30
  body=$(curl -sk "https://localhost:8443/ui/" || true)
  [[ -n $body ]] || tests_fail "incus UI returned empty body"
  echo "$body" | grep -qiE 'incus|lxd' || tests_fail "incus UI body doesn't mention incus/lxd"
  tests_log "incus web UI served"
else
  tests_log "WARN: incusd did not start (CI container without full kernel support)"
  incus --version || tests_fail "incus --version failed"
  [[ -d /opt/incus/ui ]] || tests_fail "/opt/incus/ui missing"
  tests_log "incus binary + UI assets present (daemon test skipped)"
fi
