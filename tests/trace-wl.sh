#!/bin/bash
# tests/trace-wl.sh - count, once per second, how often the wl shim functions run (kprobes) plus RX/TX KB.
# This is how the stall was located: during a stall wl_isr/wl_dpc keep running but wl_sendup drops to 0,
# i.e. the closed core stops delivering received packets (see docs/investigation.md, section 3).
#
#   sudo tests/trace-wl.sh start [OUT_FILE]   default OUT_FILE: ./results/trace-<date>.log
#   sudo tests/trace-wl.sh show [N]           last N samples (default 20)
#   sudo tests/trace-wl.sh stop               remove the probes and restore ftrace settings
#
# Notes: only shim functions (wl_*) can be probed; the closed core's wlc_* functions are notrace.
# Probes on a module are lost when wl is reloaded (e.g. by the watchdog): run "stop" and "start" again.
#
# SPDX-License-Identifier: MIT
set -u
. "$(dirname "$(readlink -f "$0")")/lib.sh"
T=/sys/kernel/tracing
STATE=/run/wl-trace
FUNCS="wl_isr wl_dpc wl_sendup wl_start wl_timer"

sample() { # OUT IF
  local out=$1 ifc=$2 rx tx rxa txa line n hit d
  declare -A prev
  rxa=$(awk -v i="$ifc:" '$1==i{print $2}' /proc/net/dev); txa=$(awk -v i="$ifc:" '$1==i{print $10}' /proc/net/dev)
  echo "# $(date -Is) start ($ifc) - time rxKB txKB $FUNCS" >> "$out"
  while true; do
    sleep 1
    rx=$(awk -v i="$ifc:" '$1==i{print $2}' /proc/net/dev); tx=$(awk -v i="$ifc:" '$1==i{print $10}' /proc/net/dev)
    line="$(date +%T) rxKB=$(( (${rx:-0} - ${rxa:-0}) / 1024 )) txKB=$(( (${tx:-0} - ${txa:-0}) / 1024 ))"
    rxa=$rx; txa=$tx
    while read -r n hit; do
      case " $FUNCS " in *" $n "*) d=$(( hit - ${prev[$n]:-$hit} )); prev[$n]=$hit; line+=" $n=$d" ;; esac
    done < <(awk 'NF==3{print $1, $2}' "$T/kprobe_profile")
    echo "$line" >> "$out"
  done
}

case "${1:-}" in
  __sample) sample "$2" "$3" ;;
  start)
    need_root
    IF=$(wl_iface) || { echo "no wl interface"; exit 1; }
    [ -e "$STATE/pid" ] && { echo "already running (pid $(cat "$STATE/pid")); run stop first"; exit 1; }
    OUT=${2:-./results/trace-$(date +%Y%m%d-%H%M%S).log}
    mkdir -p "$(dirname "$OUT")"; OUT=$(readlink -f "$OUT"); : > "$OUT"
    [ -n "${SUDO_UID:-}" ] && chown "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$(dirname "$OUT")" "$OUT"
    mkdir -p "$STATE"; cat "$T/tracing_on" > "$STATE/tracing_on"
    # buffer_size_kb reads "7 (expanded: 1408)" while unexpanded: keep the expanded size
    sed -E 's/.*expanded: ([0-9]+).*/\1/' "$T/buffer_size_kb" > "$STATE/buffer_size_kb"
    echo 0 > "$T/tracing_on"; echo 1 > "$T/buffer_size_kb"      # count hits only, record nothing
    for f in $FUNCS; do echo "p:wlk/$f $f" >> "$T/kprobe_events" || { echo "cannot probe $f"; exit 1; }; done
    echo 1 > "$T/events/wlk/enable"
    nohup "$0" __sample "$OUT" "$IF" > /dev/null 2>&1 &
    echo $! > "$STATE/pid"; echo "$OUT" > "$STATE/out"
    echo "tracing $IF -> $OUT (pid $!)"
    ;;
  show)
    [ -e "$STATE/out" ] && tail -n "${2:-20}" "$(cat "$STATE/out")" || echo "not running"
    ;;
  stop)
    need_root
    [ -e "$STATE/pid" ] && kill "$(cat "$STATE/pid")" 2>/dev/null
    [ -e "$T/events/wlk/enable" ] && echo 0 > "$T/events/wlk/enable"
    for f in $FUNCS; do echo "-:wlk/$f" >> "$T/kprobe_events" 2>/dev/null; done
    [ -e "$STATE/tracing_on" ] && cat "$STATE/tracing_on" > "$T/tracing_on"
    [ -e "$STATE/buffer_size_kb" ] && cat "$STATE/buffer_size_kb" > "$T/buffer_size_kb" 2>/dev/null
    [ -e "$STATE/out" ] && echo "trace kept in $(cat "$STATE/out")"
    rm -rf "$STATE"; echo "stopped"
    ;;
  *) sed -n '2,14p' "$0"; exit 2 ;;
esac
