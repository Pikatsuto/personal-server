#!/usr/bin/env bash
# run-tests.sh — builds a test image with pre-seeded answers + SSH key,
# converts it to a qcow2 via bootc-image-builder, boots it in QEMU/KVM
# (identical to production), then SSHes in to run each test.sh.
#
# No hacks: real boot, real systemd, real Docker daemon, real filesystem.
#
# Usage: build/run-tests.sh <oci-image> <results.json> --from-latest|--from-yaml

set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
IMG=${1:?usage: run-tests.sh <oci-image> <results.json> <mode>}
RESULTS=${2:?}
MODE=${3:?}
case $MODE in --from-latest|--from-yaml) ;; *) echo "invalid mode $MODE" >&2; exit 2 ;; esac

source "$REPO_ROOT/shared/lib/yaml.sh"
source "$REPO_ROOT/shared/lib/images.sh"

WORKDIR=$(mktemp -d /var/tmp/ps-test-vm.XXXXXX)
QCOW=$WORKDIR/disk.qcow2
SSH_KEY=$REPO_ROOT/build/test-preseed/id_ed25519
SSH_PORT=2222
VM_PID=""

cleanup() {
  if [[ ${KEEP_VM:-0} == 1 ]]; then
    echo "run-tests: KEEP_VM=1 — VM still running (pid=$VM_PID, ssh -p $SSH_PORT root@localhost)"
    echo "run-tests: workdir=$WORKDIR"
    return
  fi
  [[ -n $VM_PID ]] && kill "$VM_PID" 2>/dev/null || true
  # containers-storage has root-owned immutable overlay files; clean via
  # a privileged container that can actually remove them.
  docker run --rm --privileged --security-opt label=disable \
    -v "$WORKDIR":/w alpine rm -rf /w 2>/dev/null || true
  rm -rf "$WORKDIR" 2>/dev/null || true
}
trap cleanup EXIT

# ── 1. Build qcow2 ──────────────────────────────────────────────────
# The image was already built with TEST_PRESEED=1 by build.sh, so it
# has answers.yaml + SSH key baked in. We just need to convert to qcow2.
echo "run-tests: saving $IMG from Docker"
IMG_TAR=$WORKDIR/img.tar
docker save "$IMG" -o "$IMG_TAR"

CLEAN_STORAGE=$WORKDIR/cs
mkdir -p "$CLEAN_STORAGE"

echo "run-tests: loading into clean containers-storage"
docker run --rm --privileged \
  -v "$WORKDIR":/work \
  -v "$CLEAN_STORAGE":/var/lib/containers/storage \
  --entrypoint /bin/bash \
  quay.io/centos-bootc/bootc-image-builder:latest \
  -c 'podman load -i /work/img.tar' >/dev/null

echo "run-tests: building qcow2"
docker run --rm --privileged \
  --security-opt label=type:unconfined_t \
  -v "$WORKDIR":/output \
  -v "$CLEAN_STORAGE":/var/lib/containers/storage \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type qcow2 --rootfs xfs "$IMG"

# Fix qcow2 ownership (builder runs as root). SELinux on Fedora prevents
# cross-context chown even in --privileged; label=disable bypasses it.
docker run --rm --privileged --security-opt label=disable \
  -v "$WORKDIR":/w alpine sh -c \
  "chown -R $(id -u):$(id -g) /w/qcow2 && rm -rf /w/cs /w/img.tar"
# Resize the disk (default 10GB is too small for all Docker image pulls)
mv "$WORKDIR/qcow2/disk.qcow2" "$QCOW"
qemu-img resize "$QCOW" 30G
rmdir "$WORKDIR/qcow2" 2>/dev/null || true

# ── 2. Boot QEMU/KVM ────────────────────────────────────────────────
echo "run-tests: booting VM"
qemu-system-x86_64 \
  -machine q35,accel=kvm -cpu host -smp 4 -m 8192 \
  -drive file="$QCOW",format=qcow2,if=virtio \
  -netdev user,id=net0,hostfwd=tcp::${SSH_PORT}-:22 \
  -device virtio-net-pci,netdev=net0 \
  -nographic &>"$WORKDIR/qemu.log" &
VM_PID=$!

# ── 3. Wait for SSH ─────────────────────────────────────────────────
SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -i $SSH_KEY -p $SSH_PORT root@localhost"
SCP="scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $SSH_KEY -P $SSH_PORT"

echo "run-tests: waiting for SSH…"
for i in $(seq 1 300); do
  $SSH echo ok 2>/dev/null && { echo "run-tests: SSH up (${i}s)"; break; }
  sleep 1
  kill -0 "$VM_PID" 2>/dev/null || { echo "run-tests: VM crashed"; tail -20 "$WORKDIR/qemu.log"; exit 1; }
  [[ $i -eq 300 ]] && { echo "run-tests: SSH never came up"; exit 1; }
done

# ── 4. Wait for wizard ──────────────────────────────────────────────
WIZARD_TIMEOUT=${WIZARD_TIMEOUT:-1800}
echo "run-tests: waiting for wizard (.configured), timeout=${WIZARD_TIMEOUT}s…"
for i in $(seq 1 "$WIZARD_TIMEOUT"); do
  # Check VM is still alive
  kill -0 "$VM_PID" 2>/dev/null || {
    echo "run-tests: VM crashed while waiting for wizard"
    tail -30 "$WORKDIR/qemu.log"
    exit 1
  }
  $SSH test -f /etc/personal-server/.configured 2>/dev/null && { echo "run-tests: wizard complete (${i}s)"; break; }
  if [[ $((i % 60)) -eq 0 ]]; then
    echo "run-tests: still waiting… (${i}s)"
    # Brief liveness report: which configure.sh processes are running + which services configured so far
    $SSH "ls /etc/personal-server/configured/ 2>/dev/null | tr '\n' ' '; echo; pgrep -af 'configure.sh' | head -20" 2>/dev/null || true
  fi
  sleep 1
  if [[ $i -eq $WIZARD_TIMEOUT ]]; then
    echo "run-tests: wizard never completed (${WIZARD_TIMEOUT}s) — dumping diagnostics"
    echo "── journalctl -u personal-server-firstboot (last 100) ──"
    $SSH journalctl -u personal-server-firstboot --no-pager -n 100 2>&1 || true
    echo "── configured markers ──"
    $SSH ls -la /etc/personal-server/configured/ 2>&1 || true
    echo "── running configure.sh processes ──"
    $SSH "ps auxf | grep -E 'configure|install|curl|docker' | head -50" 2>&1 || true
    echo "── docker ps ──"
    $SSH docker ps 2>&1 || true
    echo "── systemctl list-jobs ──"
    $SSH systemctl list-jobs 2>&1 || true
    exit 1
  fi
done

# Wait for systemd to settle
for i in $(seq 1 120); do
  state=$($SSH systemctl is-system-running 2>&1 || true)
  case $state in running|degraded) break ;; esac
  sleep 1
done
echo "run-tests: systemd settled ($state)"

# ── 5. Copy test scripts ────────────────────────────────────────────
$SSH mkdir -p /var/lib/personal-server/tests
$SCP "$REPO_ROOT/tests/lib.sh" "root@localhost:/var/lib/personal-server/tests/lib.sh"
for test_sh in "$REPO_ROOT"/services/*/test.sh; do
  [[ -f $test_sh ]] || continue
  svc=$(basename "$(dirname "$test_sh")")
  $SCP "$test_sh" "root@localhost:/var/lib/personal-server/tests/test-${svc}.sh"
done

# ── 6. Run tests ────────────────────────────────────────────────────
resolve_digest_from_upstream() {
  local repo=$1
  docker buildx imagetools inspect "${repo}:latest" \
    --format '{{json .Manifest.Digest}}' 2>/dev/null | tr -d '"' || \
  docker manifest inspect "${repo}:latest" 2>/dev/null \
    | jq -r '.config.digest // .manifests[0].digest // ""' 2>/dev/null || true
}

declare -A pass=()
declare -A digests=()
hard_fail=0

for svc_dir in "$REPO_ROOT"/services/*/; do
  svc=$(basename "$svc_dir")
  yaml=$svc_dir/service.yaml
  [[ -f "$svc_dir/test.sh" ]] || continue

  # Skip unchanged services if CHANGED_SERVICES is set
  if [[ -n ${CHANGED_SERVICES:-} ]]; then
    skip=1
    for cs in $CHANGED_SERVICES; do [[ $cs == "$svc" ]] && { skip=0; break; }; done
    if [[ $skip == 1 ]]; then
      echo "run-tests: ── $svc ── (skipped, unchanged)"
      pass[$svc]=1
      continue
    fi
  fi

  echo "run-tests: ── $svc ──"

  env_cmd=""
  has_images=0
  if yq -e '.images' "$yaml" >/dev/null 2>&1; then
    has_images=1
    while IFS= read -r key; do
      [[ -z $key ]] && continue
      repo=$(yq -r ".images.$key.repo" "$yaml")
      case $MODE in
        --from-latest)
          digest=$(resolve_digest_from_upstream "$repo")
          [[ -n $digest ]] && digests[$svc:$key]=$digest
          ref="${repo}@${digest:-latest}"
          ;;
        --from-yaml)
          digest=$(yq -r ".images.$key.digest // \"\"" "$yaml")
          if [[ -n $digest && $digest != null ]]; then ref="${repo}@${digest}"
          else ref="${repo}:latest"; fi
          ;;
      esac
      KEY=${key^^}
      env_cmd="$env_cmd export IMAGE_${KEY}_REF='$ref';"
      echo "  IMAGE_${KEY}_REF=$ref"
    done < <(yq -r '.images | keys[]' "$yaml" 2>/dev/null)
  fi

  if $SSH "$env_cmd bash /var/lib/personal-server/tests/test-${svc}.sh" 2>&1; then
    pass[$svc]=1
    echo "run-tests: $svc → PASSED"
  else
    pass[$svc]=0
    echo "run-tests: $svc → FAILED"
    [[ $has_images == 0 ]] && { hard_fail=1; echo "  (native service — hard fail)"; }
  fi
done

# ── 7. Results JSON ─────────────────────────────────────────────────
{
  printf '{\n  "mode": "%s",\n  "hard_fail": %d,\n  "pass": {' "$MODE" "$hard_fail"
  first=1
  for k in "${!pass[@]}"; do
    [[ $first == 1 ]] && first=0 || printf ','
    printf '\n    "%s": %d' "$k" "${pass[$k]}"
  done
  printf '\n  },\n  "digests": {'
  first=1
  for k in "${!digests[@]}"; do
    [[ $first == 1 ]] && first=0 || printf ','
    printf '\n    "%s": "%s"' "$k" "${digests[$k]}"
  done
  printf '\n  }\n}\n'
} > "$RESULTS"

echo
echo "run-tests: report ──────────────────────────────"
for k in "${!pass[@]}"; do
  printf '  %-24s %s\n' "$k" "${pass[$k]}"
done
echo "  hard_fail=$hard_fail"
echo "run-tests: results → $RESULTS"
