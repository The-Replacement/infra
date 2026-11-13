# Runbook: rollback

**Goal:** return the host to the last state that served the stream, in under two
minutes, without touching anyone's credential.

A redeploy is a fast-forward. A rollback is a fast-forward in the other
direction — the same mechanism, the same hook, no special path.

## 1. Decide what you are rolling back

| Symptom | Roll back |
|---|---|
| Caddy config rejects requests / 502 for everyone | `caddy/` to the previous commit |
| Mario's voice stopped generating, files wrong | `Dockerfile.mario` / `src/` / `presets/` |
| The camera stopped producing | `cam/` |
| The stream itself is silent | usually **not** a code rollback — see below |

## 2. Roll back code

On the workstation, with the bad commit identified (`git log --oneline`):

```bash
git checkout -b rollback/<what> <last-good-sha>
git push mainframe rollback/<what>:master
```

The push into the bare repository moves the host's working tree to that commit,
and `post-receive` re-runs the same decisions: Caddy reload, image rebuilds.

If the host is unreachable, do it on the host:

```bash
cd ~/servers/radio
git log --oneline -10
git reset --hard <last-good-sha>          # working tree only; no push needed
docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
```

`git reset --hard` on the host is safe **while nothing else has changed there**:
the host has no uncommitted work by design. Check `git status` first and say out
loud what it shows.

## 3. Roll back a service that will not start

```bash
docker compose -f ~/servers/radio/docker-compose.yml ps
docker compose -f ~/servers/radio/docker-compose.yml logs --tail=100 <service>
```

Prefer `restart` over `up -d` for a single service: `up -d` recreates containers
and re-evaluates the whole compose file, which can drag in changes you were not
rolling back.

```bash
docker compose -f ~/servers/radio/docker-compose.yml restart caddy
```

## What a code rollback does NOT fix

- **The music library.** `./music-audio` and `./music` are content, not code.
  A bad rotation is fixed by `./scripts/indiegen-cycle.sh` with a known seed, or
  by restoring the backup (see `backup/`).
- **Mario's rendered segments.** `./data/host` is generated content. Delete the
  affected files and let the next hourly cycle regenerate them.
- **A listener's credential.** Tokens live in `secrets/tokens.txt` and
  `caddy/tokens.caddy` on the host, not in git. Rolling code back does not
  un-revoke or re-issue anything.

## After a rollback

1. Confirm the stream (audio within ~10 s of a request).
2. Confirm Caddy's reload actually happened:
   `docker compose logs --tail=20 caddy`.
3. Write down what the bad commit was and open an issue. A rollback that is not
   followed by an issue is a rollback you will do again.
