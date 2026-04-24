#!/usr/bin/env bash
# Runs AFTER all services' configure.sh have completed.
# Iterates over every services/*/service.yaml with an `sso:` block and:
#   1. Creates the OIDC client in Keycloak (via Admin API)
#   2. Runs the service's sso.script (if method=exec) to wire OIDC
#      into the service (e.g. `incus config set oidc.*`)
#
# This file is specific to Keycloak — the wizard calls any post-configure.sh
# found in a service's folder, generically. Zero hardcoded service names
# elsewhere in the code.

set -euo pipefail

SERVICES_DIR=/etc/personal-server/services
source /opt/personal-server/lib/env-loader.sh
source /opt/personal-server/keycloak/lib/keycloak.sh

ps_load_all
export PS_KEYCLOAK_REALM=$KC_REALM

KC_TOKEN=$(keycloak_admin_token 2>/dev/null || true)
if [[ -z ${KC_TOKEN:-} || $KC_TOKEN == null ]]; then
  echo "keycloak post-configure: no admin token, skipping SSO auto-config"
  exit 0
fi

for yaml in "$SERVICES_DIR"/*/service.yaml; do
  [[ -f $yaml ]] || continue
  sso_type=$(yq -r '.sso // "" | type' "$yaml")
  [[ $sso_type == "!!map" ]] || continue

  svc=$(yq -r '.name' "$yaml")
  sub=$(yq -r '.proxy.subdomain // .name' "$yaml")
  method=$(yq -r '.sso.method // ""' "$yaml")
  # client_id defaults to the service name unless overridden in sso.client_id
  client_id=$(yq -r ".sso.client_id // \"$svc\"" "$yaml")
  # secret_var defaults to <svc>_oidc_client_secret unless overridden
  secret_key=$(yq -r ".sso.secret_var // \"${svc}_oidc_client_secret\"" "$yaml")
  secret_var="PS_${secret_key^^}"
  client_secret=${!secret_var:-}
  redirect_uri="https://${sub}.${PS_DOMAIN}/*"

  if [[ -n $client_secret ]]; then
    keycloak_ensure_client "$KC_TOKEN" "$KC_REALM" "$client_id" "$client_secret" "$redirect_uri" \
      >/dev/null 2>&1 && echo "keycloak post-configure: $svc → OIDC client created"
  fi

  case $method in
    file)
      # Config file is rendered by render-all-units.sh at boot. Restart
      # the service so it picks up the new config after OIDC client creation.
      systemctl restart "personal-server-$svc.service" 2>/dev/null || true
      ;;
    exec)
      script=$(yq -r '.sso.script' "$yaml")
      echo "keycloak post-configure: $svc → running SSO exec"
      bash -c "$script" || echo "keycloak post-configure: $svc script exited $?"
      ;;
    env)
      env_file=$(yq -r '.sso.env_file' "$yaml")
      [[ -z $env_file || $env_file == null ]] && continue
      install -d -m 0755 "$(dirname "$env_file")"
      # Render each var via envsubst with the caller's environment
      while IFS= read -r key; do
        [[ -z $key ]] && continue
        val=$(yq -r ".sso.vars.\"$key\"" "$yaml")
        rendered=$(echo "$val" | envsubst)
        # Replace or append the KEY=VAL line in the env file
        if grep -q "^$key=" "$env_file" 2>/dev/null; then
          sed -i "s|^$key=.*|$key=$rendered|" "$env_file"
        else
          echo "$key=$rendered" >> "$env_file"
        fi
      done < <(yq -r '.sso.vars | keys[]' "$yaml")
      chmod 600 "$env_file"
      echo "keycloak post-configure: $svc → env injected into $env_file"
      # Restart the service to pick up new env vars
      systemctl restart "personal-server-$svc.service" 2>/dev/null || true
      ;;
  esac
done
