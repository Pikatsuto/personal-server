#!/usr/bin/env bash
# keycloak.sh — helper functions for service configure.sh scripts that
# need to create or fetch OIDC clients in the `personal-server` realm.
#
# Assumes Keycloak is reachable at http://localhost:8180 (bound on host
# by the keycloak service compose).

KC_LOCAL=${KC_LOCAL:-http://localhost:8180}
_kc_yaml=/etc/personal-server/services/keycloak/service.yaml
KC_REALM=${KC_REALM:-$(yq -r '.config.realm // ""' "$_kc_yaml" 2>/dev/null)}

keycloak_admin_token() {
  # The Keycloak bootstrap admin is created from the wizard's shared
  # admin account (PS_ADMIN_USERNAME / PS_ADMIN_PASSWORD). Those vars are
  # exported by wizard.sh before each service's configure.sh runs.
  #
  # Retry up to 2min: even after keycloak's configure.sh returns, the
  # token endpoint can momentarily return a transient error while the
  # master realm finishes initializing (slow on non-KVM CI runners).
  local user=${PS_ADMIN_USERNAME:?PS_ADMIN_USERNAME not set}
  local pass=${PS_ADMIN_PASSWORD:?PS_ADMIN_PASSWORD not set}
  local tok=""
  for _ in $(seq 1 60); do
    # --data-urlencode: the password is base64 so may contain + or / that
    # need URL-encoding (otherwise '+' becomes a space in form bodies).
    tok=$(curl -fsS -X POST "$KC_LOCAL/realms/master/protocol/openid-connect/token" \
      --data-urlencode "grant_type=password" \
      --data-urlencode "client_id=admin-cli" \
      --data-urlencode "username=$user" \
      --data-urlencode "password=$pass" 2>/dev/null \
      | jq -r '.access_token // ""' 2>/dev/null)
    [[ -n $tok && $tok != null ]] && { echo "$tok"; return 0; }
    sleep 2
  done
  echo "keycloak_admin_token: no token after 2min" >&2
  return 1
}

# keycloak_ensure_client <token> <realm> <client_id> <client_secret> <redirect_uri>
# Creates the client if it doesn't exist. Idempotent.
keycloak_ensure_client() {
  local token=$1 realm=$2 client_id=$3 client_secret=$4 redirect_uri=$5

  # Check if client already exists
  local existing
  existing=$(curl -fsS -H "Authorization: Bearer $token" \
    "$KC_LOCAL/admin/realms/$realm/clients?clientId=$client_id" \
    | jq -r '.[0].id // ""')

  if [[ -n $existing && $existing != "null" ]]; then
    # Update the secret to match what we have in PS_*
    curl -fsS -X PUT "$KC_LOCAL/admin/realms/$realm/clients/$existing" \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" \
      -d "{\"secret\":\"$client_secret\",\"redirectUris\":[\"$redirect_uri\"]}"
    return 0
  fi

  curl -fsS -X POST "$KC_LOCAL/admin/realms/$realm/clients" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "{
      \"clientId\": \"$client_id\",
      \"enabled\": true,
      \"protocol\": \"openid-connect\",
      \"publicClient\": false,
      \"secret\": \"$client_secret\",
      \"redirectUris\": [\"$redirect_uri\"],
      \"webOrigins\": [\"+\"],
      \"standardFlowEnabled\": true,
      \"directAccessGrantsEnabled\": false
    }"
}

# keycloak_client_secret <token> <realm> <client_id>
# Returns the current secret for a client.
keycloak_client_secret() {
  local token=$1 realm=$2 client_id=$3
  local cid
  cid=$(curl -fsS -H "Authorization: Bearer $token" \
    "$KC_LOCAL/admin/realms/$realm/clients?clientId=$client_id" \
    | jq -r '.[0].id // ""')
  [[ -z $cid || $cid == "null" ]] && return 1
  curl -fsS -H "Authorization: Bearer $token" \
    "$KC_LOCAL/admin/realms/$realm/clients/$cid/client-secret" \
    | jq -r .value
}
