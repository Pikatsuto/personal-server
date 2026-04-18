#!/usr/bin/env bash
# tests/lib.sh — helpers sourced by services/<svc>/test.sh.
# Lives at /var/lib/personal-server/tests/lib.sh inside the test VM.
#
# Conventions:
#   - Tests run inside a systemd-booted bootc container with the host's
#     docker socket bind-mounted, so any `docker` command spawns sibling
#     containers on the host.
#   - Each test.sh receives `IMAGE_<KEY>_REF` env vars for every key in
#     its own service.yaml `images:` block (resolved by build/run-tests.sh
#     against the candidate :latest digest).
#   - Each test.sh is responsible for its own teardown — register cleanup
#     handlers via `tests_cleanup_register`.

set -uo pipefail

TESTS_TMP=${TESTS_TMP:-$(mktemp -d /tmp/personal-server-test.XXXXXX)}
declare -a TESTS_CLEANUP_FNS=()

tests_cleanup_register() {
  TESTS_CLEANUP_FNS+=("$1")
}

tests_run_cleanup() {
  local fn
  for fn in "${TESTS_CLEANUP_FNS[@]}"; do
    "$fn" 2>/dev/null || true
  done
  rm -rf "$TESTS_TMP" 2>/dev/null || true
}
trap tests_run_cleanup EXIT

tests_log() { echo "  [test] $*"; }
tests_fail() { echo "  [test FAIL] $*" >&2; exit 1; }

# wait_for_http <url> [<expected_code>] [<max_seconds>]
# Polls a URL via curl from the current network namespace. Use this for
# native services running directly on the host (not in containers).
# Polls until the URL returns the expected HTTP code (default 200) or
# any 2xx/3xx if expected is "any". Fails after max_seconds (default 60).
wait_for_http() {
  local url=$1
  local expected=${2:-200}
  local max=${3:-60}
  local i code
  for i in $(seq 1 "$max"); do
    code=$(curl -sk -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo 000)
    case $expected in
      any) [[ $code =~ ^[23] ]] && { tests_log "$url → HTTP $code"; return 0; } ;;
      *)   [[ $code == "$expected" ]] && { tests_log "$url → HTTP $code"; return 0; } ;;
    esac
    sleep 1
  done
  tests_fail "$url never returned HTTP $expected (last code: $code)"
}

# wait_for_http_in_container <container> <port> [<path>] [<expected>] [<max>]
# Polls a URL using a curl sidecar that JOINS the target container's
# network namespace via `--network container:<name>`. Use this when the
# target service is running in a sibling Docker container (PocketID,
# Arcane, Pangolin compose stack…) — the test container's localhost cannot
# reach a port on a sibling, so we need to be IN its netns.
CURL_SIDECAR_IMAGE=${CURL_SIDECAR_IMAGE:-curlimages/curl:latest}
wait_for_http_in_container() {
  local target=$1
  local port=$2
  local path=${3:-/}
  local expected=${4:-200}
  local max=${5:-60}
  local i code
  for i in $(seq 1 "$max"); do
    code=$(docker run --rm --network "container:$target" "$CURL_SIDECAR_IMAGE" \
      -sk -o /dev/null -w '%{http_code}' "http://localhost:${port}${path}" 2>/dev/null || echo 000)
    case $expected in
      any) [[ $code =~ ^[23] ]] && { tests_log "container:$target localhost:$port$path → HTTP $code"; return 0; } ;;
      *)   [[ $code == "$expected" ]] && { tests_log "container:$target localhost:$port$path → HTTP $code"; return 0; } ;;
    esac
    sleep 1
  done
  tests_fail "container:$target localhost:$port$path never returned HTTP $expected (last code: $code)"
}

# wait_for_tcp <host> <port> [<max_seconds>]
wait_for_tcp() {
  local host=$1 port=$2 max=${3:-30}
  local i
  for i in $(seq 1 "$max"); do
    if (echo > /dev/tcp/"$host"/"$port") 2>/dev/null; then
      tests_log "$host:$port reachable"
      return 0
    fi
    sleep 1
  done
  tests_fail "$host:$port never became reachable"
}

# docker_run_bg <name> <image> [<extra args>...] -- <cmd...>
# Starts a container in the background, registers a cleanup, returns its name.
docker_run_bg() {
  local name=$1 image=$2; shift 2
  docker rm -f "$name" >/dev/null 2>&1 || true
  if ! docker run -d --name "$name" "$@" "$image" >/dev/null; then
    tests_fail "docker run failed for $name ($image)"
  fi
  tests_cleanup_register "docker rm -f $name >/dev/null 2>&1"
  tests_log "started $name from $image"
}

# expect_running <container_name>
# Asserts the container is in the `running` state.
expect_running() {
  local name=$1
  local state
  state=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo missing)
  [[ $state == running ]] || tests_fail "$name is not running (state: $state)"
  tests_log "$name is running"
}
