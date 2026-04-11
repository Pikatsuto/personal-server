#!/usr/bin/env bash
# Build-time stage: nothing to do. The actual image copies happen at
# first-boot via configure.sh because they need a running Incus daemon
# and network access — neither available inside a Docker build.
set -euo pipefail
