#!/usr/bin/env bash
# measure-runtime.sh - per-container resource footprint, sampled.
#
#   ./measure-runtime.sh            # 120 samples, 2 s apart (~4 min)
#   ./measure-runtime.sh 300        # 300 samples (~10 min)
#
# Run it while the radio is actually streaming, not while it is idle: the whole
# question is what the audio path costs when it is doing its job.
#
# Output: a per-container summary (mean / peak CPU %, peak memory) plus a
# system-level summary (MemAvailable, PSI, temperature) at the start and end.
# It writes nothing but stdout.
#
# Requires: docker, and the ability to read /proc. No root needed.

set -uo pipefail

SAMPLES="${1:-120}"
INTERVAL=2
RADIO_DIR="${RADIO_DIR:-$HOME/servers/radio}"

command -v docker >/dev/null 2>&1 || { echo "docker not found" >&2; exit 2; }
docker info >/dev/null 2>&1 || { echo "cannot talk to the docker daemon" >&2; exit 2; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cpu_summary() {
  awk '{ s[$1] += $2; n[$1]++; if ($2 > p[$1]) p[$1] = $2 } END {
    for (c in s) printf "%-24s mean=%6.1f%%  peak=%6.1f%%\n", c, s[c]/n[c], p[c]
  }' "$1" | sort
}

mem_summary() {
  awk '{ v=$2+0; if (v > p[$1]) p[$1] = v } END {
    for (c in p) printf "%-24s peak=%7.1f MiB\n", c, p[c]
  }' "$1" | sort
}

system_line() {
  avail=$(awk '/^MemAvailable:/ {printf "%.0f", $2/1024}' /proc/meminfo)
  total=$(awk '/^MemTotal:/ {printf "%.0f", $2/1024}' /proc/meminfo)
  swapf=$(awk '/^SwapFree:/ {printf "%.0f", $2/1024}' /proc/meminfo)
  psim=$(awk '/^some/ {print $2}' /proc/pressure/memory 2>/dev/null)
  psii=$(awk '/^some/ {print $2}' /proc/pressure/io 2>/dev/null)
  load=$(cut -d' ' -f1-3 /proc/loadavg)
  temp="n/a"
  for z in /sys/class/thermal/thermal_zone*/temp; do
    t=$(cat "$z" 2>/dev/null) || continue
    case "$t" in ''|*[!0-9]*) continue ;; esac
    temp=$(awk -v v="$t" 'BEGIN {printf "%.1f", v/1000}')
    break
  done
  printf '  MemAvailable %s/%s MiB  SwapFree %s MiB  PSI mem %s  PSI io %s  load %s  temp %s C\n' \
    "$avail" "$total" "$swapf" "${psim:-n/a}" "${psii:-n/a}" "$load" "$temp"
}

echo "measure-runtime.sh - $SAMPLES samples x ${INTERVAL}s"
echo "host: $(hostname)  kernel: $(uname -r)"
echo "start: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "radio checkout: $RADIO_DIR"
echo
echo "system at start:"
system_line
echo
echo "containers at start:"
docker ps --format '  {{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null
echo
echo "sampling..."

i=0
while [ "$i" -lt "$SAMPLES" ]; do
  docker stats --no-stream --format '{{.Name}} {{.CPUPerc}} {{.MemUsage}}' 2>/dev/null \
    | while read -r name cpu mem; do
        # "12.34%" -> 12.34 ; "45.6MiB / 1.9GiB" -> 45.6
        c=${cpu%\%}
        m=$(printf '%s' "$mem" | awk '{print $1}' | sed 's/MiB//;s/GiB/*1024/' )
        case "$m" in
          *'*1024') m=$(printf '%s' "$m" | awk -F'*' '{printf "%.1f", $1*$2}') ;;
        esac
        printf '%s %s\n' "$name" "$c" >> "$tmp/cpu.raw"
        printf '%s %s\n' "$name" "$m" >> "$tmp/mem.raw"
      done
  i=$((i + 1))
  sleep "$INTERVAL"
done 2>/dev/null

echo
echo "per-container CPU (% of one core, as reported by docker):"
cpu_summary "$tmp/cpu.raw"
echo
echo "per-container peak memory:"
mem_summary "$tmp/mem.raw"
echo
echo "system at end:"
system_line
echo "end: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo
echo "Read this next to docs/appliance/02-resource-budget.md:"
echo "  - a peak that is close to the container's limit is a container that will"
echo "    be killed the moment something else on the box grows;"
echo "  - peak memory is what the OOM killer sees; mean memory is what you size"
echo "    the machine for;"
echo "  - a mean CPU near 100% for liquidsoap or cam means the encoder cannot"
echo "    keep up and the stream will stutter before any alert fires."
