# infra

Deploy, monitoring and runbooks for The-Replacement projects.

The production radio host is a single always-on Ubuntu Server box on the LAN
(`192.168.100.148`, hostname `mainframe`). It runs the radio stack as Docker
Compose. It has been offline since it overheated and hit memory limits; see
`docs/mainframe/` for the audit and the appliance plan.

## Layout

```
deploy/       bootstrap, environment templates, systemd units, host audit
monitoring/   metrics, alert rules, dashboards, heartbeat
runbooks/     what to do when something is broken
```

## Ground rules

- **No secrets in this repository.** Environment templates carry variable names
  and comments, never values. Real `.env` lives on the host, mode 0600.
- **Nothing here is deployed automatically.** Every script is run by a human,
  after reading what it does.
- **A runbook that has never been executed is a guess.** Each one says when it
  was last exercised against the real host.
- **The content is disposable; the state is not.** The station's audio is
  deterministic: it is regenerated from seeds, so copying it would be copying a
  recomputable answer. What is *not* derivable is `data/indiegen/state.json`
  (the seed cursor), `.env`, `secrets/`, the agent memory trees (`.n3rv`), the
  OpenCode database and the XERJ auth state. Those are state, and
  `deploy/backup.sh` puts them in one encrypted restic repository that is
  verified after every write. Reasoning for the audio:
  `The-Replacement/docs/autonomy/04-disposability.md`. Procedure:
  [backup.md](runbooks/backup.md), proof: [restore-drill.md](runbooks/restore-drill.md).

## Runbooks

| Runbook | When |
|---|---|
| [deploy.md](runbooks/deploy.md) | Shipping a change to the host |
| [rollback.md](runbooks/rollback.md) | A deploy made things worse |
| [backup.md](runbooks/backup.md) | Backing up state, or the backup failed |
| [restore-drill.md](runbooks/restore-drill.md) | Proving a backup can be restored |
| [cloudflare-pages.md](runbooks/cloudflare-pages.md) | The player page stopped publishing |
| [credential-rotation.md](runbooks/credential-rotation.md) | Token, password or key exposure |
| [incident-response.md](runbooks/incident-response.md) | The box is hot, out of memory, or unreachable |
