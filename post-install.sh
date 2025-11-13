#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# post-install.sh
# Run as your regular user (carlos). Uses sudo for root tasks.
# - system update
# - zram-generator (zram-size = ram) -> 100% of RAM
# - keep swapfile, set swappiness
# - install AUR packages (yay): timeshift-autosnap, brave, vscodium
# - configure timeshift-autosnap retention = 3
# - enable timeshift pacman hook for pre-updates if missing
# - minimal Hyprland install + portal
# - set up auto-login on tty1 and auto-start hyperland on tty1
# - failsafe Hyprland keybind to open kitty
# - add Flathub remote
# - enable maintenance timers (cache/journal/orphans cleanup)

USERNAME="$(whoami)"
echog(){ printf "\n==> %s\n" "$*"; }
echow(){ printf "\nWARN: %s\n" "$*"; }
echof(){ printf "\nERROR: %s\n" "$*"; exit 1; }

echog "Updating system."
sudo pacman -Syu --noconfirm

echog "Installing zram-generator and related packages..."
sudo pacman -S --noconfirm --needed zram-generator

echog "Writing zram-generator config (100% RAM)..."
sudo tee /etc/systemd/zram-generator.conf > /dev/null <<'EOF'
[zram0]
zram-size = ram
compression-algorithm = zstd
EOF

echog "Reloading systemd and enabling zram..."
sudo systemctl daemon-reload
sudo systemctl enable --now systemd-zram-setup@zram0.service || true

echog "Keeping existing swapfile active; setting swappiness to 15..."
sudo sed -i '/vm.swappiness/d' /etc/sysctl.d/99-swappiness.conf 2>/dev/null || true
echo "vm.swappiness=15" | sudo tee /etc/sysctl.d/99-swappiness.conf > /dev/null
sudo sysctl --system || true

echog "Install minimal Wayland/Hyprland packages and portal..."
# names may vary slightly by repo; adjust if pacman fails
sudo pacman -S --noconfirm --needed hyprland xdg-desktop-portal-hyprland wl-clipboard grim slurp xdg-desktop-portal

echog "Install other user apps."
sudo pacman -S --noconfirm --needed flatpak firefox kitty nautilus

echog "Add Flathub remote for Flatpak."
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true

echog "Install AUR packages via yay (this runs as your user)."
yay -S --noconfirm --needed brave-bin vscodium-bin timeshift-autosnap || echow "Some AUR packages failed; you can re-run yay manually."

# configure timeshift-autosnap retention
echog "Configuring timeshift-autosnap retention to 3 snapshots..."
if [[ -f /etc/timeshift-autosnap.conf ]]; then
  sudo sed -i 's/^SNAPSHOT_LIMIT=.*/SNAPSHOT_LIMIT=3/' /etc/timeshift-autosnap.conf || true
fi

# create pacman hook for pre-update snapshot if timeshift-autosnap didn't create it
HOOK_FILE="/etc/pacman.d/hooks/timeshift-autosnap.hook"
if [[ ! -f "$HOOK_FILE" ]]; then
  echog "Creating pacman pre-transaction hook to create a timeshift snapshot..."
  sudo mkdir -p /etc/pacman.d/hooks
  sudo tee "$HOOK_FILE" > /dev/null <<'HOOK'
[Trigger]
Operation = Upgrade
Type = Package
Target = *

[Action]
Description = Creating Timeshift snapshot before upgrade...
When = PreTransaction
Exec = /usr/bin/timeshift --create --comments "pre-update" --tags D
HOOK
fi

# Hyprland failsafe config: minimal keybind to open terminal (simple fallback to ensure Hyprland always has a minimal config)
echog "Creating failsafe Hyprland config to open terminal (SUPER+ENTER)..."
mkdir -p ~/.config/hypr
if [[ ! -f ~/.config/hypr/hyprland.conf ]]; then
  cat > ~/.config/hypr/hyprland.conf <<'HYPR'
# Minimal failsafe config
bind = SUPER, RETURN, exec, kitty
HYPR
fi

# Auto-login on tty1 using systemd override
echog "Setting up auto-login on tty1 for user ${USERNAME}..."
sudo mkdir -p /etc/systemd/system/getty@tty1.service.d
sudo tee /etc/systemd/system/getty@tty1.service.d/override.conf > /dev/null <<'UNIT'
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin ${USERNAME} --noclear %I \$TERM
Type=simple
UNIT

sudo systemctl daemon-reload
sudo systemctl restart getty@tty1.service || true

# Auto-start Hyperland on tty1 for the logged-in user
echog "Creating ~/.profile entry to auto-start Hyperland on tty1..."
PROFILEF="$HOME/.profile"
if ! grep -q "exec dbus-run-session -- hyperland" "$PROFILEF" 2>/dev/null; then
  cat >> "$PROFILEF" <<'PROFILE'

# Auto-start Hyperland when logging in on tty1
if [[ -t 1 ]] && [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
  exec dbus-run-session -- hyperland
fi
PROFILE
fi

# Enable maintenance timers (pacman cache cleanup, journal vacuum, orphan removal)
echog "Enabling periodic maintenance timers..."

# pacman cache cleanup weekly (uses paccache)
sudo tee /etc/systemd/system/paccache-clean.timer > /dev/null <<'TIMER'
[Unit]
Description=Weekly pacman cache cleanup

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
TIMER

sudo tee /etc/systemd/system/paccache-clean.service > /dev/null <<'SRV'
[Unit]
Description=Run paccache to clean old package cache

[Service]
Type=oneshot
ExecStart=/usr/bin/paccache -rk3
SRV

sudo systemctl daemon-reload
sudo systemctl enable --now paccache-clean.timer || true

# journal vacuum - clean journals older than 14 days
sudo tee /etc/systemd/system/journal-clean.timer > /dev/null <<'JTIMER'
[Unit]
Description=Clean old journal logs

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
JTIMER

sudo tee /etc/systemd/system/journal-clean.service > /dev/null <<'JSRV'
[Unit]
Description=Vacuum journal older than 14 days
[Service]
Type=oneshot
ExecStart=/usr/bin/journalctl --vacuum-time=14d
JSRV

sudo systemctl daemon-reload
sudo systemctl enable --now journal-clean.timer || true

# orphaned package cleanup monthly
sudo tee /etc/systemd/system/orphan-clean.timer > /dev/null <<'OTIMER'
[Unit]
Description=Monthly orphan package cleanup

[Timer]
OnCalendar=monthly
Persistent=true

[Install]
WantedBy=timers.target
OTIMER

sudo tee /etc/systemd/system/orphan-clean.service > /dev/null <<'OSRV'
[Unit]
Description=Remove orphan packages
[Service]
Type=oneshot
ExecStart=/usr/bin/pacman -Rns --noconfirm $(pacman -Qtdq || true)
OSRV

sudo systemctl daemon-reload
sudo systemctl enable --now orphan-clean.timer || true

echog "Post-install tasks complete. You should be auto-logged in on tty1 and Hyperland will start."
echog "If you need to edit Hypr config, switch to another TTY (Ctrl+Alt+F2) and edit ~/.config/hypr/hyprland.conf"

##############################
# Install Zsh, Oh My Zsh, Powerlevel10k
##############################

echog "Installing Zsh..."
sudo pacman -S --noconfirm zsh

echog "Setting Zsh as default shell for user $USERNAME..."
chsh -s "$(which zsh)" "$USERNAME" || echow "Failed to change default shell. You may need to log out and back in."

# Install Oh My Zsh if not already installed
if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
  echog "Installing Oh My Zsh..."
  sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended || echow "Oh My Zsh installation failed."
else
  echog "Oh My Zsh already installed."
fi

# Install Powerlevel10k theme
if [[ ! -d "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k" ]]; then
  echog "Installing Powerlevel10k theme..."
  git clone --depth=1 https://github.com/romkatv/powerlevel10k.git \
    "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k"
else
  echog "Powerlevel10k already installed."
fi

# Configure .zshrc to use Powerlevel10k
ZSHRC_FILE="$HOME/.zshrc"
if ! grep -q "ZSH_THEME=\"powerlevel10k/powerlevel10k\"" "$ZSHRC_FILE" 2>/dev/null; then
  echog "Configuring .zshrc to use Powerlevel10k..."
  sed -i 's/^ZSH_THEME=.*/ZSH_THEME="powerlevel10k\/powerlevel10k"/' "$ZSHRC_FILE" || \
    echo 'ZSH_THEME="powerlevel10k/powerlevel10k"' >> "$ZSHRC_FILE"
fi

# Enable recommended plugins
if ! grep -q '^plugins=' "$ZSHRC_FILE"; then
  echog "Adding recommended plugins to .zshrc..."
  echo 'plugins=(git zsh-autosuggestions zsh-syntax-highlighting)' >> "$ZSHRC_FILE"
else
  echog "Updating plugins in .zshrc..."
  sed -i 's/^plugins=.*/plugins=(git zsh-autosuggestions zsh-syntax-highlighting)/' "$ZSHRC_FILE"
fi

echog "Zsh + Oh My Zsh + Powerlevel10k installation complete."
echog "Plugins enabled: git, zsh-autosuggestions, zsh-syntax-highlighting"
echog "You may need to restart your terminal or log out/in to use Zsh as default shell."

