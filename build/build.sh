#!/usr/bin/env bash
# build.sh — full validate-and-publish cycle.
#
# Usage:
#   ./build/build.sh dev     # tag :dev-<sha>, also moves :dev on success
#   ./build/build.sh prod    # tag :prod-<sha>, moves :latest on success
#   NO_CACHE=1 ./build/build.sh prod   # weekly: --pull --no-cache
#
# Cycle:
#   1. Build #1 — image with :latest everywhere (digests in service.yaml
#      ignored; the templates render against `repo:latest` because every
#      digest field is empty in this transient state).
#   2. run-tests.sh against build #1 → results-1.env (per-service pass/fail
#      + the candidate digest each :latest currently resolves to).
#   3. If hard_fail=1 (a service WITHOUT an images: block failed) →
#      abort, no commit, no push.
#   4. Patch service.yaml IN MEMORY (working copies under build/yaml-stage/):
#      for every service whose test PASSED, set its images.<key>.digest to
#      the resolved candidate. Failed services keep their previous digest.
#   5. Build #2 with the patched yaml-stage as the source for each service's
#      service.yaml. The result is the actual production candidate image.
#   6. run-tests.sh against build #2 → results-2.env.
#   7. If results-2 has any failure (hard or soft) → abort, NO commit,
#      NO push, no tag move. Production keeps its current image.
#   8. If results-2 is all green → commit the patched service.yaml files
#      to disk, push the image, move the floating tag (:latest or :dev).
#
# The user's golden rule: nothing is committed and nothing is pushed unless
# build #2 has fully validated.

set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BUILD_DIR=$REPO_ROOT/build
LOG_DIR=$BUILD_DIR/logs
REPORT=$BUILD_DIR/report.json
YAML_STAGE=$BUILD_DIR/yaml-stage
RESULTS_1=$BUILD_DIR/results-1.json
RESULTS_2=$BUILD_DIR/results-2.json

if (($# < 1)); then
  echo "usage: $0 dev|prod" >&2
  exit 2
fi
MODE=$1; shift
case $MODE in dev|prod) ;; *) echo "build: mode must be dev|prod" >&2; exit 2 ;; esac

# shellcheck source=../shared/lib/yaml.sh
source "$REPO_ROOT/shared/lib/yaml.sh"
# shellcheck source=../shared/lib/service-loader.sh
REPO_ROOT=$REPO_ROOT source "$REPO_ROOT/shared/lib/service-loader.sh"

mkdir -p "$LOG_DIR" "$YAML_STAGE"

REGISTRY=${REGISTRY:-ghcr.io/local}
IMAGE_NAME=${IMAGE_NAME:-personal-server}
SHA=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo local)
TAG_BUILD1="${MODE}-${SHA}-build1"
TAG_BUILD2="${MODE}-${SHA}-build2"
export REGISTRY IMAGE_NAME

BAKE_FLAGS=""
if [[ ${NO_CACHE:-0} == 1 ]]; then
  BAKE_FLAGS="--pull --no-cache"
fi

mapfile -t selected < <(services_list_topo)
echo "build: mode=$MODE sha=$SHA services=${selected[*]} no_cache=${NO_CACHE:-0}"

# ─── change detection ───────────────────────────────────────────────
# Compare against the last successfully published image on the registry.
FLOATING=$([[ $MODE == prod ]] && echo latest || echo dev)
PREV_IMG="$REGISTRY/$IMAGE_NAME:$FLOATING"
PREV_SHA=""
declare -A svc_changed=()

# Get the commit SHA baked into the previous successful image
PREV_SHA=$(docker pull "$PREV_IMG" >/dev/null 2>&1 && \
  docker inspect "$PREV_IMG" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' 2>/dev/null || true)
[[ $PREV_SHA == "<no value>" ]] && PREV_SHA=""

global_changed=0
if [[ -z $PREV_SHA ]]; then
  echo "build: no previous successful build found — full rebuild"
  global_changed=1
else
  echo "build: last successful build: $PREV_SHA"
  if ! git diff --quiet "$PREV_SHA" HEAD -- shared/ build/templates/ build/generate.sh build/build.sh build/run-tests.sh 2>/dev/null; then
    echo "build: shared/build code changed — all services need rebuild"
    global_changed=1
  fi
  base_repo=$(yq -r '.base_image.repo' "$BASE_YAML")
  base_cur=$(yq -r '.base_image.digest // ""' "$BASE_YAML")
  base_upstream=$(resolve_digest_from_upstream "$base_repo")
  if [[ -n $base_upstream && $base_cur != "$base_upstream" ]]; then
    echo "build: base image digest changed — all services need rebuild"
    global_changed=1
  fi
fi

for svc in "${selected[@]}"; do
  if [[ $global_changed == 1 ]]; then
    svc_changed[$svc]=1
    continue
  fi
  changed=0
  # Code changed since last successful build?
  if ! git diff --quiet "$PREV_SHA" HEAD -- "services/$svc/" 2>/dev/null; then
    echo "build: $svc — code changed"
    changed=1
  fi
  # Upstream image digest changed vs service.yaml?
  yaml=$REPO_ROOT/services/$svc/service.yaml
  if yq -e '.images' "$yaml" >/dev/null 2>&1; then
    while IFS= read -r key; do
      [[ -z $key ]] && continue
      repo=$(yq -r ".images.$key.repo" "$yaml")
      cur=$(yq -r ".images.$key.digest // \"\"" "$yaml")
      upstream=$(resolve_digest_from_upstream "$repo")
      if [[ -n $upstream && $upstream != "$cur" ]]; then
        echo "build: $svc.$key — upstream digest changed"
        changed=1
      fi
    done < <(yq -r '.images | keys[]' "$yaml" 2>/dev/null)
  fi
  svc_changed[$svc]=$changed
done

n_changed=0
for svc in "${selected[@]}"; do
  [[ ${svc_changed[$svc]} == 1 ]] && n_changed=$((n_changed + 1))
done

if [[ $n_changed == 0 ]]; then
  echo "build: nothing changed since last successful build — skipping"
  exit 0
fi

echo "build: $n_changed/${#selected[@]} services need rebuild/retest"
changed_list=""
for svc in "${selected[@]}"; do
  [[ ${svc_changed[$svc]} == 1 ]] && changed_list="$changed_list $svc"
done
export CHANGED_SERVICES="${changed_list# }"

# ─── helpers ─────────────────────────────────────────────────────────
resolve_digest_from_upstream() {
  local repo=$1
  docker buildx imagetools inspect "${repo}:latest" \
    --format '{{json .Manifest.Digest}}' 2>/dev/null | tr -d '"' || \
  docker manifest inspect "${repo}:latest" 2>/dev/null \
    | jq -r '.config.digest // .manifests[0].digest // ""' 2>/dev/null || true
}

do_build() {
  local tag=$1
  TAG=$tag REGISTRY=$REGISTRY IMAGE_NAME=$IMAGE_NAME \
    "$BUILD_DIR/generate.sh"

  echo '{}' > "$REPORT"
  for svc in "${selected[@]}"; do
    log=$LOG_DIR/${svc}-${tag}.log
    echo "build: ── service-$svc ($tag) ──"
    start=$(date +%s)
    if TAG=$tag REGISTRY=$REGISTRY IMAGE_NAME=$IMAGE_NAME \
       docker buildx bake $BAKE_FLAGS -f "$BUILD_DIR/docker-bake.hcl" "service-$svc" 2>&1 | tee "$log"; then
      status=ok
    else
      status=fail
      echo "build: $svc failed during $tag, aborting" >&2
      return 1
    fi
    end=$(date +%s)
    jq --arg s "$svc" --arg st "$status" --arg log "$log" --argjson dur $((end-start)) \
      '.[$s] = {status:$st, duration_sec:$dur, log:$log}' "$REPORT" > "$REPORT.tmp"
    mv "$REPORT.tmp" "$REPORT"
  done

  echo "build: assembling final image ($tag) TEST_PRESEED=${TEST_PRESEED:-0}"
  local full_sha
  full_sha=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "")
  TAG=$tag REGISTRY=$REGISTRY IMAGE_NAME=$IMAGE_NAME \
    docker buildx bake $BAKE_FLAGS \
    --set "final.args.TEST_PRESEED=${TEST_PRESEED:-0}" \
    --set "final.args.BUILD_SHA=${full_sha}" \
    -f "$BUILD_DIR/docker-bake.hcl" final
}

# Backup every services/<svc>/service.yaml before mutating in place. Used
# so we can revert if build #2 fails.
BASE_YAML=$REPO_ROOT/shared/base-packages.yaml
YAML_BACKUP=$BUILD_DIR/yaml-backup
backup_yamls() {
  rm -rf "$YAML_BACKUP"
  mkdir -p "$YAML_BACKUP"
  cp "$BASE_YAML" "$YAML_BACKUP/base-packages.yaml"
  local svc
  for svc in "${selected[@]}"; do
    install -d -m 0755 "$YAML_BACKUP/$svc"
    cp "$REPO_ROOT/services/$svc/service.yaml" "$YAML_BACKUP/$svc/service.yaml"
  done
}
restore_yamls() {
  cp "$YAML_BACKUP/base-packages.yaml" "$BASE_YAML"
  local svc
  for svc in "${selected[@]}"; do
    [[ -f $YAML_BACKUP/$svc/service.yaml ]] || continue
    cp "$YAML_BACKUP/$svc/service.yaml" "$REPO_ROOT/services/$svc/service.yaml"
  done
}

# Patch the working tree's service.yaml files in place from a results
# JSON produced by run-tests.sh. Returns 0 if hard_fail=0, 1 otherwise.
patch_yamls_from_results() {
  local results=$1
  local hard_fail
  hard_fail=$(jq -r '.hard_fail' "$results")
  if [[ $hard_fail == 1 ]]; then
    return 1
  fi

  # For each digest entry: bump the yaml only if the corresponding service's
  # test passed.
  local entry svc image digest passed yaml
  while IFS=$'\t' read -r key digest; do
    svc=${key%%:*}
    image=${key##*:}
    passed=$(jq -r --arg s "$svc" '.pass[$s] // 0' "$results")
    if [[ $passed == 1 ]]; then
      yaml=$REPO_ROOT/services/$svc/service.yaml
      yq -i ".images.$image.digest = \"$digest\"" "$yaml"
      echo "build: $svc.$image → $digest"
    fi
  done < <(jq -r '.digests | to_entries[] | "\(.key)\t\(.value)"' "$results")
  return 0
}

# Final gate: returns 0 if every test in the results JSON passed.
results_all_green() {
  local results=$1
  local hard_fail
  hard_fail=$(jq -r '.hard_fail' "$results")
  [[ $hard_fail == 0 ]] || return 1
  local n_failed
  n_failed=$(jq -r '[.pass[] | select(. != 1)] | length' "$results")
  [[ $n_failed == 0 ]]
}

# ─── cycle ───────────────────────────────────────────────────────────
echo
# Generate a fresh SSH key pair for this test run (never committed to git).
# The public key is baked into the test image; the private key is used by
# run-tests.sh to SSH into the QEMU VM. Both are deleted after the run.
SSH_KEY=$BUILD_DIR/test-preseed/id_ed25519
rm -f "$SSH_KEY" "${SSH_KEY}.pub"
ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -q -C "personal-server-test-$(date +%s)"

echo "═══ build #1 (all :latest, test preseed baked in) ══════════════════"
TEST_PRESEED=1 do_build "$TAG_BUILD1"
IMG1="$REGISTRY/$IMAGE_NAME:$TAG_BUILD1"

echo
echo "═══ run-tests against build #1 (--from-latest) ═══════════════════"
"$BUILD_DIR/run-tests.sh" "$IMG1" "$RESULTS_1" --from-latest

backup_yamls
if ! patch_yamls_from_results "$RESULTS_1"; then
  echo "build: hard fail in build #1 results — aborting" >&2
  restore_yamls
  exit 1
fi

# Pin the base image digest (same pattern as service images)
base_repo=$(yq -r '.base_image.repo' "$BASE_YAML")
base_digest=$(resolve_digest_from_upstream "$base_repo")
if [[ -n $base_digest ]]; then
  yq -i ".base_image.digest = \"$base_digest\"" "$BASE_YAML"
  echo "build: base_image → $base_digest"
fi

echo
echo "═══ build #2 (digest-pinned, test preseed baked in) ════════════════"
TEST_PRESEED=1 do_build "$TAG_BUILD2"
IMG2="$REGISTRY/$IMAGE_NAME:$TAG_BUILD2"

echo
echo "═══ run-tests against build #2 (--from-yaml) ═════════════════════"
"$BUILD_DIR/run-tests.sh" "$IMG_PROD" "$RESULTS_2" --from-yaml

if ! results_all_green "$RESULTS_2"; then
  echo "build: build #2 has failures — refusing to push, reverting yamls" >&2
  jq '.pass | to_entries[] | select(.value != 1) | .key' "$RESULTS_2"
  restore_yamls
  exit 1
fi

# Destroy test SSH key before building production image
rm -f "$SSH_KEY" "${SSH_KEY}.pub"

echo
echo "═══ build #3 (production — NO test preseed, clean image) ══════════"
TAG_PROD="${MODE}-${SHA}"
do_build "$TAG_PROD"
IMG_PROD="$REGISTRY/$IMAGE_NAME:$TAG_PROD"

echo
echo "═══ all green — leaving yaml patches in worktree + tagging ═══════"

# Floating tag move (atomic — same digest, additional tag)
FLOATING=$([[ $MODE == prod ]] && echo latest || echo dev)
docker tag "$IMG_PROD" "$REGISTRY/$IMAGE_NAME:$FLOATING"

# Manifest extraction (kept from previous build.sh — see commit history)
MANIFEST=$BUILD_DIR/manifest.txt
{
  printf '# personal-server manifest\n'
  printf 'image: %s\n' "$IMG_PROD"
  digest=$(docker image inspect "$IMG_PROD" --format '{{.Id}}' 2>/dev/null || echo '?')
  printf 'digest: %s\n' "$digest"
  printf 'built_at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '\n## rpm packages\n'
  docker run --rm --entrypoint /bin/sh "$IMG_PROD" -c 'rpm -qa | sort' 2>/dev/null \
    || echo '(rpm -qa failed)'
  printf '\n## validated digests (from services/*/service.yaml)\n'
  for svc in "${selected[@]}"; do
    yaml=$REPO_ROOT/services/$svc/service.yaml
    yq -e '.images' "$yaml" >/dev/null 2>&1 || continue
    while IFS= read -r key; do
      [[ -z $key ]] && continue
      repo=$(yq -r ".images.$key.repo" "$yaml")
      digest=$(yq -r ".images.$key.digest" "$yaml")
      printf '%s.%s: %s@%s\n' "$svc" "$key" "$repo" "${digest:-:latest}"
    done < <(yq -r '.images | keys[]' "$yaml")
  done
} > "$MANIFEST"

echo
echo "build: ✅ image  = $IMG_PROD"
echo "build: ✅ tag    = $REGISTRY/$IMAGE_NAME:$FLOATING (atomic alias)"
echo "build: ✅ manifest = $MANIFEST"
echo "build: ✅ patched yamls in working tree (commit them to land in prod)"
