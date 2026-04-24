#!/usr/bin/env bash
# Pure verifier. Checks incus daemon is running via systemd and the HTTPS
# API + web UI respond. In QEMU/KVM we boot a real kernel so incusd must
# actually start — no silent fallback.
set -uo pipefail
source /var/lib/personal-server/tests/lib.sh

systemctl is-active --quiet incus.socket \
  || tests_fail "incus.socket is not active"
tests_log "incus.socket active"

# Trigger incusd via incus info (socket activation)
daemon_up=0
for _ in $(seq 1 30); do
  if incus info >/dev/null 2>&1; then daemon_up=1; break; fi
  sleep 1
done
[[ $daemon_up == 1 ]] || tests_fail "incusd did not start within 30s"
tests_log "incusd running"

wait_for_http "https://localhost:8443/" any 30
body=$(curl -sk "https://localhost:8443/ui/" || true)
[[ -n $body ]] || tests_fail "incus UI returned empty body"
echo "$body" | grep -qiE 'incus|lxd' || tests_fail "incus UI body doesn't mention incus/lxd"
tests_log "incus web UI served"
