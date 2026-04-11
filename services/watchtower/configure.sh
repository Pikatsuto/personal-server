#!/usr/bin/env bash
set -euo pipefail
systemctl enable --now personal-server-watchtower.timer
