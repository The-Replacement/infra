#!/bin/sh
# offsite-sync.sh - put a second copy of the radio-state restic repo somewhere.
#
# Modes:
#   box     rsync the repo to mainframe:~/restic-radio-state. LAN, differential,
#           cheap enough for every night.
#   github  tar the repo and upload it as the 'nightly' release asset on the
#           private The-Replacement/radio-backup repository. Off-house.
#   all     both, box first.
#
# The repository is already encrypted by restic: nothing this script sends is
# plaintext. Fails loudly. An offsite copy that skips quietly is the failure
# that motivated this file.

set -eu

CONF=${BACKUP_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/radio-backup/backup.conf}
REPO=$(sed -n 's/^[[:space:]]*RESTIC_REPOSITORY[[:space:]]*=[[:space:]]*\(.*\)/\1/p' "$CONF" | tail -1)
ARCHIVE_REPO=${ARCHIVE_REPO:-The-Replacement/radio-backup}
TARGET_HOST=${OFFSITE_HOST:-mainframe}
TARGET_DIR=${OFFSITE_DIR:-restic-radio-state}

usage() { sed -n '3,17p' "$0"; exit 2; }
MODE=${1:-all}

[ -n "$REPO" ] || { printf 'no RESTIC_REPOSITORY in %s\n' "$CONF" >&2; exit 2; }
[ -d "$REPO" ] || { printf 'not a repository directory: %s\n' "$REPO" >&2; exit 2; }
[ -d "$REPO/keys" ] || { printf '%s has no keys/ - not a restic repo?\n' "$REPO" >&2; exit 2; }

box_copy() {
    printf 'box: rsync %s/ -> %s:%s/\n' "$REPO" "$TARGET_HOST" "$TARGET_DIR"
    rsync -a --delete --partial \
        --exclude='cache' \
        "$REPO/" "$TARGET_HOST:$TARGET_DIR/"
    printf 'box: local files=%s remote files=%s\n' \
        "$(find "$REPO" -type f | wc -l)" \
        "$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$TARGET_HOST" "find ~/$TARGET_DIR -type f | wc -l")"
}

github_copy() {
    tmp=$(mktemp -d)
    archive="$tmp/radio-state.tar.gz"
    printf 'github: tarring %s (%s) ...\n' "$REPO" "$(du -sh "$REPO" | cut -f1)"
    tar -C "$(dirname "$REPO")" -czf "$archive" "$(basename "$REPO")"
    if ! gh release view nightly -R "$ARCHIVE_REPO" >/dev/null 2>&1; then
        gh release create nightly -R "$ARCHIVE_REPO" \
            --title 'Rolling nightly archive of the radio-state restic repo' \
            --notes 'Ciphertext. Recovery key lives as a secret in The-Replacement/infra.'
    fi
    printf 'github: uploading %s bytes\n' "$(wc -c < "$archive")"
    gh release upload nightly -R "$ARCHIVE_REPO" \
        --clobber "radio-state.tar.gz#$archive"
    printf 'github: assets now: %s\n' \
        "$(gh release view nightly -R "$ARCHIVE_REPO" --json assets --jq '[.assets[].name] | join(", ")')"
}

case "$MODE" in
    box) box_copy ;;
    github) github_copy ;;
    all) box_copy; github_copy ;;
    *) usage ;;
esac
