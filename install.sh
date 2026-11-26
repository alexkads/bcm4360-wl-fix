#!/bin/bash
# install.sh - install the BCM4360 / wl stall fix (Fedora + RPM Fusion akmod-wl).
#
#   sudo ./install.sh                 patched wl + wlctl + 802.11ac off at boot
#   sudo ./install.sh --with-watchdog also install the optional wl-watchdog
#
# Nothing here replaces RPM Fusion's packages: the patched module goes to
# /lib/modules/<kver>/updates/ and wins over akmods' extra/wl. uninstall.sh
# removes everything.
#
# SPDX-License-Identifier: MIT
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
WATCHDOG=0
[ "${1:-}" = "--with-watchdog" ] && WATCHDOG=1

die() { echo "install.sh: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run as root (sudo ./install.sh)"
[ -e /usr/src/akmods/wl-kmod.latest ] || die "akmod-wl from RPM Fusion is not installed (dnf install akmod-wl)"
[ -d "/usr/src/kernels/$(uname -r)" ] || die "kernel-devel-$(uname -r) is not installed"
for t in gcc make patch rpm2cpio cpio; do command -v "$t" >/dev/null || die "missing tool: $t (dnf install gcc make patch rpm cpio)"; done

echo "==> installing files"
install -D -m 644 patches/0001-wl-add-ndo_siocdevprivate.patch /usr/local/share/wl-ioctl/0001-wl-add-ndo_siocdevprivate.patch
install -D -m 755 sbin/wl-ioctl-build   /usr/local/sbin/wl-ioctl-build
install -D -m 755 sbin/wl-disable-vht   /usr/local/sbin/wl-disable-vht
install -D -m 755 kernel-install/96-wl-ioctl.install /etc/kernel/install.d/96-wl-ioctl.install
install -D -m 644 systemd/wl-disable-vht.service /etc/systemd/system/wl-disable-vht.service
gcc -O2 -Wall -o /usr/local/sbin/wlctl tools/wlctl.c
if [ "$WATCHDOG" = 1 ]; then
  install -D -m 755 contrib/wl-watchdog /usr/local/sbin/wl-watchdog
  install -D -m 644 contrib/wl-watchdog.service /etc/systemd/system/wl-watchdog.service
fi
command -v restorecon >/dev/null && restorecon -R /usr/local/sbin /usr/local/share/wl-ioctl /etc/kernel/install.d /etc/systemd/system || true

echo "==> building the patched wl for $(uname -r)"
/usr/local/sbin/wl-ioctl-build "$(uname -r)"
echo "    modprobe now resolves wl to: $(modinfo -n wl)"

systemctl daemon-reload
systemctl enable wl-disable-vht.service
[ "$WATCHDOG" = 1 ] && systemctl enable wl-watchdog.service

cat <<'EOF'

==> done. Activate it with a reboot (recommended), or right now with:

    sudo modprobe -r wl && sudo modprobe wl && sudo systemctl start wl-disable-vht

Check:   sudo wlctl get vhtmode      ->  vhtmode=0
         modinfo -n wl               ->  /lib/modules/<kver>/updates/wl.ko
EOF
