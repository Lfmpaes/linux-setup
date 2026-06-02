#!/usr/bin/env bash
set -euo pipefail

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

  echo "Unable to locate nvm initialization script."
  return 1
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

  read -r -p "$prompt [y/N] " reply
  case "$reply" in
    [Yy]|[Yy][Ee][Ss]) return 0 ;;
    *) return 1 ;;
  esac
}

install_javascript_tooling() {
  echo "Installing Node.js LTS, Bun, Codex, and Claude Code..."

  if ! load_nvm; then
    echo "Skipping JavaScript tooling because nvm could not be loaded."
    return
  fi

  if ! nvm install --lts >/dev/null 2>&1; then
    echo "Failed to install Node.js LTS with nvm."
    return
  fi

  nvm alias default 'lts/*' >/dev/null 2>&1 || true
  nvm use --lts >/dev/null 2>&1 || true

  if ! curl -fsSL https://bun.com/install | bash >/dev/null 2>&1; then
    echo "Failed to install Bun."
  fi

  export PATH="$HOME/.bun/bin:$PATH"

  if ! npm install -g @openai/codex @anthropic-ai/claude-code >/dev/null 2>&1; then
    echo "Failed to install Codex and/or Claude Code."
  fi
}

configure_tailscale_systray() {
  echo "Configuring Tailscale systray..."

  if ! command -v tailscale >/dev/null 2>&1; then
    echo "Skipping Tailscale systray configuration; tailscale command not found."
    return 0
  fi

  tailscale configure systray --enable-startup=systemd >/dev/null 2>&1 ||
    echo "Failed to configure Tailscale systray startup."
  systemctl --user daemon-reload >/dev/null 2>&1 ||
    echo "Failed to reload user systemd units for Tailscale systray."
  systemctl --user enable --now tailscale-systray >/dev/null 2>&1 ||
    echo "Failed to enable/start tailscale-systray user service."
}

configure_google_chrome_launchers() {
  local chrome_flags target source
  local desktop_ids=(
    google-chrome.desktop
    com.google.Chrome.desktop
  )

  chrome_flags="--disable-features=ExtensionManifestV2Unsupported,ExtensionManifestV2Disabled --password-store=basic"

  mkdir -p "$HOME/.local/share/applications"

  for target in "${desktop_ids[@]}"; do
    source="/usr/share/applications/$target"
    target="$HOME/.local/share/applications/$target"

    if [ ! -f "$source" ]; then
      echo "Skipping Chrome launcher override for $(basename "$target"); source desktop file not found."
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

install_optional_windows_fonts() {
  echo "Optional installs:"
  if prompt_yes_no "Install Microsoft Windows fonts (Arial, Times New Roman, etc.) for LibreOffice compatibility?"; then
    if fc-list | grep -qi 'Arial'; then
      echo "Microsoft Windows fonts are already installed."
      return 0
    fi

    echo "Installing Microsoft Windows fonts..."
    if yay -S --needed --noconfirm ttf-ms-win11-auto msty-bin >/dev/null 2>&1; then
      fc-cache -f >/dev/null 2>&1 || true
    else
      echo "Failed to install Microsoft Windows fonts."
    fi
  else
    echo "Skipping Microsoft Windows fonts."
  fi
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

  [ -f "$file" ] || return 0

  sed -E -i \
    -e "s#/home/[^/]+/Pictures/Wallpapers/#$HOME/Pictures/Wallpapers/#g" \
    -e "s#/home/[^/]+/\\.local/share/wallpapers/#$HOME/.local/share/wallpapers/#g" \
    "$file"
}

warn_missing_wallpapers() {
  local file="$1"
  local wallpaper_path

  [ -f "$file" ] || return 0

  while IFS= read -r wallpaper_path; do
    [ -n "$wallpaper_path" ] || continue
    wallpaper_path="${wallpaper_path#file://}"
    [ -f "$wallpaper_path" ] || echo "Warning: Wallpaper asset referenced by $(basename "$file") is missing: $wallpaper_path"
  done < <(sed -nE 's/^(Image|PreviewImage)(\[[^]]*\])?=//p' "$file" | sort -u)
}

# Update system packages quietly to ensure latest base
echo "Updating system packages..."
sudo pacman -Syu --noconfirm >/dev/null 2>&1

# Ensure git is available for AUR operations
if ! command -v git >/dev/null 2>&1; then
  echo "git not found; installing git."
  sudo pacman -S --noconfirm git >/dev/null 2>&1
fi

# Install yay if missing so we can pull AUR packages later
echo "Checking for yay..."
if ! command -v yay >/dev/null 2>&1; then
  echo "Installing yay and prerequisites."
  sudo pacman -S --needed --noconfirm base-devel >/dev/null 2>&1
  workspace="$(mktemp -d)"
  git clone https://aur.archlinux.org/yay.git "$workspace/yay" >/dev/null 2>&1
  (
    cd "$workspace/yay"
    makepkg -si --noconfirm >/dev/null 2>&1
  )
  rm -rf "$workspace"
  echo "yay installation complete."
else
  echo "yay already installed; skipping."
fi

# Install Essential AUR Helper extras
echo "Installing Essential AUR Helper packages..."
yay -S --needed --noconfirm yay-debug >/dev/null 2>&1

# Install System Utilities & Hardware Extras
echo "Installing System Utilities & Hardware Extras..."
sudo pacman -S --needed --noconfirm power-profiles-daemon >/dev/null 2>&1

# Install Services & Platform Tools
echo "Installing Services & Platform Tools..."
sudo pacman -S --needed --noconfirm cronie flatpak docker tailscale >/dev/null 2>&1

# Install Shells & CLI Productivity
echo "Installing Shells & CLI Productivity..."
sudo pacman -S --needed --noconfirm \
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
  unzip >/dev/null 2>&1
yay -S --needed --noconfirm nerdfetch >/dev/null 2>&1

# Install Development & Code Tooling
echo "Installing Development & Code Tooling..."
sudo pacman -S --needed --noconfirm \
  git \
  curl \
  github-cli \
  go \
  python-pip \
  nvm >/dev/null 2>&1
yay -S --needed --noconfirm visual-studio-code-bin cursor-bin >/dev/null 2>&1

install_javascript_tooling

# Configure global Git identity
echo "Configuring Git identity..."
git config --global user.name "Luiz Fernando M. Paes"
git config --global user.email "luiz@lfmpaes.com.br"

# Install Networking & Sharing
echo "Installing Networking & Sharing..."
sudo pacman -S --needed --noconfirm qbittorrent >/dev/null 2>&1
yay -S --needed --noconfirm localsend-bin jdownloader2 >/dev/null 2>&1

# Install Browsers & Web Clients
echo "Installing Browsers & Web Clients..."
yay -S --needed --noconfirm google-chrome zen-browser-bin >/dev/null 2>&1
echo "Configuring Google Chrome launchers..."
configure_google_chrome_launchers

# Install Media, Streaming & Creative Apps
echo "Installing Media, Streaming & Creative Apps..."
sudo pacman -S --needed --noconfirm gimp mpv spotify-player >/dev/null 2>&1
yay -S --needed --noconfirm spotify cider >/dev/null 2>&1

# Install Productivity, Security & Utilities
echo "Installing Productivity, Security & Utilities..."
sudo pacman -S --needed --noconfirm discord >/dev/null 2>&1
yay -S --needed --noconfirm 1password >/dev/null 2>&1

# Install Gaming packages
echo "Installing Gaming packages..."
sudo pacman -S --needed --noconfirm steam >/dev/null 2>&1

# Install Fonts & Appearance
echo "Installing Fonts & Appearance..."
sudo pacman -S --needed --noconfirm \
  noto-fonts-cjk \
  ttf-dejavu \
  ttf-fira-code \
  ttf-jetbrains-mono-nerd \
  ttf-linux-libertine >/dev/null 2>&1

echo "Enabling Tailscale service..."
sudo systemctl enable --now tailscaled >/dev/null 2>&1 || echo "Failed to enable/start tailscaled."
configure_tailscale_systray

# Configure Zsh, Oh My Zsh, and Powerlevel10k
echo "Configuring Zsh environment..."
OH_MY_ZSH_DIR="$HOME/.oh-my-zsh"
if [ ! -d "$OH_MY_ZSH_DIR" ]; then
  git clone https://github.com/ohmyzsh/ohmyzsh.git "$OH_MY_ZSH_DIR" >/dev/null 2>&1
fi

P10K_DIR="$HOME/powerlevel10k"
if [ ! -d "$P10K_DIR" ]; then
  git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$P10K_DIR" >/dev/null 2>&1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
install -Dm644 "$SCRIPT_DIR/configs/zsh/.zshrc" "$HOME/.zshrc"
install -Dm644 "$SCRIPT_DIR/configs/zsh/.p10k.zsh" "$HOME/.p10k.zsh"

# Configure Konsole profiles and settings
echo "Configuring Konsole settings..."
if [ -d "$SCRIPT_DIR/configs/konsole/config" ]; then
  konsole_config_base="$SCRIPT_DIR/configs/konsole/config"
  while IFS= read -r -d '' file; do
    rel_path="${file#${konsole_config_base}/}"
    install -Dm644 "$file" "$HOME/.config/$rel_path"
  done < <(find "$konsole_config_base" -type f -print0)
fi

if [ -d "$SCRIPT_DIR/configs/konsole/profiles" ]; then
  konsole_profiles_base="$SCRIPT_DIR/configs/konsole/profiles"
  while IFS= read -r -d '' file; do
    rel_path="${file#${konsole_profiles_base}/}"
    install -Dm644 "$file" "$HOME/.local/share/konsole/$rel_path"
  done < <(find "$konsole_profiles_base" -type f -print0)
fi

# Configure KDE Plasma desktop environment
echo "Configuring KDE Plasma settings..."
if [ -d "$SCRIPT_DIR/configs/plasma/config" ]; then
  plasma_config_base="$SCRIPT_DIR/configs/plasma/config"
  while IFS= read -r -d '' file; do
    rel_path="${file#${plasma_config_base}/}"
    install -Dm644 "$file" "$HOME/.config/$rel_path"
  done < <(find "$plasma_config_base" -type f -print0)
fi

if [ -d "$SCRIPT_DIR/configs/plasma/wallpapers" ]; then
  copy_wallpapers_to "$SCRIPT_DIR/configs/plasma/wallpapers" "$HOME/Pictures/Wallpapers"
fi

rewrite_plasma_paths "$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"
rewrite_plasma_paths "$HOME/.config/kscreenlockerrc"
warn_missing_wallpapers "$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"
warn_missing_wallpapers "$HOME/.config/kscreenlockerrc"

install_optional_windows_fonts

if command -v plasmashell >/dev/null 2>&1; then
  kquitapp5 plasmashell >/dev/null 2>&1 || true
  (plasmashell --replace >/dev/null 2>&1 & disown)
fi

echo "Done. Reboot recommended."
echo "Remember to log in to your CLI tools after setup: gh, codex, claude."
