#!/usr/bin/env bash
# Offline tests for deploy/backup.sh (infra#9, infra#14).
#
# No restic, no network, no real state: a stub restic on PATH answers the
# calls backup.sh makes, and every source lives in a throwaway tree. Covers:
#   - unknown config keys warn by name with the closest known key
#   - KEEP_STAGE is settable from the config file
#   - backup prints the effective source list before staging
#   - PROJECTS_ROOT missing or matching zero projects exits non-zero
#   - every malformed SQLite file is reported in one run, not one per run
#   - an empty MAINFRAME_HOST still skips the mainframe silently
#   - plan mode keeps working offline
#
# Run: ./deploy/tests/test-backup.sh
# Exit: 0 all green, 1 something failed.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BACKUP_SH=$SCRIPT_DIR/../backup.sh

PASS=0
FAIL=0
CURRENT=""

say() { printf '%s\n' "$*"; }

test_start() {
  CURRENT=$1
  T=$(mktemp -d "${TMPDIR:-/tmp}/backup-test.XXXXXX")
  mkdir -p "$T/bin"
  cat >"$T/bin/restic" <<'STUB'
#!/usr/bin/env bash
# Minimal restic stub: every call backup.sh makes, answered with success.
# restic takes -r/--password options (some with separate values) before the
# verb, so dispatch on the known verb wherever it appears.
cmd=""
for arg in "$@"; do
  case "$arg" in
    cat | backup | check | forget | snapshots) cmd=$arg && break ;;
  esac
done
case "$cmd" in
  cat) exit 0 ;;
  backup) exit 0 ;;
  check) exit 0 ;;
  forget) exit 0 ;;
  snapshots)
    echo '[{"short_id":"deadbee","time":"2026-01-01T00:00:00Z"}]'
    exit 0
    ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$T/bin/restic"
  PATH="$T/bin:$PATH"
  export PATH
}

test_end() {
  local status=$1
  if [ "$status" -eq 0 ]; then
    PASS=$((PASS + 1))
    say "PASS $CURRENT"
  else
    FAIL=$((FAIL + 1))
    say "FAIL $CURRENT"
  fi
  rm -rf "$T"
}

# run_backup EXTRA_CONF_LINES
run_backup() {
  local extra=$1
  make_conf "$extra"
  BACKUP_CONFIG=$T/conf BACKUP_LOG=$T/backup.log \
    "$BACKUP_SH" backup >"$T/out.stdout" 2>"$T/out.stderr"
}

# make_conf EXTRA
# A working baseline config; EXTRA lines come FIRST, because the config
# parser is first-occurrence-wins (environment still wins over both).
make_conf() {
  {
    printf '%s\n' "$1"
    cat <<EOF
RESTIC_REPOSITORY=$T/restic-repo
RESTIC_PASSWORD_FILE=$T/pw
PROJECTS_ROOT=$T/repos
OPENCODE_DATA_DIR=$T/opencode
XERJ_DATA_DIR=$T/xerj
STAGE_DIR=$T/state/stage
EOF
  } >"$T/conf"
  touch "$T/pw"
  chmod 600 "$T/pw"
}

# Real (readable) SQLite databases.
make_good_db() {
  python3 - "$1" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute("CREATE TABLE IF NOT EXISTS t (v TEXT)")
db.commit()
db.close()
PY
}

# SQLite magic followed by garbage: the backup API raises on the first read,
# so the snapshot fails and the reason is the driver's message.
make_corrupt_db() {
  python3 - "$1" <<'PY'
import sys
with open(sys.argv[1], "wb") as handle:
    handle.write(b"SQLite format 3\x00" + b"\xde\xad\xbe\xef" * 64)
PY
}

expect_grep() {
  grep -q "$2" "$1" && return 0
  say "  assertion failed: $3 ($2 not found in $1)"
  sed 's/^/  | /' "$1"
  exit 1
}

expect_absent() {
  grep -q "$2" "$1" || return 0
  say "  assertion failed: $3 ($2 must not appear in $1)"
  sed 's/^/  | /' "$1"
  exit 1
}

fixture() {
  mkdir -p "$T/repos/alpha/.n3rv/memory" "$T/repos/beta/.n3rv/memory" \
    "$T/opencode" "$T/xerj/indexes"
  printf 'alpha memory\n' >"$T/repos/alpha/.n3rv/notes.txt"
  make_good_db "$T/repos/beta/.n3rv/memory/chroma.sqlite3"
  make_good_db "$T/opencode/opencode.db"
  printf 'xerj\n' >"$T/xerj/indexes/data.bin"
}

# --- 1. all sources good: exit 0, sources printed, staging removed ----------
test_start "all-good backup prints sources and succeeds"
fixture
run_backup "" && status=0 || status=$?
(
  set -e
  expect_grep "$T/out.stdout" '^sources:$' "source list header"
  expect_grep "$T/out.stdout" 'repos/alpha/.n3rv' "projects listed"
  expect_grep "$T/out.stdout" 'snapshot: deadbee' "snapshot line"
  [ -s "$T/out.stderr" ] && {
    say "  stderr must be empty on a clean run:"
    sed 's/^/  | /' "$T/out.stderr"
    exit 1
  }
  # The lock file lives in STAGE_DIR; only run-* trees must be gone.
  if compgen -G "$T/state/stage/run-*" >/dev/null; then
    say "  staging run tree should be removed"
    ls -A "$T/state/stage" | sed 's/^/  | /'
    exit 1
  fi
) && status=0 || status=$?
test_end "$status"

# --- 2. unknown keys warn by name with the closest known key ----------------
test_start "unknown keys warn with a suggestion and the run still succeeds"
fixture
run_backup 'OPENCODE_DB=$T/opencode
PROJECT_ROOT=$T/repos' && status=0 || status=$?
(
  set -e
  expect_grep "$T/out.stderr" \
    'unknown key in backup.conf: OPENCODE_DB (closest known: OPENCODE_DATA_DIR)' \
    "OPENCODE_DB suggestion"
  expect_grep "$T/out.stderr" \
    'unknown key in backup.conf: PROJECT_ROOT (closest known: PROJECTS_ROOT)' \
    "PROJECT_ROOT suggestion"
  expect_grep "$T/backup.log" 'unknown key in backup.conf' "warning is logged"
  expect_grep "$T/out.stdout" 'snapshot: deadbee' "run still succeeds"
) && status=0 || status=$?
test_end "$status"

# --- 3. KEEP_STAGE from the config file -------------------------------------
test_start "KEEP_STAGE=1 in backup.conf keeps the staging tree"
fixture
run_backup 'KEEP_STAGE=1' && status=0 || status=$?
(
  set -e
  expect_grep "$T/out.stdout" 'snapshot: deadbee' "run succeeds"
  expect_grep "$T/out.stderr" 'staging kept at' "staging kept message"
  found=""
  for dir in "$T/state/stage"/run-*; do
    [ -d "$dir" ] && found=$dir
  done
  [ -n "$found" ] || {
    say "  no run-* staging tree kept"
    exit 1
  }
) && status=0 || status=$?
test_end "$status"

# --- 4. PROJECTS_ROOT matches zero projects ---------------------------------
test_start "empty PROJECTS_ROOT exits non-zero without a snapshot"
fixture
mkdir -p "$T/emptyroot"
run_backup "PROJECTS_ROOT=$T/emptyroot" && status=1 || status=$?
(
  set -e
  expect_grep "$T/out.stderr" 'matched no project with a .n3rv directory' \
    "zero-match message"
  expect_absent "$T/out.stdout" 'snapshot:' "no snapshot line"
) && status=0 || status=$?
test_end "$status"

# --- 5. missing PROJECTS_ROOT -----------------------------------------------
test_start "missing PROJECTS_ROOT exits non-zero"
fixture
run_backup "PROJECTS_ROOT=$T/nonexistent" && status=1 || status=$?
(
  set -e
  expect_grep "$T/out.stderr" 'PROJECTS_ROOT does not exist' "missing-dir message"
) && status=0 || status=$?
test_end "$status"

# --- 6. every malformed SQLite file reported in one run ---------------------
test_start "two corrupt SQLite files are reported together, with repair pointer"
fixture
make_corrupt_db "$T/repos/alpha/.n3rv/memory/chroma.sqlite3"
make_corrupt_db "$T/xerj/indexes/broken.sqlite3"
run_backup "" && status=1 || status=$?
(
  set -e
  expect_grep "$T/out.stderr" 'sqlite quick_check failed for 2 file' "both counted"
  expect_grep "$T/out.stderr" "$T/repos/alpha/.n3rv/memory/chroma.sqlite3" \
    "project file named"
  expect_grep "$T/out.stderr" "$T/xerj/indexes/broken.sqlite3" "xerj file named"
  expect_grep "$T/out.stderr" 'not a database' "driver reason present"
  expect_grep "$T/out.stderr" 'runbooks/backup.md' "repair pointer"
  expect_absent "$T/out.stdout" 'snapshot:' "no snapshot written"
  expect_grep "$T/out.stderr" 'staging kept at' "staging kept for inspection"
) && status=0 || status=$?
test_end "$status"

# --- 7. empty MAINFRAME_HOST still skips the mainframe silently -------------
test_start "empty MAINFRAME_HOST skips silently"
fixture
run_backup 'MAINFRAME_HOST=' && status=0 || status=$?
(
  set -e
  expect_grep "$T/out.stdout" 'snapshot: deadbee' "run succeeds"
  expect_absent "$T/out.stderr" 'unknown key' "no warning for the empty value"
  expect_absent "$T/out.stdout" 'mainframe' "mainframe absent from sources"
) && status=0 || status=$?
test_end "$status"

# --- 8. plan still works offline --------------------------------------------
test_start "plan mode lists sources and exits 0"
fixture
make_conf ""
BACKUP_CONFIG=$T/conf BACKUP_LOG=$T/backup.log \
  "$BACKUP_SH" plan >"$T/out.stdout" 2>"$T/out.stderr" &&
  status=0 || status=$?
(
  set -e
  expect_grep "$T/out.stdout" 'repos/alpha/.n3rv' "sources listed"
  expect_grep "$T/out.stdout" 'No repository write happens in plan mode.' \
    "plan footer"
) && status=0 || status=$?
test_end "$status"

say ""
say "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
