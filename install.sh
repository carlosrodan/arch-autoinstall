#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# install.sh - Phase 1 (run from Arch ISO)
# - SAFE auto-detect (ignores USB)
# - Creates GPT, EFI (512MiB) + Btrfs root
# - Creates subvolumes: @, @home, @cache, @log, @tmp, @swap, timeshift-btrfs
# - Mounts subvolumes with BTRFS_MOUNT_OPTS for data subvols, and compress=no for swap/log/cache
# - pacstrap base system (kernel, intel-ucode, networkmanager, grub, etc.)
#
# Edit variables below before running if you want to tweak them.

MIRROR_COUNTRY="France"
BTRFS_MOUNT_OPTS_COMP="compress=zstd,ssd,noatime,discard=async,space_cache=v2"
BTRFS_MOUNT_OPTS_NOCOMP="compress=no,ssd,noatime,discard=async,space_cache=v2"
EFI_SIZE_M=512
USERNAME="carlos"
HOSTNAME="archvm"
PACSTRAP_PKGS=(base linux linux-firmware intel-ucode btrfs-progs \
               networkmanager openssh grub efibootmgr dosfstools sudo)

echog(){ printf "\n==> %s\n" "$*"; }
echow(){ printf "\nWARN: %s\n" "$*"; }
echof(){ printf "\nERROR: %s\n" "$*"; exit 1; }

if [[ $EUID -ne 0 ]]; then
  echof "Run this script as root (sudo ./install.sh)"
fi

echog "Phase 1: pre-install tasks"

# Ensure network
echog "Checking network..."
if ! ping -c1 archlinux.org >/dev/null 2>&1; then
  echow "No network detected. If you're using Wi-Fi, run 'iwctl' to connect."
  read -rp "Press ENTER once network is ready (or Ctrl+C to abort) "
fi

# Try to get fast France mirrors
if command -v reflector >/dev/null 2>&1; then
  echog "Selecting best ${MIRROR_COUNTRY} mirrors using reflector..."
  reflector --country "${MIRROR_COUNTRY}" --latest 10 --sort rate --save /etc/pacman.d/mirrorlist || echow "reflector failed; continuing with default mirrors"
else
  # install reflector temporarily
  echog "Installing reflector to choose fast mirrors..."
  pacman -Sy --noconfirm reflector >/dev/null 2>&1 || echow "Could not install reflector; continuing with existing mirrorlist"
  if command -v reflector >/dev/null 2>&1; then
    reflector --country "${MIRROR_COUNTRY}" --latest 10 --sort rate --save /etc/pacman.d/mirrorlist || echow "reflector failed; continuing"
  fi
fi

# Detect internal disks (exclude removable/usb)
echog "Detecting internal disks (non-USB)..."
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
btrfs subvolume create /mnt/timeshift-btrfs || true
umount /mnt

# Mount subvolumes
echog "Mounting subvolumes..."
mount -o "subvol=@,${BTRFS_MOUNT_OPTS_COMP}" "$ROOT_PART" /mnt
mkdir -p /mnt/{home,var,var/cache,var/log,tmp,swap,efi}
mount -o "subvol=@home,${BTRFS_MOUNT_OPTS_COMP}" "$ROOT_PART" /mnt/home
mount -o "subvol=@cache,${BTRFS_MOUNT_OPTS_NOCOMP}" "$ROOT_PART" /mnt/var/cache
mount -o "subvol=@log,${BTRFS_MOUNT_OPTS_NOCOMP}" "$ROOT_PART" /mnt/var/log
mount -o "subvol=@tmp,${BTRFS_MOUNT_OPTS_NOCOMP}" "$ROOT_PART" /mnt/tmp
# mount swap subvol with no compression
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
cat > /mnt/root/chroot.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

USERNAME="carlos"
HOSTNAME="archvm"
LOCALE="en_US.UTF-8"
TIMEZONE="Europe/Paris"
BTRFS_MOUNT_OPTS="compress=zstd,ssd,noatime,discard=async,space_cache=v2"
SWAPFILE_SIZE="8G"

echog(){ printf "\n==> %s\n" "$*"; }
echow(){ printf "\nWARN: %s\n" "$*"; }
echof(){ printf "\nERROR: %s\n" "$*"; exit 1; }

# Minimal check we are inside chroot
if [[ ! -f /etc/fstab ]]; then echof "Please run this script inside arch-chroot /mnt"; fi

echog "Setting timezone to ${TIMEZONE}..."
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc

echog "Generating locales..."
if ! grep -q "^${LOCALE}" /etc/locale.gen; then
  sed -i "s/^#${LOCALE}/${LOCALE}/" /etc/locale.gen || true
fi
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf
export LANG=${LOCALE}

echog "Setting hostname..."
echo "${HOSTNAME}" >/etc/hostname
cat >> /etc/hosts <<HOSTS
127.0.0.1	localhost
::1		localhost
127.0.1.1	${HOSTNAME}.localdomain ${HOSTNAME}
HOSTS

echog "Setting root password (you will be prompted)..."
passwd

echog "Creating user ${USERNAME} and adding to wheel..."
useradd -m -G wheel,audio,optical,video,input -s /bin/bash "${USERNAME}"
echo "Set password for ${USERNAME}:"
passwd "${USERNAME}"
# enable sudo for wheel
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers || true

echog "Enabling NetworkManager and sshd..."
systemctl enable NetworkManager
systemctl enable sshd

# Create swapfile safely on Btrfs inside /swap (mounted from @swap)
echog "Creating Btrfs-compatible swapfile of size ${SWAPFILE_SIZE} at /swap/swapfile..."
mkdir -p /swap
# ensure COW is disabled on /swap directory (chattr +C)
chattr +C /swap || echow "chattr +C /swap failed (maybe not supported); continuing"
# ensure compression disabled on this subvol (btrfs property)
btrfs property set /swap compression none || true

# create swapfile
truncate -s 0 /swap/swapfile
# allocate space (use dd to avoid fallocate on btrfs)
dd if=/dev/zero of=/swap/swapfile bs=1M count=$(( ${SWAPFILE_SIZE%G} * 1024 )) status=progress || true
chmod 600 /swap/swapfile
mkswap /swap/swapfile
swapon /swap/swapfile
echo "/swap/swapfile none swap defaults 0 0" >> /etc/fstab

echog "Enabling fstrim timer (SSD maintenance) and systemd services..."
systemctl enable fstrim.timer

echog "Installing yay prerequisites and building yay as user ${USERNAME}..."
pacman -S --noconfirm --needed git base-devel
su - "${USERNAME}" -c "cd ~ && git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si --noconfirm" || echow "Building yay failed; build manually later."

echog "Installing timeshift and basic desktop packages (will be expanded in post-install)..."
pacman -S --noconfirm --needed timeshift flatpak firefox kitty nautilus

# Note about Timeshift: timeshift-autosnap will be installed via yay in post-install
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

  2) After the chroot script finishes:
       exit
       umount -R /mnt
       reboot

  3) After first boot, log in as '${USERNAME}' and run the Phase 3 script (post-install.sh)
     (I provide post-install.sh below — save and run it as your user).

INSTR

exit 0
