#!/usr/bin/env bash
# wizard.sh — interactive first-boot setup. Asks for domain, ACME provider,
# (optional) ZFS pools, then runs every service's configure.sh in dependency
# order. Marks /etc/personal-server/.configured on success.
#
# Generic: never name a service explicitly. Iteration is driven by
# /etc/personal-server/services/*/service.yaml shipped during build.

set -euo pipefail

CONF_DIR=/etc/personal-server
SERVICES_DIR=$CONF_DIR/services
MARKER=$CONF_DIR/.configured

if [[ -f $MARKER ]]; then
  echo "wizard: already configured ($MARKER), skipping."
  exit 0
fi

install -d -m 0755 "$CONF_DIR" /var/log/personal-server
LOG=/var/log/personal-server/firstboot-$(date -u +%Y%m%dT%H%M%SZ).log
exec > >(tee -a "$LOG") 2>&1

cat <<'BANNER'

╔═══════════════════════════════════════════════════════════════╗
║              personal-server first-boot wizard                ║
╚═══════════════════════════════════════════════════════════════╝

BANNER

ask() {
  # ask <var> <prompt> [default]
  local var=$1 prompt=$2 default=${3:-} ans
  if [[ -n $default ]]; then
    read -r -p "$prompt [$default]: " ans </dev/tty
    ans=${ans:-$default}
  else
    while :; do
      read -r -p "$prompt: " ans </dev/tty
      [[ -n $ans ]] && break
      echo "  (required)"
    done
  fi
  printf -v "$var" '%s' "$ans"
}

ask_secret() {
  local var=$1 prompt=$2 ans
  read -r -s -p "$prompt: " ans </dev/tty
  echo
  printf -v "$var" '%s' "$ans"
}

ask DOMAIN     "Root domain (e.g. home.example.com)"
ask ACME_EMAIL "Email for Let's Encrypt notifications"

echo
echo "DNS provider for ACME wildcard (any Lego provider name, e.g. cloudflare, route53, gandi)"
ask ACME_DNS_PROVIDER "DNS provider" "cloudflare"

# Provider-specific creds: collect generic env-var pairs.
echo
echo "DNS provider credentials (env vars Traefik/Lego will use). Leave blank to stop."
declare -A ACME_ENV=()
while :; do
  read -r -p "  env var name (blank to finish): " key </dev/tty
  [[ -z $key ]] && break
  ask_secret val "  $key value"
  ACME_ENV[$key]=$val
done

echo
echo "ZFS pools (optional). At first boot you can skip this and use WebZFS later."
echo "If a pool is named here, it must already exist (zpool list)."
declare -A POOLS=()
for svc_yaml in "$SERVICES_DIR"/*/service.yaml; do
  [[ -f $svc_yaml ]] || continue
  svc=$(basename "$(dirname "$svc_yaml")")
  pool_key=$(yq -r '.storage.pool_key // ""' "$svc_yaml")
  data_path=$(yq -r '.storage.data_path // ""' "$svc_yaml")
  [[ -z $pool_key ]] && continue
  read -r -p "  pool for ${svc} (data_path=${data_path}, blank=rootfs): " pool </dev/tty
  [[ -n $pool ]] && POOLS[$svc]=$pool
done

# ── persist answers ──
{
  echo "domain: \"$DOMAIN\""
  echo "acme_email: \"$ACME_EMAIL\""
  echo "acme_dns_provider: \"$ACME_DNS_PROVIDER\""
} > "$CONF_DIR/domain.yaml"

{
  echo "---"
  for k in "${!ACME_ENV[@]}"; do
    printf '%s: "%s"\n' "$k" "${ACME_ENV[$k]}"
  done
} > "$CONF_DIR/acme.yaml"
chmod 600 "$CONF_DIR/acme.yaml"

{
  echo "---"
  for svc in "${!POOLS[@]}"; do
    printf '%s: "%s"\n' "$svc" "${POOLS[$svc]}"
  done
} > "$CONF_DIR/storage.yaml"

# ── topo-sorted iteration on configure.sh ──
echo
echo "wizard: running configure scripts…"
export PS_DOMAIN=$DOMAIN PS_ACME_EMAIL=$ACME_EMAIL PS_ACME_DNS_PROVIDER=$ACME_DNS_PROVIDER
for k in "${!ACME_ENV[@]}"; do export "$k=${ACME_ENV[$k]}"; done

# build a topo order from the installed services (mirrors service-loader.sh
# but uses the runtime tree under /etc/personal-server/services/).
declare -A _seen=() _temp=()
ordered=()
visit() {
  local n=$1
  [[ ${_temp[$n]:-} == 1 ]] && { echo "wizard: dependency cycle at $n" >&2; exit 2; }
  [[ ${_seen[$n]:-} == 1 ]] && return 0
  _temp[$n]=1
  local deps=()
  if [[ -f $SERVICES_DIR/$n/service.yaml ]]; then
    mapfile -t deps < <(yq -r '.depends_on // [] | .[]' "$SERVICES_DIR/$n/service.yaml")
  fi
  for d in "${deps[@]:-}"; do
    [[ -z $d ]] && continue
    visit "$d"
  done
  _temp[$n]=0; _seen[$n]=1; ordered+=("$n")
}
for d in "$SERVICES_DIR"/*/; do
  visit "$(basename "${d%/}")"
done

stage_units() {
  # Copies any /etc/personal-server/services/<svc>/files/systemd/* into
  # /etc/systemd/system. Generic for every service.
  local svc=$1
  local src=$SERVICES_DIR/$svc/files/systemd
  [[ -d $src ]] || return 0
  install -d -m 0755 /etc/systemd/system
  cp -a "$src/." /etc/systemd/system/
  systemctl daemon-reload
}

for svc in "${ordered[@]}"; do
  yaml=$SERVICES_DIR/$svc/service.yaml
  [[ -f $yaml ]] || continue
  stage_units "$svc"
  cfg_name=$(yq -r '.configure.first_boot // "configure.sh"' "$yaml")
  cfg=$SERVICES_DIR/$svc/$cfg_name
  if [[ -x $cfg ]]; then
    export PS_SERVICE=$svc
    export PS_POOL="${POOLS[$svc]:-}"
    echo "wizard: → $svc ($cfg)"
    "$cfg" || echo "wizard: $svc configure exited $?, continuing"
  fi
done

# ── apply domain to Pangolin (resources, ACME, IdP wiring) ──
if [[ -x $CONF_DIR/first-boot/apply-domain.sh ]]; then
  echo "wizard: applying domain config to Pangolin…"
  "$CONF_DIR/first-boot/apply-domain.sh" || echo "wizard: apply-domain exited $?"
fi

touch "$MARKER"
echo
echo "wizard: done. Marker: $MARKER"
echo "wizard: log: $LOG"
