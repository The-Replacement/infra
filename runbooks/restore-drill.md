# Restore drill

**Goal:** prove, with evidence, that the backup in `runbooks/backup.md` can put
the state back — before the day it is the only copy left.

A backup that has never been restored is an assumption. This document is the
procedure that turns it into a fact, and the record of when it was last a fact.

**Cadence:** monthly, and after any change to `deploy/backup.sh` or to the set
of backed-up paths.
**Last exercised:** 2026-11-15, end to end against a real repository. Snapshot
`0a552e57` (1015 MiB, 10627 files) restored to `/tmp/radio-restore`:

| Check | Result |
|---|---|
| 3.1 memory DBs (`quick_check`) | 7/7 `ok` (after repairing `mario` — see `backup.md`) |
| 3.2 `n3rv memory stats` (radio) + search | 175/175 memories, search returns real entries |
| 3.3 OpenCode | integrity `ok`, `wal`, session 173/173, message 14299/14299, part 59238/59238 |
| 3.4 XERJ auth state | `.xerj_master_key`, `_users`, `_api_tokens`, `_idp_config` … all present |
| 3.5 modes | `.env` 600, `secrets/tokens.txt` 600 |

That run corrected two bugs in this document: a `-maxdepth` on the `find` (§2)
and a query against a `sessions` table that has not existed since the schema
moved to singular table names (§3.3).

**Never against production paths.** Every step below restores to a scratch
directory. The last section is the separate, deliberate operation that writes
live.

## 0. Preconditions

On the workstation:

```bash
export RESTIC_REPOSITORY=...        # from ~/.config/radio-backup/backup.conf
export RESTIC_PASSWORD_FILE=...
restic snapshots --tag radio-state  # pick the newest, note the ID and time
```

Write down the snapshot ID before touching anything. The drill is worthless
without a result that can be re-checked later.

## 1. Dry run: what would come back

```bash
./deploy/backup.sh restore-dry-run <ID>
```

Expected:

- the `workstation/projects/<project>/.n3rv` tree for **every** project under
  the configured `PROJECTS_ROOT`;
- `workstation/opencode/opencode.db`;
- `workstation/xerj-data/`;
- `mainframe-radio/` with `.env`, `secrets/tokens.txt`, `config/feeds.yaml`,
  `caddy/tokens.caddy`, `data/indiegen/state.json`.

If a project is missing here, it was not backed up. That is the finding; stop
and fix the backup job before continuing.

## 2. Restore to scratch

```bash
mkdir -p /tmp/radio-restore
restic restore <ID> --target /tmp/radio-restore
```

The snapshot stores the staging path, so the tree lands at
`/tmp/radio-restore/<old stage path>/workstation/...`. Set it once:

```bash
R=$(find /tmp/radio-restore -type d -name workstation | head -1)
S=$(dirname "$R")
printf 'restored tree: %s\n' "$S"
```

Do not bound that `find` with `-maxdepth`: the snapshot stores the staging path,
and with the default staging directory the restored `workstation` sits ten
levels down. A `-maxdepth 6` silently finds nothing and the next line prints a
restored tree of `.` — measured on the first real drill, 2026-11-15.
## 3. Prove the workstation data is usable

### 3.1 Every project's memory is a readable database

```bash
for db in "$R"/projects/*/.n3rv/memory/*.sqlite3 "$R"/projects/*/.n3rv/memory/*.db; do
  [ -f "$db" ] || continue
  printf '%s: ' "$db"
  sqlite3 "$db" 'PRAGMA integrity_check;'
done
```

Every line must end in `ok`. A `database disk image is malformed` here means the
live writers and the copy disagreed: note which service was running and add it
to the quiesce step.

### 3.2 The memory content matches what the project had

```bash
cd "$R"/projects/radio      # a real project with its .n3rv in place
n3rv memory stats
```

Compare the counts with the live project (`cd ~/Repositories/radio && n3rv
memory stats`). Equal counts and a fresh newest entry = the memory survived.
Then search for something you know exists:

```bash
n3rv memory search "deploy hook" | head
```

### 3.3 The OpenCode database is consistent and complete

```bash
sqlite3 "$R/opencode/opencode.db" 'PRAGMA integrity_check;'
sqlite3 "$R/opencode/opencode.db" 'PRAGMA journal_mode;'
# Tables are singular in the current schema: there is no `sessions` table.
for t in session message part; do
  printf '%-8s restored=%-7s live=%s\n' "$t" \
    "$(sqlite3 "$R/opencode/opencode.db" "SELECT count(*) FROM \"$t\";")" \
    "$(sqlite3 ~/.local/share/opencode/opencode.db "SELECT count(*) FROM \"$t\";")"
done
sqlite3 "$R/opencode/opencode.db" \
  'SELECT s.id, count(m.id) FROM session s LEFT JOIN message m ON m.session_id=s.id
   GROUP BY s.id ORDER BY s.time_updated DESC LIMIT 3;'
```

`ok` for integrity and `wal` for the journal mode. The three counts should match
the live database exactly when nothing wrote during the backup — measured
2026-11-15: `session 173`, `message 14299`, `part 59238`, identical on both
sides. A count that is merely "the same order of magnitude" is weaker than it
sounds: it hides a backup that dropped the tail. The last query must show real
message counts for the newest sessions — a copy with sessions and no messages is
a schema without a life.

### 3.4 XERJ state is there, not just the index

```bash
ls -la "$R/xerj-data" | grep -E '\.xerj_(api_tokens|users|master_key|idp_config)'
```

Those files are the reason this directory is backed up. The index corpora can be
rebuilt; the auth state cannot.

### 3.5 File modes survived

```bash
stat -c '%a %n' "$R"/projects/radio/.n3rv/memory/chroma.sqlite3
stat -c '%a %n' "$S/mainframe-radio/.env" "$S/mainframe-radio/secrets/tokens.txt"
```

Expect `600` for anything secret. A restore that widens a secret's mode is a
security regression, not a cosmetic difference.

## 4. Prove the mainframe data is usable

The radio runtime data is restored **on the mainframe**, into a scratch
directory, and validated without starting or restarting anything.

```bash
# workstation -> mainframe, scratch only
rsync -a "$S/mainframe-radio/" mainframe:/tmp/radio-restore-mainframe/

ssh mainframe 'set -e
  cd /tmp/radio-restore-mainframe
  echo "--- modes"
  stat -c "%a %n" .env secrets/tokens.txt caddy/tokens.caddy
  echo "--- state.json parses"
  python3 -c "import json;d=json.load(open(\"data/indiegen/state.json\"));print(sorted(d))"
  echo "--- env keys only, never values"
  cut -d= -f1 .env | sort
  echo "--- the compose file accepts the restored env, starting nothing"
  cp ~/servers/radio/docker-compose.yml .
  docker compose --env-file .env -f docker-compose.yml config -q && echo compose-config-ok
'
```

Checks that prove correctness, in order of how badly they fail:

1. `.env` has every variable `docker-compose.yml` requires. `compose config -q`
   fails with `required variable ... is missing` when it does not. This is the
   only check that proves the restored `.env` is *complete*, not merely present.
2. `state.json` parses and contains the seed cursor. If the generator resumes
   from a missing or empty cursor it starts the library over: compare
   `INDIEGEN_SEED_BASE`/cursor fields with the live file.
3. `caddy/tokens.caddy` is non-empty and contains a matcher per listener token
   (`grep -c '@' caddy/tokens.caddy` vs `wc -l < secrets/tokens.txt`). Empty
   here means every listener is locked out on the next Caddy reload.
4. Modes are `600`. The compose file mounts these into containers; a widened
   mode is a leak.

Compare against the live tree when a value is in doubt:

```bash
ssh mainframe 'diff -r --exclude=runs --exclude="*.log" \
  /tmp/radio-restore-mainframe ~/servers/radio | head -40'
```

Expected differences: none in `secrets/`, `config/`, `caddy/tokens.caddy`, and
`.env`; `data/indiegen/` may differ because the live generator has advanced
since the snapshot. Any *other* difference is a backup bug.

## 5. Record the result

Append one row per drill. A drill that is not written down did not happen.

| Date | Snapshot | Restored by | Dry run | SQLite | OpenCode | XERJ | Mainframe env | Notes |
|---|---|---|---|---|---|---|---|---|
| not yet | — | — | — | — | — | — | — | Phase 1 shipped the tooling; first drill pending |

## Restore for real (not part of the drill)

Only after a drill has passed, and only when the data is actually gone.

1. **Stop the writers first.** The OpenCode service, `n3rv` and `xerj` hold the
   SQLite files open; restoring under them produces exactly the torn state the
   drill exists to catch.
2. Restore to a scratch directory, re-run section 3, then copy into place.
   Never restore directly over a live path: the failure mode is "half restored,
   nothing works, original gone".
3. On the mainframe, copying `secrets/` and `.env` does not affect the running
   containers — they read them at start. Changing them means a recreate, which
   **cuts the stream**. Schedule it.
4. `data/indiegen/state.json` is read by the next generator cycle. Restoring an
   old cursor moves the library backwards; that is a content decision, not a
   recovery decision.

## What a failed drill means

| Failing check | Likely cause | Fix |
|---|---|---|
| `integrity_check` not `ok` | live SQLite copied without the backup API, or a writer mid-write | keep the API path in `sqlite_snapshot`; add the service to the quiesce list |
| project missing from the snapshot | project created after the backup, or outside `PROJECTS_ROOT` | confirm the glob, run a backup, re-drill |
| `compose config` reports a missing variable | `.env` is not the file the compose file expects, or the exclude list is wrong | fix the mainframe include list, not the compose file |
| `.n3rv` present but `n3rv memory stats` empty | restored the directory but not its `memory/` subdirectory | check the staging copy: `memory/` must be in the snapshot listing |
| modes widened | restore run as a user that could not preserve ownership | restore as the owning user; `restic restore` preserves modes, tar staging must not run as root |
