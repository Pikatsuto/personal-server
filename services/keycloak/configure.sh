#!/usr/bin/env bash
# Keycloak first-boot configure:
#   1. Ensure the coolify Docker network exists (shared with other services)
#   2. Start the Keycloak stack (Postgres + Keycloak)
#   3. Wait for Keycloak's health endpoint
#   4. Get an admin access token
#   5. Create the `personal-server` realm if missing
#   6. Export helpers (token, realm) for other services' configure.sh

set -euo pipefail

ADMIN_USER=${PS_ADMIN_USERNAME:?wizard must set PS_ADMIN_USERNAME}
ADMIN_PASS=${PS_ADMIN_PASSWORD:?wizard must set PS_ADMIN_PASSWORD}
ADMIN_EMAIL=${PS_ADMIN_EMAIL:-}
REALM=$(yq -r '.config.realm' /etc/personal-server/services/keycloak/service.yaml)
KC_LOCAL=http://localhost:8180

docker network create coolify 2>/dev/null || true

systemctl daemon-reload
systemctl enable --now personal-server-keycloak.service

get_admin_token() {
  # --data-urlencode is mandatory: the admin password is base64 which may
  # contain '+' and '/' that must be URL-encoded (otherwise '+' becomes
  # a space and Keycloak rejects with invalid_user_credentials).
  curl -fsS -X POST "$KC_LOCAL/realms/master/protocol/openid-connect/token" \
    --data-urlencode "grant_type=password" \
    --data-urlencode "client_id=admin-cli" \
    --data-urlencode "username=$ADMIN_USER" \
    --data-urlencode "password=$ADMIN_PASS" 2>/dev/null \
    | jq -r .access_token 2>/dev/null
}

# Wait for Keycloak to be fully ready: both the health endpoint AND the
# admin API (bootstrap admin user creation completes AFTER /health/ready).
# On a fresh QEMU VM, first boot can take 5-10min (Postgres cold start +
# Keycloak bootstrap). Poll up to 10min.
TOKEN=""
for _ in $(seq 1 300); do
  TOKEN=$(get_admin_token || true)
  [[ -n $TOKEN && $TOKEN != null ]] && break
  sleep 2
done
[[ -n $TOKEN && $TOKEN != null ]] || { echo "keycloak: failed to get admin token after 10min" >&2; exit 1; }

# Create the realm if it doesn't exist
if ! curl -fsS -H "Authorization: Bearer $TOKEN" "$KC_LOCAL/admin/realms/$REALM" >/dev/null 2>&1; then
  echo "keycloak: creating realm $REALM"
  curl -fsS -X POST "$KC_LOCAL/admin/realms" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"realm\":\"$REALM\",\"enabled\":true,\"sslRequired\":\"external\",\"registrationAllowed\":false}"
fi

# Create the admin user inside the realm (so the operator can log in to
# services that use OIDC via Keycloak). Idempotent.
user_id=$(curl -fsS -H "Authorization: Bearer $TOKEN" \
  "$KC_LOCAL/admin/realms/$REALM/users?username=$ADMIN_USER&exact=true" \
  | jq -r '.[0].id // ""')
if [[ -z $user_id ]]; then
  echo "keycloak: creating user $ADMIN_USER in realm $REALM"
  curl -fsS -X POST "$KC_LOCAL/admin/realms/$REALM/users" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg u "$ADMIN_USER" --arg e "$ADMIN_EMAIL" --arg p "$ADMIN_PASS" '{
      username: $u,
      email: $e,
      emailVerified: true,
      enabled: true,
      credentials: [{type:"password", value:$p, temporary:false}]
    }')"
  user_id=$(curl -fsS -H "Authorization: Bearer $TOKEN" \
    "$KC_LOCAL/admin/realms/$REALM/users?username=$ADMIN_USER&exact=true" \
    | jq -r '.[0].id // ""')
fi
# Assign the realm-level admin role so this user can manage the realm
admin_role=$(curl -fsS -H "Authorization: Bearer $TOKEN" \
  "$KC_LOCAL/admin/realms/$REALM/roles/admin" 2>/dev/null || echo "")
if [[ -n $admin_role && $admin_role != *error* ]]; then
  curl -fsS -X POST "$KC_LOCAL/admin/realms/$REALM/users/$user_id/role-mappings/realm" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "[$admin_role]" 2>/dev/null || true
fi

# Persist realm name so other services can read it
install -d -m 0700 /etc/personal-server
echo "$REALM" > /etc/personal-server/keycloak-realm
chmod 600 /etc/personal-server/keycloak-realm

# Save admin URL + username for the wizard summary. Password is the one
# the operator entered during the wizard — we don't re-log it anywhere.
cat > /etc/personal-server/keycloak-admin.txt <<EOF
KEYCLOAK_ADMIN_URL=https://auth.${PS_DOMAIN}/admin/
KEYCLOAK_ADMIN_USERNAME=$ADMIN_USER
EOF
chmod 600 /etc/personal-server/keycloak-admin.txt

echo "keycloak: ready. admin at https://auth.${PS_DOMAIN}/admin/"
