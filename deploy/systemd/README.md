# systemd units for the appliance

Two jobs, deliberately separate from the deploy hook and from cron.

| Unit | Purpose | Schedule |
|---|---|---|
| `radio-gc.service` / `.timer` | Retention: build cache, images, journal, logs, run history | Nightly 04:30, persistent |
| `radio-verify.service` / `.timer` | Probe the station, write `data/status.json` | Every 5 minutes, 3 minutes after boot |

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
