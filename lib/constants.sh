#!/usr/bin/env bash
# constants.sh — Global constants for the Gentoo installer
source "${LIB_DIR}/protection.sh"

readonly INSTALLER_VERSION="1.0.0"
readonly INSTALLER_NAME="Gentoo TUI Installer"

# Paths (use defaults, allow override from environment)
: "${MOUNTPOINT:=/mnt/gentoo}"
: "${CHROOT_INSTALLER_DIR:=/tmp/gentoo-installer}"
: "${LOG_FILE:=/tmp/gentoo-installer.log}"
: "${CHECKPOINT_DIR:=/tmp/gentoo-installer-checkpoints}"
: "${CONFIG_FILE:=/tmp/gentoo-installer.conf}"

# Stage3 URLs
readonly GENTOO_DISTFILES_URL="https://distfiles.gentoo.org"
readonly STAGE3_BASE_URL="${GENTOO_DISTFILES_URL}/releases/amd64/autobuilds"
readonly STAGE3_LATEST_URL="${STAGE3_BASE_URL}/latest-stage3-amd64-desktop-systemd.txt"
readonly STAGE3_LATEST_OPENRC_URL="${STAGE3_BASE_URL}/latest-stage3-amd64-desktop-openrc.txt"

# GPG key
readonly GENTOO_GPG_KEY="13EBBDBEDE7A12775DFDB1BABB572E0E2D182910"

# Partition sizes (MiB)
readonly ESP_SIZE_MIB=512
readonly SWAP_DEFAULT_SIZE_MIB=4096

# Emerge defaults
readonly EMERGE_JOBS_DEFAULT=4
readonly EMERGE_LOAD_DEFAULT=4.0

# Profile patterns
readonly PROFILE_SYSTEMD_DESKTOP="default/linux/amd64/23.0/desktop/plasma/systemd"
readonly PROFILE_OPENRC_DESKTOP="default/linux/amd64/23.0/desktop/plasma"

# GRUB
readonly GRUB_PLATFORMS="efi-64"

# Timeouts
readonly COUNTDOWN_DEFAULT=10
readonly DIALOG_TIMEOUT=0

# Exit codes for TUI screens
readonly TUI_NEXT=0
readonly TUI_BACK=1
readonly TUI_ABORT=2

# Checkpoint names
readonly -a CHECKPOINTS=(
    "preflight"
    "disks"
    "stage3"
    "portage_preconfig"
    "portage_sync"
    "world_update"
    "system_config"
    "kernel"
    "fstab"
    "networking"
    "bootloader"
    "swap_setup"
    "desktop"
    "users"
    "extras"
    "finalize"
)

# Configuration variable names (for save/load)
readonly -a CONFIG_VARS=(
    INIT_SYSTEM
    TARGET_DISK
    PARTITION_SCHEME
    FILESYSTEM
    BTRFS_SUBVOLUMES
    SWAP_TYPE
    SWAP_SIZE_MIB
    HOSTNAME
    MIRROR_URL
    TIMEZONE
    LOCALE
    KEYMAP
    KERNEL_TYPE
    GPU_VENDOR
    GPU_DRIVER
    GPU_USE_NVIDIA_OPEN
    DESKTOP_EXTRAS
    ROOT_PASSWORD_HASH
    USERNAME
    USER_PASSWORD_HASH
    USER_GROUPS
    ENABLE_SSH
    EXTRA_PACKAGES
    ENABLE_GURU
    ENABLE_NOCTALIA
    CPU_MARCH
    CPU_FLAGS
    VIDEO_CARDS
    ESP_PARTITION
    ESP_REUSE
    ROOT_PARTITION
    SWAP_PARTITION
    BOOT_PARTITION
)
