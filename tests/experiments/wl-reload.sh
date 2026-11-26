#!/bin/bash
# tests/experiments/wl-reload.sh - reload wl the way that actually recovers a stalled chip:
# unload wl, PCI secondary bus reset, load wl (with the options in /etc/modprobe.d), restart
# wpa_supplicant and NetworkManager, then re-apply wl-disable-vht if it is installed.
#
#   sudo tests/experiments/wl-reload.sh
#
# A plain "modprobe -r wl && modprobe wl" is NOT enough after a stall: the chip stays stuck and
# wpa_supplicant fails with "Failed to initialize driver interface".
# ⚠️  Drops the Wi-Fi for ~20 s: run it on the console, in tmux, or with nohup when using SSH over Wi-Fi.
#
# SPDX-License-Identifier: MIT
set -u
. "$(dirname "$(dirname "$(readlink -f "$0")")")/lib.sh"
need_root
IF=$(wl_iface) || IF=${WL_IF:-}
[ -n "$IF" ] || { echo "no wl interface (set WL_IF=...)"; exit 1; }
PCI=$(wl_pci "$IF"); DEV=/sys/bus/pci/devices/$PCI

echo "$(date +%T) reloading wl on $IF ($PCI)"
modprobe -r wl; sleep 2
if echo 1 > "$DEV/reset" 2>/dev/null; then echo "   bus reset: ok"
else echo "   bus reset failed; remove + rescan"; echo 1 > "$DEV/remove"; sleep 2; echo 1 > /sys/bus/pci/rescan; fi
sleep 2; modprobe wl; sleep 3
for _ in $(seq 1 20); do [ -e "/sys/class/net/$IF" ] && break; sleep 0.5; done
dmesg | grep -o "Broadcom BCM43.*Controller.*" | tail -1 | sed 's/^/   /'
systemctl -q is-enabled wl-disable-vht 2>/dev/null && /usr/local/sbin/wl-disable-vht
systemctl restart wpa_supplicant 2>/dev/null; sleep 2
systemctl restart NetworkManager 2>/dev/null
for _ in $(seq 1 30); do
  gw=$(wl_gateway "$IF"); [ -n "$gw" ] && ping -c 1 -W 2 -I "$IF" "$gw" >/dev/null 2>&1 && { echo "$(date +%T) network back (gateway $gw)"; exit 0; }
  sleep 3
done
echo "$(date +%T) network did not come back in ~90 s"; exit 1
