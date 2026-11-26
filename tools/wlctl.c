/*
 * wlctl - minimal control tool for the Broadcom STA ("wl") Linux driver.
 *
 * Talks to the driver through its private ioctl (SIOCDEVPRIVATE + wl_ioctl_t),
 * which on Linux >= 5.15 only works with patches/0001-wl-add-ndo_siocdevprivate.patch.
 *
 *   wlctl [-i IFACE] get NAME          read an integer iovar   (e.g. vhtmode)
 *   wlctl [-i IFACE] set NAME VALUE    write an integer iovar
 *   wlctl [-i IFACE] cmd N             send a bare command     (2 = WLC_UP, 3 = WLC_DOWN)
 *
 * Without -i, the first network interface bound to the "wl" driver is used.
 * Needs CAP_NET_ADMIN (run as root).
 *
 * SPDX-License-Identifier: MIT
 */
#include <dirent.h>
#include <errno.h>
#include <libgen.h>
#include <limits.h>
#include <linux/sockios.h>
#include <net/if.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>

/* Same layout as wl_ioctl_t in the driver's src/include/wlioctl.h. */
typedef struct {
	unsigned int cmd;
	void *buf;
	unsigned int len;
	unsigned char set;
	unsigned int used;
	unsigned int needed;
} wl_ioctl_t;

#define WLC_GET_VAR 262
#define WLC_SET_VAR 263

static int find_wl_iface(char *out, size_t outlen)
{
	DIR *d = opendir("/sys/class/net");
	struct dirent *e;
	char path[PATH_MAX], target[PATH_MAX];

	if (!d)
		return -1;
	while ((e = readdir(d))) {
		ssize_t n;
		if (e->d_name[0] == '.')
			continue;
		snprintf(path, sizeof path, "/sys/class/net/%s/device/driver", e->d_name);
		n = readlink(path, target, sizeof target - 1);
		if (n <= 0)
			continue;
		target[n] = '\0';
		if (!strcmp(basename(target), "wl")) {
			size_t len = strlen(e->d_name);
			if (len >= outlen)
				continue;
			memcpy(out, e->d_name, len + 1);
			closedir(d);
			return 0;
		}
	}
	closedir(d);
	return -1;
}

static void usage(void)
{
	fprintf(stderr,
		"usage: wlctl [-i IFACE] get NAME | set NAME VALUE | cmd N\n"
		"       (cmd 2 = WLC_UP, cmd 3 = WLC_DOWN)\n");
	exit(2);
}

int main(int argc, char **argv)
{
	char ifname[IFNAMSIZ] = "";
	char buf[512];
	struct ifreq ifr;
	wl_ioctl_t ioc;
	int argi = 1, s, set = 0;

	if (argc > 2 && !strcmp(argv[1], "-i")) {
		snprintf(ifname, sizeof ifname, "%s", argv[2]);
		argi = 3;
	} else if (find_wl_iface(ifname, sizeof ifname) < 0) {
		fprintf(stderr, "wlctl: no network interface bound to the wl driver\n");
		return 1;
	}
	if (argc - argi < 2)
		usage();

	s = socket(AF_INET, SOCK_DGRAM, 0);
	if (s < 0) {
		perror("socket");
		return 1;
	}
	memset(&ifr, 0, sizeof ifr);
	memset(&ioc, 0, sizeof ioc);
	memset(buf, 0, sizeof buf);
	snprintf(ifr.ifr_name, sizeof ifr.ifr_name, "%s", ifname);

	const char *op = argv[argi], *name = argv[argi + 1];
	if (!strcmp(op, "cmd")) {
		int32_t zero = 0;
		ioc.cmd = (unsigned int)atoi(name);
		ioc.buf = &zero;
		ioc.len = sizeof zero;
		ioc.set = 1;
	} else if (!strcmp(op, "get") || !strcmp(op, "set")) {
		size_t n = strlen(name) + 1;
		if (n + sizeof(int32_t) > sizeof buf)
			usage();
		memcpy(buf, name, n);
		set = !strcmp(op, "set");
		if (set) {
			int32_t v;
			if (argc - argi < 3)
				usage();
			v = (int32_t)atoi(argv[argi + 2]);
			memcpy(buf + n, &v, sizeof v);
			ioc.cmd = WLC_SET_VAR;
			ioc.len = (unsigned int)(n + sizeof v);
			ioc.set = 1;
		} else {
			ioc.cmd = WLC_GET_VAR;
			ioc.len = sizeof buf;
		}
		ioc.buf = buf;
	} else {
		usage();
	}

	ifr.ifr_data = (void *)&ioc;
	if (ioctl(s, SIOCDEVPRIVATE, &ifr) < 0) {
		int err = errno;
		fprintf(stderr, "wlctl: %s %s on %s: %s%s\n", op, name, ifname, strerror(err),
			err == EOPNOTSUPP && !strcmp(op, "get") && !strcmp(name, "vhtmode") ?
			" (is the patched wl module loaded?)" : "");
		close(s);
		return 1;
	}

	if (!strcmp(op, "get")) {
		int32_t v;
		memcpy(&v, buf, sizeof v);
		printf("%s=%d\n", name, v);
	} else if (set) {
		printf("%s <- %s\n", name, argv[argi + 2]);
	} else {
		printf("cmd %s ok\n", name);
	}
	close(s);
	return 0;
}
