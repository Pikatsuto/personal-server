#!/usr/bin/env bash
# install_linux.sh already generated SECRET_KEY and wrote /opt/webzfs/.env.
# It also already wrote /etc/systemd/system/webzfs.service. We just need to
# enable it at first-boot.
set -euo pipefail
systemctl daemon-reload
systemctl enable --now webzfs.service
