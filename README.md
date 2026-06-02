## Linux setup scripts

This repository contains post-install automation and config backup scripts for Linux desktops, currently covering Arch Linux and Kubuntu.

## Scripts

### `install.sh` (Arch Linux)
Installs packages and tools on Arch Linux, configures shell/theme files, applies Konsole/Plasma configs, sets global Git identity, and provisions the JavaScript CLI toolchain.

What it does:
- Updates system packages (`pacman -Syu`)
- Ensures `git` and installs `yay` if missing
- Installs CLI/dev/media/productivity/gaming/fonts packages from `pacman` and AUR
- Offers Microsoft Windows fonts (Arial, Times New Roman, etc.) as an optional final install
- Installs `nvm`, Node.js LTS, Bun, OpenAI Codex, and Claude Code
- Configures global Git identity:
  - `user.name = Luiz Fernando M. Paes`
  - `user.email = luiz@lfmpaes.com.br`
- Installs Oh My Zsh + Powerlevel10k and copies `configs/` files into `$HOME`
- Restarts Plasma shell if available
- Reminds you to sign in to CLI tools such as `gh`, `codex`, and `claude`

Run:

```bash
./install.sh
```

### `install-kubuntu.sh` (Kubuntu)
Installs packages/tools on Kubuntu, configures Zsh and Plasma/Konsole files, sets global Git identity, provisions the JavaScript CLI toolchain, and always logs execution to file.

What it does:
- Installs apt/snap/flatpak/vendor packages for the desktop setup
- Configures Zsh, Konsole, Plasma, Git identity, and JavaScript tooling
- Offers Microsoft Windows fonts (Arial, Times New Roman, etc.) as an optional final install

Options:
- `-v`, `--verbose`: stream full command output to terminal while still logging
- `-h`, `--help`: show help

Run:

```bash
./install-kubuntu.sh
```

Run with verbose mode:

```bash
./install-kubuntu.sh --verbose
```

Logs:
- Every run writes to: `logs/install-kubuntu-YYYYMMDD-HHMMSS.log`
- Latest symlink: `logs/install-kubuntu-latest.log`

### `backup.sh`
Backs up user config files from `$HOME` into the repository under `configs/`.

What it does:
- Copies Zsh, Konsole, and Plasma config files into this repo
- Parses Plasma wallpaper entries and copies referenced wallpapers into `configs/plasma/wallpapers/`
- Warns for files that are missing and continues

Run:

```bash
./backup.sh
```

## Notes

- Run scripts from this repository root.
- Scripts use `sudo` where required.
- On fresh clones, ensure scripts are executable:

```bash
chmod +x install.sh install-kubuntu.sh backup.sh
```

- Additional reference: `package-reinstall-checklist.md`
