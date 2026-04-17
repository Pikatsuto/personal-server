#!/usr/bin/env bash
# Native WebZFS install. Verified line-by-line against
# github.com/webzfs/webzfs install_linux.sh on 2026-04-11.
#
# What the upstream installer needs that yum can't give us:
#   - Node.js 20+ (AlmaLinux 9 module: nodejs:24)
# What it does at runtime that doesn't fit a build container:
#   - prompts the user twice (enable on boot? start now?) → fed via stdin
#   - calls `systemctl daemon-reload / enable / start` → shimmed to no-op
#     (the unit is enabled at first-boot via configure.sh)
#   - chmods /etc/shadow → fine in the build, persisted in the image

set -euo pipefail

WEBZFS_REF=${WEBZFS_REF:-main}
SRC=/tmp/webzfs.src

# 1. Node.js 24 (the latest LTS stream available in AlmaLinux 9 AppStream as of
#    2026-04-11; verified via repodata modules.yaml). Upstream WebZFS only
#    requires v20+, so anything >= 20 works.
dnf module reset -y nodejs
dnf module enable -y nodejs:24
dnf module install -y nodejs:24/common

# 2. Make python3.11 the canonical `python3` in PATH for install_linux.sh's
#    find_python() lookup.
alternatives --set python3 /usr/bin/python3.11 2>/dev/null || \
  ln -sf /usr/bin/python3.11 /usr/local/bin/python3

# 3. Clone source and run the upstream installer.
git clone --depth 1 --branch "$WEBZFS_REF" https://github.com/webzfs/webzfs.git "$SRC"
cd "$SRC"

# Shim systemctl to a no-op for the duration of the install — the upstream
# script tries daemon-reload/enable/start which can't run in a build container.
SHIM=/tmp/webzfs-shim
mkdir -p "$SHIM"
cat > "$SHIM/systemctl" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$SHIM/systemctl"

# Feed `n\nn\n` to the two interactive prompts at the end (enable on boot? /
# start now?) — we enable it ourselves at first-boot in configure.sh.
PATH="$SHIM:$PATH" ./install_linux.sh < <(printf 'n\nn\n')

rm -rf "$SRC" "$SHIM"

# /opt is read-only on bootc/ostree. WebZFS's Python code uses Path.home()
# to create writable dirs (.config, .ssh). Move the user's home to /var/lib
# and symlink writable data dirs.
WEBZFS_HOME=/var/lib/webzfs
install -d -m 0755 -o webzfs -g webzfs "$WEBZFS_HOME"
usermod -d "$WEBZFS_HOME" webzfs

# Move existing writable data dirs from /opt to /var/lib
for subdir in .config .ssh; do
  if [[ -d /opt/webzfs/$subdir ]]; then
    mv "/opt/webzfs/$subdir" "$WEBZFS_HOME/$subdir"
  else
    install -d -m 0700 -o webzfs -g webzfs "$WEBZFS_HOME/$subdir"
  fi
  ln -s "$WEBZFS_HOME/$subdir" "/opt/webzfs/$subdir"
done
