#!/usr/bin/env bash
# tui/disk_select.sh — Disk selection + partition scheme
source "${LIB_DIR}/protection.sh"

screen_disk_select() {
    # Build disk list for dialog
    local -a disk_items=()
    local entry
    for entry in "${AVAILABLE_DISKS[@]}"; do
        local name size model tran
        IFS='|' read -r name size model tran <<< "${entry}"
        disk_items+=("/dev/${name}" "${size} ${model} (${tran})")
    done

    if [[ ${#disk_items[@]} -eq 0 ]]; then
        dialog_msgbox "No Disks" "No suitable disks found. Cannot continue."
        return "${TUI_ABORT}"
    fi

    # Select target disk
    local selected_disk
    selected_disk=$(dialog_menu "Select Target Disk" "${disk_items[@]}") \
        || return "${TUI_BACK}"

    TARGET_DISK="${selected_disk}"
    export TARGET_DISK

    # Partition scheme
    local scheme
    if [[ "${WINDOWS_DETECTED:-0}" == "1" ]]; then
        scheme=$(dialog_menu "Partition Scheme" \
            "dual-boot"  "Dual-boot with Windows (reuse existing ESP)" \
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
            # Reuse Windows ESP
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
                dialog_msgbox "No ESP Found" \
                    "No existing ESP found. Falling back to auto-partition."
                PARTITION_SCHEME="auto"
                ESP_REUSE="no"
            fi
            export ESP_PARTITION ESP_REUSE

            # For dual-boot, select the partition for Gentoo root
            local -a part_items=()
            while IFS= read -r line; do
                local pname psize
                read -r pname psize <<< "${line}"
                [[ "/dev/${pname}" == "${ESP_PARTITION}" ]] && continue
                part_items+=("/dev/${pname}" "${psize}")
            done < <(lsblk -lno NAME,SIZE "${TARGET_DISK}" 2>/dev/null | tail -n +2)

            if [[ ${#part_items[@]} -gt 0 ]]; then
                local use_existing
                use_existing=$(dialog_menu "Root Partition" \
                    "new"      "Create new partition in free space" \
                    "existing" "Use existing partition") \
                    || return "${TUI_BACK}"

                if [[ "${use_existing}" == "existing" ]]; then
                    ROOT_PARTITION=$(dialog_menu "Select Root Partition" "${part_items[@]}") \
                        || return "${TUI_BACK}"
                    export ROOT_PARTITION
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
