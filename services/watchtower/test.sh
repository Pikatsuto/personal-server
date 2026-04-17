#!/usr/bin/env bash
# Pure verifier. Watchtower is a one-shot timer, not a daemon. We verify
# the timer is enabled and the image ref in the rendered unit is pullable.
set -uo pipefail
source /var/lib/personal-server/tests/lib.sh

systemctl is-enabled --quiet personal-server-watchtower.timer \
  || tests_fail "personal-server-watchtower.timer not enabled"
tests_log "watchtower timer enabled"

# Extract the image ref from the rendered unit and verify it's pullable
UNIT=/etc/systemd/system/personal-server-watchtower.service
[[ -f $UNIT ]] || tests_fail "rendered watchtower unit missing"
IMG=$(grep -oE 'nickfedor/watchtower[^ ]+' "$UNIT" | head -1)
[[ -n $IMG ]] || tests_fail "no watchtower image ref found in unit"
docker pull "$IMG" >/dev/null || tests_fail "cannot pull $IMG"
# watchtower needs the docker socket even for --help, so mount it
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock "$IMG" --help >/dev/null 2>&1 \
  || tests_fail "$IMG --help failed"
tests_log "watchtower image pullable + --help OK ($IMG)"
