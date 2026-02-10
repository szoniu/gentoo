#!/usr/bin/env bash
# hardware.sh — Hardware detection: CPU, GPU, disks, ESP/Windows
source "${LIB_DIR}/protection.sh"

# --- CPU Detection ---

# detect_cpu — Detect CPU vendor, model name, core count, march flag
detect_cpu() {
    CPU_VENDOR=$(grep -m1 'vendor_id' /proc/cpuinfo 2>/dev/null | awk -F': ' '{print $2}') || CPU_VENDOR="unknown"
    CPU_MODEL=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | awk -F': ' '{print $2}') || CPU_MODEL="unknown"
    CPU_CORES=$(nproc 2>/dev/null) || CPU_CORES=4
    CPU_MARCH=$(lookup_cpu_march)

    # Try to get CPU flags
    if command -v cpuid2cpuflags &>/dev/null; then
        CPU_FLAGS=$(cpuid2cpuflags 2>/dev/null | sed 's/CPU_FLAGS_X86: //') || CPU_FLAGS=""
    else
        CPU_FLAGS=""  # Will be detected in chroot
    fi

    export CPU_VENDOR CPU_MODEL CPU_CORES CPU_MARCH CPU_FLAGS

    einfo "CPU: ${CPU_MODEL}"
    einfo "CPU march: ${CPU_MARCH}"
    einfo "CPU cores: ${CPU_CORES}"
    [[ -n "${CPU_FLAGS}" ]] && einfo "CPU flags: ${CPU_FLAGS}"
}

# --- GPU Detection ---

# detect_gpu — Detect GPU vendor, device ID, and driver recommendation
detect_gpu() {
    GPU_VENDOR=""
    GPU_DEVICE_ID=""
    GPU_DEVICE_NAME=""
    GPU_DRIVER=""
    VIDEO_CARDS=""
    GPU_USE_NVIDIA_OPEN="no"

    # Find discrete GPU first, fall back to integrated
    local gpu_line
    gpu_line=$(lspci -nn 2>/dev/null | grep -i 'vga\|3d\|display' | head -1) || true

    if [[ -z "${gpu_line}" ]]; then
        ewarn "No GPU detected via lspci"
        GPU_VENDOR="unknown"
        VIDEO_CARDS="fbdev"
        export GPU_VENDOR GPU_DEVICE_ID GPU_DEVICE_NAME GPU_DRIVER VIDEO_CARDS GPU_USE_NVIDIA_OPEN
        return
    fi

    einfo "GPU line: ${gpu_line}"

    # Extract vendor:device from [xxxx:yyyy]
    local pci_ids
    pci_ids=$(echo "${gpu_line}" | grep -oP '\[\w{4}:\w{4}\]' | tail -1) || true
    local vendor_id device_id
    vendor_id=$(echo "${pci_ids}" | tr -d '[]' | cut -d: -f1)
    device_id=$(echo "${pci_ids}" | tr -d '[]' | cut -d: -f2)

    GPU_DEVICE_ID="${device_id}"

    # Determine GPU vendor name
    case "${vendor_id}" in
        "${GPU_VENDOR_NVIDIA}")
            GPU_VENDOR="nvidia"
            GPU_DEVICE_NAME=$(echo "${gpu_line}" | sed 's/.*: //')
            ;;
        "${GPU_VENDOR_AMD}")
            GPU_VENDOR="amd"
            GPU_DEVICE_NAME=$(echo "${gpu_line}" | sed 's/.*: //')
            ;;
        "${GPU_VENDOR_INTEL}")
            GPU_VENDOR="intel"
            GPU_DEVICE_NAME=$(echo "${gpu_line}" | sed 's/.*: //')
            ;;
        *)
            GPU_VENDOR="unknown"
            GPU_DEVICE_NAME="Unknown GPU"
            ;;
    esac

    # Get driver recommendation
    local recommendation
    recommendation=$(get_gpu_recommendation "${vendor_id}" "${device_id}")
    GPU_DRIVER=$(echo "${recommendation}" | cut -d'|' -f1)
    VIDEO_CARDS=$(echo "${recommendation}" | cut -d'|' -f2)
    GPU_USE_NVIDIA_OPEN=$(echo "${recommendation}" | cut -d'|' -f3)

    export GPU_VENDOR GPU_DEVICE_ID GPU_DEVICE_NAME GPU_DRIVER VIDEO_CARDS GPU_USE_NVIDIA_OPEN

    einfo "GPU: ${GPU_DEVICE_NAME} (${GPU_VENDOR})"
    einfo "Driver: ${GPU_DRIVER}, VIDEO_CARDS=${VIDEO_CARDS}"
    [[ "${GPU_VENDOR}" == "nvidia" ]] && einfo "NVIDIA open kernel: ${GPU_USE_NVIDIA_OPEN}"
}

# --- Disk Detection ---

# detect_disks — List available block devices
# Populates AVAILABLE_DISKS array: "device|size|model|transport"
detect_disks() {
    declare -ga AVAILABLE_DISKS=()

    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        local name size model tran
        read -r name size model tran <<< "${line}"
        AVAILABLE_DISKS+=("${name}|${size}|${model:-unknown}|${tran:-unknown}")
        einfo "Disk: /dev/${name} — ${size} — ${model:-unknown} (${tran:-unknown})"
    done < <(lsblk -dno NAME,SIZE,MODEL,TRAN 2>/dev/null | grep -v '^loop\|^sr\|^rom\|^ram\|^zram')

    export AVAILABLE_DISKS

    if [[ ${#AVAILABLE_DISKS[@]} -eq 0 ]]; then
        ewarn "No suitable disks detected"
    fi
}

# get_disk_list_for_dialog — Format disks for dialog menu
get_disk_list_for_dialog() {
    local entry
    for entry in "${AVAILABLE_DISKS[@]}"; do
        local name size model tran
        IFS='|' read -r name size model tran <<< "${entry}"
        echo "/dev/${name}"
        echo "${size} ${model} (${tran})"
    done
}

# --- ESP / Windows Detection ---

# detect_esp — Find existing EFI System Partitions
# Populates ESP_PARTITIONS array and checks for Windows
detect_esp() {
    declare -ga ESP_PARTITIONS=()
    WINDOWS_DETECTED=0
    WINDOWS_ESP=""

    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        local dev uuid type parttype
        eval "${line}"

        # Check for EFI System Partition (GUID: C12A7328-F81F-11D2-BA4B-00A0C93EC93B)
        if [[ "${parttype:-}" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]] || \
           [[ "${type:-}" == "vfat" && "${parttype:-}" == "c12a7328"* ]]; then
            ESP_PARTITIONS+=("${dev}")
            einfo "Found ESP: ${dev}"

            # Check for Windows Boot Manager
            local tmp_mount="/tmp/esp-check-$$"
            mkdir -p "${tmp_mount}"
            if mount -o ro "${dev}" "${tmp_mount}" 2>/dev/null; then
                if [[ -d "${tmp_mount}/EFI/Microsoft/Boot" ]]; then
                    WINDOWS_DETECTED=1
                    WINDOWS_ESP="${dev}"
                    einfo "Windows Boot Manager found on ${dev}"
                fi
                umount "${tmp_mount}" 2>/dev/null
            fi
            rmdir "${tmp_mount}" 2>/dev/null || true
        fi
    done < <(blkid -o export 2>/dev/null | awk -v RS='' '{print}' | \
             grep -i 'PARTTYPE.*c12a7328\|TYPE.*vfat' | head -20)

    # Simpler approach: iterate over all partitions
    if [[ ${#ESP_PARTITIONS[@]} -eq 0 ]]; then
        while IFS= read -r part; do
            local parttype
            parttype=$(blkid -o value -s PART_ENTRY_TYPE "${part}" 2>/dev/null) || continue
            if [[ "${parttype,,}" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]]; then
                ESP_PARTITIONS+=("${part}")
                einfo "Found ESP: ${part}"

                local tmp_mount="/tmp/esp-check-$$"
                mkdir -p "${tmp_mount}"
                if mount -o ro "${part}" "${tmp_mount}" 2>/dev/null; then
                    if [[ -d "${tmp_mount}/EFI/Microsoft/Boot" ]]; then
                        WINDOWS_DETECTED=1
                        WINDOWS_ESP="${part}"
                        einfo "Windows Boot Manager found on ${part}"
                    fi
                    umount "${tmp_mount}" 2>/dev/null
                fi
                rmdir "${tmp_mount}" 2>/dev/null || true
            fi
        done < <(lsblk -lno PATH,FSTYPE 2>/dev/null | awk '$2=="vfat"{print $1}')
    fi

    export ESP_PARTITIONS WINDOWS_DETECTED WINDOWS_ESP
}

# --- Full Detection ---

# detect_all_hardware — Run all hardware detection
detect_all_hardware() {
    einfo "=== Hardware Detection ==="
    detect_cpu
    detect_gpu
    detect_disks
    detect_esp
    einfo "=== Hardware Detection Complete ==="
}

# get_hardware_summary — Format hardware info for display
get_hardware_summary() {
    local summary=""
    summary+="CPU: ${CPU_MODEL:-unknown}\n"
    summary+="  March: ${CPU_MARCH:-x86-64}\n"
    summary+="  Cores: ${CPU_CORES:-?}\n"
    [[ -n "${CPU_FLAGS:-}" ]] && summary+="  Flags: ${CPU_FLAGS}\n"
    summary+="\n"
    summary+="GPU: ${GPU_DEVICE_NAME:-unknown}\n"
    summary+="  Vendor: ${GPU_VENDOR:-unknown}\n"
    summary+="  Driver: ${GPU_DRIVER:-none}\n"
    [[ "${GPU_VENDOR:-}" == "nvidia" ]] && summary+="  Open kernel: ${GPU_USE_NVIDIA_OPEN:-no}\n"
    summary+="\n"
    summary+="Disks:\n"
    local entry
    for entry in "${AVAILABLE_DISKS[@]}"; do
        local name size model tran
        IFS='|' read -r name size model tran <<< "${entry}"
        summary+="  /dev/${name}: ${size} ${model} (${tran})\n"
    done
    summary+="\n"
    if [[ "${WINDOWS_DETECTED:-0}" == "1" ]]; then
        summary+="Windows: Detected (ESP: ${WINDOWS_ESP})\n"
    else
        summary+="Windows: Not detected\n"
    fi
    if [[ ${#ESP_PARTITIONS[@]} -gt 0 ]]; then
        summary+="ESP partitions: ${ESP_PARTITIONS[*]}\n"
    fi
    echo -e "${summary}"
}
