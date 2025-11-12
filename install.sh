#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# install.sh - Phase1 + Phase2 combined
# - SAFE auto-detect (ignores USB)
# - Creates GPT, EFI (512MiB) + Btrfs root
# - Creates subvolumes: @, @home, @cache, @log, @tmp, @swap, timeshift-btrfs
# - Mounts subvolumes with BTRFS_MOUNT_OPTS for data subvols, and compress=no for swap/log/cache
# - pacstrap uses -K (initialise fresh keyring) and install packages(kernel, intel-ucode, networkmanager, grub, etc.)
# - chroot commands are written to /root/chroot.sh and executed via arch-chroot

# ===============================
# Multi-column menu with auto-width and ASCII box (prompt outside)

choose_from_menu() {
  (( $# >= 3 )) || { echo "Usage: choose_from_menu <prompt> <outvar> <options...>"; return 1; }

  local prompt="$1" outvar="$2"
  shift 2
  local options=("$@")

  echo
  echo "$prompt"
  echo

  local old_PS3="${PS3:-}"
  PS3=$'\nEnter choice number: '

  local choice
  select choice in "${options[@]}"; do
      if [[ -n "$choice" ]]; then
          printf -v "$outvar" "%s" "$choice"
          break
      else
          echo "Invalid choice. Try again."
          echo
      fi
  done

  PS3="$old_PS3"
  echo
}

# Edit variables below before running if you want to tweak them.
BTRFS_MOUNT_OPTS_COMP="compress=zstd,ssd,noatime,discard=async,space_cache=v2"
BTRFS_MOUNT_OPTS_NOCOMP="compress=no,ssd,noatime,discard=async,space_cache=v2"
EFI_SIZE_M=512
SWAPFILE_SIZE_MB=8192   # 8GB swapfile
PACSTRAP_PKGS=(base linux linux-firmware intel-ucode btrfs-progs \
               networkmanager openssh grub efibootmgr grub-btrfs \
               inotify-tools dosfstools vim \
               pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber \
               zsh zsh-completions zsh-autosuggestions \
               man sudo)

# Create custom printing functions (regular, warning and error)
echog(){ printf "\n==> %s\n" "$*"; }
echow(){ printf "\nWARN: %s\n" "$*"; }
echof(){ printf "\nERROR: %s\n" "$*"; exit 1; }

# Enusre the script is run as root
if [[ $EUID -ne 0 ]]; then
  echof "Run this script as root (sudo ./install.sh)"
fi

# ==== Phase 1 starts =====
echog "Phase 1: pre-install tasks"

# Ensure network
echog "Checking network..."
if ! ping -c1 archlinux.org >/dev/null 2>&1; then
  echow "No network detected. If you're using Wi-Fi, run 'iwctl' to connect."
  read -rp "Press ENTER once network is ready (or Ctrl+C to abort) "
fi

# ====== User name and host prompts ========
echo
read -rp "Type your desired username: " USERNAME
echog "Username chosen: $USERNAME"
echo
# ====== User name prompt ========
read -rp "Type your desired computer (host) name (ex.: arch): " HOSTNAME
echog "Computer name chosen: $HOSTNAME"
echo

# ====== OPTIONS SELECTIONS ======

# ==== Choose mirror country ====
MIRROR_COUNTRIES=(
  "Spain (default)"
  "France"
  "Germany"
  "United Kingdom"
  "Netherlands"
  "Italy"
  "Belgium"
  "Sweden"
  "Poland"
  "Switzerland"
  "United States"
  "Canada"
  "Australia"
  "Japan"
  "South Korea"
  "China"
  "India"
)

choose_from_menu "Select mirror country:" MIRROR_COUNTRY "${MIRROR_COUNTRIES[@]}"
echo "Selected mirror: $MIRROR_COUNTRY"
# Extract actual value (remove "(default)" if present)
MIRROR_COUNTRY=$(echo "$MIRROR_COUNTRY" | sed 's/ (default)//')

# ==== Choose timezones ====
TIMEZONES=(
  "Europe/Madrid (default)"
  "Europe/Paris"
  "Europe/Amsterdam"
  "Europe/Berlin"
  "Europe/Brussels"
  "Europe/Helsinki"
  "Europe/Lisbon"
  "Europe/London"
  "Europe/Oslo"
  "Europe/Prague"
  "Europe/Rome"
  "Europe/Stockholm"
  "Europe/Vienna"
  "Europe/Warsaw"
  "America/New_York"
  "America/Los_Angeles"
  "America/Chicago"
  "America/Sao_Paulo"
  "Asia/Shanghai"
  "Asia/Tokyo"
  "Asia/Seoul"
  "Asia/Kolkata"
  "Australia/Sydney"
  "Africa/Johannesburg"
  "UTC"
)

choose_from_menu "Select timezone:" TIMEZONE "${TIMEZONES[@]}"
echo "Selected timezone: $TIMEZONE"
TIMEZONE=$(echo "$TIMEZONE" | sed 's/ (default)//')
echo "============================================"

# ==== Choose Keyboard layout ====
KEYMAPS=("us-intl (default)" "us" "es" "fr" "de" "uk")

choose_from_menu "Select keyboard layout:" KEYMAP "${KEYMAPS[@]}"
echo "Selected keyboard layout: $KEYMAP"
KEYMAP=$(echo "$KEYMAP" | awk '{print $1}')  # Extract first word
echo "============================================"

# ==== Choose system display language ====
LOCALES=("en_US.UTF-8 (default)" "es_ES.UTF-8" "fr_FR.UTF-8" "de_DE.UTF-8")

choose_from_menu "Select language (LANG):" LOCALE "${LOCALES[@]}"
echo "Selected language: $LOCALE"
LOCALE=$(echo "$LOCALE" | sed 's/ (default)//')
echo "============================================"

# ==== Choose measurement units ====
UNITS=("en_DK.UTF-8 (default)" "en_GB.UTF-8" "fr_FR.UTF-8" "es_ES.UTF-8")

choose_from_menu "Select units locale (LC_MEASUREMENT):" UNIT "${UNITS[@]}"
echo "Selected unit system: $UNIT"
UNIT=$(echo "$UNIT" | sed 's/ (default)//')
echo "============================================"

# ==== Choose measurement units ====
CALENDARS=("es_ES.UTF-8 (default)" "en_GB.UTF-8" "fr_FR.UTF-8" "de_DE.UTF-8" "en_US.UTF-8")

choose_from_menu "Select calendar locale (LC_TIME):" CALENDAR "${CALENDARS[@]}"
echo "Selected calendar: $CALENDAR"
CALENDAR=$(echo "$CALENDAR" | sed 's/ (default)//')
echo "============================================"

# ====== END OF OPTIONS SELECTIONS ======

# Install reflector if not already present 
if ! command -v reflector >/dev/null 2>&1; then
  echog "Installing reflector temporarily to pick fast France mirrors..."
  pacman -Sy --noconfirm reflector >/dev/null 2>&1 || echow "Could not install reflector; will continue with existing mirrorlist"
fi
# Ensure reflector was successfully installed and get fastest mirrors
if command -v reflector >/dev/null 2>&1; then
  echog "Selecting fast ${MIRROR_COUNTRY} mirrors..."
  reflector --country "${MIRROR_COUNTRY}" --latest 10 --sort rate --save /etc/pacman.d/mirrorlist --timeout 10 --retry 3 || echow "reflector failed; continuing with default mirrorlist"
fi

# Detect internal disks (exclude removable/usb)
echog "Detecting internal disks (excludes USB)..."
mapfile -t CANDIDS < <(lsblk -dno NAME,TRAN,RM,MODEL | awk '$3==0 && $2!="usb" {print "/dev/"$1" :: "$4}')
if [[ ${#CANDIDS[@]} -eq 0 ]]; then
  echow "No internal disks found automatically. Showing all disks:"
  lsblk -dn -o NAME,SIZE,MODEL,TRAN
  read -rp "Enter the disk to use (e.g. /dev/sda or /dev/nvme0n1): " TARGET_DISK
else
  echog "Internal disks found:"
  for i in "${!CANDIDS[@]}"; do
    printf "  %2d) %s\n" "$((i+1))" "${CANDIDS[$i]}"
  done
  echo
  read -rp "Enter the number of the disk to use (or full path): " choice
  if [[ $choice =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=${#CANDIDS[@]} )); then
    TARGET_DISK=$(echo "${CANDIDS[$((choice-1))]}" | cut -d' ' -f1 | sed 's|::||' | xargs)
  else
    TARGET_DISK="$choice"
  fi
fi

[[ -b "$TARGET_DISK" ]] || echof "Block device $TARGET_DISK not found."

echow "!!! THIS WILL DESTROY ALL DATA ON: $TARGET_DISK !!!"
read -rp "Type the exact device path to confirm wipe (e.g. $TARGET_DISK): " CONFIRM
if [[ "$CONFIRM" != "$TARGET_DISK" ]]; then
  echof "Confirmation mismatch. Aborting."
fi

# Partitioning
echog "Wiping partition table and creating GPT + EFI + Linux partitions..."
sgdisk --zap-all "$TARGET_DISK"
sgdisk --clear "$TARGET_DISK"
sgdisk -n 1:0:+${EFI_SIZE_M}M -t 1:ef00 -c 1:"EFI System" "$TARGET_DISK"
sgdisk -n 2:0:0 -t 2:8300 -c 2:"Linux root (btrfs)" "$TARGET_DISK"
partprobe "$TARGET_DISK" || true
sleep 1

# Partition names (handle nvme)
if [[ "$TARGET_DISK" == *nvme* ]]; then
  EFI_PART="${TARGET_DISK}p1"
  ROOT_PART="${TARGET_DISK}p2"
else
  EFI_PART="${TARGET_DISK}1"
  ROOT_PART="${TARGET_DISK}2"
fi

echog "EFI: $EFI_PART  ROOT: $ROOT_PART"

# Format partitions
echog "Formatting EFI as FAT32..."
mkfs.fat -F32 "$EFI_PART"

echog "Formatting root as Btrfs..."
mkfs.btrfs -f "$ROOT_PART"

# Create subvolumes
echog "Creating Btrfs subvolumes (this may take a moment)..."
mount "$ROOT_PART" /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@cache
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@tmp
btrfs subvolume create /mnt/@swap
# timeshift area
btrfs subvolume create /mnt/timeshift-btrfs
umount /mnt

# Mount subvolumes
echog "Mounting subvolumes..."
mount -o "subvol=@,${BTRFS_MOUNT_OPTS_COMP}" "$ROOT_PART" /mnt
mkdir -p /mnt/{home,var/cache,var/log,tmp,swap,efi}
mount -o "subvol=@home,${BTRFS_MOUNT_OPTS_COMP}" "$ROOT_PART" /mnt/home
mount -o "subvol=@cache,${BTRFS_MOUNT_OPTS_NOCOMP}" "$ROOT_PART" /mnt/var/cache
mount -o "subvol=@log,${BTRFS_MOUNT_OPTS_NOCOMP}" "$ROOT_PART" /mnt/var/log
mount -o "subvol=@tmp,${BTRFS_MOUNT_OPTS_NOCOMP}" "$ROOT_PART" /mnt/tmp
mount -o "subvol=@swap,${BTRFS_MOUNT_OPTS_NOCOMP}" "$ROOT_PART" /mnt/swap

# Mount EFI
mount "$EFI_PART" /mnt/efi

# Pacstrap base system
echog "Installing base packages (this can take a while)..."
pacstrap -K /mnt "${PACSTRAP_PKGS[@]}"

# Generate fstab
echog "Generating /etc/fstab..."
genfstab -U /mnt >> /mnt/etc/fstab
echog "fstab wrote:"
cat /mnt/etc/fstab

# Create chroot script
echog "Writing chroot script to /root/chroot.sh inside new system..."
cat > /mnt/root/chroot.sh <<EOF
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

USERNAME="${USERNAME}"
HOSTNAME="${HOSTNAME}"
SWAPFILE_SIZE_MB="${SWAPFILE_SIZE_MB}"
LOCALE="${LOCALE}"
UNIT="${UNIT}"
CALENDAR="${CALENDAR}"
TIMEZONE="${TIMEZONE}"
KEYMAP="${KEYMAP}"

echog(){ printf "\n==> %s\n" "\$*"; }
echow(){ printf "\nWARN: %s\n" "\$*"; }
echof(){ printf "\nERROR: %s\n" "\$*"; exit 1; }

# Minimal check we are inside chroot
if [[ ! -f /etc/fstab ]]; then echof "Please run this script inside arch-chroot /mnt"; fi

# ===== Set Timezone, keyboard layout and locales =====
# Set Timezone
echog "Setting timezone to ${TIMEZONE}..."
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
hwclock --systohc

# Set keyboard layout
echo "Setting keyboard layout to $KEYMAP..."
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

# Generate and set locales
echog "Setting up locales..."

for loc in "$LOCALE" "$UNIT" "$CALENDAR"; do
  [[ -z "\$loc" ]] && continue  # skip empty vars
  if ! grep -q "^\${loc} UTF-8" /etc/locale.gen; then
    echo "\${loc} UTF-8" >> /etc/locale.gen
    echo "Added \${loc} UTF-8 to locale.gen"
  fi
done

locale-gen

{
  echo "LANG=$LOCALE"
  echo "LC_NUMERIC=$UNIT" 
  echo "LC_MONETARY=$UNIT"
  echo "LC_PAPER=$UNIT"
  echo "LC_MEASUREMENT=$UNIT"
  echo "LC_TIME=$CALENDAR"
} > /etc/locale.conf

# Also set the locale for the current session
export LANG="$LOCALE"
export LC_NUMERIC="$UNIT"
export LC_MONETARY="$UNIT"
export LC_PAPER="$UNIT"
export LC_MEASUREMENT="$UNIT"
export LC_TIME="$CALENDAR"

#  ================================================

echog "Setting hostname to ${HOSTNAME}..."
echo "${HOSTNAME}" >/etc/hostname
cat >> /etc/hosts <<HOSTS
127.0.0.1	localhost
::1		localhost
127.0.1.1	${HOSTNAME}.localdomain ${HOSTNAME}
HOSTS

echog "Set root password (interactive)..."
passwd

echog "Creating user ${USERNAME} (wheel) and setting shell to zsh..."
pacman -S --noconfirm --needed zsh
useradd -m -G wheel,audio,optical,video,input -s /usr/bin/zsh "${USERNAME}"
echo "Set password for ${USERNAME}:"
passwd "${USERNAME}"
# enable wheel sudo
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers || true

echog "Enabling NetworkManager and sshd..."
systemctl enable NetworkManager
systemctl enable sshd

# Grub configuration
echog "Install GRUB (UEFI) and generate config..."
grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=GRUB  
grub-mkconfig -o /boot/grub/grub.cfg

# Create swapfile safely on Btrfs inside /swap (mounted from @swap)
echog "Creating Btrfs-compatible swapfile of size ${SWAPFILE_SIZE_MB} at /swap/swapfile..."
mkdir -p /swap
# ensure COW is disabled on /swap directory (chattr +C)
chattr +C /swap || echow "chattr +C /swap failed (maybe not supported); continuing"
# ensure compression off for swap subvol

# create swapfile
truncate -s 0 /swap/swapfile
# allocate space (use dd to avoid fallocate on btrfs)
dd if=/dev/zero of=/swap/swapfile bs=1M count=$SWAPFILE_SIZE_MB status=progress || true
chmod 600 /swap/swapfile
mkswap /swap/swapfile
swapon /swap/swapfile
echo "/swap/swapfile none swap defaults 0 0" >> /etc/fstab

echog "Enabling fstrim timer (SSD maintenance) and systemd services..."
systemctl enable fstrim.timer

echog "Installing yay prerequisites and building yay as user ${USERNAME}..."
pacman -S --noconfirm --needed git base-devel
su - "${USERNAME}" -c "cd ~ && git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si --noconfirm" || echow "Building yay failed; build manually later."

echog "Installing timeshift ..."
pacman -S --noconfirm --needed timeshift

echog "Phase 2 finished - exit chroot and reboot into new system, then run the post-install script as your normal user."
EOF

chmod +x /mnt/root/chroot.sh

echog "Phase 1 complete. Next steps:"
cat <<INSTR

  1) Enter the new system chroot and run the chroot script:

     arch-chroot /mnt /root/chroot.sh

     The chroot script will:
       - set timezone/locale/hostname
       - create the user and set passwords (interactive)
       - create a Btrfs-safe swapfile inside /swap (on @swap)
       - enable NetworkManager and sshd
       - install yay (as your user) and some base desktop packages

  2) After the chroot script finishes run:
       exit
       umount -R /mnt
       reboot

  3) After first boot, log in as '${USERNAME}' and run the Phase 3 script (post-install.sh)

INSTR

exit 0
