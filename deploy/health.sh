#!/usr/bin/env bash
# health.sh - one command that answers "is the stack green?"
#
#   ./deploy/health.sh              # human table
#   ./deploy/health.sh --quiet      # exit code only
#   ./deploy/health.sh --self-test  # offline parser checks, no network
#
# WHAT IT MODELS
# The workstation is the control plane: the OpenCode service, the N3RV hub, the
# MCP servers, the SearxNG loopback forward, XERJ, git checkouts, CI.
# The mainframe is the data plane: the radio containers, the Liquidsoap/Icecast
# stream, the token door, the deployed source SHA, the host's own status probe.
#
# WHY IT WAS REWRITTEN
# The previous version checked the retired topology: a local Jellyfin and a
# local Jellyfin container (Jellyfin runs on the mainframe), an EPG timer that
# no longer exists, SearxNG on the workstation (the listener is on the mainframe
# behind a loopback SSH forward), and it parsed the V1 `opencode mcp list` text
# format, which V2 changed. It reported false failures while the real MCPs were
# connected, and it never looked at the mainframe beyond one SSH command.
#
# RULES THIS SCRIPT FOLLOWS
#   - No internal address is hardcoded. Hosts, ports and paths come from the
#     environment or from ~/.config/radio-health/health.conf (template:
#     deploy/health.conf.example). A check with no configured target is SKIP,
#     never RED: not knowing an address is not the same as a component being
#     down.
#   - A component that lives on the other host is checked through the path that
#     actually serves it (SSH, or the loopback forward), and reported as that
#     component. Nothing is marked down because it is not local.
#   - A missing tool or an unreadable endpoint is SKIP or WARN, never green.
#     RED means a component is down, full, or misconfigured.
#
# Exit codes: 0 nothing is RED, 1 something is RED, 2 bad usage.
# Read the table, not only the exit code: WARN is a real signal.

set -uo pipefail

QUIET=0
SELF_TEST=0

usage() {
  cat <<'USAGE'
usage: health.sh [--quiet] [--self-test]

  --quiet      print nothing on success; the exit code is the answer
  --self-test  run the parsers against embedded fixtures, touch no network

Configuration: ~/.config/radio-health/health.conf (or HEALTH_CONFIG).
Environment wins over the file. See deploy/health.conf.example.
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --quiet) QUIET=1 ;;
    --self-test) SELF_TEST=1 ;;
    -h | --help) usage; exit 0 ;;
    *)
      printf 'health: unknown argument: %s\n' "$arg" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# ---------------------------------------------------------------- config

CONFIG_FILE=${HEALTH_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/radio-health/health.conf}

# Every key the config file may set. Anything else is ignored, so a typo is
# inert instead of dangerous (and the file cannot reassign PATH).
CONFIG_KEYS="MAINFRAME_HOST MAINFRAME_RADIO_DIR MAINFRAME_CONTAINERS
MAINFRAME_OPTIONAL_CONTAINERS MAINFRAME_EXTRA_CONTAINERS STATUS_MAX_AGE_S
MAINFRAME_TEMP_MAX_C RADIO_EXPECTED_SHA PROJECTS_ROOT CHECKOUT_DIRS
CHECK_CHECKOUTS CHECK_CI ORG REPOS OPENCODE_STATE_DIR OPENCODE_SERVICE_URL
MCP_WORKDIR REQUIRED_MCP MCP_TIMEOUT N3RV_A2A_CONFIG N3RV_HUB_ADDR XERJ_URL
SEARXNG_URL CRED_DIR CF_ACCOUNT_ID CRED_EXPIRY_WARN_DAYS SSH_TIMEOUT
HTTP_TIMEOUT"
# The allowlist is written across lines for readability; the matcher below
# needs it as one space-separated string.
CONFIG_KEYS=${CONFIG_KEYS//$'\n'/ }

# read_config FILE
# Plain KEY=VALUE, not shell: the file is parsed, never sourced. A health check
# must not be able to execute what it reads. A key already set in the
# environment wins over the file.
read_config() {
  local file=$1 line key value
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
      *) continue ;;
    esac
    case "$value" in
      \"*\") value=${value#\"}; value=${value%\"} ;;
      \'*\') value=${value#\'}; value=${value%\'} ;;
    esac
    [ -n "${!key:-}" ] && continue
    printf -v "$key" '%s' "$value"
  done < "$file"
  return 0
}

# Defaults. Addresses are deliberately absent: an unset target is SKIP.
apply_defaults() {
  # Empty means "not configured", which is SKIP, not RED.
  MAINFRAME_HOST=${MAINFRAME_HOST:-}
  MAINFRAME_RADIO_DIR=${MAINFRAME_RADIO_DIR:-}
  RADIO_EXPECTED_SHA=${RADIO_EXPECTED_SHA:-}
  OPENCODE_SERVICE_URL=${OPENCODE_SERVICE_URL:-}
  N3RV_HUB_ADDR=${N3RV_HUB_ADDR:-}
  CF_ACCOUNT_ID=${CF_ACCOUNT_ID:-}
  MAINFRAME_CONTAINERS=${MAINFRAME_CONTAINERS:-"radio-icecast radio-liquidsoap radio-mediamtx radio-caddy radio-indiegen"}
  MAINFRAME_OPTIONAL_CONTAINERS=${MAINFRAME_OPTIONAL_CONTAINERS:-"radio-cam"}
  # Jellyfin is a separate stack on the same host. It belongs to the mainframe
  # data plane and is checked there; empty this list when it is decommissioned.
  MAINFRAME_EXTRA_CONTAINERS=${MAINFRAME_EXTRA_CONTAINERS:-"jellyfin"}
  STATUS_MAX_AGE_S=${STATUS_MAX_AGE_S:-900}
  MAINFRAME_TEMP_MAX_C=${MAINFRAME_TEMP_MAX_C:-92}
  PROJECTS_ROOT=${PROJECTS_ROOT:-$HOME/Repositories}
  CHECKOUT_DIRS=${CHECKOUT_DIRS:-"radio indiegenerator n3rv"}
  CHECK_CHECKOUTS=${CHECK_CHECKOUTS:-1}
  CHECK_CI=${CHECK_CI:-1}
  ORG=${ORG:-The-Replacement}
  REPOS=${REPOS:-"radio indiegenerator infra docs"}
  OPENCODE_STATE_DIR=${OPENCODE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/opencode}
  MCP_WORKDIR=${MCP_WORKDIR:-$PROJECTS_ROOT/radio}
  # The MCP servers whose absence breaks the workflow. Cloudflare's remote
  # servers are deliberately not here: they need OAuth, and "needs
  # authentication" on an optional server is not a station failure.
  REQUIRED_MCP=${REQUIRED_MCP:-"n3rv-memory n3rv-hub n3rv-exec github fetch context7 codebase-memory-mcp searxng xerj open-websearch"}
  MCP_TIMEOUT=${MCP_TIMEOUT:-120}
  N3RV_A2A_CONFIG=${N3RV_A2A_CONFIG:-$PROJECTS_ROOT/n3rv/.n3rv/a2a-config.yaml}
  XERJ_URL=${XERJ_URL:-http://127.0.0.1:9200}
  SEARXNG_URL=${SEARXNG_URL:-http://127.0.0.1:8080}
  CRED_DIR=${CRED_DIR:-$HOME/.config/radio}
  CRED_EXPIRY_WARN_DAYS=${CRED_EXPIRY_WARN_DAYS:-30}
  SSH_TIMEOUT=${SSH_TIMEOUT:-20}
  HTTP_TIMEOUT=${HTTP_TIMEOUT:-8}
}

# ---------------------------------------------------------------- rows

red=0
rows=()

emit() { rows+=("$1"); }
row_ok() { emit "$(printf 'OK    %-22s %s' "$1" "$2")"; }
row_warn() { emit "$(printf 'WARN  %-22s %s' "$1" "$2")"; }
row_skip() { emit "$(printf 'SKIP  %-22s %s' "$1" "$2")"; }
row_red() {
  red=1
  emit "$(printf 'RED   %-22s %s' "$1" "$2")"
}

have() { command -v "$1" >/dev/null 2>&1; }

# http_code URL -> status code, or 000 when nothing answered.
http_code() {
  curl -s -o /dev/null -m "$HTTP_TIMEOUT" -w '%{http_code}' "$1" 2>/dev/null || true
}

# ---------------------------------------------------------------- CI

ci_check() {
  local repo=$1 branch=$2 out name conc sha

  if ! have gh; then
    row_skip "ci/$repo" "gh not installed"
    return
  fi
  # Several workflows publish runs for the same commit (ci, pages). Report the
  # gate, not whichever finished last.
  out=$(gh run list --repo "$ORG/$repo" --branch "$branch" --limit 10 \
    --json name,conclusion,status,headSha \
    --jq 'map(select(.name == "ci" or .name == "gate")) | .[0] | "\(.name)|\(.conclusion // .status)|\(.headSha[0:7])"' 2>/dev/null) || true
  out=$(printf '%s' "$out" | tr -d '"')
  if [ -z "$out" ]; then
    row_skip "ci/$repo" "no runs on $branch"
    return
  fi
  name=$(printf '%s' "$out" | cut -d'|' -f1)
  conc=$(printf '%s' "$out" | cut -d'|' -f2)
  sha=$(printf '%s' "$out" | cut -d'|' -f3)
  if [ "$conc" = "success" ]; then
    row_ok "ci/$repo" "$name $sha"
  else
    row_red "ci/$repo" "$name $sha ($conc)"
  fi
}

# ---------------------------------------------------------------- opencode

# The service writes its own address and pid to service.json. Reading it is the
# only honest way to find a port that is chosen at start. No record means the
# user runs a standalone session: SKIP, not RED.
opencode_service_check() {
  local state="$OPENCODE_STATE_DIR/service.json"
  local parsed="" pid="" url code

  url="$OPENCODE_SERVICE_URL"
  if [ -z "$url" ] && [ -f "$state" ] && have python3; then
    parsed=$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print("%s|%s" % (d.get("pid", ""), d.get("url", "")))
' "$state" 2>/dev/null) || parsed=""
    if [ -n "$parsed" ]; then
      pid=${parsed%%|*}
      url=${parsed#*|}
    fi
  fi

  if [ -z "$url" ]; then
    row_skip "opencode service" "no service record in $state"
    return
  fi
  if [ -n "$pid" ] && [ "$pid" -eq "$pid" ] 2>/dev/null && ! kill -0 "$pid" 2>/dev/null; then
    row_red "opencode service" "stale record: pid $pid is gone"
    return
  fi
  code=$(http_code "$url/health")
  case "$code" in
    2??) row_ok "opencode service" "$url/health $code" ;;
    000 | '') row_red "opencode service" "no answer on $url/health" ;;
    *) row_red "opencode service" "$url/health HTTP $code" ;;
  esac
}

# parse_mcp_list REQUIRED  (reads `opencode mcp list` output on stdin)
# V2 prints one server per line: "<glyph> <name> <status>", where status is
# "connected", "needs authentication", "failed" or similar. Only required
# servers are judged; the rest are ignorable by design.
parse_mcp_list() {
  local required=" $1 " line name status total=0 bad="" missing="" verdict
  local -A state=()

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # shellcheck disable=SC2034  # the glyph is the least reliable field; ignore it
    read -r glyph name status <<<"$line"
    [ -n "${name:-}" ] || continue
    total=$((total + 1))
    state["$name"]=${status:-unknown}
  done

  if [ "$total" -eq 0 ]; then
    row_warn "mcp" "no server lines in opencode mcp list output"
    return
  fi

  local n
  for n in $required; do # shellcheck disable=SC2086  # a configured list is split on purpose
    status=${state[$n]:-}
    if [ -z "$status" ]; then
      missing+=" $n"
    elif [ "$status" != "connected" ]; then
      bad+=" $n($status)"
    fi
  done

  if [ -n "$missing" ] || [ -n "$bad" ]; then
    verdict=$bad
    [ -n "$missing" ] && verdict="$verdict not-configured:$missing"
    row_red "mcp" "required:$verdict"
  else
    row_ok "mcp" "required servers connected ($total configured)"
  fi
}

mcp_check() {
  local out
  if ! have opencode; then
    row_skip "mcp" "opencode not installed"
    return
  fi
  if [ ! -d "$MCP_WORKDIR" ]; then
    row_skip "mcp" "no checkout at $MCP_WORKDIR"
    return
  fi
  if ! out=$(cd "$MCP_WORKDIR" && timeout "$MCP_TIMEOUT" opencode mcp list 2>&1); then
    row_red "mcp" "opencode mcp list failed: $(printf '%s' "$out" | head -1)"
    return
  fi
  if [ -z "$out" ] || printf '%s' "$out" | grep -qi '^no mcp servers'; then
    row_warn "mcp" "no MCP configuration visible from $MCP_WORKDIR"
    return
  fi
  parse_mcp_list "$REQUIRED_MCP" <<<"$out"
}

# ---------------------------------------------------------------- local services

# The N3RV hub address lives in the project's a2a-config.yaml. Reading it here
# means moving the hub is a config change, not a code change.
n3rv_hub_check() {
  local addr="$N3RV_HUB_ADDR" host="" port="" code

  if [ -z "$addr" ] && [ -f "$N3RV_A2A_CONFIG" ]; then
    host=$(awk -F: '/^[[:space:]]*host:/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$N3RV_A2A_CONFIG")
    port=$(awk -F: '/^[[:space:]]*port:/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$N3RV_A2A_CONFIG")
    if [ -n "$host" ] && [ -n "$port" ]; then
      addr="$host:$port"
    fi
  fi
  if [ -z "$addr" ]; then
    row_skip "n3rv hub" "no address in $N3RV_A2A_CONFIG"
    return
  fi

  if have curl; then
    code=$(http_code "http://$addr/")
    if [ "$code" = "000" ] || [ -z "$code" ]; then
      row_red "n3rv hub" "no HTTP answer on $addr"
    else
      row_ok "n3rv hub" "$addr (HTTP $code)"
    fi
    return
  fi
  host=${addr%:*}
  port=${addr##*:}
  if timeout 5 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null; then
    row_ok "n3rv hub" "$addr accepts TCP"
  else
    row_red "n3rv hub" "nothing listening on $addr"
  fi
}

# A service that lives on the mainframe and is reached through a loopback
# forward is healthy when the forward answers. Checking the mainframe's own
# listener from here would test a path that never carries traffic.
http_service_check() {
  local label=$1 url=$2 code
  if [ -z "$url" ]; then
    row_skip "$label" "not configured"
    return
  fi
  code=$(http_code "$url/")
  case "$code" in
    2?? | 3??) row_ok "$label" "$url" ;;
    000 | '') row_red "$label" "no answer on $url" ;;
    *) row_red "$label" "$url HTTP $code" ;;
  esac
}

# ---------------------------------------------------------------- checkouts

checkout_check() {
  local name dir dirty ahead
  for name in $CHECKOUT_DIRS; do # shellcheck disable=SC2086  # list on purpose
    dir="$PROJECTS_ROOT/$name"
    if [ ! -d "$dir/.git" ]; then
      row_skip "checkout/$name" "no git checkout at $dir"
      continue
    fi
    dirty=$(git -C "$dir" status --porcelain 2>/dev/null | grep -vc '^??' || true)
    ahead=$(git -C "$dir" rev-list --count '@{u}..HEAD' 2>/dev/null || echo "?")
    if [ "${dirty:-0}" -gt 0 ]; then
      row_warn "checkout/$name" "$dirty modified file(s) uncommitted"
    elif [ "$ahead" != "0" ] && [ "$ahead" != "?" ]; then
      row_warn "checkout/$name" "$ahead commit(s) not pushed"
    else
      row_ok "checkout/$name" "clean"
    fi
  done
}

# ---------------------------------------------------------------- credentials

cred_check() {
  local file name token body status code expires days

  if [ ! -d "$CRED_DIR" ]; then
    row_skip "credentials" "no $CRED_DIR"
    return
  fi
  for file in "$CRED_DIR"/*; do
    [ -f "$file" ] || continue
    name=$(basename "$file")
    case "$name" in cf-*) ;; *) continue ;; esac
    token=$(cat "$file" 2>/dev/null || true)
    if [ -z "$token" ]; then
      row_red "credential/$name" "empty file"
      continue
    fi
    body=$(curl -s -m "$HTTP_TIMEOUT" -H "Authorization: Bearer $token" \
      https://api.cloudflare.com/client/v4/user/tokens/verify 2>/dev/null || true)
    status=$(printf '%s' "$body" | sed -n 's/.*"status":"\([a-z]*\)".*/\1/p' | head -1)
    if [ "${status:-}" = "active" ]; then
      # Rule 3 in runbooks/credentials.md: warn before it lapses.
      expires=$(printf '%s' "$body" | sed -n 's/.*"expires_on":"\([^"]*\)".*/\1/p' | head -1)
      if [ -n "${expires:-}" ] && have python3; then
        days=$(python3 -c '
import sys
from datetime import datetime, timezone
try:
    exp = datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00"))
except ValueError:
    print("")
    raise SystemExit
print(int((exp - datetime.now(timezone.utc)).total_seconds() // 86400))
' "$expires" 2>/dev/null) || days=""
        if [ -n "$days" ] && [ "$days" -lt "$CRED_EXPIRY_WARN_DAYS" ]; then
          row_warn "credential/$name" "active, expires in ${days}d ($expires)"
          continue
        fi
        row_ok "credential/$name" "active, expires $expires"
        continue
      fi
      row_ok "credential/$name" "active"
      continue
    fi
    # Account-owned tokens are not user tokens; verify them against a read that
    # their own policy allows. Without an account id there is nothing to ask.
    if [ -z "$CF_ACCOUNT_ID" ]; then
      row_warn "credential/$name" "not a user token; set CF_ACCOUNT_ID to verify"
      continue
    fi
    code=$(curl -s -m "$HTTP_TIMEOUT" -o /dev/null -w '%{http_code}' \
      -H "Authorization: Bearer $token" \
      "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/pages/projects" 2>/dev/null || true)
    if [ "$code" = "200" ]; then
      row_ok "credential/$name" "active (account-scoped)"
    else
      row_red "credential/$name" "rejected (HTTP ${code:-000})"
    fi
  done
}

# ---------------------------------------------------------------- mainframe

# One SSH round trip. The host answers with key=value lines: no parsing of
# human output, no second connection, and every fact comes from the machine
# that owns it.
remote_collect() {
  timeout "$SSH_TIMEOUT" ssh -o BatchMode=yes -o ConnectTimeout=8 \
    -o ServerAliveInterval=5 \
    "$MAINFRAME_HOST" bash -s -- "$MAINFRAME_RADIO_DIR" <<'REMOTE'
set -u
dir=$1
if ! cd "$dir" 2>/dev/null; then
  printf 'error=cannot cd to %s on %s\n' "$dir" "$(hostname)"
  exit 0
fi
printf 'epoch=%s\n' "$(date +%s)"
printf 'sha=%s\n' "$(git rev-parse HEAD 2>/dev/null || echo unknown)"
printf 'branch=%s\n' "$(git symbolic-ref --short -q HEAD || echo detached)"
printf 'dirty=%s\n' "$(git status --porcelain 2>/dev/null | grep -vc '^??' || true)"
docker ps --format '{{.Names}}|{{.Status}}' 2>/dev/null | sed 's/^/container=/'
printf 'status=%s\n' "$(python3 -c 'import json; print(json.dumps(json.load(open("data/status.json"))))' 2>/dev/null || echo '')"
printf 'icecast=%s\n' "$(docker exec radio-caddy wget -qO- http://icecast:8000/status-json.xsl 2>/dev/null | head -c 4000)"
REMOTE
}

# JSON status.json -> whitelisted key=value lines.
status_fields() {
  printf '%s' "$1" | python3 -c '
import json, sys
from datetime import datetime
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit
out = {"probe_ts": "", "stream_flowing": "false", "stream_bps": "",
       "door_code": "", "cam_age": "", "cam_fresh": "false",
       "disk_free_gb": "", "below_floor": "false", "pkg_c": ""}
ts = d.get("ts", "")
try:
    out["probe_ts"] = int(datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp())
except Exception:
    pass
s = d.get("stream", {}) or {}
out["stream_flowing"] = "true" if s.get("flowing") else "false"
out["stream_bps"] = s.get("bytes_per_s", "")
dr = d.get("door", {}) or {}
out["door_code"] = dr.get("status_without_token", "")
c = d.get("camera", {}) or {}
out["cam_age"] = c.get("segment_age_s", "")
out["cam_fresh"] = "true" if c.get("fresh") else "false"
r = d.get("resources", {}) or {}
out["disk_free_gb"] = r.get("disk_free_gb", "")
out["below_floor"] = "true" if r.get("below_floor") else "false"
out["pkg_c"] = r.get("pkg_c", "")
for k, v in out.items():
    print("%s=%s" % (k, v))
' 2>/dev/null || true
}

# read_kv  (key=value on stdin) -> KV array, whitelisted keys only.
declare -A KV=()
read_kv() {
  local line key value
  KV=()
  while IFS= read -r line; do
    case "$line" in *=*) ;; *) continue ;; esac
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      probe_ts | stream_flowing | stream_bps | door_code | cam_age | cam_fresh | disk_free_gb | below_floor | pkg_c)
        KV["$key"]=$value
        ;;
      *) continue ;;
    esac
  done
}

# find_container NAME -> status string, or non-zero when absent.
find_container() {
  local want=$1 c
  for c in "${containers[@]}"; do
    if [ "${c%%|*}" = "$want" ]; then
      printf '%s' "${c#*|}"
      return 0
    fi
  done
  return 1
}

# mainframe_rows  (reads remote_collect output on stdin)
# Separate from the SSH call so --self-test can drive it with fixtures.
mainframe_rows() {
  local line key value epoch="" sha="" branch="" dirty="" status="" icecast=""
  local name st missing="" down="" unhealthy="" optional_absent="" msg=""
  local -a containers=()

  while IFS= read -r line; do
    case "$line" in *=*) ;; *) continue ;; esac
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      epoch) epoch=$value ;;
      sha) sha=$value ;;
      branch) branch=$value ;;
      dirty) dirty=$value ;;
      container) containers+=("$value") ;;
      status) status=$value ;;
      icecast) icecast=$value ;;
      error)
        row_red "mainframe" "$value"
        return
        ;;
    esac
  done

  if [ -z "$epoch" ]; then
    row_red "mainframe" "SSH answered but the radio checkout did not"
    return
  fi
  if [ "${#containers[@]}" -eq 0 ]; then
    row_red "mainframe" "no containers listed on the host"
    return
  fi
  # Say which machine answered. Every row below is a fact from this host, and a
  # table that never names it invites the reader to assume "local".
  row_ok "mainframe" "$MAINFRAME_HOST:$MAINFRAME_RADIO_DIR"

  # --- containers: required, optional, and other stacks on the same host
  local n
  for n in $MAINFRAME_CONTAINERS $MAINFRAME_EXTRA_CONTAINERS; do # shellcheck disable=SC2086
    if ! st=$(find_container "$n"); then
      missing+=" $n"
      continue
    fi
    case "$st" in
      Up*) case "$st" in *unhealthy*) unhealthy+=" $n" ;; esac ;;
      *) down+=" $n($st)" ;;
    esac
  done
  for n in $MAINFRAME_OPTIONAL_CONTAINERS; do # shellcheck disable=SC2086
    if ! find_container "$n" >/dev/null; then
      optional_absent+=" $n"
    fi
  done
  if [ -n "$missing" ] || [ -n "$down" ] || [ -n "$unhealthy" ]; then
    [ -n "$missing" ] && msg="missing:$missing"
    [ -n "$down" ] && msg="$msg down:$down"
    [ -n "$unhealthy" ] && msg="$msg unhealthy:$unhealthy"
    row_red "containers" "${msg# }"
  elif [ -n "$optional_absent" ]; then
    row_warn "containers" "required up; optional absent:$optional_absent"
  else
    row_ok "containers" "required up"
  fi

  # --- deploy state: what source is actually running here
  if [ -n "${RADIO_EXPECTED_SHA:-}" ] && [ "${sha:0:12}" != "${RADIO_EXPECTED_SHA:0:12}" ]; then
    row_warn "deploy" "running ${sha:0:12}, expected ${RADIO_EXPECTED_SHA:0:12}"
  elif [ "$branch" = "detached" ]; then
    row_warn "deploy" "${sha:0:12} on a detached HEAD"
  elif [ "${dirty:-0}" -gt 0 ]; then
    row_warn "deploy" "${sha:0:12} on $branch, $dirty uncommitted file(s)"
  else
    row_ok "deploy" "${sha:0:12} on $branch"
  fi

  # --- the host's own probe: freshness of data/status.json
  if [ -z "$status" ]; then
    row_warn "probe" "data/status.json missing or invalid on the host"
  elif [ -z "${KV[probe_ts]:-}" ]; then
    row_warn "probe" "data/status.json has no usable timestamp"
  else
    local age=$((epoch - KV[probe_ts]))
    if [ "$age" -le "$STATUS_MAX_AGE_S" ]; then
      row_ok "probe" "fresh, ${age}s old"
    else
      row_warn "probe" "${age}s old, the host's timer is not running"
    fi
  fi

  # --- stream: a source connected to Icecast
  local alive="" title="" rate=""
  if [ -n "$icecast" ]; then
    local parsed=""
    parsed=$(printf '%s' "$icecast" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit
src = d.get("icestats", {}).get("source")
if isinstance(src, list):
    src = src[0] if src else {}
if not isinstance(src, dict) or not src:
    raise SystemExit
print("%s|%s" % (src.get("title") or "", src.get("listeners", 0)))
' 2>/dev/null) || parsed=""
    if [ -n "$parsed" ]; then
      alive="source"
      title=${parsed%%|*}
    fi
  fi
  [ -n "${KV[stream_bps]:-}" ] && rate="${KV[stream_bps]} B/s"
  if [ "$alive" = "source" ] && [ "${KV[stream_flowing]:-false}" = "true" ]; then
    row_ok "stream" "${title:-source connected}, ${rate:-flowing}"
  elif [ "$alive" = "source" ]; then
    row_warn "stream" "${title:-source connected}, no bytes counted"
  elif [ -z "$icecast" ] && [ "${KV[stream_flowing]:-false}" = "true" ]; then
    row_warn "stream" "status.json says flowing, Icecast did not answer the probe"
  else
    row_red "stream" "no source connected to Icecast"
  fi

  # --- the door: without a token nothing may be visible
  case "${KV[door_code]:-}" in
    404) row_ok "door" "closed without a token" ;;
    '') row_warn "door" "no door status in data/status.json" ;;
    *) row_red "door" "answered HTTP ${KV[door_code]} without a token" ;;
  esac

  # --- resources, straight from the host's own measurement
  if [ "${KV[below_floor]:-false}" = "true" ]; then
    row_red "resources" "disk below floor: ${KV[disk_free_gb]:-?} GB free"
  elif [ -n "${KV[pkg_c]:-}" ] && [ "${KV[pkg_c]}" -ge "$MAINFRAME_TEMP_MAX_C" ]; then
    row_red "resources" "${KV[pkg_c]} C, above ${MAINFRAME_TEMP_MAX_C} C"
  elif [ -n "${KV[disk_free_gb]:-}" ]; then
    row_ok "resources" "${KV[disk_free_gb]} GB free, ${KV[pkg_c]:-?} C"
  else
    row_warn "resources" "no resource data in data/status.json"
  fi

  if [ "${KV[cam_fresh]:-false}" = "true" ]; then
    row_ok "camera" "fresh segment, ${KV[cam_age]:-?}s"
  else
    # A missing camera is a documented state, not a station failure: the
    # compose file refuses to start cam without its device.
    row_warn "camera" "no fresh segment (device unplugged?)"
  fi
}

mainframe_check() {
  local raw status_json
  if [ -z "$MAINFRAME_HOST" ]; then
    row_skip "mainframe" "MAINFRAME_HOST not configured"
    return
  fi
  if [ -z "$MAINFRAME_RADIO_DIR" ]; then
    row_red "mainframe" "MAINFRAME_RADIO_DIR not configured"
    return
  fi
  if ! have ssh; then
    row_skip "mainframe" "ssh not installed"
    return
  fi
  if ! raw=$(remote_collect 2>/dev/null); then
    row_red "mainframe" "unreachable over SSH ($MAINFRAME_HOST)"
    return
  fi
  if [ -z "$raw" ]; then
    row_red "mainframe" "SSH answered with nothing ($MAINFRAME_HOST)"
    return
  fi

  # status.json is one long JSON line; pull it out before the row loop, which
  # only deals with scalars.
  status_json=$(printf '%s\n' "$raw" | sed -n 's/^status=//p' | head -1)
  if [ -n "$status_json" ]; then
    read_kv < <(status_fields "$status_json")
  else
    KV=()
  fi
  mainframe_rows < <(printf '%s\n' "$raw")
}

# ---------------------------------------------------------------- self-test

t_pass=0
t_fail=0

expect() { # name haystack needle have|lack
  local name=$1 hay=$2 needle=$3 want=$4
  if printf '%s' "$hay" | grep -q -- "$needle"; then
    if [ "$want" = "have" ]; then
      t_pass=$((t_pass + 1))
    else
      t_fail=$((t_fail + 1))
      printf 'FAIL %s: unexpected %q\n' "$name" "$needle" >&2
    fi
  elif [ "$want" = "lack" ]; then
    t_pass=$((t_pass + 1))
  else
    t_fail=$((t_fail + 1))
    printf 'FAIL %s: missing %q\n' "$name" "$needle" >&2
  fi
}

# mcp_case REQUIRED  (fixture on stdin) -> rows and red flag.
# Each case runs in a subshell so the parent's table is untouched.
mcp_case() {
  red=0 rows=()
  parse_mcp_list "$1"
  printf '%s\n' "${rows[@]}"
  printf 'red=%s\n' "$red"
}

self_test_mcp() {
  local out

  # V2 output, everything connected: the common case must be green even though
  # it looks nothing like the V1 format the old check parsed.
  out=$(mcp_case "n3rv-memory github codebase-memory-mcp searxng" <<'EOF'
✓ cloudflare                connected
✓ codebase-memory-mcp       connected
✓ github                    connected
✓ n3rv-memory               connected
✓ searxng                   connected
EOF
)
  expect "mcp connected: no RED" "$out" 'RED' lack
  expect "mcp connected: red=0" "$out" 'red=0' have

  # The false failure this rewrite exists to prevent: optional remote servers
  # needing OAuth while every required server is connected.
  out=$(mcp_case "n3rv-memory github codebase-memory-mcp" <<'EOF'
✓ codebase-memory-mcp       connected
✓ github                    connected
✓ n3rv-memory               connected
⚠ cloudflare                needs authentication
⚠ cloudflare-builds         needs authentication
EOF
)
  expect "mcp optional auth: no RED" "$out" 'RED' lack
  expect "mcp optional auth: red=0" "$out" 'red=0' have

  out=$(mcp_case "n3rv-memory github" <<'EOF'
✓ n3rv-memory               connected
✗ github                    failed
EOF
)
  expect "mcp failed: RED" "$out" 'RED' have
  expect "mcp failed: names the server" "$out" 'github' have

  out=$(mcp_case "n3rv-memory github" <<'EOF'
✓ n3rv-memory               connected
⚠ github                    needs authentication
EOF
)
  expect "mcp required auth: RED" "$out" 'RED' have

  # A required server that is not configured at all is drift, and RED.
  out=$(mcp_case "n3rv-memory github" <<'EOF'
✓ n3rv-memory               connected
EOF
)
  expect "mcp missing: RED" "$out" 'RED' have
  expect "mcp missing: names it" "$out" 'github' have
}

# A healthy mainframe fixture. The camera is absent, which is documented as a
# device state, not a station failure.
mainframe_fixture() {
  local epoch=$1 ts=$2
  cat <<EOF
epoch=$epoch
sha=9fb94c2d1e4f5a6b7c8d9e0f
branch=master
dirty=0
container=radio-icecast|Up 26 hours (healthy)
container=radio-liquidsoap|Up 57 minutes
container=radio-mediamtx|Up 26 hours
container=radio-caddy|Up 26 hours
container=radio-indiegen|Up 26 hours
container=jellyfin|Up 3 days (healthy)
status={"ts":"$ts","stream":{"flowing":true,"bytes_per_s":18862,"title":"Track"},"door":{"status_without_token":"404","closed":true},"camera":{"segment_age_s":-1,"fresh":false},"resources":{"disk_free_gb":792,"below_floor":false,"pkg_c":55}}
icecast={"icestats":{"source":{"listeners":3,"title":"Track","stream_start":"x"}}}
EOF
}

# run_fixture TEXT -> rows + red, evaluated in a subshell.
run_fixture() {
  local text=$1
  red=0 rows=()
  read_kv < <(status_fields "$(printf '%s\n' "$text" | sed -n 's/^status=//p' | head -1)")
  mainframe_rows < <(printf '%s\n' "$text")
  printf '%s\n' "${rows[@]}"
  printf 'red=%s\n' "$red"
}

self_test_mainframe() {
  local now out text

  now=$(date +%s)
  out=$(run_fixture "$(mainframe_fixture "$now" "$(date -u +%FT%TZ)")")
  expect "healthy: no RED" "$out" 'RED' lack
  expect "healthy: camera is a warning" "$out" 'WARN.*camera' have
  expect "healthy: sha reported" "$out" '9fb94c2d1e4f' have
  expect "healthy: stream ok" "$out" 'OK.*stream' have
  expect "healthy: deploy ok" "$out" 'OK.*deploy' have

  # Liquidsoap restarting: the stream is down and the table must say so.
  text=$(mainframe_fixture "$now" "$(date -u +%FT%TZ)" |
    sed 's/^container=radio-liquidsoap|.*/container=radio-liquidsoap|Restarting (1) 2 seconds ago/; s/^icecast=.*/icecast=/; s/"flowing":true/"flowing":false/')
  out=$(run_fixture "$text")
  expect "restarting: RED containers" "$out" 'RED.*containers' have
  expect "restarting: RED stream" "$out" 'RED.*stream' have

  # Door open: a security invariant failure is RED even while audio flows.
  text=$(mainframe_fixture "$now" "$(date -u +%FT%TZ)" |
    sed 's/"status_without_token":"404"/"status_without_token":"200"/')
  out=$(run_fixture "$text")
  expect "door open: RED" "$out" 'RED.*door' have

  # A stale probe is a monitoring failure, not a station failure.
  text=$(mainframe_fixture "$now" "2020-01-01T00:00:00Z")
  out=$(run_fixture "$text")
  expect "stale probe: WARN" "$out" 'WARN.*probe' have
  expect "stale probe: no RED" "$out" 'RED' lack

  # No usable data at all: exactly one honest row.
  out=$(run_fixture 'nothing useful')
  expect "no data: RED" "$out" 'RED.*mainframe' have
}

self_test_topology() {
  # The regressions this rewrite exists to prevent, asserted against the source:
  # no hardcoded LAN address, no retired component, no V1 output parsing.
  local src=$1
  expect "no LAN address" "$(grep -Eo '192\.168\.[0-9]+\.' "$src" || true)" '192.168.' lack
  # Split the literals so this check does not match itself.
  expect "no retired EPG timer" "$(grep -c 'epg-re''grab' "$src")" '^0$' have
  expect "no local Jellyfin URL" "$(grep -c '127.0.0.1:80''96' "$src")" '^0$' have
}

self_test() {
  apply_defaults
  self_test_mcp
  self_test_mainframe
  self_test_topology "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  if [ "$t_fail" -ne 0 ]; then
    printf 'self-test: %d passed, %d failed\n' "$t_pass" "$t_fail" >&2
    return 1
  fi
  printf 'self-test: %d passed\n' "$t_pass"
  return 0
}

# ---------------------------------------------------------------- main

if [ "$SELF_TEST" -eq 1 ]; then
  self_test
  exit $?
fi

read_config "$CONFIG_FILE" || true
apply_defaults

if [ "$CHECK_CI" = "1" ]; then
  for repo in $REPOS; do # shellcheck disable=SC2086  # list on purpose
    case "$repo" in
      radio | indiegenerator) ci_check "$repo" master ;;
      *) ci_check "$repo" main ;;
    esac
  done
else
  row_skip "ci" "CHECK_CI=0"
fi

opencode_service_check
mcp_check
n3rv_hub_check
http_service_check "searxng" "$SEARXNG_URL"
http_service_check "xerj" "$XERJ_URL"

if [ "$CHECK_CHECKOUTS" = "1" ]; then
  checkout_check
else
  row_skip "checkouts" "CHECK_CHECKOUTS=0"
fi

mainframe_check
cred_check

if [ "$QUIET" -eq 0 ]; then
  printf '\nstack health  %s  (%s)\n\n' "$(date -u +%FT%TZ)" "$CONFIG_FILE"
  for row in "${rows[@]}"; do printf '  %s\n' "$row"; done
  printf '\n'
fi

if [ "$red" -ne 0 ]; then
  [ "$QUIET" -eq 0 ] && printf 'verdict: RED\n'
  exit 1
fi
[ "$QUIET" -eq 0 ] && printf 'verdict: green\n'
exit 0
