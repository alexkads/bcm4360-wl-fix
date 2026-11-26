# tests/lib.sh - helpers shared by the test scripts (source it, do not run it).
# SPDX-License-Identifier: MIT

# First network interface bound to the wl driver (empty if none).
wl_iface() {
  local d
  for d in /sys/class/net/*; do
    [ "$(basename "$(readlink -f "$d/device/driver" 2>/dev/null)")" = wl ] && { basename "$d"; return 0; }
  done
  return 1
}

# PCI address (e.g. 0000:02:00.0) of a network interface.
wl_pci() { basename "$(readlink -f "/sys/class/net/$1/device")"; }

# Default gateway through a given interface.
wl_gateway() { ip route show default dev "$1" 2>/dev/null | awk '{print $3; exit}'; }

need_root() { [ "$(id -u)" -eq 0 ] || { echo "$(basename "$0"): run as root" >&2; exit 1; }; }

WLCTL=${WLCTL:-$(command -v wlctl 2>/dev/null || echo /usr/local/sbin/wlctl)}
