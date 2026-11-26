#!/bin/bash
# uninstall.sh - remove everything install.sh added and go back to RPM Fusion's stock wl.
# SPDX-License-Identifier: MIT
set -u
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

systemctl disable --now wl-watchdog.service wl-disable-vht.service 2>/dev/null
rm -f /etc/systemd/system/wl-watchdog.service /etc/systemd/system/wl-disable-vht.service
rm -f /usr/local/sbin/wl-watchdog /usr/local/sbin/wl-disable-vht /usr/local/sbin/wl-ioctl-build /usr/local/sbin/wlctl
rm -f /etc/kernel/install.d/96-wl-ioctl.install
rm -rf /usr/local/share/wl-ioctl
for k in /lib/modules/*; do
  if [ -f "$k/updates/wl.ko" ]; then rm -f "$k/updates/wl.ko"; depmod -a "$(basename "$k")"; fi
done
systemctl daemon-reload
echo "Removed. Reboot (or: sudo modprobe -r wl && sudo modprobe wl) to load the stock wl again."
