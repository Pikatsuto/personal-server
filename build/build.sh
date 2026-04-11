#!/usr/bin/env bash
# build.sh — orchestrates a full build.
#
# Usage:
#   ./build/build.sh dev   [service ...]   # tolerates per-service failures
#   ./build/build.sh prod  [service ...]   # any failure aborts
#
# Stages:
#   1. generate.sh           → produces build/Dockerfile + build/docker-bake.hcl
#   2. per-service bake      → builds each service-<name> target, fills report.json
#   3. generate.sh --filter  → regenerates final stage filtering failed services (dev only)
#   4. final bake            → assembles personal-server:<tag>
#
# In dev mode build/report.json is also baked into the image at
# /etc/personal-server/build-report.json so the running server knows what's missing.

set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BUILD_DIR=$REPO_ROOT/build
LOG_DIR=$BUILD_DIR/logs
REPORT=$BUILD_DIR/report.json

if (($# < 1)); then
  echo "usage: $0 dev|prod [service ...]" >&2
  exit 2
fi
MODE=$1; shift
case $MODE in dev|prod) ;; *) echo "build: mode must be dev|prod" >&2; exit 2 ;; esac

# shellcheck source=../shared/lib/yaml.sh
source "$REPO_ROOT/shared/lib/yaml.sh"
# shellcheck source=../shared/lib/service-loader.sh
REPO_ROOT=$REPO_ROOT source "$REPO_ROOT/shared/lib/service-loader.sh"

mkdir -p "$LOG_DIR"

# Determine the service set we're building.
if (($# > 0)); then
  selected=("$@")
else
  mapfile -t selected < <(services_list_topo)
fi

REGISTRY=${REGISTRY:-ghcr.io/local}
IMAGE_NAME=${IMAGE_NAME:-personal-server}
TAG=${TAG:-${MODE}-$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo local)}
export REGISTRY IMAGE_NAME TAG

# NO_CACHE=1 forces both a re-pull of every `FROM` base image and a full
# rebuild of every stage (no layer cache hit). Used by the weekly scheduled
# workflow to capture upstream bumps (AlmaLinux bootc digest, EPEL/CRB/ZFS
# kmod package updates, docker-ce releases, Incus COPR builds, WebZFS git
# HEAD, Zabbly incus-ui, …). BuildKit's content-addressed layer store
# still dedupes identical outputs, so rebuilds that produce no real change
# cost only CPU/bandwidth, not registry storage.
BAKE_FLAGS=""
if [[ ${NO_CACHE:-0} == 1 ]]; then
  BAKE_FLAGS="--pull --no-cache"
fi

echo "build: mode=$MODE tag=$TAG services=${selected[*]} no_cache=${NO_CACHE:-0}"

"$BUILD_DIR/generate.sh"

# Initialise empty report.
echo '{}' > "$REPORT"

abort=0
for svc in "${selected[@]}"; do
  log=$LOG_DIR/${svc}.log
  echo "build: ── service-$svc ──"
  start=$(date +%s)
  if docker buildx bake $BAKE_FLAGS -f "$BUILD_DIR/docker-bake.hcl" "service-$svc" 2>&1 | tee "$log"; then
    status=ok
  else
    status=fail
    if [[ $MODE == prod ]]; then
      abort=1
    fi
  fi
  end=$(date +%s)
  jq --arg s "$svc" --arg st "$status" --arg log "$log" --argjson dur $((end-start)) \
    '.[$s] = {status:$st, duration_sec:$dur, log:$log}' "$REPORT" > "$REPORT.tmp"
  mv "$REPORT.tmp" "$REPORT"
  if (( abort )); then
    echo "build: prod mode — aborting after first failure ($svc)" >&2
    exit 1
  fi
done

if [[ $MODE == dev ]]; then
  "$BUILD_DIR/generate.sh" --filter-from-report "$REPORT"
fi

echo "build: assembling final image"
docker buildx bake $BAKE_FLAGS -f "$BUILD_DIR/docker-bake.hcl" final

# Extract a manifest of everything pinned in this build: image digest, full
# rpm set, and every `image:` reference in the service trees. This file is
# uploaded to the rolling `weekly` GitHub release so the next build can diff
# against it and surface what changed (OS package bumps captured by the
# weekly --no-cache rebuild, new Pangolin/Gerbil versions, etc.).
IMG="$REGISTRY/$IMAGE_NAME:$TAG"
MANIFEST=$BUILD_DIR/manifest.txt
{
  printf '# personal-server manifest\n'
  printf 'image: %s\n' "$IMG"
  digest=$(docker image inspect "$IMG" --format '{{.Id}}' 2>/dev/null || echo '?')
  printf 'digest: %s\n' "$digest"
  printf 'built_at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '\n## rpm packages\n'
  docker run --rm --entrypoint /bin/sh "$IMG" -c 'rpm -qa | sort' 2>/dev/null || echo '(rpm -qa failed)'
  printf '\n## pinned container images referenced by service trees\n'
  # Catches docker.io/…, ghcr.io/…, quay.io/…, containrrr/…, anywhere in the
  # service tree (compose templates, systemd units, install.sh). Template
  # vars like ${PS_PANGOLIN_VERSION} are kept intact — they're resolved at
  # runtime, not at build time, so we record the template literal as-is.
  grep -RhoE '(docker\.io|ghcr\.io|quay\.io|containrrr)/[a-zA-Z0-9._/${}-]+(:[a-zA-Z0-9._${}-]+)?' \
    "$REPO_ROOT/services" 2>/dev/null | sort -u
} > "$MANIFEST"

echo
echo "build: report ──────────────────────────────"
jq -r 'to_entries[] | "  \(.key): \(.value.status) (\(.value.duration_sec)s)"' "$REPORT"
echo "build: image = $IMG"
echo "build: manifest = $MANIFEST ($(wc -l <"$MANIFEST") lines)"
