# Investigation log: BCM4360 / wl silent RX stall

This log records how the cause was found, so the work can be redone or extended later without the original conversation. Machine: MacBookPro11,2 (Mid 2014, i7-4770HQ, 16 GB), Fedora 45, used as an always-on home server (Docker, KVM, CI). Network only over Wi-Fi.

Date: 2026-11-26. All times are local (UTC−3).

## 1. History before the investigation

- The machine rebooted 5 times in ~30 h (25/11 03:31 and 22:30; 26/11 00:40, 02:09, 10:40). The first ones were manual reboots because "the network was gone".
- A first watchdog, written that night, reloaded `wl` (`modprobe -r wl; modprobe wl`) and rebooted if that did not help. The reload **never** helped, and the watchdog always ended up rebooting.
- The persistent journal only reached back to 20/11 (1 GB cap). The oldest surviving boot, 03–13/11 on kernel 7.2, ran for 10 days. The first recorded stall is from 22/11, after the upgrade to Fedora 45 / kernel 7.3.4 on 19/11. The machine's workload also grew a lot that same week, so the timeline alone proves nothing.

## 2. Log analysis of real stalls

For each stall (`journalctl -b -N`, `wpa_supplicant`, NetworkManager, kernel):

- **No disconnect event** at the start. The `CTRL-EVENT-DISCONNECTED reason=0` that does appear has the same timestamp as the module removal, so it is a **consequence** of the reload, not the cause.
- First signs: tailscale loses its DERP connection (`i/o timeout`), then DNS times out. Prometheus `node_network_receive_bytes` fell from 9.8 MB/s to ~0 in one minute in one case. In another it fell from 0.6 KB/s, with the machine idle.
- No errors, no drops on the interface. CPU at 57–74 °C, 4–13 GB of RAM free.
- After the reload: `nl80211: deinit ifname=wlp2s0` → `Failed to initialize driver interface` → `wpa_supplicant couldn't grab this interface` → NetworkManager gives up after 5 tries.
- Two stalls were on the 2.4 GHz network (BSSID …:90) and the rest on 5 GHz (…:91). TKIP group rekeys happened every ~10 min and did not line up with the stalls. No `Michael MIC failure` was logged.

## 3. Hypotheses tested one at a time

| # | change | how it was tested | result |
|---|---|---|---|
| 1 | PCIe **ASPM** L0s/L1 + ClockPM off (`/sys/bus/pci/devices/0000:02:00.0/link/*`) | in place since 11:00 | stalled again at 12:21 → **not the cause** |
| 2 | new watchdog: **PCI secondary bus reset** (`reset_method = bus`, the chip is alone on bus 02) + restart `wpa_supplicant`/NM | forced test 11:11 → network back in 33 s | **recovery works** (4/4 real stalls later) |
| 3 | kernel **7.3.4 → 7.3.5** + `akmod-wl` **-63 → -64** (updates-testing) | reboot 11:23 | stalled 12:21, 12:44 and 13:18 → **not the cause** |
| 4 | **stress test** (`iperf3`, 8 TCP streams; 20 bursts of 60 s alternating directions) | 12:09–13:31 | **reproducer found:** 3 stalls, all in download (~240 Mbit/s); 0 in upload (~50 Mbit/s) |
| 5 | **kprobe trace** of the shim (`wl_isr`, `wl_dpc`, `wl_sendup`, `wl_start`, `wl_timer`; 1 sample/s from `kprobe_profile`) | reproduced stall 13:34:58 | **closed core stops delivering RX** (table below) |
| 6 | module option **`passivemode=1`** (DPC in a workqueue instead of a tasklet) | 10 min download | stalled after 269 s → **not enough** |
| 7 | **`vhtmode=0`** (802.11n instead of 802.11ac) through the patched ioctl | 10 min + 20 min download | **0 stalls**, ~140 Mbit/s |

### Trace of the stall at 13:34:58

```
time      rxKB    wl_isr  wl_dpc  wl_sendup  wl_start  wl_timer
13:34:56  35335    524    1150    22739      5147      63
13:34:57  32677    832    1331    21754      5050      63
13:34:58  33832   1981    2378    16329      3476      63   <- IRQ burst
13:34:59   5992   1662    1679        1         0      25   <- nothing delivered
13:35:00      0     32      32        2         1      10
13:35:08      0     15      15        0         1       2
...                (stays like this until the bus reset)
```

`wl_isr` = `wl_dpc` one to one, and the DPC re-enables interrupts (it is not rescheduling in a loop), so the open shim is healthy. The closed core (`wlc_dpc` → `wlc_bmac_recv` → `wlc_recv` → `wlc_recvdata_sendup`) stops handing packets up. It cannot be traced directly: the blob's functions are `notrace`, and kprobe refuses them with `Could not probe notrace function`.

The watchdog's diagnosis at each real stall showed the same thing: PCI vendor id `14e4` (still on the bus), `LnkSta 2.5GT/s x1`, and 97–147 interrupts per 5 s.

## 4. Why a patch was needed for `vhtmode`

- The blob contains iovars such as `vhtmode`, `nmode`, `bw_cap`, `ampdu_rx`, `ampdu_rx_factor` and `ampdu_ba_wsize` (`strings wlc_hybrid.o_shipped`).
- They are set through `SIOCDEVPRIVATE` with a `wl_ioctl_t { cmd, buf, len, set, used, needed }`, using `WLC_SET_VAR` (263) and `WLC_GET_VAR` (262).
- Since **Linux 5.15**, `dev_ifsioc()` sends `SIOCDEVPRIVATE` only to `ndo_siocdevprivate`. `wl` only fills `ndo_do_ioctl`, so user space gets `EOPNOTSUPP`. None of RPM Fusion's 38 patches (3.18 … 7.2) adds it.
- The patch adds `wl_siocdevprivate()`, which calls the existing `wl_ioctl()`, and sets it in both `net_device_ops`.
- With it, `wlctl get vhtmode` answered `vhtmode=1`. `set vhtmode 0` returned `EINVAL` while the driver was up, and worked after `WLC_DOWN` (cmd 3), with `WLC_UP` (cmd 2) afterwards.
- `ampdu*`, `amsdu` and `rxchain` answer "not supported" in this build, so the A-MPDU size cannot be tuned directly. Turning VHT off caps A-MPDU at 64 KB (HT) instead of ~1 MB (VHT).
- Side effect seen in the trace: the interrupt rate went from ~800/s to ~8,000/s, with smaller and more frequent RX batches, and the stall did not happen again.

## 5. Results of the final configuration

| test | duration | throughput | stalls |
|---|---|---|---|
| vhtmode=0, download, 8 streams | 600 s | 137 Mbit/s (9.6 GB) | 0 |
| vhtmode=0, download, 8 streams | 1,200 s | 142 Mbit/s (19.8 GB) | 0 |
| after a reboot with `install.sh` (fix applied at boot, before NetworkManager) | 300 s | 148 Mbit/s (5.2 GB) | 0 |

## 6. Pitfalls hit along the way

- `iperf3 -s` stayed "busy" after a stall. Use `--rcv-timeout`. Do **not** use `--idle-timeout`, which closes the port between tests.
- SELinux (Fedora): systemd cannot `exec` scripts from `/var/tmp` (`203/EXEC`) nor open `StandardOutput=file:` there (`209/STDOUT`). `insmod` refused a module labelled `var_lib_t`; it has to live under `/lib/modules` (`modules_object_t`).
- `kprobe_profile` lists probe names without the `group/` prefix, and kprobes on a module are lost when the module is reloaded.
- `wl_intrson` is inlined into `wl_dpc` (0 hits).
- Some stalls are "two-stage": the gateway still answers ping for a few minutes while other hosts do not (`No route to host`). A gateway-only watchdog then reacts later (~4.5 min instead of ~2).

## 7. If it comes back

1. Check `modinfo -n wl` → `updates/wl.ko` and `sudo wlctl get vhtmode` → `0`.
2. Look at `journalctl -u wl-watchdog` (or the machine's own watchdog) for the chip diagnosis.
3. Next options: lower the bandwidth with `mimo_bw_cap`, which is accepted. Or use the 2.4 GHz band. Or drop `wl`: a USB adapter with an in-kernel driver (MediaTek `mt76`), or Ethernet.
