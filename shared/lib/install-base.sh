#!/usr/bin/env bash
# install-base.sh — runs inside the `base-common` Docker stage AFTER the
# packages from base-packages.yaml have been installed. Performs the few
# multi-step setups that yq can't express:
#
#   1. EPEL (needed by ZFS, Incus deps, etc.)
#   2. CRB (CodeReady Builder — required by Incus and several -devel packages
#      on RHEL-rebuilds)
#   3. ZFS via the kABI-tracking kmod repo (NOT dkms — bootc images can't
#      compile kernel modules at runtime, so we need precompiled kmod-zfs).
#
# Source for ZFS steps (verified 2026-04-11):
#   https://openzfs.github.io/openzfs-docs/Getting%20Started/RHEL-based%20distro/index.html

set -euo pipefail

DNF_OPTS="--setopt=install_weak_deps=False --setopt=tsflags=nodocs"

dnf install -y $DNF_OPTS epel-release
dnf config-manager --set-enabled crb

# ZFS — kmod track only.
dnf install -y $DNF_OPTS https://zfsonlinux.org/epel/zfs-release-3-0.el9.noarch.rpm
dnf config-manager --disable zfs
dnf config-manager --enable zfs-kmod
dnf install -y $DNF_OPTS zfs zfs-dracut

# fish shell (EPEL, must be after epel-release)
dnf install -y $DNF_OPTS fish

# Ensure /usr/local/bin is in PATH for all shells and users (including root)
cat > /etc/profile.d/local-bin.sh <<'BASH_PROFILE'
[[ ":$PATH:" == *":/usr/local/bin:"* ]] || export PATH="/usr/local/bin:$PATH"
BASH_PROFILE

install -d -m 0755 /etc/fish/conf.d
cat > /etc/fish/conf.d/local-bin.fish <<'FISH_CONF'
fish_add_path --prepend /usr/local/bin
FISH_CONF

# Root login shell + sudo secure_path
# /root → /var/roothome (symlink on bootc, doesn't exist at build time)
install -d -m 0700 /var/roothome
echo 'export PATH="/usr/local/bin:$PATH"' >> /var/roothome/.bashrc
install -d -m 0700 /var/roothome/.config/fish
echo 'fish_add_path --prepend /usr/local/bin' >> /var/roothome/.config/fish/config.fish
if grep -q '^Defaults.*secure_path' /etc/sudoers 2>/dev/null; then
  sed -i 's|^Defaults\s*secure_path\s*=\s*"\?\([^"]*\)"\?|Defaults    secure_path = "\1:/usr/local/bin"|' /etc/sudoers
fi

dnf clean all
