#!/usr/bin/env bash
# apply-domain.sh — generates the post-bootstrap checklist.
#
# 100% data-driven: loads ALL answers dynamically as PS_<KEY>, iterates
# over every services/*/service.yaml that declares a checklist: or
# proxy: block. Zero hardcoded anything.

set -euo pipefail

CONF_DIR=/etc/personal-server
SERVICES_DIR=$CONF_DIR/services
ANSWERS=$CONF_DIR/answers.yaml
CHECKLIST=$CONF_DIR/first-boot-checklist.txt

install -d -m 0700 "$CONF_DIR"
umask 077

# ── Load ALL answers dynamically as PS_<KEY> ────────────────────────
envsubst_whitelist=""
if [[ -f $ANSWERS ]]; then
  while IFS= read -r key; do
    [[ -z $key ]] && continue
    val=$(yq -r ".[\"$key\"] // \"\"" "$ANSWERS")
    up=${key^^}
    export "PS_${up}=$val"
    envsubst_whitelist="$envsubst_whitelist \$PS_${up}"
  done < <(yq -r 'keys[]' "$ANSWERS" 2>/dev/null)
fi

# ── Collect checklist steps sorted by priority ──────────────────────
checklist_entries=()
for yaml in "$SERVICES_DIR"/*/service.yaml; do
  [[ -f $yaml ]] || continue
  has_checklist=$(yq -r '.checklist // "" | type' "$yaml")
  [[ $has_checklist == "!!map" ]] || continue

  priority=$(yq -r '.checklist.priority // 99' "$yaml")
  n_steps=$(yq -r '.checklist.steps | length' "$yaml")

  for ((i=0; i<n_steps; i++)); do
    title=$(yq -r ".checklist.steps[$i].title" "$yaml")
    body=$(yq -r ".checklist.steps[$i].body" "$yaml")
    checklist_entries+=("${priority}|${title}|${body}")
  done
done

# Sort by priority (stable — preserves step order within same priority)
IFS=$'\n' sorted=($(printf '%s\n' "${checklist_entries[@]}" | sort -t'|' -k1,1n -s))
unset IFS

# ── Write the checklist ─────────────────────────────────────────────
{
  cat <<HEADER
================================================================
 personal-server — first-boot checklist
================================================================

Generated $(date -u +%Y-%m-%dT%H:%M:%SZ)

A handful of clicks are required, ONE TIME, because some services
cannot create their first admin or API key non-interactively.
Do them in order; each step unlocks the next.

HEADER

  step=0
  for entry in "${sorted[@]}"; do
    IFS='|' read -r _ title body <<< "$entry"
    step=$((step+1))
    rendered_title=$(echo "$title" | envsubst "$envsubst_whitelist")
    rendered_body=$(echo "$body" | envsubst "$envsubst_whitelist")
    printf '\n[%d] %s\n' "$step" "$rendered_title"
    echo "$rendered_body"
  done

  # ── Dynamic reverse-proxy resources section ─────────────────────
  has_any=0
  for yaml in "$SERVICES_DIR"/*/service.yaml; do
    [[ -f $yaml ]] || continue
    t=$(yq -r '.proxy // "" | type' "$yaml")
    [[ $t == "!!map" ]] && { has_any=1; break; }
  done

  if [[ $has_any == 1 ]]; then
    step=$((step+1))
    printf '\n[%d] (Optional) create reverse-proxy resources for the self-hosted UIs\n' "$step"
    echo "       Each service below declares an upstream — create a resource"
    echo "       in the reverse-proxy and pick its auth mode."
    echo
    for yaml in "$SERVICES_DIR"/*/service.yaml; do
      [[ -f $yaml ]] || continue
      t=$(yq -r '.proxy // "" | type' "$yaml")
      [[ $t == "!!map" ]] || continue
      name=$(yq -r '.name' "$yaml")
      sub=$(yq -r '.proxy.subdomain // .name' "$yaml")
      upstream=$(yq -r '.proxy.upstream // ""' "$yaml")
      auth=$(yq -r '.proxy.auth // "proxy-auth"' "$yaml")
      printf '         %-10s  %s.%s  →  %s   [auth: %s]\n' \
        "$name" "$sub" "${PS_DOMAIN:-unknown}" "$upstream" "$auth"
    done
  fi

  cat <<FOOTER

----------------------------------------------------------------
When done, run:
    personal-server reconfigure
to re-run this checklist (idempotent) and confirm everything is
wired.
----------------------------------------------------------------
FOOTER
} > "$CHECKLIST"

chmod 600 "$CHECKLIST"

echo
echo "================================================================"
echo "  First-boot checklist written to: $CHECKLIST"
echo "  cat $CHECKLIST"
echo "================================================================"
