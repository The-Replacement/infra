# Runbook: deploy a change to the host

**Applies to:** `radio` and `indiegenerator` on `mainframe`.
**Last exercised:** 2026-11-13, by push to `mainframe:` remote (pre-shutdown).

## How deployment works

There is no CI on the host and no pull. Deployment is a **push to a bare
repository on the box**:

- `~/servers/radio` on the host is a git repository configured with
  `receive.denyCurrentBranch=updateInstead`: the push itself moves the working
  tree to the pushed commit.
- `~/servers/radio/scripts/post-receive` runs on the host after the ref updates
  and decides what changes live.

From a workstation with the host reachable:

```bash
# The branch is per repo, and it is whatever the box has checked out:
git push mainframe master:master      # radio (its HEAD is on master)
git push mainframe main:main          # indiegenerator (its HEAD is on main)
```

The hook enforces this (infra#12): a push to a branch the box does not have
checked out fails the hook, names the checked-out branch, builds nothing and
restarts nothing — `updateInstead` cannot move the worktree for a foreign
ref, so it is not a deploy. The deploy log carries the commit the worktree
moved to. A rollback of `indiegenerator` therefore pushes
`rollback/<what>:main`, not `:master`.

`mainframe` is a *separate* remote, not a second push URL of `origin`. It was a
second `pushurl` until 2026-11-13; that made every ordinary `git push origin`
fail whenever the box was down, with the push to GitHub reported as a failure
after it had already succeeded.

## What the hook does, and what it deliberately does not

| Change pushed | Hook action |
|---|---|
| `caddy/Caddyfile`, `caddy/tokens.caddy` | `caddy reload` inside the container — graceful, listeners unaffected |
| `src/`, `presets/`, `pyproject.toml`, `uv.lock`, `Dockerfile.mario`, `docker-compose.yml` | `docker compose build mario` (rebuild only; the next hourly cycle uses it) |
| `cam/`, `docker-compose.yml` | `docker compose build cam` (build only; the service is not started) |
| anything else | logged only |

It logs to `data/deploy.log` and exits non-zero if a reload or build fails. The
push has already landed at that point: the previous config or image keeps
serving.

**Not restarted by a push:** `liquidsoap`, `icecast`, `mediamtx`. Restarting
Liquidsoap cuts the stream; that is a human decision.

**Consequence to keep in mind:** a push that touches code triggers a Docker
image build **on the production host**, competing with the stream for RAM and
CPU. On a box that has already OOM-killed, this is a load spike by design. See
`docs/mainframe/resource-budget.md` for the measured cost.

## Before deploying

1. On the workstation, with the change checked out:

   ```bash
   ./scripts/claims.sh                 # no hardcoded production domain
   ./scripts/ui-gate.js                # player state structure
   ./scripts/ui-gate.js --self-test    # the gate can still fail
   ./scripts/docs.sh                   # Mermaid diagrams render
   ./scripts/query-gate.sh             # the token never crosses the door (needs Docker)
   .venv/bin/python -m pytest -q
   .venv/bin/ruff check . && .venv/bin/mypy .
   ```

2. On the host, confirm it is healthy **before** adding work:

   ```bash
   ssh kbdejavu@192.168.100.148
   uptime; free -m; df -h /; sensors 2>/dev/null || cat /sys/class/thermal/thermal_zone*/temp
   docker compose -f ~/servers/radio/docker-compose.yml ps
   ```

   Do not deploy onto a host that is already swapping or above its thermal
   band. Fix that first.

## After deploying

```bash
tail -40 ~/servers/radio/data/deploy.log

# the stream still flows
curl -sS -o /dev/null -w '%{http_code}\n' https://stream.daza.ar/

# containers are up and not restarting
docker compose -f ~/servers/radio/docker-compose.yml ps

# memory did not move the wrong way
free -m

# the deploy record agrees with what is on disk and running
ssh kbdejavu@192.168.100.148 'cd ~/servers/radio && python3 scripts/deploy_manifest.py verify'
```

`verify` answers "does this host agree with its own deploy record": checkout,
hook hash against the tracked script, image ids, revision labels. It does **not**
answer "is this the intended GitHub revision" — that needs GitHub, the manifest
and the labels compared in one verdict, which is `n3rv doctor`'s job once its
runtime leg lands (infra#3). `deploy/health.sh` deliberately reports the running
SHA without judging it: a third expectation pinned on the workstation would have
nothing to disagree against.

## Rollback

See [rollback.md](rollback.md). Short version: push the previous commit to the
same remote; a redeploy is a fast-forward.

## Known gaps

- The hook rebuilds images on the host. A build machine or a registry would move
  that cost off the appliance.
- `post-receive` is written in Spanish, against the project's language rule
  (tracked in `radio#101`).
