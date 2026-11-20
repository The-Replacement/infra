# systemd units for the appliance

There are two families here. The radio scheduler units below run **on the
mainframe** as system units in `/etc/systemd/system/` (user `kbdejavu`,
`WorkingDirectory=/home/kbdejavu/servers/radio`), installed from this directory
via `deploy/bootstrap.sh`. The `radio-backup*` units run **on the workstation**
as the operator's own user (user units under `~/.config/systemd/user/`), because
the state they save lives on the laptop.

Radio scheduled work is owned by these timers/slice; legacy cron lines for the
same jobs must not coexist with them (double-runs). On a cutover, install and
enable the timers, verify runs in the journal, then remove any `radio-job`,
`mario-slot`, `restart-on-signal`, or `mario-refresh` cron lines.

| Unit | Purpose | Schedule |
|---|---|---|
| `radio-gc.service` / `.timer` | Retention: build cache, images, journal, logs, run history (`radio-job gc`) | Nightly 04:30, persistent |
| `radio-verify.service` / `.timer` | Probe the station, write `data/status.json` (`radio-job verify`) | Every 5 minutes, 3 minutes after boot |
| `radio-tts.service` / `.timer` | Mario voice refresh (`radio-job tts`) | Hourly, persistent |
| `radio-render.service` / `.timer` | Generator cycle (`radio-job render`) | Every 6 hours, persistent |
| `radio-slot-weather.service` / `.timer` | Weather slot (`mario-slot weather`) | Every 10 minutes, persistent |
| `radio-slot-rss.service` / `.timer` | News slot (`mario-slot rss`) | Every 30 minutes, persistent |
| `radio-restart-signal.service` / `.timer` | Library-rotation restart handler (`restart-on-signal.sh`) | Every minute, persistent |
| `radio-heal.service` / `.timer` | Self-heal ladder (`radio-job heal`) | Every 5 minutes, persistent |
| `radio-batch.slice` | Low-priority slice for batch work (CPUWeight=20) | Always on |

### Workstation: backup (user units)

| Unit | Purpose | Schedule |
|---|---|---|
| `radio-backup.service` / `.timer` | `backup.sh backup`, then `offsite-sync.sh box` | Nightly 03:15, persistent |
| `radio-backup-offsite.service` / `.timer` | `offsite-sync.sh github`, encrypted off-house copy | Weekly, Sunday 04:00 |
| `radio-backup-alert.service` | `OnFailure=` hook: desktop notification + `failure.log` | Fired by a failed backup |

## Never add `PrivateTmp=yes` to these units

Not hygiene — a five-night outage (infra#25). A user unit cannot mount a private
`/tmp` without a user namespace, and systemd maps only the caller's uid into it.
Root-owned files then read back as `nobody` (65534):

```
$ systemd-run --user -p PrivateTmp=yes stat -c '%U %n' /etc/hostname
nobody /etc/hostname          # uid 0 is simply unmapped inside the namespace
```

`ssh` enforces ownership on `/etc/ssh/ssh_config.d/*`, sees `nobody`, and exits
255 with `Bad owner or permissions on ...`. The backup pulled nothing from the
mainframe, kept its (empty) stage, and reported the failure only as a systemd
line nobody reads. `deploy/tests/test-backup.sh` fails if any shipped unit sets
`PrivateTmp`, so it cannot come back quietly.

## Install (mainframe, all radio scheduler units)

```bash
cd ~/servers/infra/deploy/systemd
sudo install -m 0644 \
  radio-batch.slice \
  radio-gc.service radio-gc.timer \
  radio-verify.service radio-verify.timer \
  radio-tts.service radio-tts.timer \
  radio-render.service radio-render.timer \
  radio-slot-weather.service radio-slot-weather.timer \
  radio-slot-rss.service radio-slot-rss.timer \
  radio-restart-signal.service radio-restart-signal.timer \
  radio-heal.service radio-heal.timer \
  /etc/systemd/system/

sudo systemctl daemon-reload
sudo systemctl enable --now radio-batch.slice
sudo systemctl enable --now \
  radio-gc.timer radio-verify.timer radio-tts.timer radio-render.timer \
  radio-slot-weather.timer radio-slot-rss.timer \
  radio-restart-signal.timer radio-heal.timer

# prove they run now, not "eventually"
for s in radio-gc radio-verify radio-tts radio-render \
         radio-slot-weather radio-slot-rss radio-restart-signal radio-heal; do
  sudo systemctl start "$s.service"
  systemctl status "$s.service" --no-pager || true
done
journalctl -u 'radio-*' -n 50 --no-pager
cd ~/servers/radio && ./scripts/radio-job.sh status
```

Cutover order to avoid double-runs: install units, `daemon-reload`, remove or
comment all legacy radio/mario-slot cron lines, then `enable --now` timers and
verify runs in the journal. (If timers are already enabled elsewhere, stop
cron before enabling.)

Workstation backup units (no sudo, nothing in `/etc`):

```bash
install -m 0644 radio-backup.service radio-backup.timer \
               radio-backup-alert.service \
               radio-backup-offsite.service radio-backup-offsite.timer \
               ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now radio-backup.timer radio-backup-offsite.timer

# a timer that has never fired is a guess: run it once and read the journal
systemctl --user start radio-backup.service
journalctl --user -u radio-backup.service -n 50 --no-pager
```

## Why systemd (not cron)

`radio-job` and the slot/signal handlers are scheduled by systemd for the
reasons that matter on an unattended appliance: a journal entry per run with
exit status, `Persistent=true` so a missed activation runs at the next boot,
resource controls (`Nice`, `IOSchedulingClass`, and `radio-batch.slice`), and
no `>/dev/null`-style silent failures. Cron is not an authoritative scheduler
for these jobs.

## Known limitation

`radio-gc` cannot prune the BuildKit cache when `docker-buildx-plugin` is absent —
the legacy builder cannot see it. On 2026-11-13 the host had 8.6 GB of BuildKit
cache and no buildx; `gc` now logs that clearly instead of reporting a reclaim it
did not make. Install the plugin (`apt install docker-buildx-plugin`) or accept
that this one directory stays outside the retention policy.

Equally, `journalctl --vacuum-size` needs root. Without passwordless sudo for
that command, `gc` logs `SKIP` and the durable fix is `SystemMaxUse=1G` in
`/etc/systemd/journald.conf`. Do both: the config caps growth, the vacuum
reclaims what is already there.
