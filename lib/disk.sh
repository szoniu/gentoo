#!/usr/bin/env bash
# disk.sh — Two-phase disk operations (plan -> execute), UUID persistence
# Uses sfdisk (util-linux) for atomic GPT partitioning
source "${LIB_DIR}/protection.sh"

# Action queue for two-phase disk operations
declare -ga DISK_ACTIONS=()
declare -ga DISK_STDIN=()
# Parallel array: "1" marks an action whose failure must NOT be skippable.
# Anything whose SUCCESSOR is destructive belongs here — see disk_plan_shrink.
declare -ga DISK_CRITICAL=()

# --- Phase 1: Planning ---

# disk_plan_reset — Clear the action queue
disk_plan_reset() {
    DISK_ACTIONS=()
    DISK_STDIN=()
    DISK_CRITICAL=()
}

# disk_plan_add — Add an action to the queue (no stdin)
# Usage: disk_plan_add "description" command [args...]
disk_plan_add() {
    local desc="$1"
    shift
    local cmd
    cmd=$(printf '%q ' "$@")
    DISK_ACTIONS+=("${desc}|||${cmd}")
    DISK_STDIN+=("")
    DISK_CRITICAL+=("0")
}

# disk_plan_add_stdin — Add an action with stdin data
# Usage: disk_plan_add_stdin "description" "stdin_data" command [args...]
disk_plan_add_stdin() {
    local desc="$1" stdin="$2"
    shift 2
    local cmd
    cmd=$(printf '%q ' "$@")
    DISK_ACTIONS+=("${desc}|||${cmd}")
    DISK_STDIN+=("${stdin}")
    DISK_CRITICAL+=("0")
}

# disk_plan_add_critical — Like disk_plan_add, but failure cannot be skipped
disk_plan_add_critical() {
    disk_plan_add "$@"
    DISK_CRITICAL[$(( ${#DISK_ACTIONS[@]} - 1 ))]="1"
}

# disk_plan_add_stdin_critical — Like disk_plan_add_stdin, but not skippable
disk_plan_add_stdin_critical() {
    disk_plan_add_stdin "$@"
    DISK_CRITICAL[$(( ${#DISK_ACTIONS[@]} - 1 ))]="1"
}

# disk_plan_show — Display planned actions
disk_plan_show() {
    local i
    einfo "Planned disk operations:"
    for (( i = 0; i < ${#DISK_ACTIONS[@]}; i++ )); do
        local desc="${DISK_ACTIONS[$i]%%|||*}"
        einfo "  $((i + 1)). ${desc}"
        if [[ -n "${DISK_STDIN[$i]:-}" ]]; then
            elog "    stdin script: ${DISK_STDIN[$i]}"
        fi
    done
}

# disk_plan_auto — Generate auto-partitioning plan using sfdisk
disk_plan_auto() {
    local disk="${TARGET_DISK}"
    local fs="${FILESYSTEM:-ext4}"
    local swap_type="${SWAP_TYPE:-zram}"
    local swap_size="${SWAP_SIZE_MIB:-${SWAP_DEFAULT_SIZE_MIB}}"

    disk_plan_reset

    # Build sfdisk script — single atomic operation for all partitions
    local sfdisk_script="label: gpt"$'\n'
    sfdisk_script+="start=1MiB, size=${ESP_SIZE_MIB}MiB, type=${GPT_TYPE_EFI}, name=ESP"$'\n'

    if [[ "${swap_type}" == "partition" ]]; then
        sfdisk_script+="size=${swap_size}MiB, type=${GPT_TYPE_SWAP}, name=swap"$'\n'
    fi

    # Root partition — no size= means remaining space
    sfdisk_script+="type=${GPT_TYPE_LINUX}, name=linux"$'\n'

    # Critical: every mkfs queued below targets a device name derived from THIS
    # layout. Skipping a failed partitioning and carrying on would point mkfs at
    # whatever currently occupies those names.
    disk_plan_add_stdin_critical "Create GPT partition table and partitions on ${disk}" \
        "${sfdisk_script}" \
        sfdisk --force --no-reread "${disk}"

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
    _disk_plan_format_root "${ROOT_PARTITION}" "${fs}"

    export ESP_PARTITION ROOT_PARTITION SWAP_PARTITION

    einfo "Auto-partition plan generated for ${disk}"
}

# disk_plan_dualboot — Generate dual-boot partitioning plan
disk_plan_dualboot() {
    local disk="${TARGET_DISK}"
    local fs="${FILESYSTEM:-ext4}"

    disk_plan_reset

    # Shrink existing partition first if requested
    if [[ -n "${SHRINK_PARTITION:-}" ]]; then
        disk_plan_shrink
    fi

    # ESP is reused, never formatted — but it still has to live on the target
    # disk. The ESP picker lists partitions from EVERY disk in the machine, so
    # a dual-boot plan could otherwise point the bootloader at a stranger's ESP.
    if [[ -n "${ESP_PARTITION:-}" ]]; then
        local esp_disk
        esp_disk=$(_partition_to_disk "${ESP_PARTITION}")
        if [[ "${esp_disk}" != "${disk}" ]]; then
            ewarn "ESP ${ESP_PARTITION} lives on ${esp_disk}, not on the target disk ${disk}"
            ewarn "That is legal on multi-disk machines, but verify it is the ESP this machine boots from"
        fi
    fi
    einfo "Reusing existing ESP: ${ESP_PARTITION}"

    _DUALBOOT_RESOLVE_ROOT=0

    if [[ -z "${ROOT_PARTITION:-}" ]]; then
        # Create the root partition in free space. Its NUMBER cannot be known
        # here, and must not be guessed:
        #
        #   In GPT the partition number is the index of the entry in the table.
        #   Deleting a partition leaves a HOLE (Windows Disk Management, gparted
        #   and fdisk all leave the rest renumbered), and `sfdisk --append`
        #   (libfdisk) fills the FIRST FREE SLOT — not the highest number + 1.
        #
        # Verified on a GPT image with partitions 1,2,4: the old
        # "count + 1" arithmetic produced 4, i.e. the EXISTING partition, while
        # --append actually created the new one as number 3. That formats
        # someone else's data AND leaves the real Gentoo partition untouched.
        #
        # So: snapshot the partition list now, and resolve the new device after
        # the kernel has re-read the table (_disk_resolve_appended_root).
        _DUALBOOT_PARTS_BEFORE="$(_disk_list_partitions "${disk}")"
        _DUALBOOT_RESOLVE_ROOT=1
        export _DUALBOOT_PARTS_BEFORE

        # Critical: the resolver below assumes this action created exactly one
        # partition. Skipping it would leave the snapshot diff empty (and abort
        # there), so refusing here gives the clearer error.
        disk_plan_add_stdin_critical "Create root partition in free space" \
            "type=${GPT_TYPE_LINUX}, name=linux"$'\n' \
            sfdisk --append --force --no-reread "${disk}"

        # mkfs is deferred to disk_execute_plan — see above.
        einfo "Root partition will be created in free space (device resolved after partprobe)"
    else
        # An existing partition was picked in the wizard. It must live on the
        # target disk: TUI_BACK can re-enter the screen with a different disk
        # while ROOT_PARTITION keeps its previous value.
        local root_disk
        root_disk=$(_partition_to_disk "${ROOT_PARTITION}")
        if [[ "${root_disk}" != "${disk}" ]]; then
            die "Refusing to format ${ROOT_PARTITION} (on ${root_disk}) while the target disk is ${disk}"
        fi
        _disk_plan_format_root "${ROOT_PARTITION}" "${fs}"
    fi

    export ROOT_PARTITION _DUALBOOT_RESOLVE_ROOT
    einfo "Dual-boot plan generated"
}

# _disk_plan_format_root — Queue the mkfs action for the root filesystem
_disk_plan_format_root() {
    local part="$1" fs="$2"
    case "${fs}" in
        ext4)  disk_plan_add "Format root as ext4"  mkfs.ext4 -L gentoo "${part}" ;;
        btrfs) disk_plan_add "Format root as btrfs" mkfs.btrfs -f -L gentoo "${part}" ;;
        xfs)   disk_plan_add "Format root as XFS"   mkfs.xfs -f -L gentoo "${part}" ;;
        *)
            # Silently queueing nothing is the dangerous outcome: on dual-boot
            # with an EXISTING root partition the plan would then contain no
            # mkfs at all, and stage3 would be unpacked on top of the OS the
            # operator asked to erase. validate_config does not save us —
            # tui/summary.sh is its only caller, so `--install --config file`
            # reaches here unvalidated.
            die "Unsupported FILESYSTEM '"'"'${fs}'"'"' — cannot format ${part}"
            ;;
    esac
}

# _disk_list_partitions — Partition devices of a disk, one per line, sorted
_disk_list_partitions() {
    local disk="$1"
    if [[ -n "${_DRY_RUN_PARTITIONS:-}" ]]; then
        printf '%s\n' ${_DRY_RUN_PARTITIONS}
        return 0
    fi
    # TYPE=part only. `lsblk -l` flattens the WHOLE subtree, so LVM/crypt/mdraid
    # holders stacked on the partitions show up too — and disk_execute_plan runs
    # partprobe right before the resolver, which is exactly what makes udev
    # auto-activate a volume group that was inactive when the snapshot was taken.
    # Such a holder appearing as "the one new device" would send mkfs at a live
    # filesystem. Only a real partition of this disk can be the one we created.
    lsblk -lno PATH,TYPE "${disk}" 2>/dev/null \
        | awk '$2 == "part" { print $1 }' | sort || true
}

# _disk_resolve_appended_root — Identify the partition sfdisk --append created
#
# Compares the partition list against the snapshot taken at plan time and
# demands EXACTLY ONE new device. Everything here is a refusal to guess: a
# wrong answer means mkfs on a stranger's partition.
_disk_resolve_appended_root() {
    local disk="${TARGET_DISK}"
    local after new_parts count
    after="$(_disk_list_partitions "${disk}")"

    new_parts=$(comm -13 <(printf '%s\n' "${_DUALBOOT_PARTS_BEFORE}") <(printf '%s\n' "${after}")) || true
    new_parts=$(printf '%s\n' "${new_parts}" | sed '/^$/d')
    count=$(printf '%s\n' "${new_parts}" | sed '/^$/d' | wc -l)

    if [[ "${count}" -ne 1 ]]; then
        eerror "Expected exactly one new partition on ${disk}, found ${count}:"
        eerror "  before: $(printf '%s' "${_DUALBOOT_PARTS_BEFORE}" | tr '\n' ' ')"
        eerror "  after:  $(printf '%s' "${after}" | tr '\n' ' ')"
        die "Cannot identify the newly created root partition — refusing to format anything"
    fi

    ROOT_PARTITION="${new_parts}"
    export ROOT_PARTITION

    # Device-level checks need real devices (skipped under DRY_RUN, which never
    # touches hardware — the identification logic above is what tests exercise).
    if [[ "${DRY_RUN:-0}" != "1" ]]; then
        [[ -b "${ROOT_PARTITION}" ]] || die "Resolved root partition ${ROOT_PARTITION} is not a block device"

        # A stale filesystem signature here is NORMAL, not a red flag: installing
        # into the space of a partition someone deleted means those sectors still
        # hold the old superblock. The device cannot be anyone'"'"'s live partition —
        # it was absent from the snapshot taken moments ago — so wipe the leftover
        # signature instead of refusing, which would abort the single most common
        # dual-boot scenario.
        local sig
        sig=$(blkid -o value -s TYPE "${ROOT_PARTITION}" 2>/dev/null) || sig=""
        if [[ -n "${sig}" ]]; then
            einfo "Wiping stale ${sig} signature left on the freshly created ${ROOT_PARTITION}"
            wipefs -a "${ROOT_PARTITION}" &>/dev/null \
                || die "Could not wipe the stale ${sig} signature from ${ROOT_PARTITION}"
        fi
    fi

    # A partition smaller than the minimum means --append landed in a gap too
    # small for Gentoo; better to say so now than after hours of compiling.
    local size_mib
    size_mib=$(disk_get_partition_size_mib "${ROOT_PARTITION}")
    if [[ "${size_mib}" -lt "${GENTOO_MIN_SIZE_MIB}" ]]; then
        die "Created root partition ${ROOT_PARTITION} is ${size_mib} MiB, below the ${GENTOO_MIN_SIZE_MIB} MiB minimum"
    fi

    einfo "Root partition created: ${ROOT_PARTITION} (${size_mib} MiB)"
}

# --- Shrink helpers ---

# disk_get_free_space_mib — Get total free (unallocated) space on disk in MiB
# Returns 0 MiB if no free space or on error
disk_get_free_space_mib() {
    local disk="$1"

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        echo "${_DRY_RUN_FREE_SPACE_MIB:-0}"
        return 0
    fi

    local sectors sector_size total_free_sectors=0
    sector_size=$(blockdev --getss "${disk}" 2>/dev/null) || sector_size=512

    while IFS= read -r line; do
        # sfdisk --list-free outputs lines like: "Start    End Sectors Size"
        # Data lines have numeric fields
        local s
        s=$(echo "${line}" | awk 'NF>=3 && $3 ~ /^[0-9]+$/ {print $3}') || true
        if [[ -n "${s}" ]]; then
            (( total_free_sectors += s )) || true
        fi
    done < <(sfdisk --list-free "${disk}" 2>/dev/null)

    echo $(( total_free_sectors * sector_size / 1024 / 1024 ))
}

# disk_get_largest_free_mib — Size of the LARGEST contiguous free area, in MiB
#
# This is what decides whether a new root partition fits, not the total:
# `sfdisk --append` places the partition in one gap and stretches it to the
# next used partition, so its size comes from that single gap. Summing a
# 15 GiB and a 10 GiB hole into "25 GiB free" passed the 20 GiB check and then
# produced a 15 GiB root.
disk_get_largest_free_mib() {
    local disk="$1"

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        echo "${_DRY_RUN_LARGEST_FREE_MIB:-${_DRY_RUN_FREE_SPACE_MIB:-0}}"
        return 0
    fi

    local sector_size max_sectors
    sector_size=$(blockdev --getss "${disk}" 2>/dev/null) || sector_size=512

    max_sectors=$(sfdisk --list-free "${disk}" 2>/dev/null \
        | awk 'NF>=3 && $3 ~ /^[0-9]+$/ { if ($3 > max) max = $3 } END { print max + 0 }') || max_sectors=0
    [[ -n "${max_sectors}" ]] || max_sectors=0

    echo $(( max_sectors * sector_size / 1024 / 1024 ))
}

# disk_get_partition_size_mib — Get partition size in MiB
disk_get_partition_size_mib() {
    local part="$1"

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        echo "${_DRY_RUN_PART_SIZE_MIB:-0}"
        return 0
    fi

    local bytes
    bytes=$(lsblk -bno SIZE "${part}" 2>/dev/null | head -1) || bytes=0
    echo $(( bytes / 1024 / 1024 ))
}

# disk_get_partition_used_mib — Get used space on partition in MiB
# Supports ntfs, ext4, btrfs.
#
# Returns non-zero when the value could NOT be determined. Echoing 0 in that
# case was actively dangerous: the shrink wizard computes its floor as
# "used + 1 GiB", so an unreadable filesystem silently became "you may shrink
# down to 1 GiB". Callers must treat a non-zero exit as "unknown", not "empty".
disk_get_partition_used_mib() {
    local part="$1" fstype="$2"

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        echo "${_DRY_RUN_PART_USED_MIB:-0}"
        return 0
    fi

    case "${fstype}" in
        ntfs)
            # ntfsresize --info --force --no-action outputs "You might resize at X bytes"
            local info
            info=$(ntfsresize --info --force --no-action "${part}" 2>/dev/null) || return 1
            local bytes
            bytes=$(echo "${info}" | sed -n 's/.*resize at \([0-9]*\) bytes.*/\1/p' | head -1) || true
            if [[ -n "${bytes}" ]]; then
                echo $(( bytes / 1024 / 1024 ))
            else
                return 1
            fi
            ;;
        ext4)
            # dumpe2fs -h: Block count, Free blocks, Block size
            local dump
            dump=$(dumpe2fs -h "${part}" 2>/dev/null) || return 1
            local block_count free_blocks block_size
            block_count=$(echo "${dump}" | sed -n 's/^Block count:[[:space:]]*//p' | head -1) || true
            free_blocks=$(echo "${dump}" | sed -n 's/^Free blocks:[[:space:]]*//p' | head -1) || true
            block_size=$(echo "${dump}" | sed -n 's/^Block size:[[:space:]]*//p' | head -1) || true
            if [[ -n "${block_count}" && -n "${free_blocks}" && -n "${block_size}" ]]; then
                echo $(( (block_count - free_blocks) * block_size / 1024 / 1024 ))
            else
                return 1
            fi
            ;;
        btrfs)
            # Mount read-only, query usage, unmount
            local tmpdir
            tmpdir=$(mktemp -d) || return 1
            if mount -o ro "${part}" "${tmpdir}" 2>/dev/null; then
                local used_bytes
                used_bytes=$(btrfs filesystem usage -b "${tmpdir}" 2>/dev/null \
                    | sed -n 's/^[[:space:]]*Used:[[:space:]]*//p' | head -1) || true
                umount "${tmpdir}" 2>/dev/null || true
                rmdir "${tmpdir}" 2>/dev/null || true
                if [[ -n "${used_bytes}" ]]; then
                    echo $(( used_bytes / 1024 / 1024 ))
                else
                    return 1
                fi
            else
                rmdir "${tmpdir}" 2>/dev/null || true
                return 1
            fi
            ;;
        *)
            # Same contract as the branches above: an unsupported filesystem is
            # "unknown", never "zero used".
            return 1
            ;;
    esac
}

# disk_can_shrink_fstype — Check if filesystem type can be shrunk
# Returns 0 (true) for ntfs/ext4/btrfs, 1 (false) otherwise
disk_can_shrink_fstype() {
    local fstype="$1"
    case "${fstype}" in
        ntfs|ext4|btrfs) return 0 ;;
        *) return 1 ;;
    esac
}

# disk_plan_shrink — Add shrink actions to DISK_ACTIONS[]
# Requires: SHRINK_PARTITION, SHRINK_PARTITION_FSTYPE, SHRINK_NEW_SIZE_MIB
disk_plan_shrink() {
    # ${VAR:-} throughout: screen_disk_select now UNSETS these on entry, so a
    # bare expansion dies with "unbound variable" under set -u before the checks
    # below can report anything useful.
    local part="${SHRINK_PARTITION:-}"
    local fstype="${SHRINK_PARTITION_FSTYPE:-}"
    local new_size="${SHRINK_NEW_SIZE_MIB:-}"
    local disk="${TARGET_DISK}"

    # The partition number is fed to `sfdisk -N <num> <disk>`, so a partition
    # from ANOTHER disk would truncate the entry with that number on the target
    # disk. Nothing upstream guarantees the two match: the wizard can be
    # re-entered with a different disk (TUI_BACK) while SHRINK_* keeps its old
    # value. Refuse instead of trusting the caller.
    local part_disk
    part_disk=$(_partition_to_disk "${part}")
    if [[ "${part_disk}" != "${disk}" ]]; then
        die "Refusing to shrink ${part} (on ${part_disk}) while the target disk is ${disk}"
    fi

    # Determine partition number from device path
    local part_num
    part_num=$(echo "${part}" | sed 's/.*[^0-9]\([0-9]*\)$/\1/') || true

    if [[ -z "${part_num}" ]]; then
        eerror "Cannot determine partition number from ${part}"
        return 1
    fi

    einfo "Planning shrink: ${part} (${fstype}) → ${new_size} MiB"

    # Each filesystem shrink is ONE critical action that ends with a read-back
    # check. Two reasons for the read-back:
    #   - the next planned action truncates the partition table entry, so a
    #     filesystem that is still too big means guaranteed data loss;
    #   - a resize tool can exit 0 having done less than asked.
    # Critical => try() offers no "continue", so a failure aborts instead of
    # falling through to the destructive step.
    case "${fstype}" in
        ntfs)
            disk_plan_add_critical "Shrink NTFS filesystem on ${part} (with read-back check)" \
                bash -c '
set -eu
part="$1"; new="$2"
ntfsresize --force --size "${new}M" "${part}"
cur=$(ntfsresize --info --force --no-action "${part}" 2>/dev/null \
      | sed -n "s/.*urrent volume size: *\([0-9]*\) bytes.*/\1/p" | head -1)
[ -n "${cur}" ] || { echo "read-back: cannot determine NTFS size of ${part}" >&2; exit 1; }
size=$(( cur / 1048576 ))
[ "${size}" -le "${new}" ] || {
    echo "read-back: NTFS on ${part} is still ${size} MiB, asked for ${new} MiB" >&2; exit 1; }
' -- "${part}" "${new_size}"
            ;;
        ext4)
            disk_plan_add_critical "Shrink ext4 filesystem on ${part} (with read-back check)" \
                bash -c '
set -eu
part="$1"; new="$2"
# e2fsck exits 1 when it FIXED errors and 2 when a reboot is advised. Both mean
# the filesystem is now clean — only >= 4 is a real failure. Treating 1 as an
# error dropped the operator into the recovery menu at the worst moment.
e2fsck -f -y "${part}" || [ $? -le 2 ]
resize2fs "${part}" "${new}M"
bc=$(dumpe2fs -h "${part}" 2>/dev/null | sed -n "s/^Block count: *\([0-9]*\).*/\1/p" | head -1)
bs=$(dumpe2fs -h "${part}" 2>/dev/null | sed -n "s/^Block size: *\([0-9]*\).*/\1/p" | head -1)
[ -n "${bc}" ] && [ -n "${bs}" ] || {
    echo "read-back: cannot determine ext4 geometry of ${part}" >&2; exit 1; }
size=$(( bc * bs / 1048576 ))
[ "${size}" -le "${new}" ] || {
    echo "read-back: ext4 on ${part} is still ${size} MiB, asked for ${new} MiB" >&2; exit 1; }
' -- "${part}" "${new_size}"
            ;;
        btrfs)
            disk_plan_add_critical "Shrink btrfs filesystem on ${part} (with read-back check)" \
                bash -c '
set -eu
part="$1"; new="$2"
tmp=$(mktemp -d /tmp/gentoo-shrink-XXXXXX)
mount "${part}" "${tmp}"
# "btrfs filesystem resize <size>" targets devid 1. On a multi-device btrfs that
# is a DIFFERENT disk, so the resize would shrink the wrong member while the
# read-back happily confirmed it — and sfdisk would then truncate a partition
# whose filesystem was never touched. Address this device explicitly.
devid=$(btrfs filesystem show --raw "${tmp}" 2>/dev/null \
        | sed -n "s|^[[:space:]]*devid[[:space:]]*\([0-9][0-9]*\).*path ${part}\$|\1|p" | head -1)
if [ -z "${devid}" ]; then
    umount "${tmp}"; rmdir "${tmp}"
    echo "read-back: cannot determine btrfs devid of ${part}" >&2; exit 1
fi
rc=0
btrfs filesystem resize "${devid}:${new}M" "${tmp}" || rc=$?
size=0
if [ "${rc}" -eq 0 ]; then
    bytes=$(btrfs filesystem show --raw "${tmp}" 2>/dev/null \
            | sed -n "s|^[[:space:]]*devid[[:space:]]*[0-9][0-9]*[[:space:]]*size[[:space:]]*\([0-9][0-9]*\).*path ${part}\$|\1|p" | head -1)
    [ -n "${bytes}" ] && size=$(( bytes / 1048576 ))
fi
umount "${tmp}"; rmdir "${tmp}"
[ "${rc}" -eq 0 ] || exit "${rc}"
[ "${size}" -gt 0 ] || { echo "read-back: cannot determine btrfs size of ${part}" >&2; exit 1; }
[ "${size}" -le "${new}" ] || {
    echo "read-back: btrfs on ${part} is still ${size} MiB, asked for ${new} MiB" >&2; exit 1; }
' -- "${part}" "${new_size}"
            ;;
        *)
            # No shrink action was queued, so the truncation below would cut the
            # partition out from under an untouched filesystem. The wizard gates
            # this with disk_can_shrink_fstype, but a preset or --config can put
            # any string into SHRINK_PARTITION_FSTYPE.
            die "Cannot shrink ${part}: unsupported or empty filesystem type (${fstype})"
            ;;
    esac

    # Resize partition table entry — destructive, and only correct because the
    # shrink above verified the filesystem actually fits.
    disk_plan_add_stdin_critical "Resize partition table entry ${part_num} on ${disk}" \
        ",${new_size}MiB"$'\n' \
        sfdisk --force --no-reread -N "${part_num}" "${disk}"

    # Re-read partition table
    disk_plan_add "Re-read partition table on ${disk}" \
        partprobe "${disk}"
}

# --- Phase 2: Execution ---

# cleanup_target_disk — Unmount all partitions on target disk and deactivate swap
# Required before repartitioning (existing partitions may block sfdisk)
cleanup_target_disk() {
    local disk="${TARGET_DISK}"

    if [[ "${DRY_RUN}" == "1" ]]; then
        einfo "[DRY-RUN] Would cleanup ${disk}"
        return 0
    fi

    # The wizard is not the only way here: --config and --resume reach this
    # function without ever running hardware detection, which is where
    # LIVE_MEDIUM_DISK normally comes from.
    if declare -f ensure_live_medium_detected &>/dev/null; then
        ensure_live_medium_detected
    fi

    # Last line of defence: this function lazily unmounts EVERYTHING on the disk,
    # which for the live medium means pulling the installer's own filesystem out
    # from under it moments before sfdisk overwrites the partition table. The
    # wizard already refuses this, but a preset or --config reaches here directly.
    if [[ -n "${LIVE_MEDIUM_DISK:-}" && "${disk}" == "${LIVE_MEDIUM_DISK}" ]]; then
        # LIVE_MEDIUM_OVERRIDE_DISK holds the disk the operator explicitly
        # confirmed in screen_disk_select, never a bare "yes" — so it cannot be
        # carried by a preset to a machine where it would wave through a
        # completely different device.
        if [[ "${LIVE_MEDIUM_OVERRIDE_DISK:-}" == "${disk}" ]]; then
            ewarn "Proceeding on ${disk} despite it being the install medium (operator override)"
        else
            die "Refusing to wipe ${disk}: this is the medium the installer booted from"
        fi
    fi

    einfo "Cleaning up ${disk} (unmounting partitions, deactivating swap)..."

    # Deactivate any swap partitions on this disk
    local swap_part
    while IFS= read -r swap_part; do
        [[ -z "${swap_part}" ]] && continue
        swapoff "${swap_part}" 2>/dev/null && einfo "Deactivated swap: ${swap_part}" || true
    done < <(awk -v disk="${disk}" 'NR>1 && $1 ~ "^"disk"[p]?[0-9]" {print $1}' /proc/swaps 2>/dev/null)

    # Unmount all partitions on this disk (reverse order for nested mounts)
    local -a mounts
    readarray -t mounts < <(awk -v disk="${disk}" '$1 ~ "^"disk"[p]?[0-9]" {print $2}' /proc/mounts 2>/dev/null | sort -r)

    local mnt
    for mnt in "${mounts[@]}"; do
        [[ -z "${mnt}" ]] && continue
        umount -l "${mnt}" 2>/dev/null && einfo "Unmounted: ${mnt}" || true
    done

    einfo "Cleanup of ${disk} complete"
}

# disk_execute_plan — Execute all planned disk operations
# _disk_clear_pre_wipe_detection — Forget OS detection after an auto wipe
#
# Everything found before partitioning is gone once the whole disk was
# repartitioned. Kept as its own function so it can be tested without running a
# single disk operation.
_disk_clear_pre_wipe_detection() {
    # Cleared unconditionally: the ESP fallback sets LINUX_DETECTED while
    # recording no partition at all, so keying off the serialized string left
    # the flag alive across a full-disk wipe — after which bootloader.sh emerges
    # os-prober and writes GRUB_DISABLE_OS_PROBER=false for an OS that is gone.
    LINUX_EFI_LOADERS=""
    export LINUX_EFI_LOADERS

    if [[ -n "${DETECTED_OSES_SERIALIZED:-}" || "${LINUX_DETECTED:-0}" == "1" \
          || "${WINDOWS_DETECTED:-0}" == "1" ]]; then
        einfo "Clearing pre-wipe OS detection (auto scheme erases all)"
        declare -gA DETECTED_OSES=()
        WINDOWS_DETECTED=0
        LINUX_DETECTED=0
        BITLOCKER_DETECTED=0
        BITLOCKER_PARTITIONS=""
        DETECTED_OSES_SERIALIZED=""
        export WINDOWS_DETECTED LINUX_DETECTED BITLOCKER_DETECTED BITLOCKER_PARTITIONS DETECTED_OSES_SERIALIZED
    fi
}

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
        local stdin_data="${DISK_STDIN[$i]:-}"

        einfo "[$((i + 1))/${#DISK_ACTIONS[@]}] ${desc}"

        # A critical action is one whose successor is destructive: letting the
        # operator "skip" a failed filesystem shrink and then truncating the
        # partition table entry is a direct path to data loss.
        local _crit="${DISK_CRITICAL[$i]:-0}"

        if [[ -n "${stdin_data}" ]]; then
            TRY_NO_CONTINUE="${_crit}" \
                try "${desc}" bash -c "printf '%s' $(printf '%q' "${stdin_data}") | ${cmd}"
        else
            TRY_NO_CONTINUE="${_crit}" try "${desc}" bash -c "${cmd}"
        fi
    done

    # Ensure kernel recognizes new partitions
    if [[ "${DRY_RUN}" != "1" ]]; then
        partprobe "${TARGET_DISK}" 2>/dev/null || true
        sleep 2

        # Dual-boot with a partition created in free space: the device is only
        # knowable now, so resolve it and format it here.
        #
        # The previous safety net only fired when ${ROOT_PARTITION} did not
        # exist, and then picked `sfdisk --dump | tail -1`. Both halves were
        # wrong: a guessed number that lands on somebody else's partition IS a
        # block device (so the net never fired), and the dump is ordered by
        # partition NUMBER, so tail -1 is the highest-numbered entry, not the
        # newly created one.
        if [[ "${_DUALBOOT_RESOLVE_ROOT:-0}" == "1" ]]; then
            _disk_resolve_appended_root
            local _before_fmt="${#DISK_ACTIONS[@]}"
            _disk_plan_format_root "${ROOT_PARTITION}" "${FILESYSTEM:-ext4}"
            # An unknown FILESYSTEM queues nothing, and DISK_ACTIONS[-1] would then
            # be the PREVIOUS action — re-running sfdisk --append instead of mkfs.
            if [[ "${#DISK_ACTIONS[@]}" -ne $(( _before_fmt + 1 )) ]]; then
                die "No mkfs action queued for filesystem '"'"'${FILESYSTEM:-ext4}'"'"' — refusing to run an unrelated command"
            fi
            local fmt_entry fmt_desc fmt_cmd
            fmt_entry="${DISK_ACTIONS[-1]}"
            fmt_desc="${fmt_entry%%|||*}"
            fmt_cmd="${fmt_entry#*|||}"
            einfo "${fmt_desc}"
            # Critical like every other destructive action: a skipped mkfs would
            # let the run continue to mount_filesystems on an unformatted device.
            TRY_NO_CONTINUE=1 try "${fmt_desc}" bash -c "${fmt_cmd}"
        fi
    fi

    if [[ "${PARTITION_SCHEME:-auto}" == "auto" && "${DRY_RUN}" != "1" ]]; then
        _disk_clear_pre_wipe_detection
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

    # Skip root mount if already mounted (e.g. after resume with stale mounts)
    if mountpoint -q "${MOUNTPOINT}" 2>/dev/null; then
        einfo "Root filesystem already mounted at ${MOUNTPOINT}"
    else
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

        else
            # Simple mount for ext4/xfs
            try "Mounting root filesystem" mount "${ROOT_PARTITION}" "${MOUNTPOINT}"
        fi
    fi

    # Mount non-@ btrfs subvolumes (@home, @var-log, @snapshots) UNCONDITIONALLY —
    # even when root was already mounted (e.g. --resume). If this is skipped, a
    # resumed `users` phase runs with @home NOT mounted and `useradd -m` writes the
    # home into @ instead of @home; at boot the empty @home mounts over it and the
    # home directory "disappears" (login fails, SDDM bounces to the greeter).
    # Caught on a real HP ProBook 450 G8 resume. The per-mount `mountpoint -q`
    # guard makes this a no-op when the subvolume is already mounted.
    if [[ "${FILESYSTEM:-ext4}" == "btrfs" && -n "${BTRFS_SUBVOLUMES:-}" ]]; then
        local IFS=':'
        local -a parts
        read -ra parts <<< "${BTRFS_SUBVOLUMES}"
        local idx
        for (( idx = 0; idx < ${#parts[@]}; idx += 2 )); do
            local subvol="${parts[$idx]}"
            local mpoint="${parts[$((idx + 1))]}"
            [[ "${subvol}" == "@" ]] && continue
            if ! mountpoint -q "${MOUNTPOINT}${mpoint}" 2>/dev/null; then
                mkdir -p "${MOUNTPOINT}${mpoint}"
                try "Mounting subvolume ${subvol} at ${mpoint}" \
                    mount -o "subvol=${subvol},compress=zstd,noatime" \
                    "${ROOT_PARTITION}" "${MOUNTPOINT}${mpoint}"
            fi
        done
    fi

    # Mount ESP
    local esp_mount="${MOUNTPOINT}/efi"
    mkdir -p "${esp_mount}"
    if mountpoint -q "${esp_mount}" 2>/dev/null; then
        einfo "ESP already mounted at ${esp_mount}"
    else
        try "Mounting ESP" mount "${ESP_PARTITION}" "${esp_mount}"
    fi

    # Activate swap if partition
    if [[ "${SWAP_TYPE:-}" == "partition" && -n "${SWAP_PARTITION:-}" ]]; then
        if ! grep -q "${SWAP_PARTITION}" /proc/swaps 2>/dev/null; then
            try "Activating swap" swapon "${SWAP_PARTITION}"
        fi
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
    readarray -t mounts < <(awk -v mp="${MOUNTPOINT}" '$3 == mp || $3 ~ "^"mp"/" {print $3}' /proc/mounts 2>/dev/null | sort -r)

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
