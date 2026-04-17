#!/usr/bin/env bash
# wizard.sh — data-driven first-boot (and reconfigure) setup. Zero hardcoded
# service names, zero hardcoded questions.
#
# Every question the wizard asks comes from the `wizard.questions` block of
# each service's service.yaml. Questions are deduplicated by `key` (multiple
# services can declare the same key — e.g., "domain" — and it's asked once).
# Answers are persisted in /etc/personal-server/answers.yaml. On re-run,
# only unanswered questions are asked (incremental).
#
# After collecting answers, the wizard iterates services in topological
# dependency order and runs each service's configure.sh with the answers
# and secrets exported as PS_<KEY> env vars.

set -euo pipefail

CONF_DIR=/etc/personal-server
SERVICES_DIR=$CONF_DIR/services
ANSWERS=$CONF_DIR/answers.yaml
CONFIGURED_DIR=$CONF_DIR/configured

source /opt/personal-server/lib/yaml.sh
source /opt/personal-server/lib/images.sh

install -d -m 0755 "$CONF_DIR" "$CONFIGURED_DIR" /var/log/personal-server
LOG=/var/log/personal-server/wizard-$(date -u +%Y%m%dT%H%M%SZ).log
exec > >(tee -a "$LOG") 2>&1

cat <<'BANNER'

╔═══════════════════════════════════════════════════════════════╗
║              personal-server first-boot wizard                ║
╚═══════════════════════════════════════════════════════════════╝

BANNER

# ── Load existing answers ────────────────────────────────────────────
[[ -f $ANSWERS ]] || echo '{}' > "$ANSWERS"

get_answer() {
  yq -r ".[\"$1\"] // \"\"" "$ANSWERS"
}
set_answer() {
  yq -i ".[\"$1\"] = \"$2\"" "$ANSWERS"
}

# ── Collect unique questions from all services ───────────────────────
declare -A seen_keys=()
declare -a questions=()  # each entry: "key|prompt|required|default|type"

for yaml in "$SERVICES_DIR"/*/service.yaml; do
  [[ -f $yaml ]] || continue
  count=$(yq -r '.wizard.questions // [] | length' "$yaml")
  for (( i=0; i<count; i++ )); do
    key=$(yq -r ".wizard.questions[$i].key" "$yaml")
    [[ -z $key || $key == null ]] && continue
    [[ ${seen_keys[$key]:-} == 1 ]] && continue
    seen_keys[$key]=1
    prompt=$(yq -r ".wizard.questions[$i].prompt // \"$key\"" "$yaml")
    required=$(yq -r ".wizard.questions[$i].required // false" "$yaml")
    default=$(yq -r ".wizard.questions[$i].default // \"\"" "$yaml")
    qtype=$(yq -r ".wizard.questions[$i].type // \"string\"" "$yaml")
    questions+=("${key}|${prompt}|${required}|${default}|${qtype}")
  done
done

# ── Ask unanswered questions (interactive on tty1) ───────────────────
for entry in "${questions[@]}"; do
  IFS='|' read -r key prompt required default qtype <<<"$entry"
  existing=$(get_answer "$key")

  if [[ $qtype == secret_map ]]; then
    # Secret map: collect key=value pairs until blank. Only ask if no
    # credentials file exists yet.
    CREDS_FILE=$CONF_DIR/acme-credentials.yaml
    if [[ ! -f $CREDS_FILE ]]; then
      echo
      echo "$prompt (env vars for the provider). Leave blank to stop."
      echo '---' > "$CREDS_FILE"
      chmod 600 "$CREDS_FILE"
      while :; do
        read -r -p "  env var name (blank to finish): " k </dev/tty
        [[ -z $k ]] && break
        read -r -s -p "  $k value: " v </dev/tty; echo
        yq -i ".[\"$k\"] = \"$v\"" "$CREDS_FILE"
      done
    fi
    continue
  fi

  [[ -n $existing ]] && continue  # already answered

  # If no TTY is available (CI container, headless boot), we can't ask.
  # Required questions without an answer → fail. Optional questions → empty.
  if ! (true </dev/tty) 2>/dev/null; then
    if [[ $required == true ]]; then
      echo "wizard: REQUIRED answer for '$key' is missing and no TTY to ask"
      echo "wizard: pre-seed /etc/personal-server/answers.yaml before boot"
      exit 1
    else
      echo "wizard: optional '$key' unanswered, no TTY → defaulting to '${default}'"
      set_answer "$key" "$default"
      continue
    fi
  fi

  if [[ -n $default ]]; then
    read -r -p "$prompt [$default]: " ans </dev/tty
    ans=${ans:-$default}
  elif [[ $required == true ]]; then
    while :; do
      read -r -p "$prompt: " ans </dev/tty
      [[ -n $ans ]] && break
      echo "  (required)"
    done
  else
    read -r -p "$prompt: " ans </dev/tty
  fi
  set_answer "$key" "$ans"
done

# ── Export all answers as PS_<KEY> env vars ───────────────────────────
while IFS= read -r key; do
  [[ -z $key ]] && continue
  val=$(get_answer "$key")
  up=${key^^}
  export "PS_${up}=$val"
done < <(yq -r 'keys[]' "$ANSWERS")

# Export acme credentials if they exist
CREDS_FILE=$CONF_DIR/acme-credentials.yaml
if [[ -f $CREDS_FILE ]]; then
  while IFS= read -r key; do
    [[ -z $key ]] && continue
    val=$(yq -r ".[\"$key\"]" "$CREDS_FILE")
    export "$key=$val"
  done < <(yq -r 'keys[]' "$CREDS_FILE" 2>/dev/null)
fi

# ── Re-render all templates with the now-populated answers ───────────
# render-all-units.sh already ran at boot but answers.yaml was empty then
# (first boot). Now that we have answers, re-render so compose templates
# and systemd units contain the real values.
echo "wizard: re-rendering templates with answers…"
/opt/personal-server/lib/render-all-units.sh

# render-all-units.sh auto-generated secrets to /etc/personal-server/secrets/.
# Load them into OUR env so configure.sh subshells can see PS_<KEY>.
for _sf in /etc/personal-server/secrets/*; do
  [[ -f $_sf ]] || continue
  _key=$(basename "$_sf")
  export "PS_${_key^^}=$(<"$_sf")"
done

# ── Topo-sort services ───────────────────────────────────────────────
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
  [[ -d $d ]] || continue
  visit "$(basename "${d%/}")"
done

# ── Configure services (parallel, respecting dependency DAG) ─────────
# Services whose deps are all done start immediately in background.
# The topo-sorted `ordered` array guarantees we visit deps before
# dependents. For each service we `wait` only on its declared deps'
# PIDs, then launch it in background. Independent services (e.g.,
# docker + incus) run truly in parallel.
echo
echo "wizard: configuring ${#ordered[@]} services (parallel): ${ordered[*]}"

declare -A svc_pids=()     # svc → background PID
declare -A svc_status=()   # svc → exit code (set after wait)

run_configure() {
  local svc=$1
  local yaml=$SERVICES_DIR/$svc/service.yaml
  [[ -f $yaml ]] || return 0

  resolve_service_images "$yaml"

  local pool_key
  pool_key=$(yaml_get "$yaml" '.storage.pool_key')
  if [[ -n $pool_key ]]; then
    export PS_POOL="$(get_answer "pool_${pool_key}")"
  else
    export PS_POOL=""
  fi
  export PS_SERVICE=$svc

  local cfg_name
  cfg_name=$(yaml_get "$yaml" '.configure.first_boot')
  cfg_name=${cfg_name:-configure.sh}
  local cfg=$SERVICES_DIR/$svc/$cfg_name

  if [[ -x $cfg ]]; then
    echo "wizard: → $svc (start)"
    if "$cfg"; then
      install -d -m 0755 "$CONFIGURED_DIR"
      date -u +%Y-%m-%dT%H:%M:%SZ > "$CONFIGURED_DIR/$svc"
      echo "wizard: → $svc (done)"
    else
      echo "wizard: → $svc (exited $?)"
    fi
  fi
}

for svc in "${ordered[@]}"; do
  yaml=$SERVICES_DIR/$svc/service.yaml
  [[ -f $yaml ]] || continue

  # Wait for declared dependencies to finish (their PIDs)
  while IFS= read -r dep; do
    [[ -z $dep ]] && continue
    if [[ -n ${svc_pids[$dep]:-} ]]; then
      wait "${svc_pids[$dep]}" 2>/dev/null || true
    fi
  done < <(yq -r '.depends_on // [] | .[]' "$yaml")

  # Launch in background
  run_configure "$svc" &
  svc_pids[$svc]=$!
done

# Wait for ALL services to finish
for svc in "${ordered[@]}"; do
  if [[ -n ${svc_pids[$svc]:-} ]]; then
    wait "${svc_pids[$svc]}" 2>/dev/null
    svc_status[$svc]=$?
  fi
done

echo
echo "wizard: configure results:"
for svc in "${ordered[@]}"; do
  st=${svc_status[$svc]:-skip}
  echo "  $svc: $st"
done

# ── Post-configure: write the first-boot checklist ───────────────────
if [[ -x $CONF_DIR/first-boot/apply-domain.sh ]]; then
  echo "wizard: writing first-boot checklist…"
  "$CONF_DIR/first-boot/apply-domain.sh" || echo "wizard: apply-domain exited $?"
fi

touch "$CONF_DIR/.configured"
echo
echo "wizard: done. log: $LOG"
