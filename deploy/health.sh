#!/usr/bin/env bash
# health.sh - one command that answers "is everything green?"
#
#   ./deploy/health.sh              # human table
#   ./deploy/health.sh --quiet      # exit code only
#
# It exists because the honest answer used to require five commands in four
# repositories plus an SSH session, and a system whose health takes five commands
# to read is a system nobody checks.
#
# Checks, in the order they matter:
#   1. CI on every repository (default branch, latest run)
#   2. the station itself, over SSH (radio-job status)
#   3. credentials: are they alive, and when do they expire
#   4. local checkouts: anything uncommitted that would deploy unexpectedly
#
# Exit codes: 0 everything green, 1 something is red (the table says what).
# A missing tool is reported as SKIP, never as green.

set -uo pipefail

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

ORG="The-Replacement"
REPOS="radio indiegenerator infra docs"
HOST="${RADIO_HOST:-kbdejavu@192.168.100.148}"
CRED_DIR="$HOME/.config/radio"
CF_ACCOUNT_ID="${CF_ACCOUNT_ID:-}"

red=0
rows=()

emit() { rows+=("$1"); }

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- CI

ci_check() {
  local repo="$1" branch out line
  branch="master"
  [ "$repo" = "infra" ] || [ "$repo" = "docs" ] && branch="main"
  if ! have gh; then
    emit "$(printf 'SKIP  %-16s gh not installed' "$repo")"
    return
  fi
  out=$(gh run list --repo "$ORG/$repo" --branch "$branch" --limit 1 \
        --json name,conclusion,status,headSha --jq '.[0] | "\(.name)|\(.conclusion // .status)|\(.headSha[0:7])"' 2>/dev/null)
  if [ -z "$out" ]; then
    emit "$(printf 'SKIP  %-16s no runs on %s' "$repo" "$branch")"
    return
  fi
  line="${out}"
  local name conc sha
  name=$(printf '%s' "$line" | cut -d'|' -f1)
  conc=$(printf '%s' "$line" | cut -d'|' -f2)
  sha=$(printf '%s' "$line" | cut -d'|' -f3)
  if [ "$conc" = "success" ]; then
    emit "$(printf 'OK    %-16s %s %s' "$repo" "$name" "$sha")"
  else
    emit "$(printf 'RED   %-16s %s %s (%s)' "$repo" "$name" "$sha" "$conc")"
    red=1
  fi
}

# ---------------------------------------------------------------- station

station_check() {
  local out
  if ! have ssh; then
    emit "$(printf 'SKIP  %-16s ssh not installed' "mainframe")"
    return
  fi
  out=$(timeout 25 ssh -o BatchMode=yes -o ConnectTimeout=8 "$HOST" \
        'cd ~/servers/radio && ./scripts/radio-job.sh status' 2>/dev/null)
  if [ -z "$out" ]; then
    emit "$(printf 'RED   %-16s unreachable over SSH' "mainframe")"
    red=1
    return
  fi
  local bad hard
  bad=$(printf '%s\n' "$out" | grep -c 'FAIL')
  # A missing camera is a documented state, not a station failure: the compose
  # file refuses to start cam without its device. Everything else is a failure.
  hard=$(printf '%s\n' "$out" | grep 'FAIL' | grep -vc 'camera')
  if [ "$bad" -eq 0 ]; then
    emit "$(printf 'OK    %-16s %s' "mainframe" "$(printf '%s\n' "$out" | sed -n '2p' | sed 's/^ *//')")"
  elif [ "${hard:-0}" -eq 0 ]; then
    emit "$(printf 'WARN  %-16s camera absent (device unplugged)' "mainframe")"
  else
    emit "$(printf 'RED   %-16s %s failing check(s)' "mainframe" "$hard")"
    red=1
  fi
  # The station's own verdict, line by line, minus the header.
  if [ "$QUIET" -eq 0 ]; then
    printf '%s\n' "$out" | tail -n +2 | sed 's/^/           /'
  fi
}

# ---------------------------------------------------------------- credentials

cred_check() {
  local file name token status
  if [ ! -d "$CRED_DIR" ]; then
    emit "$(printf 'SKIP  %-16s no %s' "credentials" "$CRED_DIR")"
    return
  fi
  for file in "$CRED_DIR"/*; do
    [ -f "$file" ] || continue
    name=$(basename "$file")
    case "$name" in cf-*) ;; *) continue ;; esac
    token=$(cat "$file" 2>/dev/null)
    if [ -z "$token" ]; then
      emit "$(printf 'RED   %-16s %s is empty' "credential" "$name")"; red=1; continue
    fi
    status=$(curl -s -m 10 -H "Authorization: Bearer $token" \
             https://api.cloudflare.com/client/v4/user/tokens/verify \
             | sed -n 's/.*"status":"\([a-z]*\)".*/\1/p' | head -1)
    if [ "${status:-}" = "active" ]; then
      emit "$(printf 'OK    %-16s %s active' "credential" "$name")"
      continue
    fi
    # Account-owned tokens are not user tokens; verify them against a read their
    # own policy allows.
    local code
    code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $token" \
           "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID:-9dea0021c0549c015e968eaf98cc9f9c}/pages/projects")
    if [ "$code" = "200" ]; then
      emit "$(printf 'OK    %-16s %s active (account-scoped)' "credential" "$name")"
    else
      emit "$(printf 'RED   %-16s %s rejected (HTTP %s)' "credential" "$name" "$code")"
      red=1
    fi
  done
}

# ---------------------------------------------------------------- checkouts

checkout_check() {
  local dir name
  for dir in "$HOME/Repositories/radio" "$HOME/Repositories/indiegenerator" "$HOME/Repositories/n3rv"; do
    [ -d "$dir/.git" ] || continue
    name=$(basename "$dir")
    local dirty ahead
    dirty=$(git -C "$dir" status --porcelain 2>/dev/null | grep -vc '^??' || true)
    ahead=$(git -C "$dir" rev-list --count '@{u}..HEAD' 2>/dev/null || echo "?")
    if [ "${dirty:-0}" -gt 0 ]; then
      emit "$(printf 'WARN  %-16s %s modified file(s) uncommitted' "checkout" "$name")"
    elif [ "$ahead" != "0" ] && [ "$ahead" != "?" ]; then
      emit "$(printf 'WARN  %-16s %s commit(s) not pushed' "checkout" "$name")"
    else
      emit "$(printf 'OK    %-16s %s clean' "checkout" "$name")"
    fi
  done
}

# ---------------------------------------------------------------- main

for r in $REPOS; do ci_check "$r"; done
station_check
cred_check
checkout_check

if [ "$QUIET" -eq 0 ]; then
  printf '\nradio health  %s\n\n' "$(date -u +%FT%TZ)"
  for row in "${rows[@]}"; do printf '  %s\n' "$row"; done
  printf '\n'
fi

if [ "$red" -ne 0 ]; then
  [ "$QUIET" -eq 0 ] && printf 'verdict: RED\n'
  exit 1
fi
[ "$QUIET" -eq 0 ] && printf 'verdict: green\n'
exit 0
