#!/bin/bash
# tests/check.sh - verify that the fix is installed and active. Exit 0 only if every check passes.
#
#   sudo tests/check.sh
#
# SPDX-License-Identifier: MIT
set -u
. "$(dirname "$(readlink -f "$0")")/lib.sh"
need_root

fails=0
ok()  { printf '✅ %s\n' "$*"; }
bad() { printf '❌ %s\n' "$*"; fails=$((fails + 1)); }
warn(){ printf '⚠️  %s\n' "$*"; }

K=$(uname -r)
IF=$(wl_iface) && ok "wl interface: $IF ($(wl_pci "$IF"))" || bad "no network interface bound to the wl driver (is akmod-wl installed and loaded?)"

path=$(modinfo -n wl 2>/dev/null)
case "$path" in
  */updates/wl.ko) ok "modprobe resolves wl to the patched module: $path" ;;
  "") bad "modinfo cannot find wl for $K" ;;
  *) bad "modprobe resolves wl to $path (stock module); run: sudo wl-ioctl-build" ;;
esac

if [ -n "${IF:-}" ]; then
  if v=$("$WLCTL" -i "$IF" get vhtmode 2>&1); then
    ok "loaded wl accepts the private ioctl (patched module is the one loaded)"
    [ "$v" = "vhtmode=0" ] && ok "802.11ac off ($v)" || bad "802.11ac still ON ($v); run: sudo systemctl restart wl-disable-vht"
  else
    bad "wlctl failed: $v"
  fi
fi

systemctl -q is-enabled wl-disable-vht 2>/dev/null && ok "wl-disable-vht.service enabled" || bad "wl-disable-vht.service not enabled"
journalctl -b -u wl-disable-vht -o cat --no-pager 2>/dev/null | grep -qE "vhtmode=0|already off" &&
  ok "wl-disable-vht ran this boot" || warn "wl-disable-vht has no 'vhtmode=0' line this boot"

[ -x /etc/kernel/install.d/96-wl-ioctl.install ] && ok "kernel-install hook present" || bad "kernel-install hook missing (/etc/kernel/install.d/96-wl-ioctl.install)"
[ -f /usr/local/share/wl-ioctl/0001-wl-add-ndo_siocdevprivate.patch ] && ok "patch installed in /usr/local/share/wl-ioctl" || bad "patch missing from /usr/local/share/wl-ioctl"

for d in /lib/modules/*; do
  kv=$(basename "$d")
  [ -d "/usr/src/kernels/$kv" ] || continue
  [ -f "$d/updates/wl.ko" ] && ok "kernel $kv has updates/wl.ko" || warn "kernel $kv has no updates/wl.ko (run: sudo wl-ioctl-build $kv before booting it)"
done

if systemctl list-unit-files wl-watchdog.service >/dev/null 2>&1 && systemctl -q is-enabled wl-watchdog 2>/dev/null; then
  systemctl -q is-active wl-watchdog && ok "wl-watchdog running" || bad "wl-watchdog enabled but not running"
else
  warn "wl-watchdog not installed (optional: sudo ./install.sh --with-watchdog)"
fi

if [ -n "${IF:-}" ]; then
  gw=$(wl_gateway "$IF")
  [ -n "$gw" ] && ping -c 3 -W 2 -I "$IF" "$gw" >/dev/null 2>&1 && ok "gateway $gw answers through $IF" || bad "no answer from the gateway through $IF"
fi

echo
[ "$fails" -eq 0 ] && { echo "all checks passed"; exit 0; } || { echo "$fails check(s) failed"; exit 1; }
