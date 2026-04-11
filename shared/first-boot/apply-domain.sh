#!/usr/bin/env bash
# apply-domain.sh — generates the post-bootstrap checklist.
#
# Why no API calls: the audit (see VERIFICATION-REPORT.md §A) showed that
# Pangolin and PocketID both require an interactive UI step to create the
# first admin user and the first API key. Until those exist, no resource /
# IdP / OIDC client can be created via the REST APIs. Coolify is the same
# story for `Server → Proxy → None`.
#
# So this script is intentionally side-effect-free: it just inspects every
# service's service.yaml and writes /etc/personal-server/first-boot-checklist.txt
# with the exact URLs, env values, and clicks the operator needs to do once
# (and only once).

set -euo pipefail

CONF_DIR=/etc/personal-server
SERVICES_DIR=$CONF_DIR/services
CHECKLIST=$CONF_DIR/first-boot-checklist.txt

DOMAIN=$(yq -r '.domain' "$CONF_DIR/domain.yaml")

install -d -m 0700 "$CONF_DIR"
umask 077

{
  cat <<HEADER
================================================================
 personal-server — first-boot checklist
================================================================

Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) for domain: ${DOMAIN}

A handful of clicks are required, ONE TIME, because Pangolin /
PocketID / Coolify cannot create their first admin or API key
non-interactively. Do them in order; each step unlocks the next.

HEADER

  step=0
  next() { step=$((step+1)); printf '\n[%d] %s\n' "$step" "$1"; }

  next "Open Pangolin and create the admin account"
  cat <<EOF
       URL:      https://pangolin.${DOMAIN}
       Then:     Settings → API Keys → Create root key
       Save it:  echo '<paste-key>' > ${CONF_DIR}/pangolin-api-key
                 chmod 600 ${CONF_DIR}/pangolin-api-key
EOF

  next "Open PocketID and create the admin (passkey)"
  cat <<EOF
       URL:      https://pocketid.${DOMAIN}
       Then:     Settings → Admin → API Keys → Generate
       Save it:  echo '<paste-key>' > ${CONF_DIR}/pocketid-api-key
                 chmod 600 ${CONF_DIR}/pocketid-api-key
EOF

  next "Open Coolify and disable its proxy"
  if [[ -f $CONF_DIR/coolify-root.txt ]]; then
    src=$CONF_DIR/coolify-root.txt
    user=$(grep '^COOLIFY_ROOT_USERNAME=' "$src" | cut -d= -f2-)
    mail=$(grep '^COOLIFY_ROOT_USER_EMAIL=' "$src" | cut -d= -f2-)
    pass=$(grep '^COOLIFY_ROOT_USER_PASSWORD=' "$src" | cut -d= -f2-)
    cat <<EOF
       URL:      https://coolify.${DOMAIN}
       Login:    ${mail}  /  ${pass}
                 (also stored in ${src})
       Then:     Servers → localhost → Proxy → None  →  Save
                 (this stops Coolify from spawning coolify-proxy on
                  ports 80/443 already held by Pangolin Traefik)
EOF
  fi

  next "Wire PocketID into Pangolin as an OIDC IdP"
  cat <<EOF
       In Pangolin: Settings → Identity Providers → Add → OAuth2/OIDC
       Paste:
         Issuer URL:        https://pocketid.${DOMAIN}
         Authorization URL: https://pocketid.${DOMAIN}/authorize
         Token URL:         https://pocketid.${DOMAIN}/api/oidc/token
         Userinfo URL:      https://pocketid.${DOMAIN}/api/oidc/userinfo
         Client ID:         (created next step in PocketID)
         Client Secret:     (created next step in PocketID)
         Identifier path:   sub
         Email path:        email
         Name path:         name
         Scopes:            openid profile email
EOF

  next "Create the OIDC client in PocketID for Pangolin"
  cat <<EOF
       In PocketID: OIDC Clients → Add Client
         Name:           pangolin
         Callback URLs:  https://pangolin.${DOMAIN}/auth/callback
         PKCE:           off
       Copy the generated Client ID + Secret back into the Pangolin
       IdP form from step 4, then Save.
EOF

  next "(Optional) create Pangolin Resources for the self-hosted UIs"
  echo "       Each service below declares an upstream — paste it as a"
  echo "       Resource → Site upstream in Pangolin and pick its auth mode."
  echo
  for yaml in "$SERVICES_DIR"/*/service.yaml; do
    [[ -f $yaml ]] || continue
    has_pangolin=$(yq -r '.pangolin // "" | type' "$yaml")
    [[ $has_pangolin == "!!map" ]] || continue
    name=$(yq -r '.name' "$yaml")
    sub=$(yq -r '.pangolin.subdomain // .name' "$yaml")
    upstream=$(yq -r '.pangolin.upstream // ""' "$yaml")
    auth=$(yq -r '.pangolin.auth // "proxy-auth"' "$yaml")
    printf '         %-10s  %s.%s  →  %s   [auth: %s]\n' \
      "$name" "$sub" "$DOMAIN" "$upstream" "$auth"
  done

  cat <<FOOTER

----------------------------------------------------------------
When the 5 mandatory steps above are done, run:
    personal-server reconfigure
to re-run this checklist (idempotent) and confirm everything is
wired. Sub-systems can be reached locally without going through
Pangolin via:
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
