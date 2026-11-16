#!/usr/bin/env bash
# backup.sh - encrypted, restic-compatible backup of the state that is not in
# git and not regenerable.
#
#   ./deploy/backup.sh plan                 # what would be saved, and to where
#   ./deploy/backup.sh backup               # stage, back up, verify, retain
#   ./deploy/backup.sh snapshots            # list snapshots
#   ./deploy/backup.sh restore-dry-run [ID] # list what a restore would put back
#   ./deploy/backup.sh check                # verify the repository only
#
# WHAT IS SAVED
#   1. each project's `.n3rv` memory (the durable engineering memory)
#   2. the OpenCode database (sessions, tool output index)
#   3. the mainframe radio runtime data: .env, secrets/, config/,
#      caddy/tokens.caddy, data/indiegen/ state - NOT the audio, which is
#      regenerated from seeds, and not the 1.8 GB of render history in runs/
#   4. the XERJ data directory (indexes and the auth/idp state next to them)
#
# WHAT IS NOT SAVED, ON PURPOSE
#   music-audio/, music/, data/host/, data/cam/: generated content, rebuilt by
#   indiegenerator and Mario. Docker images, build caches, .venv, node_modules,
#   logs: rebuildable. Backing those up would turn a 1 GB job into a 30 GB one
#   and hide the files that actually matter.
#
# SAFETY RULES
#   - The repository is never created here. A typo in RESTIC_REPOSITORY must
#     fail loudly, not silently start a new empty repo: that is how backups get
#     lost without anyone noticing.
#   - The script refuses to run if the password file is readable by anyone but
#     its owner, and never prints a secret.
#   - Nothing is written to the live tree; staging is a temp directory, removed
#     on success (kept on failure so the cause is visible).
#   - One run at a time, enforced with flock.
#
# Exit codes: 0 ok, 1 a check or the backup failed, 2 bad usage or config.

set -Eeuo pipefail
umask 077

MODE=backup
SNAPSHOT=latest

for arg in "$@"; do
  case "$arg" in
    backup | plan | snapshots | check) MODE=$arg ;;
    restore-dry-run) MODE=$arg ;;
    -h | --help) MODE=help ;;
    *)
      if [ "$MODE" = "restore-dry-run" ]; then
        SNAPSHOT=$arg
      else
        printf 'backup: unknown argument: %s\n' "$arg" >&2
        MODE=bad
      fi
      ;;
  esac
done

usage() {
  cat <<'USAGE'
usage: backup.sh [plan|backup|snapshots|check|restore-dry-run [SNAPSHOT]]

  plan                 print sources, staging layout and the exact restic call
  backup               stage, back up, verify the repository, apply retention
  snapshots            list snapshots in the repository
  check                verify the repository (metadata + a data subset)
  restore-dry-run [ID] list what a restore of ID (default: latest) would write

Configuration: ~/.config/radio-backup/backup.conf (or BACKUP_CONFIG).
Environment wins over the file. See deploy/backup.conf.example.
USAGE
}

die() {
  printf 'backup: %s\n' "$*" >&2
  exit 1
}

bad_usage() {
  printf 'backup: %s\n' "$*" >&2
  usage >&2
  exit 2
}

[ "$MODE" = "help" ] && { usage; exit 0; }
[ "$MODE" = "bad" ] && bad_usage "invalid arguments"

# ---------------------------------------------------------------- config

CONFIG_FILE=${BACKUP_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/radio-backup/backup.conf}

CONFIG_KEYS="RESTIC_REPOSITORY RESTIC_PASSWORD_FILE RESTIC_PASSWORD_COMMAND
PROJECTS_ROOT OPENCODE_DATA_DIR XERJ_DATA_DIR MAINFRAME_HOST
MAINFRAME_RADIO_DIR STAGE_DIR TAG VERIFY_SUBSET KEEP_DAILY KEEP_WEEKLY
KEEP_MONTHLY KEEP_YEARLY SSH_TIMEOUT KEEP_STAGE"
# The allowlist is written across lines for readability; the matcher below
# needs it as one space-separated string.
CONFIG_KEYS=${CONFIG_KEYS//$'\n'/ }
CONFIG_UNKNOWN_KEYS=""

# closest_key KEY
# The known key sharing the longest prefix with KEY, so a typo gets named,
# not just ignored (infra#9). A known key contained inside the unknown one
# (RESTIC_REPOSITORY inside MY_RESTIC_REPOSITORY) counts as a full match.
# Prints nothing when nothing is close enough to suggest.
closest_key() {
  local want=${1^^} key best="" bestlen=0 k n i
  for key in $CONFIG_KEYS; do
    k=${key^^}
    n=0
    case "$want" in
      *"$k"*) n=${#k} ;;
    esac
    if [ "$n" -eq 0 ]; then
      i=0
      while [ "$i" -lt "${#want}" ] && [ "$i" -lt "${#k}" ] &&
        [ "${want:i:1}" = "${k:i:1}" ]; do
        i=$((i + 1))
      done
      n=$i
    fi
    if [ "$n" -gt "$bestlen" ]; then
      bestlen=$n
      best=$key
    fi
  done
  [ "$bestlen" -ge 4 ] && printf '%s' "$best"
}

# read_config FILE
# Plain KEY=VALUE, parsed and never sourced: this file sits next to the
# repository password, and it must not be able to run code.
# Unknown keys do not fail the run, but they are collected and reported by
# name with the closest known key: an ignored key is a silently different
# backup (infra#9).
read_config() {
  local file=$1 line key value unknown suggestion
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in '' | '#'*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    key=${line%%=*}
    value=${line#*=}
    key=${key//[[:space:]]/}
    case " $CONFIG_KEYS " in
      *" $key "*) ;;
      *)
        if [ -n "$key" ]; then
          CONFIG_UNKNOWN_KEYS+="$key"$'\n'
        fi
        continue
        ;;
    esac
    case "$value" in
      \"*\") value=${value#\"}; value=${value%\"} ;;
      \'*\') value=${value#\'}; value=${value%\'} ;;
    esac
    [ -n "${!key:-}" ] && continue
    printf -v "$key" '%s' "$value"
  done < "$file"
  while IFS= read -r unknown; do
    [ -n "$unknown" ] || continue
    suggestion=$(closest_key "$unknown")
    if [ -n "$suggestion" ]; then
      warn "unknown key in backup.conf: $unknown (closest known: $suggestion)"
    else
      warn "unknown key in backup.conf: $unknown"
    fi
  done <<<"$CONFIG_UNKNOWN_KEYS"
  return 0
}

apply_defaults() {
  RESTIC_REPOSITORY=${RESTIC_REPOSITORY:-}
  RESTIC_PASSWORD_FILE=${RESTIC_PASSWORD_FILE:-}
  RESTIC_PASSWORD_COMMAND=${RESTIC_PASSWORD_COMMAND:-}
  PROJECTS_ROOT=${PROJECTS_ROOT:-$HOME/Repositories}
  OPENCODE_DATA_DIR=${OPENCODE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/opencode}
  XERJ_DATA_DIR=${XERJ_DATA_DIR:-$HOME/xerj-data}
  MAINFRAME_HOST=${MAINFRAME_HOST:-}
  MAINFRAME_RADIO_DIR=${MAINFRAME_RADIO_DIR:-}
  STAGE_DIR=${STAGE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/radio-backup/stage}
  TAG=${TAG:-radio-state}
  VERIFY_SUBSET=${VERIFY_SUBSET:-1/50}
  KEEP_DAILY=${KEEP_DAILY:-7}
  KEEP_WEEKLY=${KEEP_WEEKLY:-4}
  KEEP_MONTHLY=${KEEP_MONTHLY:-6}
  KEEP_YEARLY=${KEEP_YEARLY:-2}
  SSH_TIMEOUT=${SSH_TIMEOUT:-900}
  KEEP_STAGE=${KEEP_STAGE:-0}
}

# ---------------------------------------------------------------- plumbing

LOG=${BACKUP_LOG:-${XDG_STATE_HOME:-$HOME/.local/state}/radio-backup/backup.log}

log() {
  mkdir -p "$(dirname "$LOG")"
  printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$LOG"
}

# Warnings go to stderr and to the log: a typo that silently changed what the
# backup covers must survive the scroll (infra#9).
warn() {
  printf 'backup: warning: %s\n' "$*" >&2
  mkdir -p "$(dirname "$LOG")"
  printf '%s warning: %s\n' "$(date -u +%FT%TZ)" "$*" >>"$LOG"
}

have() { command -v "$1" >/dev/null 2>&1; }

need_restic() {
  have restic || die "restic is not installed"
  [ -n "$RESTIC_REPOSITORY" ] || die "RESTIC_REPOSITORY is not configured (see deploy/backup.conf.example)"
}

# RESTIC password: a file, a command, or nothing (fail). The file must not be
# readable by anyone else; a 0644 password file in a home directory is not a
# secret, it is a delay.
RESTIC=()
setup_restic() {
  need_restic
  RESTIC=(-r "$RESTIC_REPOSITORY")
  if [ -n "$RESTIC_PASSWORD_FILE" ]; then
    [ -f "$RESTIC_PASSWORD_FILE" ] || die "RESTIC_PASSWORD_FILE does not exist: $RESTIC_PASSWORD_FILE"
    local mode
    mode=$(stat -c '%a' "$RESTIC_PASSWORD_FILE" 2>/dev/null || echo unknown)
    case "$mode" in
      600 | 400) ;;
      *) die "RESTIC_PASSWORD_FILE mode is $mode; chmod 600 $RESTIC_PASSWORD_FILE" ;;
    esac
    RESTIC+=(--password-file "$RESTIC_PASSWORD_FILE")
  elif [ -n "$RESTIC_PASSWORD_COMMAND" ]; then
    RESTIC+=(--password-command "$RESTIC_PASSWORD_COMMAND")
  else
    die "no password source: set RESTIC_PASSWORD_FILE or RESTIC_PASSWORD_COMMAND"
  fi
}

restic_cmd() { restic "${RESTIC[@]}" "$@"; }

# The repository must already exist. `restic cat config` is the cheapest read
# that fails on an uninitialised or wrong repository.
assert_repository() {
  if ! restic_cmd cat config >/dev/null 2>&1; then
    die "cannot read the repository at $RESTIC_REPOSITORY; it must already exist and be initialised (restic init), see runbooks/backup.md"
  fi
}

# ---------------------------------------------------------------- staging

STAGE=""

cleanup() {
  local status=$?
  if [ -n "$STAGE" ] && [ -d "$STAGE" ]; then
    if [ "$status" -eq 0 ] && [ "$KEEP_STAGE" != "1" ]; then
      rm -rf "$STAGE"
    else
      printf 'backup: staging kept at %s for inspection\n' "$STAGE" >&2
    fi
  fi
  exit "$status"
}
trap cleanup EXIT

# The exclusion list is one place, so "what is regenerable" is a policy, not a
# detail scattered through the copy calls.
TAR_EXCLUDE=(--exclude=logs --exclude=__pycache__ --exclude='*.tmp' --exclude='*.log' --exclude='*.lock')

# copy_tree SRC DST MEMBER
# tar through a pipe, not rsync: tar is on both hosts and preserves mode and
# mtime, which is what a restore needs.
copy_tree() {
  local src=$1 dst=$2 member=$3
  mkdir -p "$dst"
  tar -cf - -C "$src" "${TAR_EXCLUDE[@]}" "$member" | tar -xf - -C "$dst" --no-same-owner
}

# sqlite_snapshot SRC DST
# A live SQLite file copied byte for byte is a torn file. The backup API copies
# a consistent image under WAL, and quick_check proves the copy is readable.
# On failure the reason is printed on stdout and the function returns 1; the
# caller collects every failure and reports them all once, so one run names
# every damaged file instead of dying on the first (infra#14).
sqlite_snapshot() {
  local src=$1 dst=$2 detail
  mkdir -p "$(dirname "$dst")"
  if detail=$(python3 - "$src" "$dst" 2>&1 <<'PY'
import sqlite3
import sys

src, dst = sys.argv[1], sys.argv[2]
with open(src, "rb") as handle:
    magic = handle.read(16)
if magic != b"SQLite format 3\x00":
    # Not a database, despite the extension: leave the staged copy alone.
    raise SystemExit(0)
try:
    source = sqlite3.connect(src, timeout=30)
    target = sqlite3.connect(dst)
    try:
        source.backup(target)
        row = target.execute("PRAGMA quick_check").fetchone()
    finally:
        target.close()
        source.close()
except sqlite3.Error as exc:
    sys.stderr.write("%s\n" % exc)
    raise SystemExit(1)
if not row or row[0] != "ok":
    sys.stderr.write("quick_check: %s\n" % row[0])
    raise SystemExit(1)
PY
); then
    return 0
  fi
  printf '%s' "$detail"
  return 1
}

# SQLITE_FAILURES holds one entry per damaged source: "<path><TAB><reason>".
SQLITE_FAILURES=()

# normalize_sqlite STAGE_ROOT SOURCE_ROOT
# Replace every staged SQLite copy with a consistent snapshot of the live file.
# Failures are collected in SQLITE_FAILURES; the caller reports the complete
# list once, after all staging has walked every source (infra#14).
normalize_sqlite() {
  local stage_root=$1 source_root=$2 file rel out
  while IFS= read -r -d '' file; do
    rel=${file#"$stage_root/"}
    [ -f "$source_root/$rel" ] || continue
    if ! out=$(sqlite_snapshot "$source_root/$rel" "$file" 2>&1); then
      SQLITE_FAILURES+=("$source_root/$rel"$'\t'"$out")
    fi
  done < <(find "$stage_root" -type f \( -name '*.db' -o -name '*.sqlite3' \) -print0)
}

STAGED_PROJECTS=0

stage_projects() {
  local dir name
  [ -d "$PROJECTS_ROOT" ] || return 0
  for dir in "$PROJECTS_ROOT"/*/.n3rv; do
    [ -d "$dir" ] || continue
    name=$(basename "$(dirname "$dir")")
    log "stage .n3rv: $name"
    copy_tree "$(dirname "$dir")" "$STAGE/workstation/projects/$name" ".n3rv"
    normalize_sqlite "$STAGE/workstation/projects/$name" "$(dirname "$dir")"
    STAGED_PROJECTS=$((STAGED_PROJECTS + 1))
  done
}

stage_opencode() {
  local db="$OPENCODE_DATA_DIR/opencode.db"
  [ -n "$OPENCODE_DATA_DIR" ] || return 0
  if [ ! -f "$db" ]; then
    die "OpenCode database not found: $db (unset OPENCODE_DATA_DIR to skip it)"
  fi
  log "stage opencode: $db"
  local out
  if ! out=$(sqlite_snapshot "$db" "$STAGE/workstation/opencode/opencode.db" 2>&1); then
    SQLITE_FAILURES+=("$db"$'\t'"$out")
  fi
}

stage_xerj() {
  [ -n "$XERJ_DATA_DIR" ] || return 0
  if [ ! -d "$XERJ_DATA_DIR" ]; then
    die "XERJ data directory not found: $XERJ_DATA_DIR (unset XERJ_DATA_DIR to skip it)"
  fi
  log "stage xerj: $XERJ_DATA_DIR"
  copy_tree "$XERJ_DATA_DIR" "$STAGE/workstation/xerj-data" "."
  normalize_sqlite "$STAGE/workstation/xerj-data" "$XERJ_DATA_DIR"
}

# The radio runtime data, in one SSH round trip. Config and state only: the
# audio is regenerated from seeds and runs/ is 1.8 GB of render history.
stage_mainframe() {
  [ -n "$MAINFRAME_HOST" ] || return 0
  [ -n "$MAINFRAME_RADIO_DIR" ] || die "MAINFRAME_RADIO_DIR is not configured"
  log "stage mainframe: $MAINFRAME_HOST:$MAINFRAME_RADIO_DIR"
  mkdir -p "$STAGE/mainframe-radio"
  timeout "$SSH_TIMEOUT" ssh -o BatchMode=yes -o ConnectTimeout=10 \
    "$MAINFRAME_HOST" \
    "cd '$MAINFRAME_RADIO_DIR' && tar -cf - --exclude='runs' --exclude='*.log' .env secrets config caddy/tokens.caddy data/indiegen" |
    tar -xf - -C "$STAGE/mainframe-radio" --no-same-owner
}

check_sources() {
  local dir
  if [ -d "$PROJECTS_ROOT" ]; then
    for dir in "$PROJECTS_ROOT"/*/.n3rv; do
      [ -d "$dir" ] && printf '  .n3rv       %s\n' "$dir"
    done
  else
    printf '  .n3rv       (no %s)\n' "$PROJECTS_ROOT"
  fi
  if [ -n "$OPENCODE_DATA_DIR" ]; then
    printf '  opencode    %s\n' "$OPENCODE_DATA_DIR/opencode.db"
  fi
  if [ -n "$XERJ_DATA_DIR" ]; then
    printf '  xerj        %s\n' "$XERJ_DATA_DIR"
  fi
  if [ -n "$MAINFRAME_HOST" ]; then
    printf '  mainframe   %s:%s {.env secrets config caddy/tokens.caddy data/indiegen}\n' \
      "$MAINFRAME_HOST" "$MAINFRAME_RADIO_DIR"
  fi
}

# ---------------------------------------------------------------- modes

mode_plan() {
  setup_restic
  printf 'repository   %s\n' "$RESTIC_REPOSITORY"
  if [ -n "$RESTIC_PASSWORD_FILE" ]; then
    printf 'password     %s (mode %s)\n' "$RESTIC_PASSWORD_FILE" "$(stat -c '%a' "$RESTIC_PASSWORD_FILE" 2>/dev/null || echo '?')"
  else
    printf 'password     from command: %s\n' "$RESTIC_PASSWORD_COMMAND"
  fi
  printf 'staging      %s\n' "$STAGE_DIR"
  printf 'sources:\n'
  check_sources

  if [ -n "$MAINFRAME_HOST" ]; then
    printf 'mainframe check: '
    if timeout 20 ssh -o BatchMode=yes -o ConnectTimeout=8 "$MAINFRAME_HOST" \
      "cd '$MAINFRAME_RADIO_DIR' 2>/dev/null && test -e .env && test -d secrets && test -f caddy/tokens.caddy && test -d data/indiegen && echo ok" \
      >/dev/null 2>&1; then
      printf 'reachable, required members present\n'
    else
      printf 'NOT reachable or missing a required member\n'
      return 1
    fi
  fi

  printf '\nrestic       restic -r %s backup %s --tag %s --host %s\n' \
    "$RESTIC_REPOSITORY" "$STAGE_DIR" "$TAG" "$(hostname -s)"
  printf 'verify       restic -r %s check --read-data-subset=%s\n' \
    "$RESTIC_REPOSITORY" "$VERIFY_SUBSET"
  printf 'retention    --keep-daily %s --keep-weekly %s --keep-monthly %s --keep-yearly %s --prune\n' \
    "$KEEP_DAILY" "$KEEP_WEEKLY" "$KEEP_MONTHLY" "$KEEP_YEARLY"
  printf '\nNo repository write happens in plan mode.\n'
}

mode_backup() {
  setup_restic
  assert_repository
  mkdir -p "$STAGE_DIR"
  exec 9>"$STAGE_DIR/.backup.lock"
  if ! flock -n 9; then
    die "another backup holds the lock at $STAGE_DIR/.backup.lock"
  fi

  STAGE="$STAGE_DIR/run-$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$STAGE"
  log "BEGIN backup to $RESTIC_REPOSITORY"

  # Announce what is about to be staged, the way plan does: a backup that
  # quietly skips a source looks like coverage and is not (infra#9).
  printf 'sources:\n'
  check_sources

  stage_projects
  stage_opencode
  stage_xerj
  stage_mainframe

  # The project memory is the primary source; a config typo that matches zero
  # projects must not pass as a successful backup of everything else (infra#9).
  if [ "$STAGED_PROJECTS" -eq 0 ]; then
    if [ ! -d "$PROJECTS_ROOT" ]; then
      die "PROJECTS_ROOT does not exist: $PROJECTS_ROOT; refusing to snapshot without the project memory (fix backup.conf)"
    fi
    die "PROJECTS_ROOT $PROJECTS_ROOT matched no project with a .n3rv directory; refusing to snapshot without the project memory (check backup.conf for a typo)"
  fi

  # One report, every damaged file (infra#14). Exit stays non-zero and the
  # staging tree stays behind for inspection.
  if [ "${#SQLITE_FAILURES[@]}" -gt 0 ]; then
    local entry path reason
    printf 'backup: sqlite quick_check failed for %d file(s):\n' \
      "${#SQLITE_FAILURES[@]}" >&2
    for entry in "${SQLITE_FAILURES[@]}"; do
      path=${entry%%$'\t'*}
      reason=${entry#*$'\t'}
      printf '  %s\n' "$path" >&2
      printf '%s\n' "$reason" | sed 's/^/    /' >&2
    done
    die 'repair: runbooks/backup.md, "When a SQLite source is malformed"'
  fi

  local files
  files=$(find "$STAGE" -type f | wc -l)
  log "staged $files file(s)"
  [ "$files" -gt 0 ] || die "staging produced no files; refusing to write an empty snapshot"

  restic_cmd backup "$STAGE" --tag "$TAG" --host "$(hostname -s)" --verbose
  log "verify: restic check --read-data-subset=$VERIFY_SUBSET"
  restic_cmd check --read-data-subset="$VERIFY_SUBSET"
  restic_cmd forget --tag "$TAG" \
    --keep-daily "$KEEP_DAILY" --keep-weekly "$KEEP_WEEKLY" \
    --keep-monthly "$KEEP_MONTHLY" --keep-yearly "$KEEP_YEARLY" --prune

  local summary
  summary=$(restic_cmd snapshots --latest 1 --tag "$TAG" --json | python3 -c '
import json, sys
try:
    snaps = json.load(sys.stdin)
except Exception:
    raise SystemExit
if not snaps:
    raise SystemExit
# --latest groups by host and paths, and every run stages into its own
# run-<timestamp> directory, so the reply can hold one snapshot per group.
# The newest is the one this run just wrote; picking snaps[0] named an older
# snapshot, which is the ID the drill is supposed to record.
s = max(snaps, key=lambda snap: snap.get("time", ""))
print("%s %s" % (s.get("short_id", "?"), s.get("time", "?")))
' 2>/dev/null) || summary=""
  log "END backup snapshot ${summary:-unknown} ($files files)"
  printf 'snapshot: %s\n' "${summary:-unknown}"
}

mode_snapshots() {
  setup_restic
  assert_repository
  restic_cmd snapshots --tag "$TAG"
}

mode_check() {
  setup_restic
  assert_repository
  log "verify: restic check --read-data-subset=$VERIFY_SUBSET"
  restic_cmd check --read-data-subset="$VERIFY_SUBSET"
}

# restore-dry-run reads the tree the way a restore would and lists every path,
# without writing anything. The mapping back to the live location is printed
# because the snapshot stores the staging path, not the original.
mode_restore_dry_run() {
  setup_restic
  assert_repository
  local scratch listing
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/radio-restore-check.XXXXXX")

  printf 'snapshot: %s\n\n' "$SNAPSHOT"
  # Only the staged tree is interesting. The lines above it are the parent
  # directories of the staging path, recreated by the restore for free.
  listing=$(restic_cmd ls -l "$SNAPSHOT" | grep -E '/(workstation|mainframe-radio)(/|$)' || true)
  if [ -z "$listing" ]; then
    die "snapshot $SNAPSHOT has no workstation/ or mainframe-radio/ entries; is it a snapshot of this job?"
  fi
  printf '%s\n' "$listing" | sed 's/^/  /'
  printf '\n  (parent directories of the staging path omitted)\n'

  printf '\nrestore would write %s entr(ies); dry run follows\n' "$(printf '%s\n' "$listing" | grep -c .)"
  restic_cmd restore "$SNAPSHOT" --target "$scratch" --dry-run -vv 2>&1 |
    grep -E '/(workstation|mainframe-radio)(/|$)|Summary|error' | sed 's/^/  restore: /'
  rm -rf "$scratch"

  printf '\nwhere the files go when you restore for real:\n'
  printf '  <snapshot>/workstation/projects/<project>/.n3rv  ->  %s/<project>/.n3rv\n' "$PROJECTS_ROOT"
  printf '  <snapshot>/workstation/opencode/opencode.db      ->  %s/opencode.db\n' "$OPENCODE_DATA_DIR"
  printf '  <snapshot>/workstation/xerj-data                 ->  %s\n' "$XERJ_DATA_DIR"
  printf '  <snapshot>/mainframe-radio                       ->  %s:%s\n' \
    "${MAINFRAME_HOST:-<mainframe>}" "${MAINFRAME_RADIO_DIR:-<radio dir>}"
  printf '\nThe exact steps, with the checks that prove the restore, are in\n'
  printf 'runbooks/restore-drill.md.\n'
}

# ---------------------------------------------------------------- main

read_config "$CONFIG_FILE" || true
apply_defaults
# A config file that disappears must be visible, not silently replaced by
# defaults: a default repository is not the repository you think you have.
if [ ! -f "$CONFIG_FILE" ] && [ -z "$RESTIC_REPOSITORY" ]; then
  printf 'backup: no config at %s and RESTIC_REPOSITORY is unset\n' "$CONFIG_FILE" >&2
  printf 'backup: copy deploy/backup.conf.example to %s and fill it in\n' "$CONFIG_FILE" >&2
  exit 2
fi

case "$MODE" in
  plan) mode_plan ;;
  backup) mode_backup ;;
  snapshots) mode_snapshots ;;
  check) mode_check ;;
  restore-dry-run) mode_restore_dry_run ;;
  *) bad_usage "unknown mode: $MODE" ;;
esac
