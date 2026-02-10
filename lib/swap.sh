#!/usr/bin/env bash
# swap.sh — zram-generator/zram-init, optional swap file/partition
source "${LIB_DIR}/protection.sh"

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
        try "Installing zram-generator" emerge --quiet sys-block/zram-generator

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
