#!/bin/bash
# tests/experiments/passivemode.sh - hypothesis 6: wl module option passivemode=1 (DPC in a workqueue
# instead of a tasklet). Result on 2026-11-26: stalled after 269 s of download (not enough).
#
#   sudo tests/experiments/passivemode.sh status | on | off
#
# on/off write or remove /etc/modprobe.d/wl-passivemode.conf and reload wl with wl-reload.sh
# (⚠️  drops the Wi-Fi for ~20 s). The kernel log banner shows ", Passive Mode" when it is active.
# SPDX-License-Identifier: MIT
set -u
HERE=$(dirname "$(readlink -f "$0")")
CONF=/etc/modprobe.d/wl-passivemode.conf
[ "$(id -u)" -eq 0 ] || { echo "$(basename "$0"): run as root" >&2; exit 1; }
status() {
  echo "driver: $(dmesg | grep -o "Broadcom BCM43.*Controller.*" | tail -1)"
  [ -f "$CONF" ] && echo "config: $(cat "$CONF")" || echo "config: none (passivemode off)"
}
case "${1:-status}" in
  status) status ;;
  on)  echo "options wl passivemode=1" > "$CONF"; "$HERE/wl-reload.sh"; status ;;
  off) rm -f "$CONF"; "$HERE/wl-reload.sh"; status ;;
  *) sed -n '2,9p' "$0"; exit 2 ;;
esac
