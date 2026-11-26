#!/bin/bash
# tests/stall-test.sh - reproduce (or rule out) the wl RX stall with iperf3 and detect it automatically.
#
# On ANOTHER machine of the same LAN (the server; --rcv-timeout avoids "server busy" after a stall,
# do NOT use --idle-timeout, it closes the port between tests):
#     iperf3 -s --rcv-timeout 15000
#
# On the wl machine (the client):
#     tests/stall-test.sh -s SERVER_IP                      # 10 min download, 8 streams (default)
#     tests/stall-test.sh -s SERVER_IP -t 1200              # 20 min
#     tests/stall-test.sh -s SERVER_IP -d up                # upload only (never stalled)
#     tests/stall-test.sh -s SERVER_IP -m bursts -n 20      # 60 s bursts alternating up/down, 120 s idle between
#
# A stall is >= 3 consecutive seconds at 0 bit/s. After a stall the script waits up to 10 min for the
# network to come back (the watchdog's bus reset) and goes on. Results: ./results/stall-<date>/
# (summary.txt, one iperf3 log per run, watchdog.log). Run it detached so a stall does not kill it:
#     nohup tests/stall-test.sh -s SERVER_IP > /dev/null 2>&1 &      (then: tail -f results/*/summary.txt)
#
# Reference (MacBookPro11,2, 5 GHz, -62 dBm): stock 802.11ac = 6 stalls in ~15 min of download at
# ~240 Mbit/s; with the fix (vhtmode=0) = 0 stalls in 35 min at ~140 Mbit/s.
#
# SPDX-License-Identifier: MIT
set -u
. "$(dirname "$(readlink -f "$0")")/lib.sh"

SERVER=""; MODE=single; T=600; N=20; P=8; DIR=down; OUT=""
while getopts "s:m:t:n:P:d:o:h" o; do
  case $o in
    s) SERVER=$OPTARG ;; m) MODE=$OPTARG ;; t) T=$OPTARG ;; n) N=$OPTARG ;;
    P) P=$OPTARG ;; d) DIR=$OPTARG ;; o) OUT=$OPTARG ;;
    *) sed -n '2,22p' "$0"; exit 2 ;;
  esac
done
[ -n "$SERVER" ] || { sed -n '2,22p' "$0"; exit 2; }
command -v iperf3 >/dev/null || { echo "iperf3 not installed (sudo dnf install iperf3)"; exit 1; }
[ "$P" -ge 2 ] || { echo "-P must be >= 2 (the parser reads the [SUM] lines)"; exit 2; }
OUT=${OUT:-./results/stall-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT" && [ -w "$OUT" ] || { echo "cannot write results to $OUT (use -o DIR)"; exit 1; }
START=$(date '+%Y-%m-%d %H:%M:%S')
IF=$(wl_iface || true)
stalls=0; load=0; failed=0

log() { echo "$*" | tee -a "$OUT/summary.txt"; }
reachable() { ping -c 1 -W 2 "$SERVER" >/dev/null 2>&1; }
wait_net() {
  local i
  for i in $(seq 1 120); do reachable && { sleep 10; return 0; }; sleep 5; done
  return 1
}

# analyze FILE -> prints "seconds_with_data avg_mbit stall_at" (stall_at = -1 if none)
analyze() {
  awk '
    /^\[SUM\]/ && !/sender|receiver/ {
      split($2, iv, "-"); t = int(iv[1]); v = $6 + 0; u = $7
      if (u ~ /^Gbits/) v *= 1000; else if (u ~ /^Kbits/) v /= 1000; else if (u ~ /^bits/) v /= 1e6
      if (v == 0) { if (z == 0) zs = t; z++; if (z >= 3 && stall < 0) stall = zs } else { z = 0; n++; s += v }
    }
    BEGIN { stall = -1 }
    END { printf "%d %.0f %d\n", n, (n ? s / n : 0), stall }' "$1"
}

run() { # label seconds direction(down|up)
  local label=$1 secs=$2 d=$3 f flag="" res n avg st
  f="$OUT/$(echo "$label" | tr ' /' '__').log"
  # --rcv-timeout makes the receiving client give up after a stall; iperf3 accepts it only with -R
  [ "$d" = down ] && flag="-R --rcv-timeout 15000"
  reachable || { log "$(date +%T) $label: server unreachable before start; waiting"; wait_net || { log "network did not come back"; return 1; }; }
  iperf3 -c "$SERVER" -P "$P" -t "$secs" -i 1 --forceflush --connect-timeout 5000 $flag > "$f" 2>&1
  local rc=$?
  read -r n avg st <<<"$(analyze "$f" 2>/dev/null)"
  n=${n:-0}; avg=${avg:-0}; st=${st:--1}
  load=$((load + n))
  if [ "$n" -eq 0 ] && [ "$st" -lt 0 ]; then
    failed=$((failed + 1))
    log "$(date +%T) $label ($d): ❌ no data (iperf3 rc=$rc: $(grep -m1 -i error "$f" 2>/dev/null))"
    return 0
  fi
  if [ "$st" -ge 0 ]; then
    stalls=$((stalls + 1))
    log "$(date +%T) $label ($d): 🔴 STALL after ${st}s at ~${avg} Mbit/s"
    wait_net && log "$(date +%T)    network back" || { log "    network did not come back in 10 min"; return 1; }
  else
    log "$(date +%T) $label ($d): ok, ${n}s at ~${avg} Mbit/s"
  fi
}

reachable || { echo "server $SERVER does not answer ping; is it on the LAN and is iperf3 -s running?"; exit 1; }
log "stall-test start $START | server $SERVER | mode $MODE | streams $P | iface ${IF:-?} | kernel $(uname -r)"
[ -n "$IF" ] && log "wl module: $(modinfo -n wl 2>/dev/null) | $( (sudo -n "$WLCTL" -i "$IF" get vhtmode || "$WLCTL" -i "$IF" get vhtmode) 2>/dev/null || echo 'vhtmode=?')"

case $MODE in
  single) run "single" "$T" "$DIR" ;;
  bursts) for i in $(seq 1 "$N"); do
            d=up; [ $((i % 2)) -eq 0 ] && d=down
            run "burst $i/$N" 60 "$d" || break
            [ "$i" -lt "$N" ] && sleep 120
          done ;;
  *) echo "unknown mode $MODE"; exit 2 ;;
esac

journalctl -u wl-watchdog --since "$START" -o short-iso --no-pager > "$OUT/watchdog.log" 2>/dev/null || true
log "result: $stalls stall(s) in ${load}s of load$([ "$failed" -gt 0 ] && echo ", $failed run(s) without data") | logs: $OUT"
[ "$stalls" -eq 0 ] && [ "$failed" -eq 0 ]
