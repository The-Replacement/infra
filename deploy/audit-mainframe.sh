#!/usr/bin/env bash
# audit-mainframe.sh - read-only inventory of the radio host.
#
#   ./audit-mainframe.sh                     # report to stdout
#   ./audit-mainframe.sh > audit.txt         # report to a file
#   ssh -t kbdejavu@192.168.100.148 'bash -s' < ./audit-mainframe.sh > audit.txt
#
# WHY THIS EXISTS
# The host overheated and hit memory limits and was powered off. Before any
# decision about what runs on it, we need to know what is actually running on it.
# Guessing from docker-compose.yml answers only part of the question: the compose
# file says nothing about Jellyfin, cron jobs, systemd timers, stray processes,
# disk consumers or the thermal envelope.
#
# It only READS. No service is stopped, no package installed, no file written
# outside stdout (and the caller's redirect). The one exception is `docker
# system df`, which may touch the daemon's cache statistics and nothing else.
#
# Runs as a normal user. Sections that need root (some SMART data, journal
# errors) are skipped with a note instead of escalating.
#
# Exit codes: always 0. A missing tool is a line in the report, not a failure.

set -uo pipefail

# Optional: the radio checkout on the host. Used to compare the running
# containers against the compose file.
RADIO_DIR="${RADIO_DIR:-$HOME/servers/radio}"

hr() { printf '\n=== %s %s\n' "$1" "$(printf '=%.0s' $(seq 1 $((60 - ${#1}))))"; }
have() { command -v "$1" >/dev/null 2>&1; }
note() { printf '  (%s)\n' "$*"; }

hr "host"
printf 'date_utc:      %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'hostname:      %s\n' "$(hostname)"
printf 'kernel:        %s\n' "$(uname -srm)"
printf 'uptime:        %s\n' "$(uptime | sed 's/^ *//')"
printf 'loadavg:       %s\n' "$(cat /proc/loadavg)"
if have lsb_release; then
  printf 'distro:        %s\n' "$(lsb_release -ds 2>/dev/null)"
else
  printf 'distro:        %s\n' "$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | tr -d '"')"
fi
printf 'boot_time:     %s\n' "$(uptime -s 2>/dev/null || echo unknown)"
printf 'wm/desktop:    %s\n' "${XDG_CURRENT_DESKTOP:-none (headless or unset)}"
if [ -d /sys/firmware/efi ]; then echo "firmware:      UEFI"; else echo "firmware:      BIOS"; fi

hr "cpu"
if have lscpu; then
  lscpu | grep -E '^(Model name|Socket|Core\(s\) per socket|Thread\(s\) per core|CPU\(s\):|CPU max MHz|CPU min MHz|Virtualization|L3 cache)' | sed 's/^/  /'
fi
printf '  governor(s): '
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  [ -r "$g" ] && printf '%s ' "$(cat "$g")"
done
echo
printf '  frequency policy: %s\n' "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null || echo 'not exposed (VM or locked firmware)')"
printf '  pressure (cpu): %s\n' "$(cat /proc/pressure/cpu 2>/dev/null | tr '\n' ' ')"

hr "memory"
grep -E '^(MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapTotal|SwapFree|Dirty|Committed_AS|CommitLimit)' /proc/meminfo | sed 's/^/  /'
printf '  pressure (memory): %s\n' "$(cat /proc/pressure/memory 2>/dev/null | tr '\n' ' ')"
printf '  pressure (io):     %s\n' "$(cat /proc/pressure/io 2>/dev/null | tr '\n' ' ')"
printf '  overcommit_memory: %s\n' "$(cat /proc/sys/vm/overcommit_memory 2>/dev/null)"
printf '  swappiness:        %s\n' "$(cat /proc/sys/vm/swappiness 2>/dev/null)"
if have swapon; then swapon --show | sed 's/^/  /' || note "no swap devices"; fi
if [ -d /sys/block/zram0 ]; then
  # mem_used_total was removed from newer kernels; mm_stat still carries it as
  # its first field. Try both instead of printing an empty value.
  zused=$(cat /sys/block/zram0/mem_used_total 2>/dev/null)
  [ -n "${zused:-}" ] || zused=$(awk 'NR==1 {print $1}' /sys/block/zram0/mm_stat 2>/dev/null)
  printf '  zram0: disksize=%s mem_used=%s\n' \
    "$(cat /sys/block/zram0/disksize 2>/dev/null)" "${zused:-unknown}"
else
  echo "  zram: not present"
fi
echo "  top 5 by RSS:"
ps -eo rss,comm --sort=-rss | head -6 | awk 'NR>1 {printf "    %6.0f MB  %s\n", $1/1024, $2}'

hr "thermal"
if have sensors; then
  sensors 2>/dev/null | sed 's/^/  /' || note "sensors present but returned nothing"
else
  note "lm-sensors not installed: reading raw sysfs"
fi
# A file can be present in sysfs and still fail to read (EIO on a dead sensor).
# Read once into a variable and skip the reading, instead of handing awk a path
# it cannot open.
for zone in /sys/class/thermal/thermal_zone*; do
  [ -d "$zone" ] || continue
  zt=$(cat "$zone/temp" 2>/dev/null) || continue
  [ -n "$zt" ] || continue
  printf '  %s: %.1f C' "$(cat "$zone/type" 2>/dev/null)" "$(awk -v v="$zt" 'BEGIN {print v/1000}')"
  for tp in "$zone"/trip_point_*_temp; do
    [ -f "$tp" ] || continue
    tv=$(cat "$tp" 2>/dev/null) || continue
    # Negative millidegrees are "sensor not implemented", not -274 C.
    case "$tv" in ''|*[!0-9]*) continue ;; esac
    [ "$tv" -gt 1000 ] || continue
    printf ' %s=%.0fC' "$(basename "$tp" _temp | sed 's/trip_point_//')" "$(awk -v v="$tv" 'BEGIN {print v/1000}')"
  done
  echo
done
for hw in /sys/class/hwmon/hwmon*; do
  [ -d "$hw" ] || continue
  name=$(cat "$hw/name" 2>/dev/null)
  temps=""
  for t in "$hw"/temp*_input; do
    [ -f "$t" ] || continue
    v=$(cat "$t" 2>/dev/null) || continue
    case "$v" in ''|*[!0-9-]*) continue ;; esac
    [ "$v" -gt 1000 ] || continue
    label=$(cat "${t%_input}_label" 2>/dev/null || basename "$t" _input)
    temps="$temps $label=$(awk -v v="$v" 'BEGIN {printf "%.1f", v/1000}')C"
  done
  fans=""
  for f in "$hw"/fan*_input; do
    [ -f "$f" ] || continue
    v=$(cat "$f" 2>/dev/null) || continue
    [ -n "$v" ] || continue
    fans="$fans $(basename "$f" _input)=${v}rpm"
  done
  [ -n "$temps$fans" ] && printf '  %s:%s%s\n' "$name" "$temps" "$fans"
done
echo "  throttle events this boot:"
if have journalctl; then
  journalctl -k -b --no-pager 2>/dev/null \
    | grep -iE 'thermal|throttl|critical temperature|mce: |Machine check' \
    | tail -20 | sed 's/^/    /' || echo "    none matched (or journal unreadable without root)"
else
  note "journalctl not available"
fi

hr "disk"
df -h -x tmpfs -x devtmpfs | sed 's/^/  /'
echo "  inodes:"
df -i -x tmpfs -x devtmpfs | sed 's/^/  /'
echo "  largest directories under /var and /home (depth 1):"
du -h -d1 /var /home 2>/dev/null | sort -hr | head -12 | sed 's/^/  /'
if have du; then
  echo "  docker root:"
  d=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)
  if [ -n "$d" ]; then
    # Reported path always; size only when this user can actually walk it.
    printf '    %s\n' "$d"
    if sz=$(du -sh "$d" 2>/dev/null); then
      printf '    size: %s\n' "$sz"
    else
      printf '    size: needs root\n'
    fi
  fi
  jsize=$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+ ?[KMGTP]i?B' | head -1)
  printf '  journal size: %s\n' "${jsize:-unknown (journalctl --disk-usage failed)}"
fi
echo "  files >100MB outside /proc /sys /usr /opt:"
find / -xdev -type f -size +100M \
  -not -path '/proc/*' -not -path '/sys/*' -not -path '/usr/*' -not -path '/opt/*' 2>/dev/null \
  | head -20 | while read -r f; do printf '    %s  %s\n' "$(du -h "$f" 2>/dev/null | cut -f1)" "$f"; done

hr "systemd"
echo "  failed units:"
systemctl --failed --no-pager --no-legend 2>/dev/null | sed 's/^/    /' || note "not readable"
echo "  running services (non-system):"
systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null \
  | awk '{print "    " $1}' | grep -vE 'systemd-|dbus|getty|ssh|cron|polkit|udisks|networkd|resolved|logind|rsyslog|snapd' | head -40
echo "  enabled timers:"
systemctl list-timers --all --no-pager --no-legend 2>/dev/null | head -20 | sed 's/^/    /'

hr "processes"
echo "  top 15 by CPU time:"
ps -eo pid,pcpu,pmem,rss,etime,args --sort=-pcpu | grep -v 'ps -eo' | head -16 | cut -c1-160 | sed 's/^/    /'
echo "  processes with oom_score_adj != 0:"
for p in /proc/[0-9]*; do
  a=$(cat "$p/oom_score_adj" 2>/dev/null) || continue
  [ "${a:-0}" = "0" ] && continue
  printf '    %6s adj=%-5s %s\n' "$(basename "$p")" "$a" "$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null | cut -c1-80)"
done | head -20

hr "docker"
if ! have docker; then
  note "docker not installed"
else
  docker version --format '  server: {{.Server.Version}}  api: {{.Server.APIVersion}}' 2>/dev/null || note "cannot talk to the daemon"
  echo "  containers:"
  docker ps -a --format '    {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.RunningFor}}' 2>/dev/null
  echo "  resource limits (empty = unlimited):"
  for c in $(docker ps -aq 2>/dev/null); do
    docker inspect "$c" --format '    {{.Name}}: mem={{if .HostConfig.Memory}}{{.HostConfig.Memory}}{{else}}unlimited{{end}} cpus={{if .HostConfig.NanoCpus}}{{.HostConfig.NanoCpus}}{{else}}unlimited{{end}} pids={{if .HostConfig.PidsLimit}}{{.HostConfig.PidsLimit}}{{else}}unlimited{{end}} restart={{.HostConfig.RestartPolicy.Name}}' 2>/dev/null
  done
  echo "  live stats (one shot):"
  docker stats --no-stream --format '    {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}' 2>/dev/null
  echo "  disk:"
  docker system df 2>/dev/null | sed 's/^/    /'
  echo "  volumes:"
  docker volume ls --format '    {{.Name}}' 2>/dev/null | head -20
fi

hr "network"
if have ss; then
  ss -tulpn 2>/dev/null | sed 's/^/  /' || note "ss needs root for process names"
else
  note "ss not installed"
fi
ip -br addr 2>/dev/null | sed 's/^/  /'
echo "  default route: $(ip route show default 2>/dev/null | head -1)"

hr "scheduled work"
echo "  crontabs:"
for u in $(cut -d: -f1 /etc/passwd); do
  out=$(crontab -l -u "$u" 2>/dev/null | grep -vE '^\s*#|^\s*$') || continue
  [ -n "$out" ] && printf '    [%s]\n%s\n' "$u" "$(echo "$out" | sed 's/^/      /')"
done
echo "  /etc/cron.d and cron.daily:"
ls /etc/cron.d /etc/cron.daily /etc/cron.hourly 2>/dev/null | sed 's/^/    /'
echo "  root crontab readable: $( [ -r /var/spool/cron/crontabs/root ] && echo yes || echo 'no (needs root)')"

hr "packages and updates"
if have dpkg; then
  printf '  installed packages: %s\n' "$(dpkg-query -f '.\n' -W 2>/dev/null | wc -l)"
  printf '  manually installed: %s\n' "$(apt-mark showmanual 2>/dev/null | wc -l)"
  printf '  pending upgrades:   %s\n' "$(apt list --upgradable 2>/dev/null | tail -n +2 | wc -l)"
fi
printf '  unattended-upgrades: %s\n' "$(a=$(systemctl is-active unattended-upgrades 2>/dev/null); printf '%s' "${a:-not installed}")"
printf '  reboot required:     %s\n' "$( [ -f /var/run/reboot-required ] && echo yes || echo no)"

hr "radio checkout"
if [ -d "$RADIO_DIR/.git" ]; then
  printf '  path:   %s\n' "$RADIO_DIR"
  printf '  commit: %s\n' "$(git -C "$RADIO_DIR" rev-parse --short HEAD 2>/dev/null)"
  printf '  dirty:  %s\n' "$(git -C "$RADIO_DIR" status --porcelain 2>/dev/null | wc -l) file(s)"
  printf '  .env:   %s\n' "$( [ -f "$RADIO_DIR/.env" ] && stat -c '%a %U:%G' "$RADIO_DIR/.env" || echo missing)"
  printf '  deploy log (last 5):\n'
  tail -5 "$RADIO_DIR/data/deploy.log" 2>/dev/null | sed 's/^/    /' || echo "    none"
  printf '  library: %s audio file(s), %s meta file(s)\n' \
    "$(find "$RADIO_DIR/music-audio" -maxdepth 1 -name '*.flac' 2>/dev/null | wc -l)" \
    "$(find "$RADIO_DIR/music" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l)"
else
  note "no git checkout at $RADIO_DIR (set RADIO_DIR=...)"
fi

hr "end"
printf 'audit complete: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
