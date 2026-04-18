#!/usr/bin/env bash
# images.sh — generic helpers to resolve a service.yaml's `images:` block
# into env vars + an envsubst whitelist, and to render .tmpl files with
# whitelisted substitution.
#
# `images:` schema (see any services/*/service.yaml for examples):
#   images:
#     <key>:
#       repo: <registry>/<image>
#       digest: ""        # empty → use :latest, set → use <repo>@<digest>
#
# resolve_service_images yaml_path
#   Side effect: exports `IMAGE_<KEY>_REF` for every key found, where
#   <KEY> is the YAML key uppercased and the value is either
#   `<repo>@<digest>` (digest non-empty) or `<repo>:latest` (digest empty).
#   Stdout: the envsubst whitelist string for these vars (or "" if no
#   images: block exists).
#
# render_tmpl_files dir [extra_whitelist]
#   For every *.tmpl in `dir` (recursive), runs `envsubst <whitelist>`
#   and writes the output to the same path without the .tmpl suffix.
#   The whitelist is whatever the caller passes — caller is responsible
#   for combining the IMAGE_*_REF whitelist with any per-service vars.

set -euo pipefail

LIB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=yaml.sh
source "$LIB_DIR/yaml.sh"

RESOLVE_WHITELIST=""
resolve_service_images() {
  # MUST NOT be called inside $() — the exports would be lost in the
  # subshell. Call directly, then read RESOLVE_WHITELIST for the envsubst
  # whitelist string.
  local yaml=$1
  RESOLVE_WHITELIST=""
  local key
  while IFS= read -r key; do
    [[ -z $key ]] && continue
    local repo digest ref up
    repo=$(yaml_get "$yaml" ".images.$key.repo")
    digest=$(yaml_get "$yaml" ".images.$key.digest")
    if [[ -n $digest ]]; then
      ref="${repo}@${digest}"
    else
      ref="${repo}:latest"
    fi
    up=${key^^}
    export "IMAGE_${up}_REF=$ref"
    RESOLVE_WHITELIST="$RESOLVE_WHITELIST \$IMAGE_${up}_REF"
  done < <(yaml_keys "$yaml" '.images')
}

render_tmpl_files() {
  local dir=$1
  local whitelist=${2:-}
  [[ -d $dir ]] || return 0
  local tmpl out
  while IFS= read -r tmpl; do
    out=${tmpl%.tmpl}
    envsubst "$whitelist" < "$tmpl" > "$out"
  done < <(find "$dir" -type f -name '*.tmpl')
}
