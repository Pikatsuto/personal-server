#!/usr/bin/env bash
# Stages Pangolin's compose templates into /opt/personal-server/pangolin/.
# Templates carry .tmpl suffixes; configure.sh substitutes envs at first boot.
set -euo pipefail

install -d -m 0755 /opt/personal-server/pangolin
cp -a "$(dirname "$0")/files/." /opt/personal-server/pangolin/
