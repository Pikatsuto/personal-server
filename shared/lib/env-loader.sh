#!/usr/bin/env bash
# env-loader.sh — generic helpers to load answers + secrets + service
# configs from the on-disk state (/etc/personal-server/) into env as
# PS_<KEY>=<value>.
#
# Used by: render-all-units.sh (boot-time rendering), post-configure
# scripts, personal-server reconfigure, tests.
#
# Zero hardcoded service names.

_CONF_DIR=${PS_CONF_DIR:-/etc/personal-server}
_ANSWERS=$_CONF_DIR/answers.yaml
_SECRETS_DIR=$_CONF_DIR/secrets
_SERVICES_DIR=$_CONF_DIR/services

# Load all user answers as PS_<KEY>
ps_load_answers() {
  [[ -f $_ANSWERS ]] || return 0
  while IFS= read -r key; do
    [[ -z $key ]] && continue
    local val up
    val=$(yq -r ".[\"$key\"] // \"\"" "$_ANSWERS")
    up=${key^^}
    export "PS_${up}=$val"
  done < <(yq -r 'keys[]' "$_ANSWERS" 2>/dev/null)
}

# Load all auto-generated secrets as PS_<KEY>
ps_load_secrets() {
  [[ -d $_SECRETS_DIR ]] || return 0
  local f key
  for f in "$_SECRETS_DIR"/*; do
    [[ -f $f ]] || continue
    key=$(basename "$f")
    export "PS_${key^^}=$(<"$f")"
  done
}

# Export every service's `config:` block as PS_<SVC>_<KEY>
ps_load_service_configs() {
  local svc_yaml svc_name ckey cval
  for svc_yaml in "$_SERVICES_DIR"/*/service.yaml; do
    [[ -f $svc_yaml ]] || continue
    svc_name=$(basename "$(dirname "$svc_yaml")")
    while IFS= read -r ckey; do
      [[ -z $ckey ]] && continue
      cval=$(yq -r ".config.\"$ckey\"" "$svc_yaml")
      export "PS_${svc_name^^}_${ckey^^}=$cval"
    done < <(yq -r '(.config // {}) | keys[]' "$svc_yaml" 2>/dev/null)
  done
}

# Load everything at once
ps_load_all() {
  ps_load_answers
  ps_load_secrets
  ps_load_service_configs
}
