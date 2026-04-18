#!/usr/bin/env bash
# run-install.sh — executed inside each `service-<name>` Docker stage.
# Reads /build/svc/service.yaml and:
#   1. enables COPR / extra repos declared by the service
#   2. installs declared packages
#   3. runs the service-provided install_script (defaults to install.sh)
#
# Generic for every service. Adding a new service requires NO change here.

set -euo pipefail

LIB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=yaml.sh
source "$LIB_DIR/yaml.sh"

SVC_DIR=${SVC_DIR:-/build/svc}
SVC_YAML=$SVC_DIR/service.yaml

if [[ ! -f $SVC_YAML ]]; then
  echo "run-install: $SVC_YAML not found" >&2
  exit 1
fi

NAME=$(yaml_get "$SVC_YAML" '.name')
[[ -n $NAME ]] || { echo "run-install: .name missing in $SVC_YAML" >&2; exit 1; }

echo ">>> run-install: $NAME"

# 1. extra repos (raw .repo URLs or rpm package URLs)
while IFS= read -r repo; do
  [[ -z $repo ]] && continue
  case $repo in
    *.rpm)
      dnf install -y "$repo"
      ;;
    *.repo|http*)
      repofile="/etc/yum.repos.d/${NAME}-$(basename "$repo")"
      curl -fsSL "$repo" -o "$repofile"
      # Some upstream repos use $releasever in URLs but only publish for
      # the major version (e.g. "9" not "9.7"). Pin to major.
      major=$(rpm -E '%{rhel}' 2>/dev/null || sed -n 's/^VERSION_ID="\?\([0-9]*\).*/\1/p' /etc/os-release)
      sed -i "s|\$releasever|$major|g" "$repofile"
      ;;
    *)
      echo "run-install: unrecognised extra_repo entry: $repo" >&2
      exit 1
      ;;
  esac
done < <(yaml_get_array "$SVC_YAML" '.build.extra_repos')

# 2. COPR repos
COPRS=$(yaml_get_array "$SVC_YAML" '.build.copr_repos')
if [[ -n $COPRS ]]; then
  dnf install -y dnf-plugins-core
  while IFS= read -r copr; do
    [[ -z $copr ]] && continue
    dnf copr enable -y "$copr"
  done <<<"$COPRS"
fi

# 3. packages
PKGS=()
while IFS= read -r p; do
  [[ -z $p ]] && continue
  PKGS+=("$p")
done < <(yaml_get_array "$SVC_YAML" '.build.packages')
if (( ${#PKGS[@]} > 0 )); then
  dnf install -y "${PKGS[@]}"
fi

# 4. service-provided install script
INSTALL_SCRIPT=$(yaml_get "$SVC_YAML" '.build.install_script')
INSTALL_SCRIPT=${INSTALL_SCRIPT:-install.sh}
if [[ -f $SVC_DIR/$INSTALL_SCRIPT ]]; then
  chmod +x "$SVC_DIR/$INSTALL_SCRIPT"
  ( cd "$SVC_DIR" && "./$INSTALL_SCRIPT" )
fi

# 5. drop a marker file so the final stage can introspect what's installed
install -d -m 0755 /etc/personal-server/installed
date -u +%Y-%m-%dT%H:%M:%SZ > "/etc/personal-server/installed/$NAME"

# 6. ship the service.yaml + configure script into the image so the first-boot
# wizard can find them on the running system.
install -d -m 0755 "/etc/personal-server/services/$NAME"
cp "$SVC_YAML" "/etc/personal-server/services/$NAME/service.yaml"
CONFIGURE=$(yaml_get "$SVC_YAML" '.configure.first_boot')
CONFIGURE=${CONFIGURE:-configure.sh}
if [[ -f $SVC_DIR/$CONFIGURE ]]; then
  install -m 0755 "$SVC_DIR/$CONFIGURE" "/etc/personal-server/services/$NAME/$CONFIGURE"
fi
if [[ -d $SVC_DIR/files ]]; then
  cp -a "$SVC_DIR/files/." "/etc/personal-server/services/$NAME/files/" 2>/dev/null || \
    { install -d "/etc/personal-server/services/$NAME/files" && cp -a "$SVC_DIR/files/." "/etc/personal-server/services/$NAME/files/"; }
fi

# Note: unit files live in /etc/personal-server/services/<name>/files/systemd/.
# They are NOT copied into /etc/systemd/system at build time — that would let
# multi-service merges clobber each other in the final stage. Instead the
# first-boot wizard stages them via stage-units(), then runs `systemctl enable`.

dnf clean all || true
echo ">>> run-install: $NAME OK"
