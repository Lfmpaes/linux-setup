#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERBOSE=0
LOG_FILE=""
DISTRO_FAMILY=""

exec 3>&1 4>&2

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

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
  LOG_FILE="$log_dir/install-${DISTRO_FAMILY}-${timestamp}.log"
  : >"$LOG_FILE"
  ln -sfn "$(basename "$LOG_FILE")" "$log_dir/install-${DISTRO_FAMILY}-latest.log"

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

die() {
  printf 'ERROR: %s\n' "$*" >&2
  printf 'ERROR: %s\n' "$*" >&4
  exit 1
}

ensure_cmd() {
  local cmd="$1"
  local hint="${2:-}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    die "Required command not found: $cmd${hint:+ ($hint)}"
  fi
}

detect_distro_family() {
  local distro_id distro_like

  [ -r /etc/os-release ] || die "/etc/os-release not found; unable to detect distribution."
  # shellcheck source=/dev/null
  . /etc/os-release

  distro_id="${ID:-}"
  distro_like="${ID_LIKE:-}"

  case "$distro_id" in
    arch)
      DISTRO_FAMILY="arch"
      return 0
      ;;
    ubuntu)
      DISTRO_FAMILY="ubuntu"
      return 0
      ;;
  esac

  case " $distro_like " in
    *" arch "*)
      DISTRO_FAMILY="arch"
      return 0
      ;;
    *" ubuntu "*)
      DISTRO_FAMILY="ubuntu"
      return 0
      ;;
  esac

  die "Unsupported distribution. This installer only supports Arch and Ubuntu."
}

require_kde_plasma() {
  local desktop_markers

  desktop_markers="$(
    printf '%s\n' \
      "${XDG_CURRENT_DESKTOP:-}" \
      "${XDG_SESSION_DESKTOP:-}" \
      "${DESKTOP_SESSION:-}" \
      "${KDE_FULL_SESSION:-}" \
      "${KDE_SESSION_VERSION:-}"
  )"

  if printf '%s' "$desktop_markers" | grep -Eqi 'kde|plasma'; then
    return 0
  fi

  die "KDE Plasma was not detected in the current session. This installer only runs on KDE Plasma."
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

install_google_chrome_deb() {
  if command -v google-chrome >/dev/null 2>&1; then
    return 0
  fi

  local tmp_deb
  tmp_deb="$(mktemp --suffix=.deb)"

  if wget -qO "$tmp_deb" "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"; then
    sudo dpkg -i "$tmp_deb" || sudo apt-get install -fy
  else
    warn "Failed to download Google Chrome .deb"
  fi

  rm -f "$tmp_deb"
}

install_1password_deb() {
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

install_nvm_if_needed() {
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
  case "$DISTRO_FAMILY" in
    arch)
      sudo pacman -S --needed --noconfirm sox flac mp3val lame curl git || warn "Failed to install Smoked Salmon dependencies"
      ;;
    ubuntu)
      install_apt_packages sox flac mp3val lame curl git
      ;;
  esac

  if ! command -v uv >/dev/null 2>&1; then
    log "uv not found; installing uv for Smoked Salmon..."
    if ! curl -fsSL https://astral.sh/uv/install.sh | sh; then
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

install_tailscale_deb() {
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

configure_google_chrome_launchers() {
  local chrome_flags desktop_id source target

  chrome_flags="--disable-features=ExtensionManifestV2Unsupported,ExtensionManifestV2Disabled --password-store=basic"

  mkdir -p "$HOME/.local/share/applications"

  for desktop_id in google-chrome.desktop com.google.Chrome.desktop; do
    source="/usr/share/applications/$desktop_id"
    target="$HOME/.local/share/applications/$desktop_id"

    if [ ! -f "$source" ]; then
      warn "Skipping Chrome launcher override for $desktop_id; source desktop file not found"
      continue
    fi

    install -Dm644 "$source" "$target"
    sed -i \
      -e "s#^Exec=/usr/bin/google-chrome-stable %U#Exec=/usr/bin/google-chrome-stable ${chrome_flags} %U#" \
      -e "s#^Exec=/usr/bin/google-chrome-stable\$#Exec=/usr/bin/google-chrome-stable ${chrome_flags}#" \
      -e "s#^Exec=/usr/bin/google-chrome-stable --incognito#Exec=/usr/bin/google-chrome-stable ${chrome_flags} --incognito#" \
      "$target"
  done
}

install_optional_windows_fonts_arch() {
  log "Optional installs:"
  if prompt_yes_no "Install Microsoft Windows fonts (Arial, Times New Roman, etc.) for LibreOffice compatibility?"; then
    if fc-list | grep -qi 'Arial'; then
      log "Microsoft Windows fonts are already installed."
      return 0
    fi

    log "Installing Microsoft Windows fonts..."
    if yay -S --needed --noconfirm ttf-ms-win11-auto; then
      fc-cache -f || true
    else
      warn "Failed to install Microsoft Windows fonts"
    fi
  else
    log "Skipping Microsoft Windows fonts."
  fi
}

install_optional_windows_fonts_ubuntu() {
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

  if [ ! -d "$oh_my_zsh_dir" ]; then
    git clone https://github.com/ohmyzsh/ohmyzsh.git "$oh_my_zsh_dir" || warn "Failed to clone oh-my-zsh"
  fi

  if [ ! -d "$p10k_dir" ]; then
    git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$p10k_dir" || warn "Failed to clone powerlevel10k"
  fi

  install -Dm644 "$SCRIPT_DIR/configs/zsh/.zshrc" "$HOME/.zshrc"
  install -Dm644 "$SCRIPT_DIR/configs/zsh/.p10k.zsh" "$HOME/.p10k.zsh"
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

apply_kde_configs() {
  log "Applying Kitty, Konsole, and Plasma configs from repository..."
  copy_tree_to "$SCRIPT_DIR/configs/kitty" "$HOME/.config/kitty"
  copy_tree_to "$SCRIPT_DIR/configs/konsole/config" "$HOME/.config"
  copy_tree_to "$SCRIPT_DIR/configs/konsole/profiles" "$HOME/.local/share/konsole"
  copy_tree_to "$SCRIPT_DIR/configs/plasma/config" "$HOME/.config"
  copy_wallpapers_to "$SCRIPT_DIR/configs/plasma/wallpapers" "$HOME/Pictures/Wallpapers"
  rewrite_plasma_paths "$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"
  rewrite_plasma_paths "$HOME/.config/kscreenlockerrc"
  normalize_plasma_wallpaper_paths "$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"
  normalize_plasma_wallpaper_paths "$HOME/.config/kscreenlockerrc"
  restore_kde_window_shortcuts
  warn_missing_wallpapers "$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"
  warn_missing_wallpapers "$HOME/.config/kscreenlockerrc"
  restart_kde_shortcuts
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

run_arch_install() {
  local workspace

  ensure_cmd sudo
  ensure_cmd pacman
  ensure_cmd git
  ensure_cmd curl

  log "Updating system packages..."
  sudo pacman -Sy --needed --noconfirm archlinux-keyring cachyos-keyring || warn "Keyring refresh failed; continuing."
  sudo pacman -Syu --noconfirm || warn "System upgrade failed; continuing with existing packages."

  if ! command -v git >/dev/null 2>&1; then
    log "git not found; installing git."
    sudo pacman -S --noconfirm git
  fi

  log "Checking for yay..."
  if ! command -v yay >/dev/null 2>&1; then
    log "Installing yay and prerequisites."
    sudo pacman -S --needed --noconfirm base-devel
    workspace="$(mktemp -d)"
    git clone https://aur.archlinux.org/yay.git "$workspace/yay"
    (
      cd "$workspace/yay"
      makepkg -si --noconfirm
    )
    rm -rf "$workspace"
    log "yay installation complete."
  else
    log "yay already installed; skipping."
  fi

  log "Installing Essential AUR Helper packages..."
  yay -S --needed --noconfirm yay-debug

  log "Installing system utilities and hardware extras..."
  sudo pacman -S --needed --noconfirm power-profiles-daemon

  log "Installing services and platform tools..."
  sudo pacman -S --needed --noconfirm cronie flatpak docker tailscale

  log "Installing shells and CLI productivity tools..."
  sudo pacman -S --needed --noconfirm \
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
    wget \
    unrar \
    unzip
  yay -S --needed --noconfirm nerdfetch

  log "Installing development and code tooling..."
  sudo pacman -S --needed --noconfirm \
    git \
    curl \
    github-cli \
    go \
    python-pip \
    nvm
  yay -S --needed --noconfirm visual-studio-code-bin cursor-bin
  install_node_lts_with_nvm
  install_javascript_tooling
  install_smoked_salmon

  log "Configuring Git identity..."
  configure_git_identity

  log "Installing networking and sharing tools..."
  sudo pacman -S --needed --noconfirm qbittorrent
  yay -S --needed --noconfirm localsend-bin jdownloader2

  log "Installing browsers and web clients..."
  yay -S --needed --noconfirm google-chrome zen-browser-bin
  configure_google_chrome_launchers

  log "Installing media, streaming, and creative apps..."
  sudo pacman -S --needed --noconfirm mpv
  yay -S --needed --noconfirm spotify

  log "Installing productivity, security, and utilities..."
  sudo pacman -S --needed --noconfirm discord
  yay -S --needed --noconfirm 1password

  log "Installing gaming packages..."
  sudo pacman -S --needed --noconfirm steam

  log "Installing fonts and appearance packages..."
  sudo pacman -S --needed --noconfirm \
    noto-fonts-cjk \
    ttf-dejavu \
    ttf-fira-code \
    ttf-jetbrains-mono-nerd \
    ttf-linux-libertine

  log "Enabling Docker service..."
  sudo systemctl enable --now docker || warn "Failed to enable/start docker."
  sudo usermod -aG docker "$USER" || warn "Failed to add $USER to docker group."

  log "Enabling Tailscale service..."
  sudo systemctl enable --now tailscaled || warn "Failed to enable/start tailscaled."
  configure_tailscale_systray

  log "Configuring Zsh and shell prompt..."
  configure_zsh

  apply_kde_configs
  install_optional_windows_fonts_arch
  restart_plasma_shell

  log "Done. Reboot recommended."
  log "If this is your first Docker setup, log out and log back in for group changes to apply."
  log "Remember to log in to your CLI tools after setup: gh, codex."
}

run_ubuntu_install() {
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
  install_snap cursor --classic || true

  log "Installing Flatpak applications..."
  install_flatpak org.localsend.localsend_app
  install_flatpak org.jdownloader.JDownloader
  install_flatpak app.zen_browser.zen
  install_flatpak com.spotify.Client
  install_flatpak sh.cider.Cider

  log "Installing vendor packages..."
  install_google_chrome_deb
  configure_google_chrome_launchers
  install_1password_deb
  install_tailscale_deb
  install_nvm_if_needed
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

  apply_kde_configs
  install_optional_windows_fonts_ubuntu
  restart_plasma_shell

  log "Done. Reboot recommended."
  log "If this is your first Docker setup, log out and log back in for group changes to apply."
  log "Remember to log in to your CLI tools after setup: gh, codex."
}

main() {
  parse_args "$@"
  detect_distro_family
  require_kde_plasma
  setup_logging
  log "Detected distro family: $DISTRO_FAMILY"
  log "Logging to: $LOG_FILE"

  case "$DISTRO_FAMILY" in
    arch)
      run_arch_install
      ;;
    ubuntu)
      run_ubuntu_install
      ;;
    *)
      die "Unsupported distribution. This installer only supports Arch and Ubuntu."
      ;;
  esac
}

main "$@"
