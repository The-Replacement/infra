# systemd units for the appliance

There are two families here. The radio units below run **on the mainframe** as
`kbdejavu` (system units, `/etc/systemd/system/`). The `radio-backup*` units run
**on the workstation** as the operator's own user (user units under
`~/.config/systemd/user/`), because the state they save lives on the laptop.

Two jobs, deliberately separate from the deploy hook and from cron.

| Unit | Purpose | Schedule |
|---|---|---|
| `radio-gc.service` / `.timer` | Retention: build cache, images, journal, logs, run history | Nightly 04:30, persistent |
| `radio-verify.service` / `.timer` | Probe the station, write `data/status.json` | Every 5 minutes, 3 minutes after boot |
| `radio-tts.service` / `.timer` | Mario voice refresh (`radio-job tts`) | Hourly |
| `radio-render.service` / `.timer` | Generator cycle (`radio-job render`) | Every 6 hours |
| `radio-slot-weather.service` / `.timer` | Weather slot (`mario-slot weather`) | Every 10 minutes |
| `radio-slot-rss.service` / `.timer` | News slot (`mario-slot rss`) | Every 30 minutes |
| `radio-restart-signal.service` / `.timer` | Library-rotation restart handler | Every minute |
| `radio-heal.service` / `.timer` | Self-heal ladder (`radio-job heal`) | Every 5 minutes |
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

Both run as `kbdejavu` with `WorkingDirectory` in the radio checkout, so they use
the same `.env`, the same Compose file and the same data as everything else. No
root, no daemon, no agent.

## Install

```bash
sudo install -m 0644 radio-gc.service radio-gc.timer \
                      radio-verify.service radio-verify.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now radio-gc.timer radio-verify.timer

# prove they run, now, not "eventually"
sudo systemctl start radio-gc.service radio-verify.service
systemctl status radio-gc.service radio-verify.service --no-pager
./scripts/radio-job.sh status
```

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

## Why not cron

The two existing cron watchers (`restart-on-signal.sh` every minute,
`mario-refresh.sh` hourly) stay for now; they are replaced by `radio-job` in
#105. New work goes into systemd because it brings, for free: a journal entry per
run with exit status, `Persistent=true` so a job missed during downtime runs at
the next boot, resource controls (`Nice`, `IOSchedulingClass`, and a slice when
#105 lands), and no email-on-output surprise.

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
