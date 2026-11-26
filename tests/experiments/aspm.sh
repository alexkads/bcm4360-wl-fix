#!/bin/bash
# tests/experiments/aspm.sh - hypothesis 1: PCIe ASPM (L0s/L1) + ClockPM on the Wi-Fi link.
# Result on 2026-11-26: ASPM off did NOT prevent the stall (it is not the cause). Kept for replication.
#
#   sudo tests/experiments/aspm.sh status | off | on
#
# Runtime only (back to the firmware/kernel default at the next boot). Then run tests/stall-test.sh.
# SPDX-License-Identifier: MIT
set -u
. "$(dirname "$(dirname "$(readlink -f "$0")")")/lib.sh"
IF=$(wl_iface) || { echo "no wl interface"; exit 1; }
L=/sys/bus/pci/devices/$(wl_pci "$IF")/link
show() { echo "$IF $(wl_pci "$IF"): l0s_aspm=$(cat "$L/l0s_aspm") l1_aspm=$(cat "$L/l1_aspm") clkpm=$(cat "$L/clkpm")"; lspci -vvv -s "$(wl_pci "$IF")" 2>/dev/null | grep -E "LnkCtl:" | sed 's/^\s*/   /'; }
case "${1:-status}" in
  status) show ;;
  off) need_root; for f in l1_aspm l0s_aspm clkpm; do echo 0 > "$L/$f"; done; show ;;
  on)  need_root; for f in clkpm l0s_aspm l1_aspm; do echo 1 > "$L/$f" 2>/dev/null || echo "   $f: not supported"; done; show ;;
  *) sed -n '2,8p' "$0"; exit 2 ;;
esac
