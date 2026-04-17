#!/usr/bin/env bash
# render-all-units.sh — runs at EVERY boot (via personal-server-render-units
# .service) BEFORE any service starts. Generic: iterates over every
# services/*/ in the image, resolves IMAGE_<KEY>_REF from the service.yaml's
# images: block, reads answers from /etc/personal-server/answers.yaml, auto-
# generates any declared secrets that don't exist yet, then envsubst's every
# .tmpl found in the service's files/ tree.
#
# This ensures that after a bootc upgrade which ships new digests in the
# service.yaml files, the rendered systemd units and compose files are
# always up-to-date with the current image — without needing the wizard
# to re-run.
#
# Zero hardcoded service names.

set -euo pipefail

LIB=/opt/personal-server/lib
source "$LIB/yaml.sh"
source "$LIB/images.sh"

SERVICES_DIR=/etc/personal-server/services
ANSWERS=/etc/personal-server/answers.yaml
SECRETS_DIR=/etc/personal-server/secrets
# /opt is read-only on bootc (ostree) — services that need a writable runtime
# directory (compose files, config, etc.) get one rendered into /var/lib.
RUNTIME_BASE=/var/lib/personal-server

install -d -m 0755 /etc/systemd/system "$SECRETS_DIR" "$RUNTIME_BASE"

# ── Load answers into env (PS_<KEY>=<value>) ─────────────────────────
if [[ -f $ANSWERS ]]; then
  while IFS= read -r key; do
    [[ -z $key ]] && continue
    val=$(yq -r ".[\"$key\"] // \"\"" "$ANSWERS")
    up=${key^^}
    export "PS_${up}=$val"
  done < <(yq -r 'keys[]' "$ANSWERS" 2>/dev/null)
fi

# ── Per-service loop ─────────────────────────────────────────────────
for svc_dir in "$SERVICES_DIR"/*/; do
  [[ -d $svc_dir ]] || continue
  svc=$(basename "$svc_dir")
  yaml=$svc_dir/service.yaml
  [[ -f $yaml ]] || continue

  # 1. Resolve IMAGE_<KEY>_REF (returns the envsubst whitelist)
  resolve_service_images "$yaml"
  img_whitelist=$RESOLVE_WHITELIST

  # 2. Auto-generate secrets declared in service.yaml that don't exist yet
  while IFS= read -r key; do
    [[ -z $key ]] && continue
    secret_file=$SECRETS_DIR/$key
    if [[ ! -f $secret_file ]]; then
      gen=$(yaml_get "$yaml" ".secrets[] | select(.key == \"$key\") | .generate")
      if [[ -n $gen ]]; then
        eval "$gen" > "$secret_file"
        chmod 600 "$secret_file"
      fi
    fi
    up=${key^^}
    export "PS_${up}=$(<"$secret_file")"
  done < <(yq -r '(.secrets // [])[].key' "$yaml" 2>/dev/null)

  # 3. Build the full envsubst whitelist (images + answers + secrets).
  #    We MUST whitelist so that systemd runtime vars like ${APP_URL} in
  #    unit templates are NOT touched by envsubst (they're resolved at
  #    runtime by systemd from EnvironmentFile=).
  whitelist="$img_whitelist"
  if [[ -f $ANSWERS ]]; then
    while IFS= read -r key; do
      [[ -z $key ]] && continue
      whitelist="$whitelist \$PS_${key^^}"
    done < <(yq -r 'keys[]' "$ANSWERS" 2>/dev/null)
  fi
  while IFS= read -r key; do
    [[ -z $key ]] && continue
    whitelist="$whitelist \$PS_${key^^}"
  done < <(yq -r '(.secrets // [])[].key' "$yaml" 2>/dev/null)

  # 4. Render systemd .tmpl → /etc/systemd/system/
  if [[ -d $svc_dir/files/systemd ]]; then
    for f in "$svc_dir"/files/systemd/*; do
      [[ -f $f ]] || continue
      base=$(basename "$f")
      if [[ $base == *.tmpl ]]; then
        envsubst "$whitelist" < "$f" > "/etc/systemd/system/${base%.tmpl}"
      else
        cp -n "$f" "/etc/systemd/system/$base"
      fi
    done
  fi

  # 5. Mirror /opt/personal-server/<svc>/ (read-only, staged by install.sh)
  #    into /var/lib/personal-server/<svc>/ (writable), rendering .tmpl files.
  #    The runtime dir is what systemd units + docker compose actually read.
  src=/opt/personal-server/$svc
  dst=$RUNTIME_BASE/$svc
  if [[ -d $src ]]; then
    install -d -m 0755 "$dst"
    while IFS= read -r rel; do
      [[ -z $rel ]] && continue
      install -d -m 0755 "$dst/$rel"
    done < <(cd "$src" && find . -mindepth 1 -type d -printf '%P\n' 2>/dev/null)
    while IFS= read -r rel; do
      [[ -z $rel ]] && continue
      if [[ $rel == *.tmpl ]]; then
        envsubst "$whitelist" < "$src/$rel" > "$dst/${rel%.tmpl}"
      else
        cp -f "$src/$rel" "$dst/$rel"
      fi
    done < <(cd "$src" && find . -type f -printf '%P\n' 2>/dev/null)
  fi
done

systemctl daemon-reload
