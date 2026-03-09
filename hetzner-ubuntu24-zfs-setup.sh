#!/bin/bash

: <<'end_header_info'
(c) Andrey Prokopenko job@terem.fr
(c) 2026 Joe Kappus joe@wt.gd
fully automatic script to install Ubuntu 24 with ZFS root on Hetzner VPS
WARNING: all data on the disk will be destroyed
How to use: add SSH key to the rescue console, then press "mount rescue and power cycle" button
Next, connect via SSH to console, and run the script
Answer script questions about desired hostname and ZFS ARC cache size
To cope with network failures its higly recommended to run the script inside screen console
screen -dmS zfs
screen -r zfs
To detach from screen console, hit Ctrl-d then a
end_header_info

set -euo pipefail

# ---- Configuration ----
SYSTEM_HOSTNAME=""
ROOT_PASSWORD=""
ZFS_POOL=""
UBUNTU_CODENAME="noble"   # Ubuntu 24.04
TARGET="/mnt/ubuntu"
ENCRYPT_ROOT=0             # 0=false, 1=true
LUKS_PASSPHRASE=""
LUKS_DEVICE_NAME="cryptroot"

# Hetzner mirrors
MIRROR_SITE="https://mirror.hetzner.com"
MIRROR_MAIN="deb ${MIRROR_SITE}/ubuntu/packages ${UBUNTU_CODENAME} main restricted universe multiverse"
MIRROR_UPDATES="deb ${MIRROR_SITE}/ubuntu/packages ${UBUNTU_CODENAME}-updates main restricted universe multiverse"
MIRROR_BACKPORTS="deb ${MIRROR_SITE}/ubuntu/packages ${UBUNTU_CODENAME}-backports main restricted universe multiverse"
MIRROR_SECURITY="deb ${MIRROR_SITE}/ubuntu/security ${UBUNTU_CODENAME}-security main restricted universe multiverse"

# Global variables
INSTALL_DISK=""
EFI_MODE=false
BOOT_PART=""
ZFS_PART=""
ZFS_DEVICE=""  # either raw partition or /dev/mapper/cryptroot

# ---- User Input Functions ----
function setup_whiptail_colors {
    # Green text on black background - classic terminal theme
    export NEWT_COLORS='
    root=green,black
    window=green,black
    shadow=green,black
    border=green,black
    title=green,black
    textbox=green,black
    button=black,green
    listbox=green,black
    actlistbox=black,green
    actsellistbox=black,green
    checkbox=green,black
    actcheckbox=black,green
    entry=green,black
    label=green,black
    '
}

function check_whiptail {
    if ! command -v whiptail &> /dev/null; then
        echo "Installing whiptail..."
        apt update
        apt install -y whiptail
    fi
    setup_whiptail_colors
}

function get_hostname {
    while true; do
        SYSTEM_HOSTNAME=$(whiptail \
            --title "System Hostname" \
            --inputbox "Enter the hostname for the new system:" \
            10 60 "zfs-ubuntu" \
            3>&1 1>&2 2>&3)

        local exit_status=$?
        if [ $exit_status -ne 0 ]; then
            whiptail --title "Cancelled" --msgbox "Installation cancelled by user." 10 50
            exit 1
        fi

        # Validate hostname
        if [[ "$SYSTEM_HOSTNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9]$ ]] && [[ ${#SYSTEM_HOSTNAME} -le 63 ]]; then
            break
        else
            whiptail \
                --title "Invalid Hostname" \
                --msgbox "Invalid hostname. Please use only letters, numbers, and hyphens. Must start and end with alphanumeric character. Maximum 63 characters." \
                12 60
        fi
    done
}

function get_zfs_pool_name {
    while true; do
        ZFS_POOL=$(whiptail \
            --title "ZFS Pool Name" \
            --inputbox "Enter the name for the ZFS pool:" \
            10 60 "rpool" \
            3>&1 1>&2 2>&3)

        local exit_status=$?
        if [ $exit_status -ne 0 ]; then
            whiptail --title "Cancelled" --msgbox "Installation cancelled by user." 10 50
            exit 1
        fi

        # Validate ZFS pool name
        if [[ "$ZFS_POOL" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]] && [[ ${#ZFS_POOL} -le 255 ]]; then
            break
        else
            whiptail \
                --title "Invalid Pool Name" \
                --msgbox "Invalid ZFS pool name. Must start with a letter and contain only letters, numbers, hyphens, and underscores. Maximum 255 characters." \
                12 60
        fi
    done
}

function get_root_password {
    while true; do
        local password1
        local password2

        password1=$(whiptail \
            --title "Root Password" \
            --passwordbox "Enter root password (input hidden):" \
            10 60 \
            3>&1 1>&2 2>&3)

        local exit_status=$?
        if [ $exit_status -ne 0 ]; then
            whiptail --title "Cancelled" --msgbox "Installation cancelled by user." 10 50
            exit 1
        fi

        password2=$(whiptail \
            --title "Confirm Root Password" \
            --passwordbox "Confirm root password (input hidden):" \
            10 60 \
            3>&1 1>&2 2>&3)

        exit_status=$?
        if [ $exit_status -ne 0 ]; then
            whiptail --title "Cancelled" --msgbox "Installation cancelled by user." 10 50
            exit 1
        fi

        if [ "$password1" = "$password2" ]; then
            if [ -n "$password1" ]; then
                ROOT_PASSWORD="$password1"
                break
            else
                whiptail \
                    --title "Empty Password" \
                    --msgbox "Password cannot be empty. Please enter a password." \
                    10 50
            fi
        else
            whiptail \
                --title "Password Mismatch" \
                --msgbox "Passwords do not match. Please try again." \
                10 50
        fi
    done
}

function ask_encryption {
    if whiptail \
        --title "LUKS Disk Encryption" \
        --defaultno \
        --yesno "Do you want to encrypt the root disk with LUKS?\n\nThis enables full disk encryption with dm-crypt/LUKS.\nYou will need to enter a passphrase at boot (via dropbear SSH)." \
        12 70; then
        ENCRYPT_ROOT=1

        while true; do
            local pass1
            local pass2

            pass1=$(whiptail \
                --title "LUKS Passphrase" \
                --passwordbox "Enter LUKS encryption passphrase (input hidden):" \
                10 60 \
                3>&1 1>&2 2>&3)

            local exit_status=$?
            if [ $exit_status -ne 0 ]; then
                whiptail --title "Cancelled" --msgbox "Installation cancelled by user." 10 50
                exit 1
            fi

            pass2=$(whiptail \
                --title "Confirm LUKS Passphrase" \
                --passwordbox "Confirm LUKS encryption passphrase (input hidden):" \
                10 60 \
                3>&1 1>&2 2>&3)

            exit_status=$?
            if [ $exit_status -ne 0 ]; then
                whiptail --title "Cancelled" --msgbox "Installation cancelled by user." 10 50
                exit 1
            fi

            if [ "$pass1" = "$pass2" ]; then
                if [ -n "$pass1" ]; then
                    LUKS_PASSPHRASE="$pass1"
                    break
                else
                    whiptail \
                        --title "Empty Passphrase" \
                        --msgbox "Passphrase cannot be empty. Please enter a passphrase." \
                        10 50
                fi
            else
                whiptail \
                    --title "Passphrase Mismatch" \
                    --msgbox "Passphrases do not match. Please try again." \
                    10 50
            fi
        done
    fi
}

function show_summary_and_confirm {
    local encryption_status="No"
    if [ "$ENCRYPT_ROOT" = "1" ]; then
        encryption_status="Yes (LUKS + dropbear SSH unlock)"
    fi

    local summary
    summary="Please review the installation settings:

Hostname: $SYSTEM_HOSTNAME
ZFS Pool: $ZFS_POOL
Ubuntu Version: $UBUNTU_CODENAME (24.04)
Target: $TARGET
Boot Mode: $([ "$EFI_MODE" = true ] && echo "EFI" || echo "BIOS")
Install Disk: $INSTALL_DISK
Encryption: $encryption_status

*** WARNING: This will DESTROY ALL DATA on $INSTALL_DISK! ***

Do you want to continue with the installation?"

    if whiptail \
        --title " Installation Summary " \
        --yesno "$summary" \
        20 60; then
        echo "User confirmed installation. Starting now..."
    else
        echo "Installation cancelled by user."
        exit 1
    fi
}

function get_user_input {
    echo "======= Gathering Installation Parameters =========="
    check_whiptail

    # Show welcome message
    whiptail \
        --title "ZFS Ubuntu Installer" \
        --msgbox "Welcome to the ZFS Ubuntu Installer for Hetzner Cloud.\n\nThis script will install Ubuntu 24.04 with ZFS root on your server." \
        12 60

    get_hostname
    get_zfs_pool_name
    get_root_password
    ask_encryption
}

# ---- System Detection Functions ----
function detect_efi {
    echo "======= Detecting EFI support =========="

    if [ -d /sys/firmware/efi ]; then
        echo "EFI firmware detected"
        EFI_MODE=true
    else
        echo "Legacy BIOS mode detected"
        EFI_MODE=false
    fi
}

function find_install_disk {
    echo "======= Finding install disk =========="

    local candidate_disks=()

    while IFS= read -r disk; do
        [[ -n "$disk" ]] && candidate_disks+=("$disk")
    done < <(lsblk -npo NAME,TYPE,RO,MOUNTPOINT | awk '
        $2 == "disk" && $3 == "0" && $4 == "" {print $1}
    ')

    if [[ ${#candidate_disks[@]} -eq 0 ]]; then
        echo "No suitable installation disks found" >&2
        echo "Looking for: unmounted, writable disks without partitions in use" >&2
        exit 1
    fi

    INSTALL_DISK="${candidate_disks[0]}"
    echo "Using installation disk: $INSTALL_DISK"

    echo "All available disks:"
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,RO | grep -v loop
}

# ---- Rescue System Preparation Functions ----
function remove_unused_kernels {
    echo "=========== Removing unused kernels in rescue system =========="
    for kver in $(find /lib/modules/* -maxdepth 0 -type d \
                    | grep -v "$(uname -r)" \
                    | cut -s -d "/" -f 4); do

        for pkg in "linux-headers-$kver" "linux-image-$kver"; do
            if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
                echo "Purging $pkg ..."
                apt purge --yes "$pkg"
            else
                echo "Package $pkg not installed, skipping."
            fi
        done
    done
}

function install_zfs_on_rescue_system {
    echo "======= Installing ZFS on rescue system =========="
    echo "zfs-dkms zfs-dkms/note-incompatible-licenses note true" | debconf-set-selections
    # Enable backports for the rescue system's release
    local rescue_codename
    # shellcheck disable=SC1091
    rescue_codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
    sed -i "s/^# deb http:\/\/mirror.hetzner.com\/debian\/packages ${rescue_codename}-backports/deb http:\/\/mirror.hetzner.com\/debian\/packages ${rescue_codename}-backports/" /etc/apt/sources.list
    apt update
    apt -t "${rescue_codename}-backports" install -y zfsutils-linux
}

# ---- Disk Partitioning Functions ----
function partition_disk {
    echo "======= Partitioning disk =========="
    sgdisk -Z "$INSTALL_DISK"

    if [ "$EFI_MODE" = true ]; then
        echo "Creating EFI partition layout"
        # BIOS boot partition (for grub hybrid)
        sgdisk -a1 -n1:24K:+1000K -t1:EF02 -c1:"bios_grub" "$INSTALL_DISK"
        # EFI System Partition
        sgdisk -n2:1M:+512M -t2:EF00 -c2:"EFI" "$INSTALL_DISK"
        # Boot pool partition
        sgdisk -n3:0:+2G -t3:BF01 -c3:"bpool" "$INSTALL_DISK"
        # Root partition (ZFS or LUKS+ZFS)
        sgdisk -n4:0:0 -t4:BF01 -c4:"rpool" "$INSTALL_DISK"
    else
        echo "Creating BIOS partition layout"
        # BIOS boot partition
        sgdisk -a1 -n1:24K:+1000K -t1:EF02 -c1:"bios_grub" "$INSTALL_DISK"
        # Boot pool partition
        sgdisk -n2:1M:+2G -t2:BF01 -c2:"bpool" "$INSTALL_DISK"
        # Root partition (ZFS or LUKS+ZFS)
        sgdisk -n3:0:0 -t3:BF01 -c3:"rpool" "$INSTALL_DISK"
    fi

    partprobe "$INSTALL_DISK" || true
    udevadm settle

    # Set partition variables
    if [ "$EFI_MODE" = true ]; then
        BOOT_PART="$(blkid -t PARTLABEL='EFI' -o device)"
        local BPOOL_PART
        BPOOL_PART="$(blkid -t PARTLABEL='bpool' -o device)"
        ZFS_PART="$(blkid -t PARTLABEL='rpool' -o device)"
        mkfs.fat -F 32 -n EFI "$BOOT_PART"
    else
        local BPOOL_PART
        BPOOL_PART="$(blkid -t PARTLABEL='bpool' -o device)"
        ZFS_PART="$(blkid -t PARTLABEL='rpool' -o device)"
    fi

    # Export BPOOL_PART for use by pool creation
    export BPOOL_PART
}

function setup_luks {
    echo "======= Setting up LUKS encryption =========="
    apt install -y cryptsetup

    echo -n "$LUKS_PASSPHRASE" | cryptsetup luksFormat --type luks2 "$ZFS_PART" -

    echo -n "$LUKS_PASSPHRASE" | cryptsetup open --type luks2 "$ZFS_PART" "$LUKS_DEVICE_NAME" -

    ZFS_DEVICE="/dev/mapper/$LUKS_DEVICE_NAME"
    echo "LUKS device opened at $ZFS_DEVICE"
}

# ---- ZFS Pool and Dataset Functions ----
function create_zfs_pools {
    echo "======= Creating ZFS pools =========="
    export PATH=/usr/sbin:$PATH
    modprobe zfs

    # If not encrypting, ZFS goes directly on the partition
    if [ "$ENCRYPT_ROOT" != "1" ]; then
        ZFS_DEVICE="$ZFS_PART"
    fi

    # Create boot pool (unencrypted, on separate partition)
    zpool create -f \
        -o ashift=12 \
        -o cachefile=/etc/zpool.cache \
        -O compression=lz4 \
        -O canmount=off \
        -O devices=off \
        -O mountpoint=/boot \
        -R "$TARGET" \
        bpool "$BPOOL_PART"

    # Create root pool
    zpool create -f \
        -o ashift=12 \
        -o cachefile=/etc/zpool.cache \
        -O compression=lz4 \
        -O acltype=posixacl \
        -O xattr=sa \
        -O canmount=off \
        -O mountpoint=/ \
        -R "$TARGET" \
        "$ZFS_POOL" "$ZFS_DEVICE"

    # Create datasets
    zfs create -o canmount=off -o mountpoint=none "$ZFS_POOL/ROOT"
    zfs create -o canmount=noauto -o mountpoint=/ "$ZFS_POOL/ROOT/ubuntu"
    zfs mount "$ZFS_POOL/ROOT/ubuntu"

    zfs create -o canmount=off -o mountpoint=none "bpool/BOOT"
    zfs create -o canmount=noauto -o mountpoint=/boot "bpool/BOOT/ubuntu"
    zfs mount "bpool/BOOT/ubuntu"

    zfs create "$ZFS_POOL/home"
    zfs create -o canmount=off "$ZFS_POOL/var"
    zfs create "$ZFS_POOL/var/log"
    zfs create "$ZFS_POOL/var/spool"
    zfs create -o com.sun:auto-snapshot=false "$ZFS_POOL/var/cache"
    zfs create -o com.sun:auto-snapshot=false "$ZFS_POOL/var/tmp"
    chmod 1777 "$TARGET/var/tmp"
    zfs create "$ZFS_POOL/srv"
    zfs create -o canmount=off "$ZFS_POOL/usr"
    zfs create "$ZFS_POOL/usr/local"
    zfs create "$ZFS_POOL/var/mail"
    zfs create -o com.sun:auto-snapshot=false -o canmount=on -o mountpoint=/tmp "$ZFS_POOL/tmp"
    chmod 1777 "$TARGET/tmp"

    zpool set bootfs="$ZFS_POOL/ROOT/ubuntu" "$ZFS_POOL"
}

# ---- System Bootstrap Functions ----
function bootstrap_ubuntu_system {
    echo "======= Bootstrapping Ubuntu =========="

    # Add Hetzner Ubuntu mirror as trusted
    echo "deb [trusted=yes] http://mirror.hetzner.com/ubuntu/packages noble main" > /etc/apt/sources.list.d/ubuntu-temp.list

    apt-get update
    apt-get -o APT::Sandbox::User=root download ubuntu-keyring

    # shellcheck disable=SC2144
    if [ ! -f ubuntu-keyring*.deb ]; then
        echo "ERROR: Failed to download ubuntu-keyring package"
        exit 1
    fi

    dpkg-deb -x ubuntu-keyring*.deb /tmp/ubuntu-keyring-extract/
    mkdir -p /usr/share/keyrings
    cp /tmp/ubuntu-keyring-extract/usr/share/keyrings/ubuntu-archive-keyring.gpg /usr/share/keyrings/

    rm -f /etc/apt/sources.list.d/ubuntu-temp.list
    apt update
    rm -f ubuntu-keyring*.deb

    debootstrap --arch=amd64 "$UBUNTU_CODENAME" "$TARGET" "${MIRROR_SITE}/ubuntu/packages"

    zfs set devices=off "$ZFS_POOL"
}

function setup_chroot_environment {
    echo "======= Mounting virtual filesystems for chroot =========="
    mount -t proc proc "$TARGET/proc"
    mount -t sysfs sysfs "$TARGET/sys"
    mount -t tmpfs tmpfs "$TARGET/run"
    mount -t tmpfs tmpfs "$TARGET/tmp"
    mount --bind /dev "$TARGET/dev"
    mount --bind /dev/pts "$TARGET/dev/pts"

    configure_dns_resolution
}

function configure_dns_resolution {
    echo "======= Configuring DNS resolution =========="
    mkdir -p "$TARGET/run/systemd/resolve"

    if command -v resolvectl >/dev/null 2>&1; then
        echo "Getting DNS from resolvectl..."

        local DNS_SERVERS
        DNS_SERVERS=$(resolvectl dns | awk '
            /^Global:/ {
                for(i=2; i<=NF; i++) print $i
            }
        ' | head -3)

        if [ -z "$DNS_SERVERS" ]; then
            echo "No global DNS servers found, searching for first non-empty link..."
            DNS_SERVERS=$(resolvectl dns | awk '
                /^Link [0-9]+ / && NF > 3 {
                    for(i=4; i<=NF; i++) print $i
                    exit
                }
            ')
        fi

        if [ -n "$DNS_SERVERS" ]; then
            echo "$DNS_SERVERS" | while read -r dns; do
                echo "nameserver $dns"
            done > "$TARGET/run/systemd/resolve/stub-resolv.conf"
            echo "Using DNS servers: $(echo "$DNS_SERVERS" | tr '\n' ' ')"
        else
            echo "ERROR: No DNS servers found in resolvectl output"
            resolvectl dns
            exit 1
        fi
    else
        echo "ERROR: resolvectl command not found"
        exit 1
    fi
}

# ---- System Configuration Functions ----
function configure_basic_system {
    echo "======= Configuring basic system settings =========="

    # Set up apt sources
    cat > "$TARGET/etc/apt/sources.list" <<EOF
$MIRROR_MAIN
$MIRROR_UPDATES
$MIRROR_BACKPORTS
$MIRROR_SECURITY
EOF

    chroot "$TARGET" /bin/bash <<EOF
set -euo pipefail

echo "$SYSTEM_HOSTNAME" > /etc/hostname

echo "UTC" > /etc/timezone
ln -sf /usr/share/zoneinfo/UTC /etc/localtime

cat > /etc/locale.gen <<'LOCALES'
en_US.UTF-8 UTF-8
LOCALES

locale-gen
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

cat > /etc/default/keyboard <<'KEYBOARD'
XKBMODEL="pc105"
XKBLAYOUT="us"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
KEYBOARD

setupcon --force || true

echo "127.0.0.1 localhost" > /etc/hosts
echo "127.0.1.1 $SYSTEM_HOSTNAME" >> /etc/hosts
echo "::1 localhost ip6-localhost ip6-loopback" >> /etc/hosts
echo "ff02::1 ip6-allnodes" >> /etc/hosts
echo "ff02::2 ip6-allrouters" >> /etc/hosts

chmod 1777 /tmp
chmod 1777 /var/tmp
EOF
}

function install_system_packages {
    echo "======= Installing ZFS and essential packages in chroot =========="
    chroot "$TARGET" /bin/bash <<'EOF'
set -euo pipefail
apt update

apt install -y --no-install-recommends linux-image-generic linux-headers-generic

echo "zfs-dkms zfs-dkms/note-incompatible-licenses note true" | debconf-set-selections
apt install -y zfs-dkms zfsutils-linux zfs-initramfs software-properties-common bash curl nano htop net-tools ssh

echo "zfs" >> /etc/initramfs-tools/modules
EOF
}

function install_grub {
    echo "======= Installing and configuring GRUB =========="

    if [ "$EFI_MODE" = true ]; then
        mkdir -p "$TARGET/boot/efi"
        mount "$BOOT_PART" "$TARGET/boot/efi"
        chroot "$TARGET" /bin/bash <<'EOF'
set -euo pipefail
apt install -y grub-efi-amd64
EOF
        chroot "$TARGET" grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck
    else
        chroot "$TARGET" /bin/bash <<'EOF'
set -euo pipefail
echo 'grub-pc grub-pc/install_devices_empty boolean true' | debconf-set-selections
apt install -y grub-pc
EOF
        chroot "$TARGET" grub-install --recheck "$INSTALL_DISK"
    fi

    chroot "$TARGET" /bin/bash <<EOF
set -euo pipefail
sed -i 's/#GRUB_TERMINAL=console/GRUB_TERMINAL=console/g' /etc/default/grub
sed -i 's|GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT="net.ifnames=0"|' /etc/default/grub
sed -i 's|GRUB_CMDLINE_LINUX=""|GRUB_CMDLINE_LINUX="root=ZFS=$ZFS_POOL/ROOT/ubuntu"|g' /etc/default/grub
sed -i 's/quiet//g' /etc/default/grub
sed -i 's/splash//g' /etc/default/grub
echo 'GRUB_DISABLE_OS_PROBER=true' >> /etc/default/grub
EOF
}

function configure_ssh {
    echo "======= Setting up OpenSSH =========="
    mkdir -p "$TARGET/root/.ssh/"
    cp /root/.ssh/authorized_keys "$TARGET/root/.ssh/authorized_keys"
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/g' "$TARGET/etc/ssh/sshd_config"
    sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/g' "$TARGET/etc/ssh/sshd_config"

    chroot "$TARGET" /bin/bash <<'EOF'
rm /etc/ssh/ssh_host_*
dpkg-reconfigure openssh-server -f noninteractive
EOF
}

function set_root_credentials {
    echo "======= Setting root password =========="
    chroot "$TARGET" /bin/bash -c "echo root:$(printf "%q" "$ROOT_PASSWORD") | chpasswd"

    cat > "$TARGET/root/.bashrc" <<CONF
export PS1='\[\033[01;31m\]\u\[\033[01;33m\]@\[\033[01;32m\]\h \[\033[01;33m\]\w \[\033[01;35m\]\$ \[\033[00m\]'
umask 022
export LS_OPTIONS='--color=auto -h'
eval "\$(dircolors)"
CONF
}

function setup_luks_crypttab {
    echo "======= Configuring crypttab for LUKS =========="
    local luks_uuid
    luks_uuid=$(blkid -s UUID -o value "$ZFS_PART")

    echo "$LUKS_DEVICE_NAME UUID=$luks_uuid none luks,discard,initramfs" > "$TARGET/etc/crypttab"

    # Install cryptsetup in the target
    chroot "$TARGET" /bin/bash <<'EOF'
set -euo pipefail
apt install -y cryptsetup cryptsetup-initramfs
echo "CRYPTSETUP=y" >> /etc/cryptsetup-initramfs/conf-hook
EOF
}

function setup_dropbear {
    echo "======= Setting up dropbear for remote LUKS unlock =========="
    chroot "$TARGET" /bin/bash <<'EOF'
set -euo pipefail
apt install -y dropbear-initramfs
EOF

    mkdir -p "$TARGET/etc/dropbear/initramfs"
    cp /root/.ssh/authorized_keys "$TARGET/etc/dropbear/initramfs/authorized_keys"

    # Convert OpenSSH host keys to dropbear format
    cp "$TARGET/etc/ssh/ssh_host_rsa_key" "$TARGET/etc/ssh/ssh_host_rsa_key_temp"
    chroot "$TARGET" ssh-keygen -p -i -m pem -N '' -f /etc/ssh/ssh_host_rsa_key_temp
    chroot "$TARGET" /usr/lib/dropbear/dropbearconvert openssh dropbear /etc/ssh/ssh_host_rsa_key_temp /etc/dropbear/initramfs/dropbear_rsa_host_key
    rm -f "$TARGET/etc/ssh/ssh_host_rsa_key_temp"

    cp "$TARGET/etc/ssh/ssh_host_ecdsa_key" "$TARGET/etc/ssh/ssh_host_ecdsa_key_temp"
    chroot "$TARGET" ssh-keygen -p -i -m pem -N '' -f /etc/ssh/ssh_host_ecdsa_key_temp
    chroot "$TARGET" /usr/lib/dropbear/dropbearconvert openssh dropbear /etc/ssh/ssh_host_ecdsa_key_temp /etc/dropbear/initramfs/dropbear_ecdsa_host_key
    rm -f "$TARGET/etc/ssh/ssh_host_ecdsa_key_temp"

    # Remove DSS key if present
    rm -f "$TARGET/etc/dropbear/initramfs/dropbear_dss_host_key"
}

function setup_initramfs_networking {
    echo "======= Setting up initramfs networking hook =========="
    mkdir -p "$TARGET/usr/share/initramfs-tools/scripts/init-premount"
    cat > "$TARGET/usr/share/initramfs-tools/scripts/init-premount/static-route" <<'CONF'
#!/bin/sh
PREREQ=""
prereqs()
{
    echo "$PREREQ"
}

case $1 in
prereqs)
    prereqs
    exit 0
    ;;
esac

. /scripts/functions
# Begin real processing below this line

configure_networking
CONF

    chmod 755 "$TARGET/usr/share/initramfs-tools/scripts/init-premount/static-route"
}

# ---- System Services Functions ----
function configure_system_services {
    echo "======= Configuring ZFS cachefile in chrooted system =========="
    mkdir -p "$TARGET/etc/zfs"
    cp /etc/zpool.cache "$TARGET/etc/zfs/zpool.cache"

    echo "======= Enabling essential system services =========="
    chroot "$TARGET" /bin/bash <<'EOF'
set -euo pipefail

systemctl enable systemd-resolved
systemctl enable systemd-timesyncd

systemctl enable zfs-import-cache
systemctl enable zfs-mount

systemctl enable ssh
systemctl enable apt-daily.timer
EOF
}

function configure_networking {
    echo "======= Configuring Netplan for Hetzner Cloud =========="
    chroot "$TARGET" /bin/bash <<'EOF'
set -euo pipefail
mkdir -p /etc/netplan
cat > /etc/netplan/01-hetzner.yaml <<'EOL'
network:
  version: 2
  renderer: networkd
  ethernets:
    all-interfaces:
      match:
        name: "!lo"
      dhcp4: true
      dhcp6: true
      dhcp4-overrides:
        use-dns: true
        use-hostname: true
        use-domains: true
        route-metric: 100
      dhcp6-overrides:
        use-dns: true
        use-hostname: true
        use-domains: true
        route-metric: 100
      critical: true
EOL

chmod 600 /etc/netplan/01-hetzner.yaml
chown root:root /etc/netplan/01-hetzner.yaml
netplan generate
EOF
}

function finalize_initramfs_and_grub {
    echo "======= Updating initramfs and GRUB =========="
    chroot "$TARGET" /bin/bash <<'EOF'
set -euo pipefail
echo RESUME=none > /etc/initramfs-tools/conf.d/resume
update-initramfs -u -k all
update-grub
EOF
}

function set_mountpoints_and_fstab {
    echo "======= Setting mountpoints and fstab =========="

    chroot "$TARGET" /bin/bash <<EOF
set -euo pipefail

zfs set mountpoint=legacy bpool/BOOT/ubuntu
echo "bpool/BOOT/ubuntu /boot zfs nodev,relatime,x-systemd.requires=zfs-mount.service,x-systemd.device-timeout=10 0 0" > /etc/fstab

zfs set mountpoint=legacy $ZFS_POOL/var/log
echo "$ZFS_POOL/var/log /var/log zfs nodev,relatime 0 0" >> /etc/fstab

zfs set mountpoint=legacy $ZFS_POOL/var/spool
echo "$ZFS_POOL/var/spool /var/spool zfs nodev,relatime 0 0" >> /etc/fstab

zfs set mountpoint=legacy $ZFS_POOL/var/tmp
echo "$ZFS_POOL/var/tmp /var/tmp zfs nodev,relatime 0 0" >> /etc/fstab

zfs set mountpoint=legacy $ZFS_POOL/tmp
echo "$ZFS_POOL/tmp /tmp zfs nodev,relatime 0 0" >> /etc/fstab
EOF

    if [ "$EFI_MODE" = true ]; then
        echo "PARTLABEL=EFI /boot/efi vfat defaults 0 0" >> "$TARGET/etc/fstab"
    fi
}

# ---- Cleanup and Finalization Functions ----
function unmount_chroot_environment {
    echo "======= Unmounting virtual filesystems =========="
    for dir in dev/pts dev tmp run sys proc; do
        if mountpoint -q "$TARGET/$dir"; then
            echo "Unmounting $TARGET/$dir"
            umount "$TARGET/$dir" 2>/dev/null || true
        fi
    done
}

function unmount_and_export {
    echo "======= Unmounting filesystems and exporting pools =========="

    if [ "$EFI_MODE" = true ] && mountpoint -q "$TARGET/boot/efi"; then
        umount "$TARGET/boot/efi" 2>/dev/null || true
    fi

    zfs umount -a 2>/dev/null || true

    if mountpoint -q "$TARGET"; then
        umount "$TARGET" 2>/dev/null || true
    fi

    zpool export bpool 2>/dev/null || true
    zpool export "$ZFS_POOL" 2>/dev/null || true

    if [ "$ENCRYPT_ROOT" = "1" ]; then
        cryptsetup close "$LUKS_DEVICE_NAME" 2>/dev/null || true
    fi
}

function show_final_instructions {
    echo ""
    echo "=========================================="
    echo "  INSTALLATION COMPLETE!"
    echo "=========================================="
    echo ""
    echo "System Information:"
    echo "  Hostname: $SYSTEM_HOSTNAME"
    echo "  ZFS Pool: $ZFS_POOL"
    echo "  Boot Mode: $([ "$EFI_MODE" = true ] && echo "EFI" || echo "BIOS")"
    echo "  Ubuntu Version: $UBUNTU_CODENAME"
    if [ "$ENCRYPT_ROOT" = "1" ]; then
        echo "  Encryption: LUKS (dm-crypt)"
        echo "  Remote Unlock: dropbear SSH on boot"
        echo ""
        echo "  To unlock at boot:"
        echo "    ssh root@<server-ip>"
        echo "    Then enter your LUKS passphrase when prompted"
    fi
    echo ""
    echo "=========================================="
    echo "Rebooting..."
}

# ---- Main Execution Function ----
function main {
    echo "Starting ZFS Ubuntu installation on Hetzner Cloud..."

    # Phase 0: User input
    get_user_input

    # Phase 1: System detection and preparation
    detect_efi
    find_install_disk

    show_summary_and_confirm

    remove_unused_kernels
    install_zfs_on_rescue_system

    # Phase 2: Disk partitioning
    partition_disk

    # Phase 2.5: LUKS encryption (if enabled)
    if [ "$ENCRYPT_ROOT" = "1" ]; then
        setup_luks
    fi

    # Phase 3: ZFS pool and dataset creation
    create_zfs_pools

    # Phase 4: System bootstrap
    bootstrap_ubuntu_system
    setup_chroot_environment

    # Phase 5: System configuration
    configure_basic_system
    install_system_packages
    install_grub
    configure_ssh
    set_root_credentials
    configure_system_services
    configure_networking

    # Phase 6: Encryption support (if enabled)
    if [ "$ENCRYPT_ROOT" = "1" ]; then
        setup_luks_crypttab
        setup_dropbear
        setup_initramfs_networking
    fi

    # Phase 7: Finalize boot
    finalize_initramfs_and_grub
    set_mountpoints_and_fstab

    # Phase 8: Cleanup
    unmount_chroot_environment
    unmount_and_export

    show_final_instructions
    reboot
}

main "$@"
