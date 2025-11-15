#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

USERNAME="$(whoami)"
echog(){ printf "\n==> %s\n" "$*"; }
echow(){ printf "\nWARN: %s\n" "$*"; }
echof(){ printf "\nERROR: %s\n" "$*"; exit 1; }

if [[ $EUID -eq 0 ]]; then
    echof "Run this script as your NORMAL USER, not root."
fi

###############################################################
# 1. SYSTEM UPDATE
###############################################################
echog "Updating system..."
sudo pacman -Syu --noconfirm

###############################################################
# 2. ZRAM + SWAPFILE
###############################################################
echog "Installing zram-generator..."
sudo pacman -S --noconfirm --needed zram-generator

echog "Writing zram generator config (100% of RAM)..."
sudo tee /etc/systemd/zram-generator.conf >/dev/null <<'EOF'
[zram0]
zram-size = ram
compression-algorithm = zstd
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now systemd-zram-setup@zram0.service || true

echog "Setting swappiness to 15..."
sudo tee /etc/sysctl.d/99-swappiness.conf >/dev/null <<EOF
vm.swappiness=15
EOF

###############################################################
# 3. CORE APPLICATIONS
###############################################################
echog "Installing core applications..."
sudo pacman -S --noconfirm --needed \
    firefox flatpak kitty nautilus

echog "Adding Flathub..."
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true

###############################################################
# 4. HYPRLAND + PORTALS
###############################################################
echog "Installing Hyprland and required Wayland utilities..."
sudo pacman -S --noconfirm --needed \
    hyprland \
    xdg-desktop-portal-hyprland \
    xdg-desktop-portal \
    wl-clipboard grim slurp \
    polkit-kde-agent

###############################################################
# 5. DISPLAY MANAGER: LY
###############################################################
echog "Installing Ly display manager..."
sudo pacman -S --noconfirm --needed ly
sudo systemctl enable ly.service

###############################################################
# 6. AUTO-START HYPRLAND AFTER LOGIN (WITH LY)
###############################################################
echog "Configuring auto-start of Hyprland after login..."

if ! grep -q "exec Hyprland" "$HOME/.zprofile" 2>/dev/null; then
cat >> "$HOME/.zprofile" <<'EOF'

# Auto-launch Hyprland when logging in from tty1 (Ly)
if [[ -z "$WAYLAND_DISPLAY" ]] && [[ $(tty) == /dev/tty1 ]]; then
    exec Hyprland
fi
EOF
fi

# Create Wayland session entry (helps Ly detect Hyprland)
sudo mkdir -p /usr/share/wayland-sessions
sudo tee /usr/share/wayland-sessions/hyprland.desktop >/dev/null <<EOF
[Desktop Entry]
Name=Hyprland
Comment=Hyprland Wayland compositor
Exec=Hyprland
Type=Application
EOF

###############################################################
# 7. YAY + AUR PACKAGES
###############################################################
echog "Installing AUR packages using yay..."

yay -S --noconfirm --needed \
    vscodium-bin \
    brave-bin \
    timeshift-autosnap \
    zsh-autosuggestions \
    zsh-syntax-highlighting \
    || echow "Some AUR packages failed."

###############################################################
# 8. TIMESHiFT AUTOSNAP CONFIG
###############################################################
echog "Configuring timeshift-autosnap (limit = 3 snapshots)..."

if [[ -f /etc/timeshift-autosnap.conf ]]; then
    sudo sed -i 's/^SNAPSHOT_LIMIT=.*/SNAPSHOT_LIMIT=3/' /etc/timeshift-autosnap.conf
fi

# Ensure pacman hook exists
sudo mkdir -p /etc/pacman.d/hooks
sudo tee /etc/pacman.d/hooks/timeshift-autosnap.hook >/dev/null <<'HOOK'
[Trigger]
Operation = Upgrade
Type = Package
Target = *

[Action]
Description = Creating Timeshift snapshot before upgrade...
When = PreTransaction
Exec = /usr/bin/timeshift --create --comments "pre-update" --tags D
HOOK

###############################################################
# 9. MAINTENANCE TIMERS (CACHE + JOURNAL + ORPHANS)
###############################################################
echog "Enabling system maintenance timers..."

# Pacman cache cleanup
sudo tee /etc/systemd/system/paccache-clean.service >/dev/null <<'EOF'
[Unit]
Description=Clean pacman cache
[Service]
Type=oneshot
ExecStart=/usr/bin/paccache -rk3
EOF

sudo tee /etc/systemd/system/paccache-clean.timer >/dev/null <<'EOF'
[Unit]
Description=Weekly pacman cache cleanup
[Timer]
OnCalendar=weekly
Persistent=true
[Install]
WantedBy=timers.target
EOF

sudo systemctl enable --now paccache-clean.timer

# Journal cleanup
sudo tee /etc/systemd/system/journal-clean.service >/dev/null <<'EOF'
[Unit]
Description=Clean journal logs older than 14 days
[Service]
Type=oneshot
ExecStart=/usr/bin/journalctl --vacuum-time=14d
EOF

sudo tee /etc/systemd/system/journal-clean.timer >/dev/null <<'EOF'
[Unit]
Description=Weekly journal cleanup
[Timer]
OnCalendar=weekly
Persistent=true
[Install]
WantedBy=timers.target
EOF

sudo systemctl enable --now journal-clean.timer

# Orphan cleanup
sudo tee /etc/systemd/system/orphan-clean.service >/dev/null <<'EOF'
[Unit]
Description=Remove orphaned packages
[Service]
Type=oneshot
ExecStart=/usr/bin/pacman -Rns --noconfirm $(pacman -Qtdq || true)
EOF

sudo tee /etc/systemd/system/orphan-clean.timer >/dev/null <<'EOF'
[Unit]
Description=Monthly orphan cleanup
[Timer]
OnCalendar=monthly
Persistent=true
[Install]
WantedBy=timers.target
EOF

sudo systemctl enable --now orphan-clean.timer

###############################################################
# 10. ZSH + OHMYZSH + POWERLEVEL10K
###############################################################
echog "Installing Zsh and customizing shell..."

sudo pacman -S --noconfirm --needed zsh

echog "Setting default shell to zsh..."
chsh -s "$(command -v zsh)" "$USERNAME" || echow "Could not change shell"

if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
  echog "Installing Oh My Zsh..."
  sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
fi

# Powerlevel10k
if [[ ! -d "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k" ]]; then
  git clone --depth=1 https://github.com/romkatv/powerlevel10k.git \
    "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k"
fi

# Update .zshrc
sed -i 's/^ZSH_THEME=.*/ZSH_THEME="powerlevel10k\/powerlevel10k"/' "$HOME/.zshrc" || true

# Recommended plugins
if ! grep -q 'zsh-autosuggestions' "$HOME/.zshrc"; then
  echo 'plugins=(git zsh-autosuggestions zsh-syntax-highlighting)' >> "$HOME/.zshrc"
fi

echog "Installation finished! Reboot and log in through Ly — Hyprland will start automatically."
