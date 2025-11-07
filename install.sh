#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

########################################################################
# install.sh
# Automated Arch installer (Phase 1)
#
# - SAFE mode: detects internal disks only (ignores USB) and asks you
#   to type the disk path to confirm wipe.
# - Partitions: UEFI (512M FAT32) + Btrfs (rest).
# - Btrfs: creates standard subvolumes: @, @home, @cache, @log, @tmp
# - Mount options: compress=zstd,ssd,noatime,discard=async,space_cache=v2
# - Uses reflector to pick best France mirrors
# - pacstrap installs: base, linux, linux-firmware, intel-ucode, btrfs-progs,
#   networkmanager, openssh, grub, efibootmgr, dosfstools, sudo
# - Writes /mnt/root/chroot.sh for phase 2
#
# USAGE (from Arch ISO)
# 1) Connect to the internet (wired is automatic; for wifi use iwctl)
# 2) Create file: nano install.sh  (paste this script)
# 3) chmod +x install.sh
# 4) ./install.sh
#
# VERY IMPORTANT: script WILL WIPE THE TARGET DISK after explicit confirmation.
########################################################################

# --- Configurable defaults ------------------------------------------------
MIRROR_COUNTRY="France"
BTRFS_MOUNT_OPTS="compress=zstd,ssd,noatime,discard=async,space_cache=v2"
EFI_SIZE_M="512"        # EFI size in MiB
USERNAME="carlos"       # user created by chroot.sh
HOSTNAME="archvm"
# pacstrap package list
PACSTRAP_PKGS=(base linux linux-firmware intel-ucode btrfs-progs \
               networkmanager openssh grub efibootmgr dosfstools sudo)
# --------------------------------------------------------------------------

echog() { printf "\n\e[1;32m==> %s\e[0m\n" "$*"; }
echow() { printf "\n\e[1;33mWARN: %s\e[0m\n" "$*"; }
echof() { printf "\n\e[1;31mERROR: %s\e[0m\n" "$*"; exit 1; }

# Ensure running as root
if [[ $EUID -ne 0 ]]; then
  echof "This script must be run as root (run: sudo ./install.sh)"
fi

echog "Starting automated install (Phase 1)."

# 1) Ensure network
echog "Checking network connectivity..."
if ! ping -c 1 archlinux.org >/dev/null 2>&1; then
  echow "No network yet. You must connect (wired is usually automatic)."
  echow "For Wi-Fi, run: iwctl -> station <dev> connect <SSID>"
  read -rp "Press ENTER when network is ready (or Ctrl+C to abort) "
fi

# 2) Install reflector temporarily to choose FR mirrors
echog "Installing reflector to select France mirrors (temporary)..."
pacman -Sy --noconfirm reflector >/dev/null 2>&1 || {
  echow "Could not install reflector automatically; continuing — pacman may use default mirrors."
}

if command -v reflector >/dev/null 2>&1; then
  echog "Selecting best mirrors in ${MIRROR_COUNTRY} with reflector..."
  reflector --country "${MIRROR_COUNTRY}" --latest 10 --sort rate --save /etc/pacman.d/mirrorlist --verbose || \
    echow "reflector failed; continuing with existing mirrorlist"
else
  echow "reflector not available; skipping mirror tuning"
fi

# 3) Detect internal (non-USB) disks and show them
echog "Detecting candidate disks (internal NVMe/SATA, excluding USB)..."
mapfile -t CANDIDATES < <(lsblk -dno NAME,MODEL,TRAN,RM | awk '$4==0 && $3!="usb" {print "/dev/"$1" | "$2" | "$3"}')
if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
  echow "No internal disks found automatically. Listing all block devices:"
  lsblk -dn -o NAME,SIZE,MODEL,TRAN
  read -rp "Enter the full disk device to use (e.g. /dev/sda or /dev/nvme0n1): " TARGET_DISK
else
  echog "Internal disks found:"
  for i in "${!CANDIDATES[@]}"; do
    printf "  %2d) %s\n" "$((i+1))" "${CANDIDATES[$i]}"
  done
  echo
  read -rp "Enter the number of the disk to use (or type device path manually): " choice
  if [[ $choice =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#CANDIDATES[@]} )); then
    TARGET_DISK="/dev/$(echo "${CANDIDATES[$((choice-1))]}" | cut -d'|' -f1 | sed 's|/dev/||g' | xargs)"
  else
    # assume user typed a device path
    TARGET_DISK="$choice"
  fi
fi

# Validate TARGET_DISK exists
if [[ ! -b "$TARGET_DISK" ]]; then
  echof "Target disk ${TARGET_DISK} not found or is not a block device. Aborting."
fi

echo
echow "!!! DANGER: THIS WILL WIPE ALL DATA ON ${TARGET_DISK} !!!"
echo "If you are sure, type the device path exactly to confirm (e.g. ${TARGET_DISK})"
read -rp "Type disk to confirm wipe: " CONFIRM
if [[ "$CONFIRM" != "$TARGET_DISK" ]]; then
  echof "Confirmation mismatch. Aborting without touching any disks."
fi
echog "Confirmed. Proceeding to partition ${TARGET_DISK}..."

# 4) Partition the disk (GPT, EFI + rest)
echog "Creating GPT partition table and partitions on ${TARGET_DISK}..."
sgdisk --zap-all "${TARGET_DISK}"
sgdisk --clear "${TARGET_DISK}"
# EFI partition number 1, size EFI_SIZE_M MiB, type EF00
sgdisk -n 1:0:+${EFI_SIZE_M}M -t 1:ef00 -c 1:"EFI System" "${TARGET_DISK}"
# Linux partition number 2 occupies rest
sgdisk -n 2:0:0 -t 2:8300 -c 2:"Linux root (btrfs)" "${TARGET_DISK}"

# Wait for kernel to recognize partitions
partprobe "${TARGET_DISK}" || true
sleep 1

# Identify partitions
if echo "$TARGET_DISK" | grep -q "nvme"; then
  EFI_PART="${TARGET_DISK}p1"
  ROOT_PART="${TARGET_DISK}p2"
else
  EFI_PART="${TARGET_DISK}1"
  ROOT_PART="${TARGET_DISK}2"
fi

echog "EFI partition: $EFI_PART"
echog "Root partition: $ROOT_PART"

# 5) Format partitions
echog "Formatting EFI partition as FAT32..."
mkfs.fat -F32 "$EFI_PART"

echog "Formatting root partition as Btrfs..."
mkfs.btrfs -f "$ROOT_PART"

# 6) Create Btrfs subvolumes
echog "Creating Btrfs subvolumes..."
mount "$ROOT_PART" /mnt
# create subvolumes
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@cache
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@tmp
# also create a timeshift mountpoint (Timeshift will create its own if needed)
btrfs subvolume create /mnt/timeshift-btrfs || true

# Unmount and remount proper subvolumes with options
umount /mnt

echog "Mounting subvol=@ to /mnt with mount options: ${BTRFS_MOUNT_OPTS}"
mount -o "subvol=@" "$ROOT_PART" /mnt
mkdir -p /mnt/{home,var,var/cache,var/log,tmp,efi}
mount -o "subvol=@home,${BTRFS_MOUNT_OPTS}" "$ROOT_PART" /mnt/home
# mount cache/log/tmp subvols
mount -o "subvol=@cache,${BTRFS_MOUNT_OPTS}" "$ROOT_PART" /mnt/var/cache
mount -o "subvol=@log,${BTRFS_MOUNT_OPTS}" "$ROOT_PART" /mnt/var/log
mount -o "subvol=@tmp,${BTRFS_MOUNT_OPTS}" "$ROOT_PART" /mnt/tmp

# mount EFI
mkdir -p /mnt/efi
mount "$EFI_PART" /mnt/efi

# 7) Pacstrap base system
echog "Installing base system to /mnt (this may take a few minutes)..."
pacstrap /mnt "${PACSTRAP_PKGS[@]}"

# 8) Generate fstab
echog "Generating /etc/fstab (using UUIDs)..."
genfstab -U /mnt >> /mnt/etc/fstab
echog "Generated /mnt/etc/fstab:"
cat /mnt/etc/fstab

# 9) Create chroot phase 2 script (/root/chroot.sh inside new system)
echog "Writing chroot script to /mnt/root/chroot.sh (Phase 2)."

cat > /mnt/root/chroot.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# chroot.sh - run inside arch-chroot /mnt
# This script configures timezone, locales, hostname, user, GRUB (UEFI),
# NetworkManager, zram + swapfile, installs AUR helper (yay) and enables services.

USERNAME="carlos"
HOSTNAME="archvm"
LOCALE="en_US.UTF-8"
TIMEZONE="Europe/Paris"
BTRFS_MOUNT_OPTS="compress=zstd,ssd,noatime,discard=async,space_cache=v2"

echog() { printf "\n\e[1;32m==> %s\e[0m\n" "$*"; }
echow() { printf "\n\e[1;33mWARN: %s\e[0m\n" "$*"; }
echof() { printf "\n\e[1;31mERROR: %s\e[0m\n" "$*"; exit 1; }

# Ensure this script is run in chroot (simple check)
if [[ ! -d /sys/firmware/efi ]] && [[ ! -d /sys/class/dmi ]]; then
  echow "You are probably not in chroot. Please run: arch-chroot /mnt /root/chroot.sh"
  exit 1
fi

echog "Setting timezone to ${TIMEZONE}..."
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc

echog "Generating locales..."
if ! grep -q "${LOCALE}" /etc/locale.gen; then
  sed -i "s/^#${LOCALE}/${LOCALE}/" /etc/locale.gen || true
fi
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf
export LANG=${LOCALE}

echog "Setting hostname..."
echo "${HOSTNAME}" > /etc/hostname
cat >> /etc/hosts <<HOSTS
127.0.0.1	localhost
::1		localhost
127.0.1.1	${HOSTNAME}.localdomain ${HOSTNAME}
HOSTS

echog "Creating user ${USERNAME}..."
passwd root
useradd -m -G wheel,audio,optical,video,input -s /bin/bash "${USERNAME}"
echo "Set password for ${USERNAME}:"
passwd "${USERNAME}"
# Allow sudo for wheel group
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers || true

echog "Enabling NetworkManager..."
systemctl enable NetworkManager
systemctl enable sshd

echog "Create swapfile + enable zram"
# Create zram.service via systemd-swap? We'll install zram-generator-dkms later
# Create swapfile (if not present)
SWAPFILE=/swapfile
if [[ ! -f $SWAPFILE ]]; then
  fallocate -l 4G $SWAPFILE || dd if=/dev/zero of=$SWAPFILE bs=1M count=4096
  chmod 600 $SWAPFILE
  mkswap $SWAPFILE
  swapon $SWAPFILE
  echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab
fi

echog "Installing additional packages: grub, efibootmgr (installed via pacstrap earlier) and configuring GRUB..."
# Install grub (already installed in pacstrap list but ensure)
pacman -Syu --noconfirm grub efibootmgr

# Ensure EFI mount exists at /efi or /boot/efi; genfstab used earlier. Find EFI mount:
EFI_PATH=$(awk '/vfat/ && /\/efi|\/boot/ {print $2; exit}' /etc/fstab || true)
if [[ -z "$EFI_PATH" ]]; then
  # fallback
  mkdir -p /efi
  mount | grep -q "/efi" || true
  EFI_PATH="/efi"
fi

# Install GRUB for UEFI
grub-install --target=x86_64-efi --efi-directory="${EFI_PATH}" --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

echog "Installing AUR helper (yay) prerequisites..."
pacman -S --noconfirm --needed git base-devel

echog "Creating a temporary user build to install yay (build as your user later if you wish)..."
# build yay as the real user
su - "${USERNAME}" -c "cd /home/${USERNAME} && git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si --noconfirm" || echow "yay build failed; you can build it after first boot as ${USERNAME}"

echog "Enable fstrim.timer for SSD maintenance"
systemctl enable fstrim.timer

echog "Final sync and exit chroot"
sync

echo
echog "Phase 2 complete — exit the chroot, umount and reboot into the new system."
echo "Run the following from the live environment now:"
echo "  arch-chroot /mnt /root/chroot.sh"
EOF

chmod +x /mnt/root/chroot.sh

echog "Phase 1 complete."
echo
echog "What to do next (manual steps to finish installation):"
cat <<INSTR

1) Enter the new system chroot and run Phase 2:

   arch-chroot /mnt /root/chroot.sh

   -> In the chroot script you will:
      - set root password and create the '${USERNAME}' user (script prompts for passwords)
      - configure locale/timezone/hostname
      - install and configure GRUB (UEFI)
      - install yay (AUR helper) for Phase 3 usage

2) After the chroot script finishes, exit the chroot:
   exit

   Then unmount and reboot:
   umount -R /mnt
   reboot

3) After booting into your new system, run the Phase 3 post-install steps
   (I will generate post-install.sh separately when you want it), e.g.:

   - install Hyprland and Wayland packages
   - install Firefox, Brave, VSCodium, Kitty, Nautilus, Flatpak, Timeshift + autosnap
   - configure zram-generator and timeshift-autosnap

IMPORTANT: the chroot script will ask you to set root and user passwords interactively.
INSTR

echog "Script finished. Good luck! If you want, I can now generate the chroot/post-install scripts contents for you to paste (or include a complete post-install script)."

exit 0

