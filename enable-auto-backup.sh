#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="linux-setup-auto-backup.service"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
SERVICE_PATH="$SYSTEMD_USER_DIR/$SERVICE_NAME"
SOURCE_UNIT="$SCRIPT_DIR/configs/systemd/user/$SERVICE_NAME"

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

require_command systemctl

mkdir -p "$SYSTEMD_USER_DIR"
sed \
  -e "s|@REPO_DIR@|$SCRIPT_DIR|g" \
  "$SOURCE_UNIT" > "$SERVICE_PATH"
chmod 644 "$SERVICE_PATH"

systemctl --user daemon-reload
systemctl --user enable --now "$SERVICE_NAME"

log "Enabled $SERVICE_NAME"
log "It will run at the start of each user session."
