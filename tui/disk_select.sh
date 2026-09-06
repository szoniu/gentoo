#!/usr/bin/env bash
# tui/disk_select.sh — Disk selection + partition scheme
source "${LIB_DIR}/protection.sh"

# _get_partition_info_for_dialog — Build rich partition list with OS info
# Args: disk esp_partition
# Populates: part_items[] (tag, description pairs) and DANGEROUS_PARTITIONS[]
_get_partition_info_for_dialog() {
    local disk="$1" esp_partition="${2:-}"
    part_items=()
    declare -gA DANGEROUS_PARTITIONS=()

    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        local pname psize pfstype plabel
        read -r pname psize pfstype plabel <<< "${line}"
        local pdev="/dev/${pname}"

        # Skip the disk device itself and ESP
        [[ "${pdev}" == "${disk}" ]] && continue
        [[ "${pdev}" == "${esp_partition}" ]] && continue

        # Build description with filesystem and label info
        local desc="${psize}"
        [[ -n "${pfstype}" ]] && desc+=" ${pfstype}"
        [[ -n "${plabel}" ]] && desc+=" \"${plabel}\""

        # Add detected OS info
        if [[ -n "${DETECTED_OSES[${pdev}]:-}" ]]; then
            desc+=" [${DETECTED_OSES[${pdev}]}]"
            DANGEROUS_PARTITIONS["${pdev}"]="${DETECTED_OSES[${pdev}]}"
        fi

        part_items+=("${pdev}" "${desc}")
    done < <(lsblk -lno NAME,SIZE,FSTYPE,LABEL "${disk}" 2>/dev/null | tail -n +2)
}

# _shrink_wizard — Interactive wizard for shrinking a partition to make room for Gentoo
# Sets: SHRINK_PARTITION, SHRINK_PARTITION_FSTYPE, SHRINK_NEW_SIZE_MIB
# Returns: TUI_NEXT on success, TUI_BACK on cancel
_shrink_wizard() {
    local disk="$1" esp_partition="${2:-}"

    # Step 1: Warning about backup (ignore return code — informational only)
    dialog_msgbox "No Free Space" \
        "There is not enough free space on ${disk} to create a Gentoo partition.\n\n\
To proceed, an existing partition must be shrunk.\n\n\
!!! IMPORTANT: BACK UP YOUR DATA FIRST !!!\n\n\
Shrinking a partition carries a risk of data loss.\n\
Make sure you have a full backup before continuing." || true

    # Step 2: Build list of shrinkable partitions
    local -a shrink_items=()
    local -a shrink_parts=()
    local -a shrink_fstypes=()

    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        local pname psize pfstype plabel
        read -r pname psize pfstype plabel <<< "${line}"
        local pdev="/dev/${pname}"

        # Skip disk itself, ESP, and unshrinkable filesystems
        [[ "${pdev}" == "${disk}" ]] && continue
        [[ "${pdev}" == "${esp_partition}" ]] && continue
        [[ -z "${pfstype}" ]] && continue
        disk_can_shrink_fstype "${pfstype}" || continue

        # Check resize tools available (skip if missing)
        case "${pfstype}" in
            ntfs) command -v ntfsresize >/dev/null 2>&1 || continue ;;
            ext4) command -v resize2fs >/dev/null 2>&1 || continue ;;
            btrfs) command -v btrfs >/dev/null 2>&1 || continue ;;
        esac

        local desc="${psize} ${pfstype}"
        [[ -n "${plabel}" ]] && desc+=" \"${plabel}\""
        if [[ -n "${DETECTED_OSES[${pdev}]:-}" ]]; then
            desc+=" [${DETECTED_OSES[${pdev}]}]"
        fi

        # First item pre-selected, rest off (dialog_radiolist expects triples)
        local on_off="off"
        [[ ${#shrink_items[@]} -eq 0 ]] && on_off="on"
        shrink_items+=("${pdev}" "${desc}" "${on_off}")
        shrink_parts+=("${pdev}")
        shrink_fstypes+=("${pfstype}")
    done < <(lsblk -lno NAME,SIZE,FSTYPE,LABEL "${disk}" 2>/dev/null | tail -n +2)

    if [[ ${#shrink_items[@]} -eq 0 ]]; then
        dialog_msgbox "Cannot Shrink" \
            "No shrinkable partitions found on ${disk}.\n\n\
Supported filesystems: NTFS, ext4, btrfs.\n\
XFS cannot be shrunk.\n\n\
Please use manual partitioning instead."
        return "${TUI_BACK}"
    fi

    # Step 3: Select partition to shrink
    local selected_part
    selected_part=$(dialog_radiolist "Select Partition to Shrink" "${shrink_items[@]}") \
        || return "${TUI_BACK}"

    # Find fstype for selected partition
    local selected_fstype=""
    local i
    for (( i = 0; i < ${#shrink_parts[@]}; i++ )); do
        if [[ "${shrink_parts[$i]}" == "${selected_part}" ]]; then
            selected_fstype="${shrink_fstypes[$i]}"
            break
        fi
    done

    # Step 4: OS warning
    if [[ -n "${DETECTED_OSES[${selected_part}]:-}" ]]; then
        local os_name="${DETECTED_OSES[${selected_part}]}"
        dialog_yesno "WARNING: OS Detected" \
            "The partition ${selected_part} contains:\n\n\
  ${os_name}\n\n\
Shrinking this partition will resize the filesystem.\n\
Data should be preserved, but there is always a risk.\n\n\
Are you sure you want to shrink this partition?" \
            || return "${TUI_BACK}"
    fi

    # NTFS-specific: warn about hibernation/fast startup
    if [[ "${selected_fstype}" == "ntfs" ]]; then
        dialog_msgbox "NTFS Warning" \
            "Before shrinking an NTFS partition:\n\n\
1. Disable Windows Fast Startup\n\
   (Settings > Power > Fast Startup > OFF)\n\
2. Disable hibernation (powercfg /h off)\n\
3. Perform a clean shutdown (not hibernate)\n\
4. Run chkdsk on Windows first\n\n\
Failure to do so may cause data loss." || true
    fi

    # Step 5: Get sizes
    local total_mib used_mib available_mib
    total_mib=$(disk_get_partition_size_mib "${selected_part}")

    # An unreadable filesystem must NOT be treated as "0 MiB used": the floor
    # below is computed as used + 1 GiB, so a failed probe used to silently
    # authorise shrinking a full partition down to 1 GiB.
    if ! used_mib=$(disk_get_partition_used_mib "${selected_part}" "${selected_fstype}"); then
        dialog_msgbox "Cannot Read Filesystem" \
            "Could not determine how much of ${selected_part} (${selected_fstype}) is in use.\n\n\
Shrinking without that number is not safe, so this partition cannot be\n\
resized here.\n\n\
For NTFS this usually means the filesystem was not cleanly unmounted:\n\
  1. Disable Windows Fast Startup\n\
  2. Disable hibernation (powercfg /h off)\n\
  3. Perform a full shutdown, then retry\n\n\
Alternatively, shrink the partition from within the other OS first."
        return "${TUI_BACK}"
    fi

    # Safety margin: 1 GiB above used
    local safety_margin=1024
    local min_part_size=$(( used_mib + safety_margin ))

    if [[ ${total_mib} -le ${min_part_size} ]]; then
        dialog_msgbox "Cannot Shrink" \
            "Partition ${selected_part} cannot be shrunk further.\n\n\
Total: ${total_mib} MiB\n\
Used:  ${used_mib} MiB\n\
Minimum (used + 1 GiB safety): ${min_part_size} MiB\n\n\
There is not enough room to free space for Gentoo."
        return "${TUI_BACK}"
    fi

    local max_gentoo_mib=$(( total_mib - min_part_size ))

    # Default: half available or 40 GiB, whichever is smaller
    local default_gentoo=40960
    if [[ $(( max_gentoo_mib / 2 )) -lt ${default_gentoo} ]]; then
        default_gentoo=$(( max_gentoo_mib / 2 ))
    fi
    # Clamp to minimum
    if [[ ${default_gentoo} -lt ${GENTOO_MIN_SIZE_MIB} ]]; then
        default_gentoo=${GENTOO_MIN_SIZE_MIB}
    fi

    # Step 6: Ask for Gentoo size
    local gentoo_size_mib
    while true; do
        gentoo_size_mib=$(dialog_inputbox "Space for Gentoo (MiB)" \
            "How much space to free for Gentoo?\n\n\
Partition: ${selected_part} (${selected_fstype})\n\
Total:     ${total_mib} MiB\n\
Used:      ${used_mib} MiB\n\
Maximum:   ${max_gentoo_mib} MiB\n\
Minimum:   ${GENTOO_MIN_SIZE_MIB} MiB (20 GiB)\n\n\
Enter size in MiB:" \
            "${default_gentoo}") || return "${TUI_BACK}"

        # Validate input is a number
        if [[ ! "${gentoo_size_mib}" =~ ^[0-9]+$ ]]; then
            dialog_msgbox "Invalid Input" "Please enter a number (MiB)." || true
            continue
        fi

        if [[ ${gentoo_size_mib} -lt ${GENTOO_MIN_SIZE_MIB} ]]; then
            dialog_msgbox "Too Small" \
                "Minimum size for Gentoo is ${GENTOO_MIN_SIZE_MIB} MiB (20 GiB)." || true
            continue
        fi

        if [[ ${gentoo_size_mib} -gt ${max_gentoo_mib} ]]; then
            dialog_msgbox "Too Large" \
                "Maximum available space is ${max_gentoo_mib} MiB.\n\
(Total ${total_mib} - Used ${used_mib} - 1 GiB safety margin)" || true
            continue
        fi

        break
    done

    local new_part_size=$(( total_mib - gentoo_size_mib ))

    # Step 7: Confirmation
    dialog_yesno "Confirm Shrink" \
        "Shrink plan:\n\n\
  Partition:    ${selected_part} (${selected_fstype})\n\
  Current size: ${total_mib} MiB\n\
  New size:     ${new_part_size} MiB\n\
  Freed space:  ${gentoo_size_mib} MiB (for Gentoo)\n\n\
Proceed with shrink?" \
        || return "${TUI_BACK}"

    # Export results
    SHRINK_PARTITION="${selected_part}"
    SHRINK_PARTITION_FSTYPE="${selected_fstype}"
    SHRINK_NEW_SIZE_MIB="${new_part_size}"
    export SHRINK_PARTITION SHRINK_PARTITION_FSTYPE SHRINK_NEW_SIZE_MIB

    return "${TUI_NEXT}"
}

screen_disk_select() {
    # Clear any selection left by a previous pass through this screen.
    #
    # run_wizard lets the operator go BACK and re-enter with a different disk or
    # a different scheme, and nothing here used to reset the previous answers.
    # Two ways that ends badly:
    #   - a stale ROOT_PARTITION makes disk_plan_dualboot skip creating the new
    #     partition and mkfs the OLD value instead, bypassing the ERASE prompt
    #     (that prompt only exists on the "use existing partition" path);
    #   - stale SHRINK_* shrinks a partition on the disk the operator just
    #     navigated away from.
    # lib/disk.sh now also refuses cross-disk values, but the state must not
    # survive this screen in the first place.
    # unset, NOT ="" — the difference is load-bearing. config_save writes every
    # variable that is SET, empty ones included (lib/config.sh: [[ -n "${!var+x}" ]]),
    # and the chroot process re-loads that file (install.sh: config_load) on top of
    # the environment it inherited. An empty ROOT_PARTITION in the config would
    # therefore overwrite the real device that disk_execute_plan had resolved and
    # exported — dracut would get no root=, and generate_fstab would call
    # get_uuid "" and die mid-file. For auto/dual-boot these names are assigned
    # only during disk_execute_plan, i.e. long AFTER the wizard writes the config,
    # so leaving them unset is exactly what the previous behaviour relied on.
    unset ROOT_PARTITION SWAP_PARTITION ESP_PARTITION
    unset SHRINK_PARTITION SHRINK_PARTITION_FSTYPE SHRINK_NEW_SIZE_MIB
    unset LIVE_MEDIUM_OVERRIDE_DISK

    # Build disk list for dialog
    local -a disk_items=()
    local entry
    for entry in "${AVAILABLE_DISKS[@]}"; do
        local name size model tran
        IFS='|' read -r name size model tran <<< "${entry}"
        if [[ -n "${LIVE_MEDIUM_DISK:-}" && "/dev/${name}" == "${LIVE_MEDIUM_DISK}" ]]; then
            disk_items+=("/dev/${name}" "${size} ${model} (${tran}) [INSTALL MEDIUM — DO NOT SELECT]")
        else
            disk_items+=("/dev/${name}" "${size} ${model} (${tran})")
        fi
    done

    if [[ ${#disk_items[@]} -eq 0 ]]; then
        dialog_msgbox "No Disks" "No suitable disks found. Cannot continue."
        return "${TUI_ABORT}"
    fi

    # Select target disk. Looping here rather than returning TUI_BACK on refusal:
    # run_wizard decrements the screen index on TUI_BACK, so "pick a different
    # disk" would drop the operator on the PREVIOUS screen and make them walk
    # forward again — the opposite of what the message says.
    local selected_disk
    while true; do
        selected_disk=$(dialog_menu "Select Target Disk" "${disk_items[@]}") \
            || return "${TUI_BACK}"

        if [[ -n "${LIVE_MEDIUM_DISK:-}" && "${selected_disk}" == "${LIVE_MEDIUM_DISK}" ]]; then
            # An escape hatch is required, not optional: an ISO copied onto an
            # internal disk and booted through GRUB loopback makes that disk both
            # "the medium" and the only sensible target. Without a way through,
            # the loop below would have no exit at all on a single-disk machine.
            # Count disks, not dialog cells: "-le 2" silently encoded "two array
            # entries per disk" and would become unreachable if a column were
            # ever added — restoring the exit-less loop this branch exists to
            # prevent. And a removable medium is never the loopback case: an
            # undetected internal disk (Intel RST, missing driver) also leaves
            # the USB stick as the only entry, and then this dialog would be
            # talking the operator into wiping their install stick.
            local _medium_tran="" _d
            for _d in "${AVAILABLE_DISKS[@]}"; do
                [[ "/dev/${_d%%|*}" == "${LIVE_MEDIUM_DISK}" ]] && _medium_tran="${_d##*|}"
            done

            if [[ ${#AVAILABLE_DISKS[@]} -le 1 && "${_medium_tran}" != "usb" ]]; then
                # Whether this can work at all depends on the medium being in
                # RAM: after sfdisk, copy_installer_to_chroot still reads the
                # installer and the config FROM DISK. Without toram the run does
                # not merely become unresumable — it aborts partway, with the
                # disk already repartitioned. Say which case this is.
                local _ram_warning=""
                if ! grep -qE '(^| )(toram|rd\.live\.ram=1)( |$)' /proc/cmdline 2>/dev/null; then
                    _ram_warning="\n\nWARNING: this medium does NOT look RAM-loaded (no toram /\n\
rd.live.ram on the kernel command line). The installer reads its own\n\
files from this disk AFTER partitioning it, so the run will most likely\n\
ABORT partway — with the disk already repartitioned. Reboot with toram\n\
first if you can."
                fi

                dialog_msgbox "Only Disk Is the Install Medium" \
                    "${selected_disk} is the medium this installer booted from, and it is\n\
the only disk in this machine.\n\n\
That happens when the ISO was copied onto an internal disk and booted\n\
through GRUB loopback. Installing here means the installer loses its own\n\
files the moment the disk is repartitioned, so the run must finish in one\n\
go and cannot be resumed.${_ram_warning}\n\n\
Confirm on the next screen, or cancel to go back."

                local override
                override=$(dialog_inputbox "Confirm Install Medium" \
                    "Type OVERRIDE to install onto ${selected_disk} anyway:" "") \
                    || return "${TUI_BACK}"
                if [[ "${override}" == "OVERRIDE" ]]; then
                    # Records WHICH disk was granted, never a bare "yes", and is
                    # kept out of CONFIG_VARS on purpose: a portable preset
                    # carrying "override = yes" would wave through the live USB
                    # of every other machine it is imported on — re-enabling
                    # exactly the data loss this guard exists to prevent.
                    LIVE_MEDIUM_OVERRIDE_DISK="${selected_disk}"
                    export LIVE_MEDIUM_OVERRIDE_DISK
                    ewarn "Operator overrode the install-medium guard for ${selected_disk}"
                    break
                fi
                continue
            fi

            dialog_msgbox "Cannot Install Onto the Install Medium" \
                "${selected_disk} is the medium this installer booted from.\n\n\
Partitioning it would destroy the running installer: the target disk is\n\
unmounted and repartitioned, so the installer would lose its own files\n\
mid-run and leave nothing to resume from.\n\n\
Pick a different disk."
            continue
        fi
        break
    done

    TARGET_DISK="${selected_disk}"
    export TARGET_DISK

    # Partition scheme — offer dual-boot if Windows OR Linux detected
    local scheme
    if [[ "${WINDOWS_DETECTED:-0}" == "1" || "${LINUX_DETECTED:-0}" == "1" ]]; then
        local dualboot_desc="Dual-boot (reuse existing ESP)"
        [[ "${WINDOWS_DETECTED:-0}" == "1" ]] && dualboot_desc="Dual-boot with Windows (reuse existing ESP)"
        [[ "${LINUX_DETECTED:-0}" == "1" && "${WINDOWS_DETECTED:-0}" == "1" ]] && \
            dualboot_desc="Dual-boot with Windows + Linux (reuse existing ESP)"
        [[ "${LINUX_DETECTED:-0}" == "1" && "${WINDOWS_DETECTED:-0}" != "1" ]] && \
            dualboot_desc="Dual-boot with Linux (reuse existing ESP)"

        scheme=$(dialog_menu "Partition Scheme" \
            "dual-boot"  "${dualboot_desc}" \
            "auto"       "Auto-partition entire disk (DESTROYS ALL DATA)" \
            "manual"     "Manual partitioning (advanced)") \
            || return "${TUI_BACK}"
    else
        scheme=$(dialog_menu "Partition Scheme" \
            "auto"   "Auto-partition entire disk (DESTROYS ALL DATA)" \
            "manual" "Manual partitioning (advanced)") \
            || return "${TUI_BACK}"
    fi

    PARTITION_SCHEME="${scheme}"
    export PARTITION_SCHEME

    case "${scheme}" in
        dual-boot)
            # Reuse existing ESP
            if [[ -n "${WINDOWS_ESP:-}" ]]; then
                ESP_PARTITION="${WINDOWS_ESP}"
                ESP_REUSE="yes"
            elif [[ ${#ESP_PARTITIONS[@]} -gt 0 ]]; then
                # Let user pick ESP
                local -a esp_items=()
                local esp
                for esp in "${ESP_PARTITIONS[@]}"; do
                    esp_items+=("${esp}" "EFI System Partition")
                done
                ESP_PARTITION=$(dialog_menu "Select ESP" "${esp_items[@]}") \
                    || return "${TUI_BACK}"
                ESP_REUSE="yes"
            else
                # Falling back to auto from inside the dual-boot arm means the
                # auto arm — and with it the "DESTROY ALL DATA" yes/no gate —
                # never runs. The operator asked for dual-boot; do not hand them
                # a full-disk wipe on the strength of an informational box.
                dialog_msgbox "No ESP Found" \
                    "No existing ESP was found on this machine.\n\n\
Dual-boot needs an existing EFI System Partition to reuse, so it is not\n\
possible here. The alternative is auto-partitioning, which ERASES the\n\
whole disk."
                if ! dialog_yesno "WARNING: Data Destruction" \
                    "Switch to auto-partitioning?\n\n\
This DESTROYS ALL DATA on:\n\n  ${TARGET_DISK}\n\n\
Choose No to go back and pick a different disk or scheme."; then
                    return "${TUI_BACK}"
                fi
                PARTITION_SCHEME="auto"
                ESP_REUSE="no"
            fi
            export ESP_PARTITION ESP_REUSE

            # For dual-boot, select the partition for Gentoo root
            local -a part_items=()
            _get_partition_info_for_dialog "${TARGET_DISK}" "${ESP_PARTITION:-}"

            if [[ ${#part_items[@]} -gt 0 ]]; then
                local use_existing
                use_existing=$(dialog_menu "Root Partition" \
                    "new"      "Create new partition in free space" \
                    "existing" "Use existing partition") \
                    || return "${TUI_BACK}"

                if [[ "${use_existing}" == "existing" ]]; then
                    ROOT_PARTITION=$(dialog_menu "Select Root Partition" "${part_items[@]}") \
                        || return "${TUI_BACK}"

                    # Warn if selected partition has a detected OS
                    if [[ -n "${DANGEROUS_PARTITIONS[${ROOT_PARTITION}]:-}" ]]; then
                        local os_name="${DANGEROUS_PARTITIONS[${ROOT_PARTITION}]}"

                        dialog_msgbox "WARNING: Existing OS Detected" \
                            "!!! DANGER !!!\n\n\
The partition you selected contains:\n\n\
  ${ROOT_PARTITION}: ${os_name}\n\n\
Formatting this partition will PERMANENTLY DESTROY\n\
this operating system and ALL its data.\n\n\
Type ERASE in the next dialog to confirm."

                        local erase_confirm
                        erase_confirm=$(dialog_inputbox "Confirm Destruction" \
                            "Type ERASE to confirm destruction of ${os_name} on ${ROOT_PARTITION}:" \
                            "") || return "${TUI_BACK}"

                        if [[ "${erase_confirm}" != "ERASE" ]]; then
                            dialog_msgbox "Cancelled" \
                                "Partition selection cancelled. You typed: '${erase_confirm}'"
                            return "${TUI_BACK}"
                        fi
                    fi

                    export ROOT_PARTITION
                else
                    # "Create new" — check free space, launch shrink wizard if needed
                    # The new partition lands in ONE gap and stretches to the
                    # next used partition, so what matters is the largest gap —
                    # not the sum, which happily reported "25 GiB free" for a
                    # 15 GiB and a 10 GiB hole and then produced a 15 GiB root.
                    local free_mib
                    free_mib=$(disk_get_largest_free_mib "${TARGET_DISK}")
                    if [[ ${free_mib} -lt ${GENTOO_MIN_SIZE_MIB} ]]; then
                        _shrink_wizard "${TARGET_DISK}" "${ESP_PARTITION}" \
                            || return "${TUI_BACK}"
                    fi
                fi
            fi
            ;;
        auto)
            ESP_REUSE="no"
            export ESP_REUSE

            dialog_yesno "WARNING: Data Destruction" \
                "Auto-partitioning will DESTROY ALL DATA on:\n\n  ${TARGET_DISK}\n\nAre you sure?" \
                || return "${TUI_BACK}"
            ;;
        manual)
            dialog_msgbox "Manual Partitioning" \
                "You will be dropped to a shell for manual partitioning.\n\n\
Required partitions:\n\
  1. ESP (EFI System Partition) — at least 512 MiB, vfat\n\
  2. Root partition — your choice of filesystem\n\
  3. (Optional) Swap partition\n\n\
After partitioning, type 'exit' to return.\n\
You will then be asked to specify partition paths."

            PS1="(gentoo-partition) \w \$ " bash --norc --noprofile || true

            ESP_PARTITION=$(dialog_inputbox "ESP Partition" \
                "Enter the path to the ESP partition:" \
                "/dev/${TARGET_DISK##*/}1") || return "${TUI_BACK}"
            ROOT_PARTITION=$(dialog_inputbox "Root Partition" \
                "Enter the path to the root partition:" \
                "/dev/${TARGET_DISK##*/}2") || return "${TUI_BACK}"

            local has_swap
            has_swap=$(dialog_yesno "Swap Partition" \
                "Did you create a swap partition?" && echo "yes" || echo "no")
            if [[ "${has_swap}" == "yes" ]]; then
                SWAP_PARTITION=$(dialog_inputbox "Swap Partition" \
                    "Enter the path to the swap partition:" \
                    "/dev/${TARGET_DISK##*/}3") || return "${TUI_BACK}"
                export SWAP_PARTITION
            fi

            local esp_reuse
            esp_reuse=$(dialog_yesno "ESP Reuse" \
                "Is this an existing ESP with other bootloaders? (e.g., Windows)" \
                && echo "yes" || echo "no")
            ESP_REUSE="${esp_reuse}"

            export ESP_PARTITION ROOT_PARTITION ESP_REUSE
            ;;
    esac

    einfo "Disk: ${TARGET_DISK}, Scheme: ${PARTITION_SCHEME}"
    return "${TUI_NEXT}"
}
