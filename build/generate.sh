#!/usr/bin/env bash
# generate.sh — produces build/Dockerfile and build/docker-bake.hcl from
# shared/base-packages.yaml + every services/*/service.yaml.
#
# Usage:
#   ./build/generate.sh                       # full Dockerfile, all services
#   ./build/generate.sh --filter-from-report build/report.json
#                                             # final stage only includes ok services
#   ./build/generate.sh --list-services       # one service name per line (for CI matrix)
#
# Adding a new service requires zero changes to this script: drop a folder under
# services/ with a service.yaml and it'll be picked up.

set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export REPO_ROOT
# shellcheck source=../shared/lib/yaml.sh
source "$REPO_ROOT/shared/lib/yaml.sh"
# shellcheck source=../shared/lib/service-loader.sh
source "$REPO_ROOT/shared/lib/service-loader.sh"

BUILD_DIR=$REPO_ROOT/build
TEMPLATES=$BUILD_DIR/templates
OUT_DOCKERFILE=$BUILD_DIR/Dockerfile
OUT_BAKE=$BUILD_DIR/docker-bake.hcl
BASE_YAML=$REPO_ROOT/shared/base-packages.yaml

filter_report=""
list_only=0

while (($# > 0)); do
  case $1 in
    --filter-from-report) filter_report=$2; shift 2 ;;
    --list-services)      list_only=1; shift ;;
    -h|--help)
      sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "generate: unknown arg $1" >&2; exit 2 ;;
  esac
done

ordered=()
while IFS= read -r svc; do ordered+=("$svc"); done < <(services_list_topo)

if (( list_only )); then
  printf '%s\n' "${ordered[@]}"
  exit 0
fi

# Determine the subset of services that go into the FINAL stage.
final_services=("${ordered[@]}")
if [[ -n $filter_report ]]; then
  if [[ ! -f $filter_report ]]; then
    echo "generate: report not found at $filter_report" >&2; exit 1
  fi
  mapfile -t final_services < <(services_filter_failed "${ordered[@]}" "$filter_report")
fi

base_image=$(yaml_get "$BASE_YAML" '.base_image')
[[ -n $base_image ]] || { echo "generate: .base_image missing in $BASE_YAML" >&2; exit 1; }

# ---- service stages block ----
# Stages are chained in topological order: service-X is FROM the previous
# service in the chain (or base-common for the first), so all installed
# binaries / users / files accumulate into a single rootfs that the `final`
# stage inherits as-is. This costs parallel CI builds but is the only way
# to merge dnf/useradd/file changes from multiple stages without payload-tar
# trickery and rpmdb conflicts.
#
# The `RUN rm -rf /build/svc` BEFORE the COPY is mandatory: COPY only adds
# files, never removes, so without it /build/svc would accumulate the union
# of every previous service's files (and run-install.sh would mis-attribute
# them to the current service when staging /etc/personal-server/services/X).
service_stages=""
prev_stage="base-common"
for svc in "${ordered[@]}"; do
  service_stages+=$'\n'"FROM ${prev_stage} AS service-${svc}"$'\n'
  service_stages+="RUN rm -rf /build/svc"$'\n'
  service_stages+="COPY services/${svc}/ /build/svc/"$'\n'
  service_stages+="RUN /opt/personal-server/lib/run-install.sh"$'\n'
  prev_stage="service-${svc}"
done

# ---- final stage parent ----
# In dev mode with --filter-from-report, we honour the report by chaining only
# successful services and skipping failures (which means losing the failed
# service's children too — see services_filter_failed). The final stage is
# always FROM the last successfully chained service.
if [[ -n $filter_report ]]; then
  # Rebuild a filtered chain.
  service_stages=""
  prev_stage="base-common"
  for svc in "${final_services[@]}"; do
    service_stages+=$'\n'"FROM ${prev_stage} AS service-${svc}"$'\n'
    service_stages+="RUN rm -rf /build/svc"$'\n'
    service_stages+="COPY services/${svc}/ /build/svc/"$'\n'
    service_stages+="RUN /opt/personal-server/lib/run-install.sh"$'\n'
    prev_stage="service-${svc}"
  done
fi

final_parent=$prev_stage
final_copies="# final inherits the entire rootfs from the chain head: ${final_parent}"

# Substitute into the Dockerfile template (use sed with custom delimiter to
# survive arbitrary content in the variables).
python3 - "$TEMPLATES/Dockerfile.tmpl" "$OUT_DOCKERFILE" \
    "$base_image" "$service_stages" "$final_copies" "$final_parent" <<'PY'
import sys
src, dst, base, stages, copies, final_parent = sys.argv[1:]
with open(src) as f:
    tmpl = f.read()
tmpl = tmpl.replace("__BASE_IMAGE__", base)
tmpl = tmpl.replace("__SERVICE_STAGES__", stages)
tmpl = tmpl.replace("__FINAL_COPIES__", copies)
tmpl = tmpl.replace("__FINAL_PARENT__", final_parent)
with open(dst, "w") as f:
    f.write(tmpl)
PY

# ---- bake targets ----
service_targets=""
for svc in "${ordered[@]}"; do
  service_targets+=$'\n'"target \"service-${svc}\" {"$'\n'
  service_targets+="  inherits = [\"_common\"]"$'\n'
  service_targets+="  target   = \"service-${svc}\""$'\n'
  service_targets+="}"$'\n'
done
service_target_list=$(printf '"service-%s",' "${ordered[@]}")
service_target_list=${service_target_list%,}

python3 - "$TEMPLATES/docker-bake.hcl.tmpl" "$OUT_BAKE" \
    "$service_targets" "$service_target_list" <<'PY'
import sys
src, dst, targets, target_list = sys.argv[1:]
with open(src) as f:
    tmpl = f.read()
tmpl = tmpl.replace("__SERVICE_TARGETS__", targets)
tmpl = tmpl.replace("__SERVICE_TARGET_LIST__", target_list)
with open(dst, "w") as f:
    f.write(tmpl)
PY

echo "generate: wrote $OUT_DOCKERFILE"
echo "generate: wrote $OUT_BAKE"
echo "generate: services in build order: ${ordered[*]}"
if [[ -n $filter_report ]]; then
  echo "generate: services in final stage: ${final_services[*]}"
fi
