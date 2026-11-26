#!/bin/bash
# tests/experiments/vht.sh - hypothesis 7 (THE FIX): 802.11ac (VHT) on/off in the wl driver.
# Result on 2026-11-26: with vhtmode=1 (stock) 6 stalls in ~15 min of download; with vhtmode=0, 0 in 35 min.
#
#   sudo tests/experiments/vht.sh status | off | on
#
# Needs the patched module (wl-ioctl-build) and wlctl. vhtmode can only change while the driver is
# down, so "off"/"on" drop the association for a few seconds and reconnect through NetworkManager.
# Runtime only: at boot wl-disable-vht.service sets it to 0 again.
# SPDX-License-Identifier: MIT
set -u
. "$(dirname "$(dirname "$(readlink -f "$0")")")/lib.sh"
need_root
IF=$(wl_iface) || { echo "no wl interface"; exit 1; }
set_vht() {
  "$WLCTL" -i "$IF" cmd 3 >/dev/null && "$WLCTL" -i "$IF" set vhtmode "$1" >/dev/null && "$WLCTL" -i "$IF" cmd 2 >/dev/null
  sleep 2; nmcli device connect "$IF" >/dev/null 2>&1 || true
}
case "${1:-status}" in
  status) "$WLCTL" -i "$IF" get vhtmode; "$WLCTL" -i "$IF" get nmode; iw dev "$IF" link 2>/dev/null | grep -E "freq|bitrate" ;;
  off) set_vht 0; "$WLCTL" -i "$IF" get vhtmode ;;
  on)  set_vht 1; "$WLCTL" -i "$IF" get vhtmode ;;
  *) sed -n '2,10p' "$0"; exit 2 ;;
esac
