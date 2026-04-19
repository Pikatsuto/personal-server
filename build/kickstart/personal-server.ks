# personal-server net-install kickstart
# Anaconda pulls the bootc image from GHCR at install time.

# Disk — interactive: Anaconda shows the disk picker
# No autopart, no clearpart — the user chooses the disk

# Pull the bootc image from the registry
ostreecontainer --url=ghcr.io/pikatsuto/personal-server:latest --no-signature-verification

# Reboot after install
reboot
