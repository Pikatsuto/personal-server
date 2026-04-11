#!/usr/bin/env bash
# yaml.sh — wrappers around yq for standardised parsing of service.yaml and shared/*.yaml.
# All other scripts (build/generate.sh, run-install.sh, move-service-storage, wizard.sh)
# go through these helpers so the parser is in exactly one place.

set -euo pipefail

if ! command -v yq >/dev/null 2>&1; then
  echo "yaml.sh: yq is required but not installed" >&2
  exit 127
fi

yaml_get() {
  # yaml_get <file> <expression>
  # Returns empty string when key is missing instead of "null".
  local file=$1 expr=$2
  local out
  out=$(yq -r "$expr // \"\"" "$file")
  [[ $out == "null" ]] && out=""
  printf '%s' "$out"
}

yaml_get_array() {
  # yaml_get_array <file> <expression>
  # Prints one element per line, empty when key missing.
  local file=$1 expr=$2
  yq -r "($expr // []) | .[]" "$file" 2>/dev/null || true
}

yaml_has() {
  # yaml_has <file> <expression> — returns 0 if key is set and not null.
  local file=$1 expr=$2
  local out
  out=$(yq -r "($expr) // \"__missing__\"" "$file")
  [[ $out != "__missing__" && $out != "null" ]]
}

yaml_keys() {
  # yaml_keys <file> <expression> — list keys of a map.
  local file=$1 expr=$2
  yq -r "($expr // {}) | keys | .[]" "$file" 2>/dev/null || true
}
