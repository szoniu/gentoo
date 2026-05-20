#!/usr/bin/env bash
# swap.sh — zram-generator/zram-init, optional swap file/partition, build-time swap
source "${LIB_DIR}/protection.sh"

# Target TOTAL memory (RAM+swap, KiB) for the chroot build. The global
# MAKEOPTS is -j(nproc+1); heavy C++ (KDE/Qt moc, breeze, oxygen, etc.)
# can use ~1.5-2 GiB per cc1plus. 8 GiB was far too low — a 12 GiB GPD
# Pocket 4 sailed past the old threshold and then OOM-killed cc1plus on
# breeze/oxygen/plasma-vault/kimageformats. Top up to 24 GiB total so
# -j17 heavy builds have headroom (combined with per-package throttle).
: "${BUILD_SWAP_TARGET_KIB:=25165824}"  # 24 GiB
readonly BUILD_SWAP_FILE="${MOUNTPOINT:-/mnt/gentoo}/build-swap"

# ensure_build_swap — Create temporary swap if RAM is insufficient for compilation.
# Called from the outer process before the chroot phase (both CLI run_pre_chroot
# and TUI _execute_chroot_phase). Swap is kernel-level so it works inside chroot.
# Idempotent: safe to call from multiple sites / on --resume.
ensure_build_swap() {
    [[ "${DRY_RUN:-0}" == "1" ]] && return 0

    # Already active? (multiple call sites + resume re-entry)
    if swapon --show=NAME --noheadings 2>/dev/null | grep -qF "${BUILD_SWAP_FILE}"; then
        return 0
    fi

    local mem_total_kib swap_total_kib
    mem_total_kib=$(awk '/MemTotal/{print $2}' /proc/meminfo) || return 0
    swap_total_kib=$(awk '/SwapTotal/{print $2}' /proc/meminfo) || true
    : "${swap_total_kib:=0}"

    local available_kib=$(( mem_total_kib + swap_total_kib ))
    if (( available_kib >= BUILD_SWAP_TARGET_KIB )); then
        return 0
    fi

    local needed_kib=$(( BUILD_SWAP_TARGET_KIB - available_kib ))
    local needed_mib=$(( (needed_kib + 1023) / 1024 ))

    einfo "Low build memory: $(( mem_total_kib / 1024 )) MiB RAM + $(( swap_total_kib / 1024 )) MiB swap"
    einfo "Creating ${needed_mib} MiB temporary build swap (target $(( BUILD_SWAP_TARGET_KIB / 1024 / 1024 )) GiB total)..."

    if [[ -f "${BUILD_SWAP_FILE}" ]]; then
        swapoff "${BUILD_SWAP_FILE}" 2>/dev/null || true
        rm -f "${BUILD_SWAP_FILE}"
    fi

    # btrfs needs a NOCOW, hole-free swapfile or swapon fails with "has
    # holes" — the old plain dd+mkswap path silently failed on every
    # btrfs target. Prefer btrfs-progs mkswapfile (does mkswap itself),
    # fall back to chattr +C, then plain dd for ext4/xfs.
    local made=0
    if [[ "${FILESYSTEM:-}" == "btrfs" ]] && command -v btrfs >/dev/null 2>&1; then
        if btrfs filesystem mkswapfile --size "${needed_mib}m" "${BUILD_SWAP_FILE}" 2>/dev/null; then
            made=1
        fi
    fi
    if (( made == 0 )); then
        rm -f "${BUILD_SWAP_FILE}" 2>/dev/null || true
        if [[ "${FILESYSTEM:-}" == "btrfs" ]]; then
            : > "${BUILD_SWAP_FILE}" 2>/dev/null || true
            chattr +C "${BUILD_SWAP_FILE}" 2>/dev/null || true
        fi
        if ! dd if=/dev/zero of="${BUILD_SWAP_FILE}" bs=1M count="${needed_mib}" status=none 2>/dev/null; then
            ewarn "Could not create build swap file (disk space?) — build may OOM on low RAM"
            rm -f "${BUILD_SWAP_FILE}" 2>/dev/null || true
            return 0
        fi
        chmod 0600 "${BUILD_SWAP_FILE}"
        if ! mkswap "${BUILD_SWAP_FILE}" >/dev/null 2>&1; then
            ewarn "mkswap failed for build swap — build may OOM on low RAM"
            rm -f "${BUILD_SWAP_FILE}"
            return 0
        fi
    fi

    if ! swapon "${BUILD_SWAP_FILE}" 2>/dev/null; then
        ewarn "swapon failed for build swap (FILESYSTEM=${FILESYSTEM:-?}) — build may OOM on low RAM"
        rm -f "${BUILD_SWAP_FILE}"
        return 0
    fi

    einfo "Temporary build swap active: ${needed_mib} MiB ($(( BUILD_SWAP_TARGET_KIB / 1024 / 1024 )) GiB total)"
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
        # btrfs filesystem mkswapfile requires btrfs-progs >= 6.1
        local btrfs_ver
        btrfs_ver=$(btrfs --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
        if [[ -n "${btrfs_ver}" ]] && awk "BEGIN{exit !(${btrfs_ver} >= 6.1)}"; then
            try "Creating btrfs swap file" \
                btrfs filesystem mkswapfile --size "${size_mib}m" "${swap_file}"
        else
            # Fallback for older btrfs-progs
            try "Allocating swap file" truncate -s 0 "${swap_file}"
            chattr +C "${swap_file}" 2>/dev/null || true
            try "Filling swap file" dd if=/dev/zero of="${swap_file}" bs=1M count="${size_mib}" status=progress
            chmod 0600 "${swap_file}"
            try "Formatting swap file" mkswap "${swap_file}"
        fi
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
