#!/bin/bash
# tests/regenerate-patch.sh - recreate patches/0001-wl-add-ndo_siocdevprivate.patch against the wl-kmod
# SRPM currently installed by akmod-wl (use it when wl-ioctl-build says "our patch no longer applies").
#
#   tests/regenerate-patch.sh            regenerate and compare with the patch in the repo
#   tests/regenerate-patch.sh --build    also compile the result for the running kernel (proves it builds)
#
# The edit is always the same: add wl_siocdevprivate() (calls the existing wl_ioctl) before
# wl_netdev_ops, and set .ndo_siocdevprivate in both net_device_ops structures.
#
# SPDX-License-Identifier: MIT
set -euo pipefail
REPO=$(dirname "$(dirname "$(readlink -f "$0")")")
DEST=$REPO/patches/0001-wl-add-ndo_siocdevprivate.patch
SRPM=${WL_SRPM:-$(readlink -f /usr/src/akmods/wl-kmod.latest 2>/dev/null || true)}
[ -f "$SRPM" ] || { echo "wl-kmod SRPM not found (install akmod-wl)"; exit 1; }
for t in rpm2cpio cpio patch python3 diff; do command -v $t >/dev/null || { echo "missing $t"; exit 1; }; done

W=$(mktemp -d /var/tmp/wl-regen.XXXXXX)
trap 'case "$W" in /var/tmp/wl-regen.*) rm -rf -- "$W";; esac' EXIT
cd "$W"
rpm2cpio "$SRPM" | cpio -idm --quiet
mkdir a && tar -C a -xzf hybrid-v35_64-nodebug-pcoem-*.tar.gz
awk '/^Patch[0-9]+:/{n=$1; gsub(/[^0-9]/,"",n); print n, $2}' wl-kmod.spec | sort -n |
  while read -r _ p; do patch -d a -s -p1 < "$p"; done
echo "applied $(grep -c '^Patch[0-9]*:' wl-kmod.spec) RPM Fusion patches from $(basename "$SRPM")"
cp -a a b

python3 - b/src/wl/sys/wl_linux.c <<'PY'
import re, sys
f = sys.argv[1]; s = open(f).read()
if "ndo_siocdevprivate" in s:
    print("RPM Fusion's source already sets ndo_siocdevprivate: our patch is no longer needed"); sys.exit(3)
hook = '''#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 15, 0)
/*
 * Since Linux 5.15, SIOCDEVPRIVATE issued from user space is delivered through
 * ndo_siocdevprivate instead of ndo_do_ioctl. Without this hook the wl private
 * ioctl (WLC_GET_VAR / WLC_SET_VAR / WLC_UP / WLC_DOWN) is unreachable from user
 * space, so driver settings such as "vhtmode" cannot be changed.
 */
static int wl_siocdevprivate(struct net_device *dev, struct ifreq *ifr,
			     void __user *data, int cmd)
{
	return wl_ioctl(dev, ifr, SIOCDEVPRIVATE);
}
#endif

'''
anchor = "static const struct net_device_ops wl_netdev_ops"
if anchor not in s: sys.exit("anchor not found: " + anchor)
s = s.replace(anchor, hook + anchor, 1)
s, n = re.subn(r"(\t\.ndo_do_ioctl = wl_ioctl),?\n",
               r"\1,\n#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 15, 0)\n\t.ndo_siocdevprivate = wl_siocdevprivate,\n#endif\n", s)
if n != 2: sys.exit(f"expected 2 '.ndo_do_ioctl = wl_ioctl' fields, found {n}")
open(f, "w").write(s)
PY

diff -u a/src/wl/sys/wl_linux.c b/src/wl/sys/wl_linux.c | sed -E '1,2s/\t.*$//' > 0001.patch || true
if cmp -s 0001.patch "$DEST"; then
  echo "✅ regenerated patch is identical to $DEST"
else
  cp 0001.patch "$DEST"
  echo "⚠️  patch changed; written to $DEST - review with: git -C $REPO diff patches/"
fi

if [ "${1:-}" = "--build" ]; then
  K=$(uname -r); KD=/usr/src/kernels/$K; [ -d "$KD" ] || KD=/lib/modules/$K/build
  nice -n 10 make -s -j2 -C "$KD" M="$W/b" modules >/dev/null
  echo "✅ builds for $K: $(modinfo -F vermagic b/wl.ko)"
fi
