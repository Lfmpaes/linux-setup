#!/usr/bin/env bash
set -euo pipefail

# Mirror key desktop and shell configuration files into the repository.
# Run from any location; files are placed relative to this script directory.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Map of source file -> destination file inside the repo.
declare -A FILE_BACKUPS=(
  ["$HOME/.bashrc"]="$SCRIPT_DIR/configs/bash/.bashrc"
  ["$HOME/.bash_profile"]="$SCRIPT_DIR/configs/bash/.bash_profile"
  ["$HOME/.zshrc"]="$SCRIPT_DIR/configs/zsh/.zshrc"
  ["$HOME/.p10k.zsh"]="$SCRIPT_DIR/configs/zsh/.p10k.zsh"
  ["$HOME/.config/konsolerc"]="$SCRIPT_DIR/configs/konsole/config/konsolerc"
  ["$HOME/.config/konsolesshconfig"]="$SCRIPT_DIR/configs/konsole/config/konsolesshconfig"
  ["$HOME/.local/share/konsole/Profile 1.profile"]="$SCRIPT_DIR/configs/konsole/profiles/Profile 1.profile"
  ["$HOME/.config/smoked-salmon/config.toml"]="$SCRIPT_DIR/configs/smoked-salmon/config.toml"
  ["$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"]="$SCRIPT_DIR/configs/plasma/config/plasma-org.kde.plasma.desktop-appletsrc"
  ["$HOME/.config/plasmashellrc"]="$SCRIPT_DIR/configs/plasma/config/plasmashellrc"
  ["$HOME/.config/kdeglobals"]="$SCRIPT_DIR/configs/plasma/config/kdeglobals"
  ["$HOME/.config/kscreenlockerrc"]="$SCRIPT_DIR/configs/plasma/config/kscreenlockerrc"
  ["$HOME/.config/kglobalshortcutsrc"]="$SCRIPT_DIR/configs/plasma/config/kglobalshortcutsrc"
  ["$HOME/.config/kwinrc"]="$SCRIPT_DIR/configs/plasma/config/kwinrc"
  ["$HOME/.config/dolphinrc"]="$SCRIPT_DIR/configs/plasma/config/dolphinrc"
  ["$HOME/.config/katerc"]="$SCRIPT_DIR/configs/plasma/config/katerc"
  ["$HOME/.config/kcminputrc"]="$SCRIPT_DIR/configs/plasma/config/kcminputrc"
  ["$HOME/.config/krunnerrc"]="$SCRIPT_DIR/configs/plasma/config/krunnerrc"
  ["$HOME/.config/spectaclerc"]="$SCRIPT_DIR/configs/plasma/config/spectaclerc"
  ["$HOME/.config/khotkeysrc"]="$SCRIPT_DIR/configs/plasma/config/khotkeysrc"
  ["$HOME/.config/micro/settings.json"]="$SCRIPT_DIR/configs/micro/settings.json"
  ["$HOME/.config/micro/bindings.json"]="$SCRIPT_DIR/configs/micro/bindings.json"
)

declare -A ALLOWED_APPLICATION_BACKUPS=(
  ["Paralives.desktop"]=1
  ["appimagekit_e79d32fd8a09b38e08cb6e9762dd1c8f-twitter.desktop"]=1
  ["hermes-desktop.desktop"]=1
  ["mimeapps.list"]=1
  ["net.local.kitty.desktop"]=1
)

should_copy_backup_file() {
  local path="$1"
  local base_name

  base_name="$(basename "$path")"

  if [[ "$path" == "$HOME/.local/share/applications/"* ]]; then
    [[ -n "${ALLOWED_APPLICATION_BACKUPS[$base_name]:-}" ]]
    return
  fi

  return 0
}

prune_untracked_application_backups() {
  local app_dir="$SCRIPT_DIR/configs/desktop/applications"
  local file base_name

  [[ -d "$app_dir" ]] || return 0

  while IFS= read -r -d '' file; do
    base_name="$(basename "$file")"
    if [[ -z "${ALLOWED_APPLICATION_BACKUPS[$base_name]:-}" ]]; then
      rm -f "$file"
    fi
  done < <(find "$app_dir" -maxdepth 1 -type f -print0)
}

copy_tree_backup() {
  local src_base="$1"
  local dest_base="$2"
  local file rel_path

  if [[ ! -d "$src_base" ]]; then
    warn_missing "$src_base"
    return 0
  fi

  while IFS= read -r -d '' file; do
    if ! should_copy_backup_file "$file"; then
      continue
    fi
    rel_path="${file#${src_base}/}"
    mkdir -p "$(dirname "$dest_base/$rel_path")"
    cp -f "$file" "$dest_base/$rel_path"
    log "Saved ${dest_base#$SCRIPT_DIR/}/$rel_path"
  done < <(find "$src_base" -type f -print0 | sort -z)
}

log() {
  printf '%s\n' "$1"
}

warn_missing() {
  printf 'Warning: %s not found, skipping.\n' "$1" >&2
}

for src in "${!FILE_BACKUPS[@]}"; do
  dest="${FILE_BACKUPS[$src]}"
  if [[ -f "$src" ]]; then
    mkdir -p "$(dirname "$dest")"
    cp -f "$src" "$dest"
    rel_dest="${dest#$SCRIPT_DIR/}"
    log "Saved ${rel_dest}"
  else
    warn_missing "$src"
  fi
done

copy_tree_backup "$HOME/.config/kitty" "$SCRIPT_DIR/configs/kitty"
copy_tree_backup "$HOME/.local/share/kscreen" "$SCRIPT_DIR/configs/plasma/kscreen"
copy_tree_backup "$HOME/.config/micro/colorschemes" "$SCRIPT_DIR/configs/micro/colorschemes"
copy_tree_backup "$HOME/.config/kate/externaltools" "$SCRIPT_DIR/configs/kate/externaltools"
copy_tree_backup "$HOME/.config/autostart" "$SCRIPT_DIR/configs/desktop/autostart"
copy_tree_backup "$HOME/.config/gtk-3.0" "$SCRIPT_DIR/configs/desktop/gtk-3.0"
copy_tree_backup "$HOME/.config/gtk-4.0" "$SCRIPT_DIR/configs/desktop/gtk-4.0"
copy_tree_backup "$HOME/.local/share/applications" "$SCRIPT_DIR/configs/desktop/applications"
prune_untracked_application_backups

if [[ -f "$SCRIPT_DIR/configs/plasma/config/kdeglobals" ]]; then
  sed -i 's/^BrowserApplication=.*/BrowserApplication=/' "$SCRIPT_DIR/configs/plasma/config/kdeglobals"
fi

if [[ -f "$SCRIPT_DIR/configs/plasma/config/plasma-org.kde.plasma.desktop-appletsrc" ]]; then
  sed -i \
    -e 's#^launchers=.*#launchers=preferred://filemanager,applications:kitty.desktop#' \
    -e 's/^hiddenItems=.*/hiddenItems=org.kde.plasma.clipboard/' \
    "$SCRIPT_DIR/configs/plasma/config/plasma-org.kde.plasma.desktop-appletsrc"
fi

WALLPAPER_DEST_BASE="$SCRIPT_DIR/configs/plasma/wallpapers"
declare -A COPIED_WALLPAPERS=()
wallpaper_sources=(
  "$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"
  "$HOME/.config/kscreenlockerrc"
)

for wallpaper_source in "${wallpaper_sources[@]}"; do
  if [[ ! -f "$wallpaper_source" ]]; then
    warn_missing "$wallpaper_source"
    continue
  fi

  while IFS= read -r wallpaper_path; do
    [[ -z "$wallpaper_path" ]] && continue
    wallpaper_path="${wallpaper_path#file://}"
    if [[ "$wallpaper_path" == ~* ]]; then
      # Expand leading tilde manually
      wallpaper_path="$HOME${wallpaper_path:1}"
    fi
    if [[ ! -f "$wallpaper_path" ]] || [[ -n "${COPIED_WALLPAPERS[$wallpaper_path]:-}" ]]; then
      [[ -f "$wallpaper_path" ]] || warn_missing "$wallpaper_path"
      continue
    fi

    if [[ "$wallpaper_path" == *"/Pictures/Wallpapers/"* ]]; then
      rel_path="${wallpaper_path#*\/Pictures\/Wallpapers\/}"
      rel_path="Pictures/Wallpapers/$rel_path"
    elif [[ "$wallpaper_path" == "$HOME/"* ]]; then
      rel_path="Pictures/Wallpapers/$(basename "$wallpaper_path")"
    else
      rel_path="external/$(basename "$wallpaper_path")"
    fi
    dest="$WALLPAPER_DEST_BASE/$rel_path"
    if [[ "$wallpaper_path" == "$dest" ]]; then
      COPIED_WALLPAPERS["$wallpaper_path"]=1
      continue
    fi
    mkdir -p "$(dirname "$dest")"
    cp -f "$wallpaper_path" "$dest"
    rel_dest="${dest#$SCRIPT_DIR/}"
    log "Saved ${rel_dest}"
    COPIED_WALLPAPERS["$wallpaper_path"]=1
  done < <(sed -nE 's/^(Image|PreviewImage)(\[[^]]*\])?=//p' "$wallpaper_source" | sort -u)
done

log "Backup complete."
