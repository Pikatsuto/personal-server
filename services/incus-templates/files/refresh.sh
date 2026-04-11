#!/usr/bin/env bash
# Idempotent template sync. Discovers the CURRENT stable release of each
# distro at runtime so the local Incus image cache always tracks "latest
# stable" without ever pinning a specific version in this repo.
#
# Discovery sources (verified 2026-04-12):
#   AlmaLinux: max numeric release in
#     https://images.linuxcontainers.org/streams/v1/index.json
#   Debian:    https://deb.debian.org/debian/dists/stable/Release
#              `Codename:` field — Debian's own pointer to current stable.
#
# For each (alias, expected-release) tuple:
#   - if no local alias        → `incus image copy ... --auto-update`
#   - if alias on the right rel → `incus image refresh` (cheap)
#   - if alias on the wrong rel → delete + re-copy (major bump)

set -euo pipefail

LOG=/var/log/personal-server/incus-template-refresh-$(date -u +%Y%m%dT%H%M%SZ).log
mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1

echo "incus-template-refresh: starting at $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ── Discover current stable releases ─────────────────────────────────
ALMA_REL=$(curl -fsSL "https://images.linuxcontainers.org/streams/v1/index.json" \
  | jq -r '.index.images.products[]' \
  | grep -E '^almalinux:[0-9]+:amd64:cloud$' \
  | awk -F: '{print $2}' \
  | sort -n | tail -1)

DEBIAN_REL=$(curl -fsSL "https://deb.debian.org/debian/dists/stable/Release" \
  | awk '/^Codename:/ {print $2}')

if [[ -z $ALMA_REL || -z $DEBIAN_REL ]]; then
  echo "incus-template-refresh: failed to discover one of the releases (alma=$ALMA_REL debian=$DEBIAN_REL)"
  exit 1
fi
echo "incus-template-refresh: alma=$ALMA_REL debian=$DEBIAN_REL"

# ── Desired state ────────────────────────────────────────────────────
# Each line: alias  expected_release  source_path  optional_vm_flag
desired=(
  "almalinux-cloud-lxc $ALMA_REL   images:almalinux/$ALMA_REL/cloud"
  "almalinux-cloud-vm  $ALMA_REL   images:almalinux/$ALMA_REL/cloud --vm"
  "debian-cloud-lxc    $DEBIAN_REL images:debian/$DEBIAN_REL/cloud"
  "debian-cloud-vm     $DEBIAN_REL images:debian/$DEBIAN_REL/cloud --vm"
)

# ── Reconcile ────────────────────────────────────────────────────────
for entry in "${desired[@]}"; do
  # shellcheck disable=SC2086
  set -- $entry
  alias=$1; want_rel=$2; source=$3; vmflag=${4:-}

  if incus image alias list -f csv 2>/dev/null | grep -q "^${alias},"; then
    # Alias exists. Compare its release against the desired one.
    fp=$(incus image alias list -f csv | awk -F, -v a="$alias" '$1==a {print $3}')
    cur_rel=$(incus image show "$fp" 2>/dev/null | yq -r '.properties.release // ""')
    if [[ $cur_rel == "$want_rel" ]]; then
      echo "incus-template-refresh: $alias on $cur_rel — refresh"
      incus image refresh "$fp" || echo "  refresh failed (continuing)"
    else
      echo "incus-template-refresh: $alias on $cur_rel → re-copy at $want_rel"
      incus image delete "$fp" || true
      # shellcheck disable=SC2086
      incus image copy "$source" local: --alias "$alias" --auto-update $vmflag \
        || echo "  copy failed (continuing)"
    fi
  else
    echo "incus-template-refresh: $alias missing → copy from $source $vmflag"
    # shellcheck disable=SC2086
    incus image copy "$source" local: --alias "$alias" --auto-update $vmflag \
      || echo "  copy failed (continuing)"
  fi
done

echo "incus-template-refresh: done"
