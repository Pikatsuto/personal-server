#!/usr/bin/env bash
# apply-domain.sh — generates the post-bootstrap checklist.
#
# Fully data-driven: iterates over every services/*/service.yaml that
# declares a `checklist:` block, sorts by priority, renders each step
# with envsubst (PS_DOMAIN etc.), and appends a dynamic Pangolin
# resources section from the `pangolin:` blocks. Zero hardcoded
# service names.

set -euo pipefail

CONF_DIR=/etc/personal-server
SERVICES_DIR=$CONF_DIR/services
CHECKLIST=$CONF_DIR/first-boot-checklist.txt

DOMAIN=$(yq -r '.domain' "$CONF_DIR/answers.yaml")
export PS_DOMAIN=$DOMAIN

install -d -m 0700 "$CONF_DIR"
umask 077

# ── Collect checklist steps sorted by priority ──────────────────────
# Each entry: "priority|service|title|body"
checklist_entries=()
for yaml in "$SERVICES_DIR"/*/service.yaml; do
  [[ -f $yaml ]] || continue
  has_checklist=$(yq -r '.checklist // "" | type' "$yaml")
  [[ $has_checklist == "!!map" ]] || continue

  svc=$(yq -r '.name' "$yaml")
  priority=$(yq -r '.checklist.priority // 99' "$yaml")
  n_steps=$(yq -r '.checklist.steps | length' "$yaml")

  for ((i=0; i<n_steps; i++)); do
    title=$(yq -r ".checklist.steps[$i].title" "$yaml")
    body=$(yq -r ".checklist.steps[$i].body" "$yaml")
    checklist_entries+=("${priority}|${svc}|${title}|${body}")
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

Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) for domain: ${DOMAIN}

A handful of clicks are required, ONE TIME, because some services
cannot create their first admin or API key non-interactively.
Do them in order; each step unlocks the next.

HEADER

  step=0
  for entry in "${sorted[@]}"; do
    IFS='|' read -r _ svc title body <<< "$entry"
    step=$((step+1))
    printf '\n[%d] %s\n' "$step" "$title"
    # Render PS_* variables in the body (e.g. ${PS_DOMAIN})
    echo "$body" | envsubst '$PS_DOMAIN'
  done

  # ── Dynamic Pangolin resources section ────────────────────────────
  has_any_pangolin=0
  for yaml in "$SERVICES_DIR"/*/service.yaml; do
    [[ -f $yaml ]] || continue
    t=$(yq -r '.pangolin // "" | type' "$yaml")
    [[ $t == "!!map" ]] && { has_any_pangolin=1; break; }
  done

  if [[ $has_any_pangolin == 1 ]]; then
    step=$((step+1))
    printf '\n[%d] (Optional) create Pangolin Resources for the self-hosted UIs\n' "$step"
    echo "       Each service below declares an upstream — paste it as a"
    echo "       Resource → Site upstream in Pangolin and pick its auth mode."
    echo
    for yaml in "$SERVICES_DIR"/*/service.yaml; do
      [[ -f $yaml ]] || continue
      t=$(yq -r '.pangolin // "" | type' "$yaml")
      [[ $t == "!!map" ]] || continue
      name=$(yq -r '.name' "$yaml")
      sub=$(yq -r '.pangolin.subdomain // .name' "$yaml")
      upstream=$(yq -r '.pangolin.upstream // ""' "$yaml")
      auth=$(yq -r '.pangolin.auth // "proxy-auth"' "$yaml")
      printf '         %-10s  %s.%s  →  %s   [auth: %s]\n' \
        "$name" "$sub" "$DOMAIN" "$upstream" "$auth"
    done
  fi

  cat <<FOOTER

----------------------------------------------------------------
When done, run:
    personal-server reconfigure
to re-run this checklist (idempotent) and confirm everything is
wired. Sub-systems can be reached locally without going through
the reverse-proxy via:
    personal-server status
----------------------------------------------------------------
FOOTER
} > "$CHECKLIST"

chmod 600 "$CHECKLIST"

echo
echo "================================================================"
echo "  First-boot checklist written to: $CHECKLIST"
echo "  cat $CHECKLIST"
echo "================================================================"
