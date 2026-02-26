#!/usr/bin/env bash
# constants.sh — Global constants for the Gentoo installer
source "${LIB_DIR}/protection.sh"

readonly INSTALLER_VERSION="1.1.0"
readonly INSTALLER_NAME="Gentoo TUI Installer"

# Paths (use defaults, allow override from environment)
: "${MOUNTPOINT:=/mnt/gentoo}"
: "${CHROOT_INSTALLER_DIR:=/tmp/gentoo-installer}"
: "${LOG_FILE:=/tmp/gentoo-installer.log}"
: "${CHECKPOINT_DIR:=/tmp/gentoo-installer-checkpoints}"
: "${CHECKPOINT_DIR_SUFFIX:=/tmp/gentoo-installer-checkpoints}"
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

# GPT partition type GUIDs (for sfdisk)
readonly GPT_TYPE_EFI="C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
readonly GPT_TYPE_LINUX="0FC63DAF-8483-4772-8E79-3D69D8477DE4"
readonly GPT_TYPE_SWAP="0657FD6D-A4AB-43C4-84E5-0933C84B4F4F"

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

# Gum (bundled TUI backend)
: "${GUM_VERSION:=0.17.0}"
: "${GUM_CACHE_DIR:=/tmp/gentoo-installer-gum}"

# Exit codes for TUI screens
readonly TUI_NEXT=0
readonly TUI_BACK=1
readonly TUI_ABORT=2

# Checkpoint names
readonly -a CHECKPOINTS=(
    "preflight"
    "disks"
    "stage3_download"
    "stage3_verify"
    "stage3_extract"
    "portage_preconfig"
    "chroot"
    # Inner chroot checkpoints (managed by _do_chroot_phases):
    "portage_sync"
    "world_update"
    "preserved_rebuild"
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
    EXTRA_PACKAGES
    ENABLE_GURU
    ENABLE_NOCTALIA
    NOCTALIA_COMPOSITOR
    CPU_MARCH
    CPU_FLAGS
    VIDEO_CARDS
    ESP_PARTITION
    ESP_REUSE
    ROOT_PARTITION
    SWAP_PARTITION
    BOOT_PARTITION
    HYBRID_GPU
    IGPU_VENDOR
    IGPU_DEVICE_NAME
    DGPU_VENDOR
    DGPU_DEVICE_NAME
    ASUS_ROG_DETECTED
    ENABLE_ASUSCTL
    WINDOWS_DETECTED
    LINUX_DETECTED
    DETECTED_OSES_SERIALIZED
)
