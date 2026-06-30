#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_PATH="$SCRIPT_DIR/backup.sh"

log() {
  printf '%s\n' "$1"
}

warn() {
  printf 'Warning: %s\n' "$1" >&2
}

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    warn "Required command not found: $cmd"
    exit 1
  fi
}

require_command git

if ! git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  warn "Directory is not a Git repository: $SCRIPT_DIR"
  exit 1
fi

if [[ ! -f "$BACKUP_PATH" ]]; then
  warn "backup.sh not found: $BACKUP_PATH"
  exit 1
fi

branch="$(git -C "$SCRIPT_DIR" symbolic-ref --quiet --short HEAD || true)"
if [[ -z "$branch" ]]; then
  warn "Unable to determine the current Git branch."
  exit 1
fi

log "Running backup.sh"
bash "$BACKUP_PATH"

git -C "$SCRIPT_DIR" add -A -- configs/

if git -C "$SCRIPT_DIR" diff --cached --quiet -- configs/; then
  log "No backup changes detected."
  exit 0
fi

commit_message="$(date '+Auto backup generated at %d/%m/%Y %H:%M')"
git -C "$SCRIPT_DIR" commit -m "$commit_message"

if ! git -C "$SCRIPT_DIR" remote get-url origin >/dev/null 2>&1; then
  warn "Git remote 'origin' is not configured. Backup changes were committed locally only."
  exit 1
fi

git -C "$SCRIPT_DIR" push origin "$branch"
log "Backup changes pushed to origin/$branch"
