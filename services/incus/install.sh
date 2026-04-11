#!/usr/bin/env bash
# Native Incus install. The COPR neelc/incus does not ship `incus-ui-canonical`,
# so the web UI is fetched from the Zabbly APT repo (Stéphane Graber, upstream
# Incus maintainer) and extracted into /opt/incus.
#
# Procedure verified 2026-04-11 against:
#   https://discuss.linuxcontainers.org/t/tutorial-installing-the-web-ui-for-incus-on-fedora-or-other-redhat-based-distros/20986
#   https://pkgs.zabbly.com/incus/stable/dists/jammy/main/binary-amd64/Packages

set -euo pipefail

ZABBLY_BASE=https://pkgs.zabbly.com/incus/stable

# Find the latest incus-ui-canonical .deb in the Zabbly index. The package
# contains only static assets (no executables), so the architecture/release
# of the .deb is irrelevant on EL9.
PKG_REL=$(curl -fsSL "$ZABBLY_BASE/dists/jammy/main/binary-amd64/Packages" \
  | awk '/^Package: incus-ui-canonical$/{p=1} p && /^Filename:/{print $2; exit}')

if [[ -z $PKG_REL ]]; then
  echo "incus: failed to discover incus-ui-canonical .deb in Zabbly index" >&2
  exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
curl -fsSL "$ZABBLY_BASE/$PKG_REL" -o "$WORK/ui.deb"
mkdir -p "$WORK/extracted"
dpkg -x "$WORK/ui.deb" "$WORK/extracted"
install -d -m 0755 /opt/incus
rsync -aH "$WORK/extracted/opt/incus/." /opt/incus/

# Tell incus.service where the UI lives. systemd dropin (idempotent).
install -d -m 0755 /etc/systemd/system/incus.service.d
cat > /etc/systemd/system/incus.service.d/10-ui.conf <<'EOF'
[Service]
Environment=INCUS_UI=/opt/incus/ui/
EOF

# units enabled at first-boot via wizard's stage_units(), nothing to do here.
