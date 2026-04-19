#!/usr/bin/env bash
# install_linux.sh already generated SECRET_KEY and wrote /opt/webzfs/.env.
# It also already wrote /etc/systemd/system/webzfs.service. We just need to
# add a drop-in for bootc compatibility and enable at first-boot.
set -euo pipefail

# bootc: /opt/webzfs is read-only. Redirect all runtime writes:
# - TMPDIR → /run/webzfs (created by RuntimeDirectory= in upstream unit)
# - HOME → /var/lib/webzfs (already has .config and .ssh symlinks)
# - worker-tmp-dir via gunicorn flag (not reliably settable via env var)
install -d -m 0755 /etc/systemd/system/webzfs.service.d
cat > /etc/systemd/system/webzfs.service.d/bootc.conf <<'DROPIN'
[Service]
Environment="TMPDIR=/run/webzfs"
Environment="HOME=/var/lib/webzfs"
ExecStart=
ExecStart=/opt/webzfs/.venv/bin/gunicorn -c config/gunicorn.conf.py --worker-tmp-dir /run/webzfs
DROPIN

systemctl daemon-reload
systemctl enable --now webzfs.service
