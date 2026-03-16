#!/usr/bin/env bash
# swap.sh — zram-generator/zram-init, optional swap file/partition, build-time swap
source "${LIB_DIR}/protection.sh"

# Minimum RAM (KiB) for heavy compilation (SpiderMonkey, Rust, etc.)
: "${BUILD_SWAP_THRESHOLD_KIB:=8388608}"  # 8 GiB
readonly BUILD_SWAP_FILE="${MOUNTPOINT:-/mnt/gentoo}/build-swap"

# ensure_build_swap — Create temporary swap if RAM is insufficient for compilation
# Called from outer process (before chroot). Swap is kernel-level so it works inside chroot too.
ensure_build_swap() {
    [[ "${DRY_RUN:-0}" == "1" ]] && return 0

    local mem_total_kib
    mem_total_kib=$(awk '/MemTotal/{print $2}' /proc/meminfo) || return 0

    local swap_total_kib
    swap_total_kib=$(awk '/SwapTotal/{print $2}' /proc/meminfo) || true
    : "${swap_total_kib:=0}"

    local available_kib=$(( mem_total_kib + swap_total_kib ))

    if (( available_kib >= BUILD_SWAP_THRESHOLD_KIB )); then
        return 0
    fi

    local needed_kib=$(( BUILD_SWAP_THRESHOLD_KIB - available_kib ))
    local needed_mib=$(( (needed_kib + 1023) / 1024 ))

    einfo "Low memory detected: $(( mem_total_kib / 1024 )) MiB RAM + $(( swap_total_kib / 1024 )) MiB swap"
    einfo "Creating temporary ${needed_mib} MiB build swap..."

    if [[ -f "${BUILD_SWAP_FILE}" ]]; then
        swapoff "${BUILD_SWAP_FILE}" 2>/dev/null || true
        rm -f "${BUILD_SWAP_FILE}"
    fi

    dd if=/dev/zero of="${BUILD_SWAP_FILE}" bs=1M count="${needed_mib}" status=none 2>/dev/null || {
        ewarn "Could not create build swap file (not enough disk space?)"
        return 0
    }
    chmod 0600 "${BUILD_SWAP_FILE}"
    mkswap "${BUILD_SWAP_FILE}" >/dev/null 2>&1 || { rm -f "${BUILD_SWAP_FILE}"; return 0; }
    swapon "${BUILD_SWAP_FILE}" 2>/dev/null || { rm -f "${BUILD_SWAP_FILE}"; return 0; }

    einfo "Temporary build swap active: ${needed_mib} MiB"
}

# cleanup_build_swap — Remove temporary build swap
cleanup_build_swap() {
    [[ "${DRY_RUN:-0}" == "1" ]] && return 0

    if [[ -f "${BUILD_SWAP_FILE}" ]]; then
        swapoff "${BUILD_SWAP_FILE}" 2>/dev/null || true
        rm -f "${BUILD_SWAP_FILE}"
        einfo "Temporary build swap removed"
    fi
}

# swap_setup — Configure swap based on SWAP_TYPE
swap_setup() {
    local swap_type="${SWAP_TYPE:-zram}"

    case "${swap_type}" in
        zram)
            swap_setup_zram
            ;;
        partition)
            # Already set up during disk phase, just ensure fstab entry
            einfo "Swap partition configured during disk setup"
            ;;
        file)
            swap_setup_file
            ;;
        none)
            einfo "No swap configured"
            ;;
    esac
}

# swap_setup_zram — Install and configure zram
swap_setup_zram() {
    einfo "Setting up zram swap..."

    if [[ "${INIT_SYSTEM:-systemd}" == "systemd" ]]; then
        # Use zram-generator for systemd
        try "Installing zram-generator" emerge --quiet sys-apps/zram-generator

        mkdir -p /etc/systemd
        cat > /etc/systemd/zram-generator.conf << 'ZRAMEOF'
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
ZRAMEOF

        try "Enabling zram-generator" systemctl daemon-reload

        einfo "zram-generator configured"
    else
        # Use zram-init for OpenRC
        try "Installing zram-init" emerge --quiet sys-block/zram-init

        # Configure zram-init
        if [[ -f /etc/conf.d/zram-init ]]; then
            cat >> /etc/conf.d/zram-init << 'ZRAMEOF'

# Gentoo TUI Installer: zram swap configuration
type0="swap"
flag0=""
size0="$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 2 ))K"
mlim0=""
back0=""
icmp0=""
algo0="zstd"
labl0="zram_swap"
uuid0=""
ZRAMEOF
        fi

        try "Enabling zram-init" rc-update add zram-init boot

        einfo "zram-init configured"
    fi
}

# swap_setup_file — Create and configure a swap file
swap_setup_file() {
    local size_mib="${SWAP_SIZE_MIB:-${SWAP_DEFAULT_SIZE_MIB}}"
    local swap_file="/swapfile"

    einfo "Creating ${size_mib} MiB swap file..."

    if [[ "${FILESYSTEM:-ext4}" == "btrfs" ]]; then
        # btrfs requires special handling for swap files
        try "Creating btrfs swap file" \
            btrfs filesystem mkswapfile --size "${size_mib}m" "${swap_file}"
    else
        try "Allocating swap file" \
            dd if=/dev/zero of="${swap_file}" bs=1M count="${size_mib}" status=progress
        chmod 0600 "${swap_file}"
        try "Formatting swap file" mkswap "${swap_file}"
    fi

    # Add to fstab
    echo "${swap_file}    none    swap    sw    0 0" >> /etc/fstab

    einfo "Swap file created: ${swap_file} (${size_mib} MiB)"
}
