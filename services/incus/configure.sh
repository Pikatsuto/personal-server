#!/usr/bin/env bash
# Non-interactive Incus init via `incus admin init --preseed`.
# Detects container context (CI, Docker) and adapts:
#   - /dev/kvm available → full KVM support for VMs
#   - /dev/kvm absent → LXC containers only (no VMs)
#   - Container detected + no kernel namespace support → incusd may fail
#     to start; configure.sh exits 0 anyway (the test.sh will detect it)
set -euo pipefail

# Detect container context
IN_CONTAINER=0
if systemd-detect-virt --container >/dev/null 2>&1; then
  IN_CONTAINER=1
  echo "incus: running inside a container"
  [[ -e /dev/kvm ]] && echo "incus: /dev/kvm available → KVM VMs supported" \
                     || echo "incus: /dev/kvm absent → LXC only, no KVM VMs"
fi

systemctl enable incus.socket
# Start socket (lightweight, always works). Then start the service with
# --no-block so we don't hang if incusd crash-loops in a container.
systemctl start incus.socket || true
systemctl start --no-block incus.service || true

# Poll for the daemon. Check TWO things each iteration:
# 1. Is incus.service in `failed` state? → stop immediately (crash detected)
# 2. Does `incus info` respond? → daemon is up
daemon_up=0
for _ in $(seq 1 30); do
  svc_state=$(systemctl is-active incus.service 2>/dev/null || true)
  if [[ $svc_state == failed ]]; then
    echo "incus: incus.service entered failed state (crash detected)"
    break
  fi
  if incus info >/dev/null 2>&1; then daemon_up=1; break; fi
  sleep 1
done

if [[ $daemon_up == 0 ]]; then
  if [[ $IN_CONTAINER == 1 ]]; then
    echo "incus: daemon did not start (expected in container without full kernel support)"
    exit 0
  else
    echo "incus: daemon failed to start on bare metal — this is a real error" >&2
    exit 1
  fi
fi

# If init has already run, just make sure the HTTPS UI is exposed and exit.
if incus storage list -f csv 2>/dev/null | grep -q .; then
  incus config set core.https_address ":8443" || true
  exit 0
fi

POOL=${PS_POOL:-}
PRESEED=$(mktemp)
trap 'rm -f "$PRESEED"' EXIT

{
  echo "config:"
  echo "  core.https_address: \":8443\""
  if [[ -n $POOL ]]; then
    DATASET="$POOL/personal-server/incus"
    zfs list -H -o name "$DATASET" >/dev/null 2>&1 || zfs create -p "$DATASET"
    cat <<YAML
storage_pools:
  - name: default
    driver: zfs
    config:
      source: $DATASET
YAML
  fi
  cat <<'YAML'
networks:
  - name: incusbr0
    type: bridge
    config:
      ipv4.address: auto
      ipv6.address: none
profiles:
  - name: default
    devices:
      eth0:
        type: nic
        nictype: bridged
        parent: incusbr0
YAML
  if [[ -n $POOL ]]; then
    cat <<'YAML'
      root:
        path: /
        pool: default
        type: disk
YAML
  fi
} > "$PRESEED"

incus admin init --preseed < "$PRESEED"

if [[ -n $POOL ]]; then
  yq -i ".incus = \"$DATASET\"" /etc/personal-server/storage.yaml
fi
