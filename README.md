# bcm4360-wl-fix

**Broadcom BCM4360 + `wl` (broadcom-sta) on Linux: the Wi-Fi silently stops under fast downloads. This repo has the diagnosis, the fix (turn 802.11ac off via a small driver patch) and a watchdog that recovers the chip without rebooting.**

> 🇧🇷 **Resumo em português:** no MacBook Pro 2014 (BCM4360, driver `wl` do RPM Fusion), o Wi-Fi "trava em silêncio": a interface continua conectada, mas o tráfego vai a zero, e só um reinício resolvia. A causa é o núcleo fechado do `wl`, que trava a fila de recepção (DMA) quando recebe rápido no **802.11ac**. A correção desliga o 802.11ac (`vhtmode=0`) por um remendo de 20 linhas que religa o ioctl privado do driver nos kernels ≥ 5.15. Num teste de estresse, a placa caiu 6 vezes em ~15 min com o 802.11ac e nenhuma vez em 30 min sem ele. Instalação: `sudo ./install.sh`. A investigação inteira está em [`docs/investigation.md`](docs/investigation.md).

---

## Symptom

- The interface stays **"connected"** (NetworkManager, `iw link`), but traffic drops to **zero within one second**: no ping to the router, no SSH, no DNS. Nothing is logged, and there is no PCIe/AER error.
- It happens under **fast receive traffic** (downloads, `docker pull`, `dnf upgrade`), from a few seconds to a few minutes in. Upload never triggered it.
- `modprobe -r wl && modprobe wl` does **not** bring it back: the chip stays stuck and `wpa_supplicant` logs `Failed to initialize driver interface` / `couldn't grab this interface`. Only a reboot, or a PCI bus reset, recovers it.
- It got much more frequent when the machine moved from a 2.4 GHz network to a 5 GHz/802.11ac one, which allows much faster reception.

**Tested on:** MacBookPro11,2 (Mid 2014) · BCM4360 `[14e4:43a0]` rev 03 · Fedora 45 · kernels 7.3.4 and 7.3.5 · RPM Fusion `wl-kmod` 6.30.223.271-63 and -64 · 5 GHz router (WPA/WPA2).

## Root cause

The `wl` driver has two parts:

- an **open shim** (`wl_linux.c`, `wl_cfg80211_hybrid.c`) that talks to the kernel;
- a **closed core** (`wlc_hybrid.o_shipped`, Broadcom, 2015) that drives the chip.

Counting calls of the shim functions with kprobes, one sample per second, during a reproduced stall:

| moment | `wl_isr` (IRQs) | `wl_dpc` | **`wl_sendup` (packets to the stack)** | RX |
|---|---|---|---|---|
| normal download | ~800/s | ~1,350/s | **~22,000/s** | ~32 MB/s |
| stall second | **1,981/s** (IRQ burst) | 2,378/s | 16,329/s → **1** | → 6 MB/s |
| afterwards, forever | 15–35/s | 15–35/s | **0** | 0 |

The shim keeps working: interrupts arrive, the DPC runs and re-enables interrupts. But the **closed core never delivers another packet**. Its receive DMA path stalls after a burst and never recovers. The chip is still alive: PCI config reads `14e4`, the link state is normal and it still raises interrupts.

With **802.11ac** the access point sends A-MPDU aggregates of up to **~1 MB**. With **802.11n** the limit is **64 KB**. Forcing 802.11n (`vhtmode=0`) made the stall disappear.

## Evidence (iperf3 between this machine and another LAN host)

| configuration | heavy download | stalls |
|---|---|---|
| 802.11ac (stock) | ~15 min total at ~240 Mbit/s | **6**, after 21, 34, 43, 113 and 269 s of load |
| 802.11ac + upload only | ~10 min at ~50 Mbit/s | 0 |
| **802.11n (`vhtmode=0`)** | **10 min + 20 min at ~140 Mbit/s** (29.4 GB) | **0** |
| **after a reboot with `install.sh`** | 5 min at 148 Mbit/s (5.2 GB) | **0** |

With the stock rate (one stall every ~2 min of heavy download), 30 clean minutes by chance is far below 1 % likely.

**Ruled out:** PCIe ASPM (disabled, still stalled) · kernel 7.3.4 → 7.3.5 · `wl-kmod` -63 → -64 · `passivemode=1` (DPC in a workqueue: stalled after 269 s) · power save (already off) · TKIP group rekeys (no MIC failures) · temperature (57–74 °C) · memory · the router band (stalled on 2.4 and 5 GHz) · a failing card (it always comes back after a bus reset, with no errors).

## The fix

`vhtmode` is a driver setting (iovar) of the closed core. It is normally changed with Broadcom's `wl` utility through the private ioctl `SIOCDEVPRIVATE`. **Since Linux 5.15 that ioctl reaches drivers through `ndo_siocdevprivate`, which `wl` never implemented**, so on current kernels nothing in user space can change driver settings.

This repo provides:

| piece | what it does |
|---|---|
| [`patches/0001-wl-add-ndo_siocdevprivate.patch`](patches/0001-wl-add-ndo_siocdevprivate.patch) | 20 lines: wires `ndo_siocdevprivate` to the existing `wl_ioctl`. Applies on top of RPM Fusion's 38 patches |
| [`tools/wlctl.c`](tools/wlctl.c) | minimal `wl` tool: `wlctl get NAME`, `set NAME VALUE`, `cmd N` (2 = up, 3 = down). Finds the wl interface by itself |
| [`sbin/wl-ioctl-build`](sbin/wl-ioctl-build) | rebuilds **RPM Fusion's own wl-kmod SRPM** (from `/usr/src/akmods`) + our patch, and installs it as `/lib/modules/<kver>/updates/wl.ko`, which wins over akmods' `extra/wl` |
| [`kernel-install/96-wl-ioctl.install`](kernel-install/96-wl-ioctl.install) | rebuilds it automatically for every new kernel |
| [`sbin/wl-disable-vht`](sbin/wl-disable-vht) + [`systemd/wl-disable-vht.service`](systemd/wl-disable-vht.service) | at boot, before NetworkManager: `down`, `vhtmode 0`, `up`. If the running kernel has no patched module yet, it builds one |
| [`contrib/wl-watchdog`](contrib/wl-watchdog) (optional) | if the link still stalls: logs a chip diagnosis, then unloads wl, **PCI bus reset**, reloads, re-applies the fix. It came back in ~2 min in 4 out of 4 real stalls, without a reboot |

**Cost:** downloads top out at ~140 Mbit/s instead of ~240 Mbit/s on this machine and signal (−62 dBm). Upload is unchanged (~50 Mbit/s).

## Install (Fedora + RPM Fusion)

Requirements: `akmod-wl` from RPM Fusion already working, `kernel-devel` for the running kernel, and `gcc make patch rpm cpio`.

```bash
git clone https://github.com/alexkads/bcm4360-wl-fix.git
cd bcm4360-wl-fix
sudo ./install.sh                  # or: sudo ./install.sh --with-watchdog
sudo reboot
```

Check after the reboot:

```bash
modinfo -n wl                        # /lib/modules/<kver>/updates/wl.ko
sudo wlctl get vhtmode               # vhtmode=0
journalctl -b -u wl-disable-vht      # "802.11ac off"
```

Other distributions: the patch and `wlctl` are distro-independent. Apply the patch to your `broadcom-sta` / `wl` DKMS source, rebuild, and run `wl-disable-vht` (or `wlctl cmd 3; wlctl set vhtmode 0; wlctl cmd 2`) before your network manager starts.

## Uninstall

```bash
sudo ./uninstall.sh && sudo reboot
```

This removes every file, the service and the `updates/wl.ko` modules, so the stock RPM Fusion module loads again.

## Troubleshooting

- **`wlctl: ... Operation not supported (is the patched wl module loaded?)`**: the stock module is loaded. Check `modinfo -n wl`, then run `sudo wl-ioctl-build` and reload `wl`.
- **`our patch no longer applies`** after an RPM Fusion update: their patches changed the context around `ndo_do_ioctl`. Re-create the 20-line patch: add `wl_siocdevprivate()` and `.ndo_siocdevprivate` to both `net_device_ops` in `src/wl/sys/wl_linux.c`.
- **Kernel update without network:** the `kernel-install` hook builds the module when the kernel is installed. If `kernel-devel` arrived later, `wl-disable-vht.service` builds it at boot. Logs are in `/var/log/wl-ioctl.log`.
- **It still stalls:** the definitive fix is to stop depending on `wl`. Use a USB Wi-Fi adapter with an in-kernel driver (MediaTek MT7921AU / MT7612U, `mt76`), or Ethernet (USB 3 RTL8153/AX88179, or Thunderbolt).
- **SELinux (Fedora):** systemd cannot execute scripts or open `StandardOutput=file:` in `/var/tmp`, and `insmod` only loads files labelled `modules_object_t` (that is, under `/lib/modules`). The scripts here already respect that.
- The iovars `ampdu_rx`, `ampdu_rx_factor`, `ampdu_ba_wsize`, `amsdu` and similar answer "not supported" in this driver build. `vhtmode`, `nmode`, `mimo_bw_cap` and `stbc_rx` work.

## Notes

- Nothing from Broadcom is redistributed here. The build script uses the SRPM that `akmod-wl` already installed.
- Full investigation, with every test and data point: [`docs/investigation.md`](docs/investigation.md).
- Background, status and acceptance criteria: [issue #1](https://github.com/alexkads/bcm4360-wl-fix/issues/1).

License: MIT (our scripts, tool and patch). The `wl` driver itself remains under Broadcom's license.
