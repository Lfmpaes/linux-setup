#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERBOSE=0
LOG_FILE=""

usage() {
  cat <<'EOF'
Usage: ./install-kubuntu.sh [options]

Options:
  -v, --verbose  Print command output live while still logging to file
  -h, --help     Show this help
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -v|--verbose)
        VERBOSE=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        printf 'Unknown option: %s\n\n' "$1" >&2
        usage >&2
        exit 1
        ;;
    esac
    shift
  done
}

setup_logging() {
  local log_dir timestamp

  log_dir="$SCRIPT_DIR/logs"
  timestamp="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$log_dir"
  LOG_FILE="$log_dir/install-kubuntu-${timestamp}.log"
  : >"$LOG_FILE"
  ln -sfn "$(basename "$LOG_FILE")" "$log_dir/install-kubuntu-latest.log"

  exec 3>&1 4>&2
  if [ "$VERBOSE" -eq 1 ]; then
    exec > >(tee -a "$LOG_FILE") 2>&1
  else
    exec >>"$LOG_FILE" 2>&1
  fi
}

log() {
  printf '%s\n' "$*"
  if [ "$VERBOSE" -eq 0 ]; then
    printf '%s\n' "$*" >&3
  fi
}

warn() {
  printf 'WARNING: %s\n' "$*" >&2
  if [ "$VERBOSE" -eq 0 ]; then
    printf 'WARNING: %s\n' "$*" >&4
  fi
}

prompt_yes_no() {
  local prompt="$1"
  local default="${2:-N}"
  local reply

  if [ ! -t 0 ]; then
    case "$default" in
      [Yy]*) return 0 ;;
      *) return 1 ;;
    esac
  fi

  printf '%s [y/N] ' "$prompt" >&3
  read -r reply
  case "$reply" in
    [Yy]|[Yy][Ee][Ss]) return 0 ;;
    *) return 1 ;;
  esac
}

ensure_cmd() {
  local cmd="$1"
  local hint="${2:-}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    warn "Required command not found: $cmd${hint:+ ($hint)}"
    exit 1
  fi
}

install_apt_packages() {
  local pkg
  local failed=()

  for pkg in "$@"; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
      continue
    fi

    if ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"; then
      failed+=("$pkg")
    fi
  done

  if [ "${#failed[@]}" -gt 0 ]; then
    warn "Failed apt packages: ${failed[*]}"
  fi
}

install_snap() {
  local pkg="$1"
  shift

  if snap list "$pkg" >/dev/null 2>&1; then
    return 0
  fi

  if ! sudo snap install "$pkg" "$@"; then
    warn "Failed to install snap package: $pkg"
  fi
}

install_flatpak() {
  local app_id="$1"

  if flatpak info "$app_id" >/dev/null 2>&1; then
    return 0
  fi

  if ! flatpak install -y flathub "$app_id"; then
    warn "Failed to install flatpak app: $app_id"
  fi
}

install_1password() {
  if command -v 1password >/dev/null 2>&1 || command -v op >/dev/null 2>&1; then
    return 0
  fi

  sudo install -d -m 0755 /etc/apt/keyrings
  if curl -fsSL https://downloads.1password.com/linux/keys/1password.asc | \
    sudo gpg --dearmor -o /etc/apt/keyrings/1password-archive-keyring.gpg; then
    sudo chmod go+r /etc/apt/keyrings/1password-archive-keyring.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/$(dpkg --print-architecture) stable main" |
      sudo tee /etc/apt/sources.list.d/1password.list

    sudo mkdir -p /etc/debsig/policies/AC2D62742012EA22/
    curl -fsSL https://downloads.1password.com/linux/debian/debsig/1password.pol |
      sudo tee /etc/debsig/policies/AC2D62742012EA22/1password.pol

    sudo mkdir -p /usr/share/debsig/keyrings/AC2D62742012EA22
    curl -fsSL https://downloads.1password.com/linux/keys/1password.asc |
      sudo gpg --dearmor -o /usr/share/debsig/keyrings/AC2D62742012EA22/debsig.gpg

    sudo apt-get update -y
    install_apt_packages 1password
  else
    warn "Failed to configure 1Password repository"
  fi
}

configure_1password_allowed_browsers() {
  local allowed_browsers_file

  allowed_browsers_file="/etc/1password/custom_allowed_browsers"

  if ! sudo install -d -m 0755 /etc/1password; then
    warn "Failed to create /etc/1password"
    return 0
  fi

  if ! printf 'zen-bin\n' | sudo tee "$allowed_browsers_file" >/dev/null; then
    warn "Failed to write $allowed_browsers_file"
  fi
}

install_nvm() {
  if [ -d "$HOME/.nvm" ]; then
    return 0
  fi

  if ! curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash; then
    warn "Failed to install nvm"
  fi
}

load_nvm() {
  local candidate

  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

  for candidate in \
    "$NVM_DIR/nvm.sh" \
    "/usr/share/nvm/init-nvm.sh" \
    "/usr/share/nvm/nvm.sh"
  do
    if [ -s "$candidate" ]; then
      # shellcheck source=/dev/null
      . "$candidate"
      return 0
    fi
  done

  warn "Unable to locate nvm initialization script"
  return 1
}

install_javascript_tooling() {
  if ! load_nvm; then
    warn "Skipping JavaScript tooling because nvm could not be loaded"
    return 0
  fi

  if ! curl -fsSL https://bun.com/install | bash; then
    warn "Failed to install Bun"
  fi

  export PATH="$HOME/.bun/bin:$PATH"

  if ! npm install -g @openai/codex; then
    warn "Failed to install Codex"
  fi
}

install_smoked_salmon() {
  if command -v salmon >/dev/null 2>&1; then
    return 0
  fi

  log "Installing Smoked Salmon dependencies..."
  install_apt_packages sox flac mp3val lame curl git

  if ! command -v uv >/dev/null 2>&1; then
    log "uv not found; installing uv for Smoked Salmon..."
    if ! curl -fsSL https://astral.sh/uv/install.sh | sh >/dev/null 2>&1; then
      warn "Failed to install uv"
      return 0
    fi
    export PATH="$HOME/.local/bin:$PATH"
  fi

  if ! uv tool install git+https://github.com/smokin-salmon/smoked-salmon; then
    warn "Failed to install Smoked Salmon"
  fi
}

install_node_lts_with_nvm() {
  log "Installing Node.js LTS via nvm..."

  if ! load_nvm; then
    warn "Skipping Node.js LTS install because nvm could not be loaded"
    return 0
  fi

  if command -v node >/dev/null 2>&1; then
    log "Node.js already installed; skipping nvm-managed Node install."
    return 0
  fi

  set +u
  if ! nvm install --lts; then
    set -u
    warn "Failed to install Node.js LTS with nvm"
    return 0
  fi

  nvm alias default 'lts/*' || true
  nvm use --lts || true
  set -u
}

install_tailscale() {
  if command -v tailscale >/dev/null 2>&1; then
    return 0
  fi

  if ! curl -fsSL https://tailscale.com/install.sh | sh; then
    warn "Failed to install Tailscale"
  fi
}

configure_tailscale_systray() {
  if ! command -v tailscale >/dev/null 2>&1; then
    warn "Skipping Tailscale systray configuration; tailscale command not found"
    return 0
  fi

  tailscale configure systray --enable-startup=systemd ||
    warn "Failed to configure Tailscale systray startup"
  systemctl --user daemon-reload ||
    warn "Failed to reload user systemd units for Tailscale systray"
  systemctl --user enable --now tailscale-systray ||
    warn "Failed to enable/start tailscale-systray user service"
}

install_jetbrains_nerd_font() {
  if fc-list | grep -qi 'JetBrainsMono Nerd Font Mono'; then
    return 0
  fi

  local font_dir="$HOME/.local/share/fonts/JetBrainsMonoNerd"
  local tmp_dir archive

  tmp_dir="$(mktemp -d)"
  archive="$tmp_dir/JetBrainsMono.zip"

  if ! curl -fsSL -o "$archive" "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.zip"; then
    warn "Failed to download JetBrainsMono Nerd Font"
    rm -rf "$tmp_dir"
    return 0
  fi

  mkdir -p "$font_dir"
  if ! unzip -oq "$archive" -d "$font_dir"; then
    warn "Failed to extract JetBrainsMono Nerd Font"
    rm -rf "$tmp_dir"
    return 0
  fi

  rm -rf "$tmp_dir"
  fc-cache -f "$font_dir" || warn "Failed to refresh font cache for $font_dir"
}

install_optional_windows_fonts() {
  log "Optional installs:"
  if prompt_yes_no "Install Microsoft Windows fonts (Arial, Times New Roman, etc.) for LibreOffice compatibility?"; then
    if fc-list | grep -qi 'Arial'; then
      log "Microsoft Windows fonts are already installed."
      return 0
    fi

    if [ ! -t 0 ]; then
      warn "Microsoft Windows fonts require interactive EULA acceptance; rerun this step in a terminal."
      return 0
    fi

    log "Installing Microsoft Windows fonts..."
    if ! sudo apt-get install --reinstall ttf-mscorefonts-installer; then
      warn "Failed to install Microsoft Windows fonts"
      return 0
    fi
    fc-cache -f || warn "Failed to refresh font cache"
  else
    log "Skipping Microsoft Windows fonts."
  fi
}

configure_zsh() {
  local oh_my_zsh_dir="$HOME/.oh-my-zsh"
  local p10k_dir="$HOME/powerlevel10k"
  local current_shell zsh_path

  if [ ! -d "$oh_my_zsh_dir" ]; then
    git clone https://github.com/ohmyzsh/ohmyzsh.git "$oh_my_zsh_dir" || warn "Failed to clone oh-my-zsh"
  fi

  if [ ! -d "$p10k_dir" ]; then
    git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$p10k_dir" || warn "Failed to clone powerlevel10k"
  fi

  install -Dm644 "$SCRIPT_DIR/configs/zsh/.zshrc" "$HOME/.zshrc"
  install -Dm644 "$SCRIPT_DIR/configs/zsh/.p10k.zsh" "$HOME/.p10k.zsh"

  zsh_path="$(command -v zsh)"
  current_shell="$(getent passwd "$USER" | awk -F: '{print $7}')"
  if [ "$current_shell" = "$zsh_path" ]; then
    log "Zsh is already the default shell."
  elif sudo chsh -s "$zsh_path" "$USER"; then
    log "Set Zsh as the default shell. Log out and back in for the change to take effect."
  else
    warn "Could not set Zsh as the default shell"
  fi
}

configure_git_identity() {
  git config --global user.name "Luiz Fernando M. Paes"
  git config --global user.email "luiz@lfmpaes.com.br"
}

install_smoked_salmon_config() {
  local source="$SCRIPT_DIR/configs/smoked-salmon/config.toml"
  local target="$HOME/.config/smoked-salmon/config.toml"

  [ -f "$source" ] || return 0
  install -Dm644 "$source" "$target"
}

copy_tree_to() {
  local source_base="$1"
  local target_base="$2"
  local file rel_path

  [ -d "$source_base" ] || return 0

  while IFS= read -r -d '' file; do
    rel_path="${file#${source_base}/}"
    install -Dm644 "$file" "$target_base/$rel_path"
  done < <(find "$source_base" -type f -print0)
}

copy_wallpapers_to() {
  local source_base="$1"
  local target_base="$2"
  local file rel_path

  [ -d "$source_base" ] || return 0

  while IFS= read -r -d '' file; do
    rel_path="${file#${source_base}/}"
    rel_path="${rel_path#Pictures/Wallpapers/}"
    install -Dm644 "$file" "$target_base/$rel_path"
  done < <(find "$source_base" -type f -print0)
}

rewrite_plasma_paths() {
  local file="$1"
  local repo_wallpaper_base="$SCRIPT_DIR/configs/plasma/wallpapers"
  local home_wallpaper_base="$HOME"

  [ -f "$file" ] || return 0

  sed -E -i \
    -e "s#${repo_wallpaper_base}/#${home_wallpaper_base}/#g" \
    -e "s#/home/[^/]+/Pictures/Wallpapers/#$HOME/Pictures/Wallpapers/#g" \
    -e "s#/home/[^/]+/\\.local/share/wallpapers/#$HOME/.local/share/wallpapers/#g" \
    "$file"
}

normalize_plasma_wallpaper_paths() {
  local file="$1"

  [ -f "$file" ] || return 0

  sed -E -i \
    -e "s#${HOME}/Pictures/Wallpapers/Pictures/Wallpapers/#${HOME}/Pictures/Wallpapers/#g" \
    -e "s#${HOME}/\\.local/share/wallpapers/\\.local/share/wallpapers/#${HOME}/.local/share/wallpapers/#g" \
    "$file"
}

warn_missing_wallpapers() {
  local file="$1"
  local wallpaper_path

  [ -f "$file" ] || return 0

  while IFS= read -r wallpaper_path; do
    [ -n "$wallpaper_path" ] || continue
    wallpaper_path="${wallpaper_path#file://}"
    [ -f "$wallpaper_path" ] || warn "Wallpaper asset referenced by $(basename "$file") is missing: $wallpaper_path"
  done < <(sed -nE 's/^(Image|PreviewImage)(\[[^]]*\])?=//p' "$file" | sort -u)
}

restore_kde_window_shortcuts() {
  local file="$HOME/.config/kglobalshortcutsrc"

  [ -f "$file" ] || return 0

  perl -0pi -e '
    s/^Window Maximize=.*$/Window Maximize=Meta+Up,Meta+PgUp,Maximise Window/m;
    s/^Window Move Center=.*$/Window Move Center=Meta+Shift+C,,Move Window to the Centre/m;
  ' "$file"
}

restart_kde_shortcuts() {
  local daemon_cmd daemon_name

  for daemon_cmd in kglobalaccel6 kglobalaccel5; do
    if command -v "$daemon_cmd" >/dev/null 2>&1; then
      daemon_name="$daemon_cmd"
      break
    fi
  done

  [ -n "${daemon_name:-}" ] || return 0

  if command -v "kquitapp${daemon_name#kglobalaccel}" >/dev/null 2>&1; then
    "kquitapp${daemon_name#kglobalaccel}" "$daemon_name" || true
  else
    pkill -x "$daemon_name" || true
  fi

  (nohup "$daemon_name" --replace >/dev/null 2>&1 &)
}

detect_zen_browser_desktop_id() {
  local desktop_id

  for desktop_id in \
    app.zen_browser.zen.desktop \
    zen-browser.desktop \
    zen.desktop
  do
    if [ -f "$HOME/.local/share/applications/$desktop_id" ] || \
      [ -f "$HOME/.local/share/flatpak/exports/share/applications/$desktop_id" ] || \
      [ -f "/var/lib/flatpak/exports/share/applications/$desktop_id" ] || \
      [ -f "/usr/share/applications/$desktop_id" ]; then
      printf '%s\n' "$desktop_id"
      return 0
    fi
  done

  return 1
}

configure_default_browser() {
  local browser_desktop_id kdeglobals_file plasma_file mimeapps_file

  browser_desktop_id="$(detect_zen_browser_desktop_id || true)"
  if [ -z "$browser_desktop_id" ]; then
    warn "Zen Browser desktop entry not found; skipping default browser configuration"
    return 0
  fi

  kdeglobals_file="$HOME/.config/kdeglobals"
  plasma_file="$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"
  mimeapps_file="$HOME/.local/share/applications/mimeapps.list"

  rm -f \
    "$HOME/.local/share/applications/google-chrome.desktop" \
    "$HOME/.local/share/applications/com.google.Chrome.desktop"

  if [ -f "$kdeglobals_file" ]; then
    sed -i "s/^BrowserApplication=.*/BrowserApplication=$browser_desktop_id/" "$kdeglobals_file"
  fi

  if [ -f "$plasma_file" ]; then
    sed -i \
      -e "s#^launchers=.*#launchers=applications:${browser_desktop_id},preferred://filemanager,applications:kitty.desktop#" \
      -e 's/^hiddenItems=chrome_status_icon_1,org\.kde\.plasma\.clipboard$/hiddenItems=org.kde.plasma.clipboard/' \
      "$plasma_file"
  fi

  mkdir -p "$(dirname "$mimeapps_file")"
  cat >"$mimeapps_file" <<EOF
[Default Applications]
application/xhtml+xml=$browser_desktop_id
text/html=$browser_desktop_id
x-scheme-handler/about=$browser_desktop_id
x-scheme-handler/http=$browser_desktop_id
x-scheme-handler/https=$browser_desktop_id
x-scheme-handler/unknown=$browser_desktop_id

[Added Associations]
application/xhtml+xml=$browser_desktop_id;
text/html=$browser_desktop_id;
x-scheme-handler/about=$browser_desktop_id;
x-scheme-handler/http=$browser_desktop_id;
x-scheme-handler/https=$browser_desktop_id;
x-scheme-handler/unknown=$browser_desktop_id;
EOF

  if command -v xdg-settings >/dev/null 2>&1; then
    xdg-settings set default-web-browser "$browser_desktop_id" || warn "Failed to set default browser with xdg-settings"
  fi

  if command -v xdg-mime >/dev/null 2>&1; then
    xdg-mime default "$browser_desktop_id" x-scheme-handler/http || warn "Failed to set HTTP handler with xdg-mime"
    xdg-mime default "$browser_desktop_id" x-scheme-handler/https || warn "Failed to set HTTPS handler with xdg-mime"
    xdg-mime default "$browser_desktop_id" text/html || warn "Failed to set HTML handler with xdg-mime"
    xdg-mime default "$browser_desktop_id" application/xhtml+xml || warn "Failed to set XHTML handler with xdg-mime"
  fi
}

restart_plasma_shell() {
  if ! command -v plasmashell >/dev/null 2>&1; then
    return 0
  fi

  if command -v kquitapp5 >/dev/null 2>&1; then
    kquitapp5 plasmashell || true
  else
    pkill -x plasmashell || true
  fi

  (nohup plasmashell --replace &)
}

main() {
  parse_args "$@"
  setup_logging
  log "Logging to: $LOG_FILE"

  ensure_cmd sudo
  ensure_cmd apt-get
  ensure_cmd curl
  ensure_cmd wget
  ensure_cmd git

  log "Bootstrapping apt helpers..."
  sudo apt-get update -y
  install_apt_packages software-properties-common ca-certificates gnupg apt-transport-https

  log "Enabling Ubuntu repositories (universe/restricted/multiverse)..."
  sudo add-apt-repository -y universe || true
  sudo add-apt-repository -y restricted || true
  sudo add-apt-repository -y multiverse || true

  log "Updating apt metadata..."
  sudo apt-get update -y
  sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

  log "Installing base tools and services..."
  install_apt_packages \
    flatpak \
    plasma-discover-backend-flatpak \
    power-profiles-daemon \
    cron \
    docker.io \
    zsh \
    kitty \
    micro \
    neovim \
    vim \
    eza \
    yazi \
    btop \
    htop \
    fastfetch \
    tldr \
    wget \
    unrar \
    unzip \
    git \
    gh \
    golang-go \
    python3-pip \
    qbittorrent \
    mpv \
    steam-installer \
    fonts-noto-cjk \
    fonts-dejavu \
    fonts-firacode \
    fonts-jetbrains-mono \
    fonts-linuxlibertine

  log "Enabling Docker service..."
  sudo systemctl enable --now docker || warn "Could not enable docker service"
  sudo usermod -aG docker "$USER" || warn "Could not add $USER to docker group"

  log "Configuring Flatpak (Flathub)..."
  sudo flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

  log "Installing snap packages..."
  install_snap code --classic
  install_snap discord

  # Cursor snap availability can vary by channel/account.
  install_snap cursor --classic || true

  log "Installing Flatpak applications..."
  install_flatpak org.localsend.localsend_app
  install_flatpak org.jdownloader.JDownloader
  install_flatpak app.zen_browser.zen
  install_flatpak com.spotify.Client
  install_flatpak sh.cider.Cider

  log "Installing vendor packages..."
  install_1password
  configure_1password_allowed_browsers
  install_tailscale
  install_nvm
  install_node_lts_with_nvm
  install_javascript_tooling
  install_smoked_salmon
  install_smoked_salmon_config

  log "Ensuring Nerd Font for Powerlevel10k..."
  install_jetbrains_nerd_font

  log "Enabling Tailscale service..."
  sudo systemctl enable --now tailscaled || warn "Could not enable tailscaled service"
  configure_tailscale_systray

  log "Configuring Zsh and shell prompt..."
  configure_zsh

  log "Configuring Git identity..."
  configure_git_identity

  log "Applying shell, editor, desktop, and Plasma configs from repository..."
  [ ! -f "$SCRIPT_DIR/configs/bash/.bashrc" ] || install -Dm644 "$SCRIPT_DIR/configs/bash/.bashrc" "$HOME/.bashrc"
  [ ! -f "$SCRIPT_DIR/configs/bash/.bash_profile" ] || install -Dm644 "$SCRIPT_DIR/configs/bash/.bash_profile" "$HOME/.bash_profile"
  copy_tree_to "$SCRIPT_DIR/configs/micro" "$HOME/.config/micro"
  copy_tree_to "$SCRIPT_DIR/configs/kate/externaltools" "$HOME/.config/kate/externaltools"
  copy_tree_to "$SCRIPT_DIR/configs/desktop/autostart" "$HOME/.config/autostart"
  copy_tree_to "$SCRIPT_DIR/configs/desktop/gtk-3.0" "$HOME/.config/gtk-3.0"
  copy_tree_to "$SCRIPT_DIR/configs/desktop/gtk-4.0" "$HOME/.config/gtk-4.0"
  copy_tree_to "$SCRIPT_DIR/configs/desktop/applications" "$HOME/.local/share/applications"
  copy_tree_to "$SCRIPT_DIR/configs/kitty" "$HOME/.config/kitty"
  copy_tree_to "$SCRIPT_DIR/configs/konsole/config" "$HOME/.config"
  copy_tree_to "$SCRIPT_DIR/configs/konsole/profiles" "$HOME/.local/share/konsole"
  copy_tree_to "$SCRIPT_DIR/configs/plasma/config" "$HOME/.config"
  copy_tree_to "$SCRIPT_DIR/configs/plasma/kscreen" "$HOME/.local/share/kscreen"
  copy_wallpapers_to "$SCRIPT_DIR/configs/plasma/wallpapers" "$HOME/Pictures/Wallpapers"
  rewrite_plasma_paths "$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"
  rewrite_plasma_paths "$HOME/.config/kscreenlockerrc"
  normalize_plasma_wallpaper_paths "$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"
  normalize_plasma_wallpaper_paths "$HOME/.config/kscreenlockerrc"
  restore_kde_window_shortcuts
  warn_missing_wallpapers "$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"
  warn_missing_wallpapers "$HOME/.config/kscreenlockerrc"
  restart_kde_shortcuts
  configure_default_browser

  install_optional_windows_fonts

  restart_plasma_shell

  log "Done. Reboot recommended."
  log "If this is your first Docker setup, log out and log back in for group changes to apply."
  log "Remember to log in to your CLI tools after setup: gh, codex, claude."
}

main "$@"
