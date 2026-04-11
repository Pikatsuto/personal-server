#!/usr/bin/env bash
# service-loader.sh — discovers services/*/service.yaml and resolves dependency order.
# Used by build/generate.sh, the first-boot wizard, and bin/personal-server.

set -euo pipefail

LIB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=yaml.sh
source "$LIB_DIR/yaml.sh"

# REPO_ROOT can be overridden (CI may invoke from a different cwd).
REPO_ROOT=${REPO_ROOT:-$(cd -- "$LIB_DIR/../.." && pwd)}
SERVICES_DIR=${SERVICES_DIR:-$REPO_ROOT/services}

services_list_raw() {
  # Lists every services/*/service.yaml as a service name (basename of dir).
  find "$SERVICES_DIR" -mindepth 2 -maxdepth 2 -type f -name service.yaml \
    | sed -E 's|.*/([^/]+)/service.yaml$|\1|' \
    | sort
}

service_yaml_path() {
  # service_yaml_path <name>
  printf '%s/%s/service.yaml' "$SERVICES_DIR" "$1"
}

service_dir() {
  printf '%s/%s' "$SERVICES_DIR" "$1"
}

service_depends_on() {
  # Prints dependencies one per line.
  local name=$1
  yaml_get_array "$(service_yaml_path "$name")" '.depends_on'
}

services_list_topo() {
  # Topological sort. Cycles are reported on stderr and exit 2.
  local -A seen=() temp=()
  local -a ordered=()
  local svc
  _visit() {
    local n=$1
    if [[ ${temp[$n]:-} == 1 ]]; then
      echo "service-loader: dependency cycle involving '$n'" >&2
      exit 2
    fi
    [[ ${seen[$n]:-} == 1 ]] && return 0
    temp[$n]=1
    local dep
    while IFS= read -r dep; do
      [[ -z $dep ]] && continue
      if [[ ! -f $(service_yaml_path "$dep") ]]; then
        echo "service-loader: '$n' depends on unknown service '$dep'" >&2
        exit 2
      fi
      _visit "$dep"
    done < <(service_depends_on "$n")
    temp[$n]=0
    seen[$n]=1
    ordered+=("$n")
  }
  while IFS= read -r svc; do
    _visit "$svc"
  done < <(services_list_raw)
  printf '%s\n' "${ordered[@]}"
}

services_filter_failed() {
  # services_filter_failed <ordered list...> <report.json>
  # Reads report.json on stdin or as last arg, returns the subset of services
  # whose status==ok AND whose transitive deps are all ok.
  local report=${!#}
  local -a all=("${@:1:$#-1}")
  local -A ok=()
  local svc
  for svc in "${all[@]}"; do
    local status
    status=$(jq -r --arg s "$svc" '.[$s].status // "missing"' "$report")
    if [[ $status == ok ]]; then
      local all_deps_ok=1
      local dep
      while IFS= read -r dep; do
        [[ -z $dep ]] && continue
        [[ ${ok[$dep]:-0} == 1 ]] || all_deps_ok=0
      done < <(service_depends_on "$svc")
      [[ $all_deps_ok == 1 ]] && ok[$svc]=1
    fi
  done
  for svc in "${all[@]}"; do
    [[ ${ok[$svc]:-0} == 1 ]] && printf '%s\n' "$svc"
  done
}
