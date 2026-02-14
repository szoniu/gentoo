#!/usr/bin/env bash
# disk.sh — Two-phase disk operations (plan -> execute), UUID persistence
source "${LIB_DIR}/protection.sh"

# Action queue for two-phase disk operations
declare -ga DISK_ACTIONS=()

# --- Phase 1: Planning ---

# disk_plan_reset — Clear the action queue
disk_plan_reset() {
    DISK_ACTIONS=()
}

# disk_plan_add — Add an action to the queue
# Usage: disk_plan_add "description" "command" [args...]
disk_plan_add() {
    local desc="$1"
    shift
    local cmd
    cmd=$(printf '%q ' "$@")
    DISK_ACTIONS+=("${desc}|||${cmd}")
}

# disk_plan_show — Display planned actions
disk_plan_show() {
    local i
    einfo "Planned disk operations:"
    for (( i = 0; i < ${#DISK_ACTIONS[@]}; i++ )); do
        local desc="${DISK_ACTIONS[$i]%%|||*}"
        einfo "  $((i + 1)). ${desc}"
    done
}

# disk_plan_auto — Generate auto-partitioning plan
disk_plan_auto() {
    local disk="${TARGET_DISK}"
    local fs="${FILESYSTEM:-ext4}"
    local swap_type="${SWAP_TYPE:-zram}"
    local swap_size="${SWAP_SIZE_MIB:-${SWAP_DEFAULT_SIZE_MIB}}"

    disk_plan_reset

    # Create GPT label
    disk_plan_add "Create GPT partition table on ${disk}" \
        parted -s "${disk}" mklabel gpt

    # ESP partition (512 MiB)
    disk_plan_add "Create ESP partition (${ESP_SIZE_MIB} MiB)" \
        parted -s "${disk}" mkpart ESP fat32 1MiB "$((ESP_SIZE_MIB + 1))MiB"
    disk_plan_add "Set ESP flag" \
        parted -s "${disk}" set 1 esp on

    local next_start="$((ESP_SIZE_MIB + 1))"

    # Optional swap partition
    if [[ "${swap_type}" == "partition" ]]; then
        local swap_end="$((next_start + swap_size))"
        disk_plan_add "Create swap partition (${swap_size} MiB)" \
            parted -s "${disk}" mkpart swap linux-swap "${next_start}MiB" "${swap_end}MiB"
        next_start="${swap_end}"
    fi

    # Root partition (rest of disk)
    disk_plan_add "Create root partition (remaining space)" \
        parted -s "${disk}" mkpart linux "${next_start}MiB" "100%"

    # Determine partition device names
    local part_prefix="${disk}"
    # Handle NVMe and other numbered device names
    if [[ "${disk}" =~ [0-9]$ ]]; then
        part_prefix="${disk}p"
    fi

    local part_num=1
    ESP_PARTITION="${part_prefix}${part_num}"
    disk_plan_add "Format ESP as FAT32" \
        mkfs.vfat -F 32 -n EFI "${ESP_PARTITION}"
    (( part_num++ ))

    if [[ "${swap_type}" == "partition" ]]; then
        SWAP_PARTITION="${part_prefix}${part_num}"
        disk_plan_add "Format swap partition" \
            mkswap -L swap "${SWAP_PARTITION}"
        (( part_num++ ))
    fi

    ROOT_PARTITION="${part_prefix}${part_num}"
    case "${fs}" in
        ext4)
            disk_plan_add "Format root as ext4" \
                mkfs.ext4 -L gentoo "${ROOT_PARTITION}"
            ;;
        btrfs)
            disk_plan_add "Format root as btrfs" \
                mkfs.btrfs -f -L gentoo "${ROOT_PARTITION}"
            ;;
        xfs)
            disk_plan_add "Format root as XFS" \
                mkfs.xfs -f -L gentoo "${ROOT_PARTITION}"
            ;;
    esac

    export ESP_PARTITION ROOT_PARTITION SWAP_PARTITION

    einfo "Auto-partition plan generated for ${disk}"
}

# disk_plan_dualboot — Generate dual-boot partitioning plan
disk_plan_dualboot() {
    local disk="${TARGET_DISK}"
    local fs="${FILESYSTEM:-ext4}"

    disk_plan_reset

    # ESP is reused, never formatted
    einfo "Reusing existing ESP: ${ESP_PARTITION}"

    if [[ -z "${ROOT_PARTITION:-}" ]]; then
        # Need to create root partition in free space
        # Find free space on disk
        disk_plan_add "Create root partition in free space" \
            parted -s "${disk}" mkpart linux ext4 0% 100%

        # Determine partition name
        local part_count
        part_count=$(lsblk -lno NAME "${disk}" 2>/dev/null | wc -l)
        local part_prefix="${disk}"
        [[ "${disk}" =~ [0-9]$ ]] && part_prefix="${disk}p"
        ROOT_PARTITION="${part_prefix}${part_count}"
    fi

    # Format root
    case "${fs}" in
        ext4)
            disk_plan_add "Format root as ext4" \
                mkfs.ext4 -L gentoo "${ROOT_PARTITION}"
            ;;
        btrfs)
            disk_plan_add "Format root as btrfs" \
                mkfs.btrfs -f -L gentoo "${ROOT_PARTITION}"
            ;;
        xfs)
            disk_plan_add "Format root as XFS" \
                mkfs.xfs -f -L gentoo "${ROOT_PARTITION}"
            ;;
    esac

    export ROOT_PARTITION
    einfo "Dual-boot plan generated"
}

# --- Phase 2: Execution ---

# cleanup_target_disk — Unmount all partitions on target disk and deactivate swap
# Required before repartitioning (parted refuses if partitions are in use)
cleanup_target_disk() {
    local disk="${TARGET_DISK}"

    if [[ "${DRY_RUN}" == "1" ]]; then
        einfo "[DRY-RUN] Would cleanup ${disk}"
        return 0
    fi

    einfo "Cleaning up ${disk} (unmounting partitions, deactivating swap)..."

    # Deactivate any swap partitions on this disk
    local swap_part
    while IFS= read -r swap_part; do
        [[ -z "${swap_part}" ]] && continue
        swapoff "${swap_part}" 2>/dev/null && einfo "Deactivated swap: ${swap_part}" || true
    done < <(awk -v disk="${disk}" 'NR>1 && $1 ~ "^"disk {print $1}' /proc/swaps 2>/dev/null)

    # Unmount all partitions on this disk (reverse order for nested mounts)
    local -a mounts
    readarray -t mounts < <(awk -v disk="${disk}" '$1 ~ "^"disk {print $2}' /proc/mounts 2>/dev/null | sort -r)

    local mnt
    for mnt in "${mounts[@]}"; do
        [[ -z "${mnt}" ]] && continue
        umount -l "${mnt}" 2>/dev/null && einfo "Unmounted: ${mnt}" || true
    done

    einfo "Cleanup of ${disk} complete"
}

# disk_execute_plan — Execute all planned disk operations
disk_execute_plan() {
    if [[ ${#DISK_ACTIONS[@]} -eq 0 ]]; then
        # Generate plan based on scheme
        case "${PARTITION_SCHEME:-auto}" in
            auto)      disk_plan_auto ;;
            dual-boot) disk_plan_dualboot ;;
            manual)
                einfo "Manual partitioning — no automated plan"
                return 0
                ;;
        esac
    fi

    # Clean up any leftover mounts from previous installation attempts
    cleanup_target_disk

    disk_plan_show

    local i
    for (( i = 0; i < ${#DISK_ACTIONS[@]}; i++ )); do
        local entry="${DISK_ACTIONS[$i]}"
        local desc="${entry%%|||*}"
        local cmd="${entry#*|||}"

        einfo "[$((i + 1))/${#DISK_ACTIONS[@]}] ${desc}"
        try "${desc}" bash -c "${cmd}"
    done

    # Ensure kernel recognizes new partitions
    if [[ "${DRY_RUN}" != "1" ]]; then
        partprobe "${TARGET_DISK}" 2>/dev/null || true
        sleep 2
    fi

    einfo "All disk operations completed"
}

# --- Mount/unmount ---

# mount_filesystems — Mount root, ESP, and btrfs subvolumes
mount_filesystems() {
    einfo "Mounting filesystems..."

    if [[ "${DRY_RUN}" == "1" ]]; then
        einfo "[DRY-RUN] Would mount filesystems"
        return 0
    fi

    mkdir -p "${MOUNTPOINT}"

    local fs="${FILESYSTEM:-ext4}"

    if [[ "${fs}" == "btrfs" ]]; then
        # Mount btrfs root to create subvolumes
        try "Mounting btrfs root" mount "${ROOT_PARTITION}" "${MOUNTPOINT}"

        # Create subvolumes
        if [[ -n "${BTRFS_SUBVOLUMES:-}" ]]; then
            local IFS=':'
            local -a parts
            read -ra parts <<< "${BTRFS_SUBVOLUMES}"
            local idx
            for (( idx = 0; idx < ${#parts[@]}; idx += 2 )); do
                local subvol="${parts[$idx]}"
                if ! btrfs subvolume list "${MOUNTPOINT}" 2>/dev/null | grep -q " ${subvol}$"; then
                    try "Creating btrfs subvolume ${subvol}" \
                        btrfs subvolume create "${MOUNTPOINT}/${subvol}"
                fi
            done
        fi

        # Unmount and remount with subvolumes
        umount "${MOUNTPOINT}"

        # Mount @ subvolume as root
        try "Mounting @ subvolume" \
            mount -o subvol=@,compress=zstd,noatime "${ROOT_PARTITION}" "${MOUNTPOINT}"

        # Mount other subvolumes
        if [[ -n "${BTRFS_SUBVOLUMES:-}" ]]; then
            local IFS=':'
            local -a parts
            read -ra parts <<< "${BTRFS_SUBVOLUMES}"
            local idx
            for (( idx = 0; idx < ${#parts[@]}; idx += 2 )); do
                local subvol="${parts[$idx]}"
                local mpoint="${parts[$((idx + 1))]}"
                [[ "${subvol}" == "@" ]] && continue
                mkdir -p "${MOUNTPOINT}${mpoint}"
                try "Mounting subvolume ${subvol} at ${mpoint}" \
                    mount -o "subvol=${subvol},compress=zstd,noatime" \
                    "${ROOT_PARTITION}" "${MOUNTPOINT}${mpoint}"
            done
        fi
    else
        # Simple mount for ext4/xfs
        try "Mounting root filesystem" mount "${ROOT_PARTITION}" "${MOUNTPOINT}"
    fi

    # Mount ESP
    local esp_mount="${MOUNTPOINT}/efi"
    mkdir -p "${esp_mount}"
    try "Mounting ESP" mount "${ESP_PARTITION}" "${esp_mount}"

    # Activate swap if partition
    if [[ "${SWAP_TYPE:-}" == "partition" && -n "${SWAP_PARTITION:-}" ]]; then
        try "Activating swap" swapon "${SWAP_PARTITION}"
    fi

    einfo "Filesystems mounted at ${MOUNTPOINT}"
}

# unmount_filesystems — Unmount everything in reverse order
unmount_filesystems() {
    einfo "Unmounting filesystems..."

    if [[ "${DRY_RUN}" == "1" ]]; then
        einfo "[DRY-RUN] Would unmount filesystems"
        return 0
    fi

    # Deactivate swap
    if [[ "${SWAP_TYPE:-}" == "partition" && -n "${SWAP_PARTITION:-}" ]]; then
        swapoff "${SWAP_PARTITION}" 2>/dev/null || true
    fi

    # Unmount in reverse order — find all mounts under MOUNTPOINT
    local -a mounts
    readarray -t mounts < <(mount | grep "${MOUNTPOINT}" | awk '{print $3}' | sort -r)

    local mnt
    for mnt in "${mounts[@]}"; do
        umount -l "${mnt}" 2>/dev/null || true
    done

    einfo "Filesystems unmounted"
}

# get_uuid — Get UUID of a partition
get_uuid() {
    local partition="$1"
    blkid -s UUID -o value "${partition}" 2>/dev/null
}

# get_partuuid — Get PARTUUID of a partition
get_partuuid() {
    local partition="$1"
    blkid -s PARTUUID -o value "${partition}" 2>/dev/null
}
