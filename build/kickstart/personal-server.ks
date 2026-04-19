# personal-server net-install kickstart
# Anaconda pulls the bootc image from GHCR at install time.
# Usage: boot any AlmaLinux 9 boot ISO with:
#   inst.ks=https://raw.githubusercontent.com/<owner>/personal-server/main/build/kickstart/personal-server.ks

# Disk — interactive: Anaconda shows the disk picker
# No autopart, no clearpart — the user chooses the disk

# Pull the bootc image from the registry
bootc --source-imgref=__BOOTC_IMAGE_REF__

# Reboot after install
reboot
