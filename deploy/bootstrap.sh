#!/usr/bin/env bash
# bootstrap.sh - turn a fresh Ubuntu Server into the radio appliance.
#
#   sudo ./bootstrap.sh --env-file /root/radio.env          # real run
#      ./bootstrap.sh --env-file /root/radio.env --dry-run  # print, touch nothing
#
# It is idempotent: running it twice changes nothing the second time. Every step
# checks before it acts, so a half-finished run is resumed, not restarted.
#
# What it does NOT do: invent secrets. The .env is copied from a path you provide
# and must contain the Icecast passwords, the UIDs/GIDs and the site addresses.
# Listener tokens are issued afterwards with ./scripts/token.sh.
#
# WHY THIS EXISTS
# "The appliance" is a claim until a machine can be rebuilt from the repo. This
# script is the difference between a pet and a reproducible box, and it is the
# only way to test that the previous steps (caps, retention, status, scheduler)
# actually compose into something that runs.

set -uo pipefail

USER_NAME="${SUDO_USER:-}"
REPO_DIR=""
ENV_FILE=""
DRY_RUN=0
FIREWALL=0
RADIO_URL="https://github.com/The-Replacement/radio.git"
INDIEGEN_URL="https://github.com/The-Replacement/indiegenerator.git"

usage() {
  cat <<'USAGE'
bootstrap.sh - provision the radio appliance

  --user NAME        run the stack as this user (default: $SUDO_USER)
  --repo-dir PATH    where to clone (default: /home/NAME/servers)
  --env-file PATH    path to a ready .env (required; never generated here)
  --enable-firewall  enable ufw after adding the rules (default: rules only)
  --dry-run          print every action, change nothing
  -h, --help         this text

Exit codes: 0 done or already provisioned, 1 something failed and was not
rolled back (the script is idempotent: fix and re-run).
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --user) USER_NAME="${2:-}"; shift 2 ;;
    --repo-dir) REPO_DIR="${2:-}"; shift 2 ;;
    --env-file) ENV_FILE="${2:-}"; shift 2 ;;
    --enable-firewall) FIREWALL=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

say()  { printf '\n== %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '   WARN: %s\n' "$*" >&2; }
die()  { printf '\nFAIL: %s\n' "$*" >&2; exit 1; }

run() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '   [dry] %s\n' "$*"
    return 0
  fi
  "$@"
}

# shellcheck disable=SC2317  # reached only through run() in a real run
must() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '   [dry] %s\n' "$*"
    return 0
  fi
  "$@" || die "command failed: $*"
}

[ "$(id -u)" = "0" ] || [ "$DRY_RUN" = "1" ] || die "run as root (sudo) or with --dry-run"
[ -n "$USER_NAME" ] || die "--user is required when not invoked via sudo"
id "$USER_NAME" >/dev/null 2>&1 || die "no such user: $USER_NAME"

USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
[ -n "$REPO_DIR" ] || REPO_DIR="$USER_HOME/servers"
[ -n "$ENV_FILE" ] || die "--env-file is required: this script does not invent secrets"
[ -f "$ENV_FILE" ] || die "env file not found: $ENV_FILE"

say "target: user=$USER_NAME home=$USER_HOME repos=$REPO_DIR dry_run=$DRY_RUN"

# ---------------------------------------------------------------- packages

say "packages"
PKGS="docker.io docker-compose-v2 git curl zram-tools lm-sensors ufw unattended-upgrades ca-certificates python3"
MISSING=""
for p in $PKGS; do
  if dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'ok installed'; then
    continue
  fi
  MISSING="$MISSING $p"
done
if [ -n "$MISSING" ]; then
  info "installing:$MISSING"
  must apt-get update -qq
  # shellcheck disable=SC2086
  must env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $MISSING
else
  info "all present"
fi

# Docker from the distro is old enough to lack some flags; say so rather than
# pretend. The stack needs Compose v2.
if command -v docker >/dev/null 2>&1; then
  info "docker: $(docker --version 2>/dev/null)"
  if docker compose version >/dev/null 2>&1; then
    info "compose: $(docker compose version --short 2>/dev/null)"
  else
    warn "docker compose v2 not available: install docker-compose-v2 from the distro or Docker's repo"
  fi
fi

say "docker group"
if id -nG "$USER_NAME" | tr ' ' '\n' | grep -qx docker; then
  info "$USER_NAME already in docker"
else
  must usermod -aG docker "$USER_NAME"
  info "added $USER_NAME to docker (re-login required for the group to apply)"
fi

must systemctl enable --now docker

# ---------------------------------------------------------------- repos

say "repositories"
run mkdir -p "$REPO_DIR"
for pair in "radio:$RADIO_URL" "indiegenerator:$INDIEGEN_URL"; do
  name="${pair%%:*}"
  url="${pair#*:}"
  if [ -d "$REPO_DIR/$name/.git" ]; then
    info "$name: present"
    run git -C "$REPO_DIR/$name" fetch --quiet origin || warn "fetch failed for $name (offline?)"
  else
    must git clone --depth 1 "$url" "$REPO_DIR/$name"
  fi
  run chown -R "$USER_NAME":"$USER_NAME" "$REPO_DIR/$name"
done

say "environment file"
if [ -f "$REPO_DIR/radio/.env" ]; then
  info "existing .env kept (delete it yourself to replace)"
else
  must install -m 0600 -o "$USER_NAME" -g "$USER_NAME" "$ENV_FILE" "$REPO_DIR/radio/.env"
  info "installed from $ENV_FILE (mode 0600)"
fi

say "runtime directories"
for d in data/host data/cam data/caddy data/indiegen music music-audio jingles; do
  run mkdir -p "$REPO_DIR/radio/$d"
  run chown -R "$USER_NAME":"$USER_NAME" "$REPO_DIR/radio/$d"
done
run mkdir -p "$REPO_DIR/radio/secrets"
run chmod 700 "$REPO_DIR/radio/secrets"

# ---------------------------------------------------------------- host tuning

say "zram (compressed swap, no disk swap)"
if [ -f /etc/default/zramswap ]; then
  info "zramswap config present"
else
  if [ "$DRY_RUN" = "1" ]; then
    printf '   [dry] write /etc/default/zramswap (ALGO=zstd, PERCENT=25)\n'
  else
    printf 'ALGO=zstd\nPERCENT=25\nPRIORITY=100\n' > /etc/default/zramswap
  fi
fi
run systemctl enable --now zramswap
# Disk swap on an SSD turns a memory spike into minutes of I/O thrash. Keep it
# out of the appliance's way if it exists.
if swapon --show --noheadings 2>/dev/null | grep -q '/swap'; then
  warn "disk swap is active; radio-job does not manage /etc/fstab. Disable it deliberately."
fi

say "journald cap"
if grep -qs '^SystemMaxUse=' /etc/systemd/journald.conf; then
  info "SystemMaxUse already set"
elif [ "$DRY_RUN" = "1" ]; then
  printf '   [dry] append SystemMaxUse=1G to /etc/systemd/journald.conf\n'
else
  printf 'SystemMaxUse=1G\n' >> /etc/systemd/journald.conf
  systemctl restart systemd-journald
fi

say "firewall"
run ufw allow 22/tcp
run ufw allow 8090/tcp
run ufw allow 8443/tcp
if [ "$FIREWALL" = "1" ]; then
  must ufw --force enable
  info "ufw enabled"
else
  info "rules added, ufw NOT enabled (pass --enable-firewall once you are sure SSH is open)"
fi

# ---------------------------------------------------------------- scheduling

say "cron"
CRON_LINES="30 4 * * * $REPO_DIR/radio/scripts/radio-job.sh gc >/dev/null 2>&1
*/5 * * * * $REPO_DIR/radio/scripts/radio-job.sh verify >/dev/null 2>&1
* * * * * $REPO_DIR/radio/scripts/restart-on-signal.sh
0 * * * * $REPO_DIR/radio/scripts/mario-refresh.sh"
if [ "$DRY_RUN" = "1" ]; then
  printf '   [dry] crontab for %s would contain:\n%s\n' "$USER_NAME" "$(printf '%s' "$CRON_LINES" | sed 's/^/     /')"
else
  CURRENT=$(crontab -l -u "$USER_NAME" 2>/dev/null || true)
  ADDED=""
  while IFS= read -r line; do
    if printf '%s\n' "$CURRENT" | grep -Fqx "$line"; then
      continue
    fi
    ADDED="$ADDED$line"$'\n'
  done <<< "$CRON_LINES"
  if [ -n "$ADDED" ]; then
    { printf '%s\n' "$CURRENT"; printf '%s' "$ADDED"; } | crontab -u "$USER_NAME" -
    info "installed $(printf '%s' "$ADDED" | grep -c .) new entries"
  else
    info "all entries present"
  fi
fi

# ---------------------------------------------------------------- bring it up

say "stack"
info "the compose file refuses to start cam without its device: expected on a fresh box"
run docker compose -f "$REPO_DIR/radio/docker-compose.yml" \
  --project-directory "$REPO_DIR/radio" up -d icecast liquidsoap caddy mediamtx indiegen

say "done"
cat <<NEXT
   Next, as $USER_NAME (re-login first so the docker group applies):

     cd $REPO_DIR/radio
     ./scripts/token.sh add <name>            # issue a listener credential
     ./scripts/radio-job.sh verify            # one status file
     ./scripts/radio-job.sh status            # and read it

   The first generator cycle happens by interval, or on demand:

     ./scripts/radio-job.sh render

   Nothing here is trusted until you have watched one cycle publish and restart
   Liquidsoap. See The-Replacement/docs/autonomy/02-design.md.
NEXT
