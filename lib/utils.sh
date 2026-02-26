#!/usr/bin/env bash
# utils.sh — Utility functions: try (interactive recovery), countdown, dependency checks
source "${LIB_DIR}/protection.sh"

# try — Execute a command with interactive recovery on failure
# Usage: try "description" command [args...]
try() {
    local desc="$1"
    shift

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        einfo "[DRY-RUN] Would execute: $*"
        return 0
    fi

    while true; do
        einfo "Running: ${desc}"
        elog "Command: $*"

        local exit_code=0
        if [[ "${LIVE_OUTPUT:-0}" == "1" ]]; then
            # Show output on terminal AND log to file (pipeline, not process substitution)
            "$@" 2>&1 | tee -a "${LOG_FILE}" || exit_code=$?
        else
            "$@" >> "${LOG_FILE}" 2>&1 || exit_code=$?
        fi

        if [[ ${exit_code} -eq 0 ]]; then
            einfo "Success: ${desc}"
            return 0
        fi
        eerror "Failed (exit ${exit_code}): ${desc}"
        eerror "Command: $*"

        if [[ "${NON_INTERACTIVE:-0}" == "1" ]]; then
            die "Non-interactive mode — aborting on failure: ${desc}"
        fi

        # Restore stderr for dialog UI if it was redirected (fd 4 saved by screen_progress)
        local _stderr_redirected=0
        if { true >&4; } 2>/dev/null; then
            exec 2>&4
            _stderr_redirected=1
        fi

        local choice

        if command -v "${DIALOG_CMD:-dialog}" &>/dev/null; then
            # Full dialog UI available
            choice=$(dialog_menu "Command Failed: ${desc}" \
                "retry"    "Retry the command" \
                "shell"    "Drop to a shell (type 'exit' to return)" \
                "continue" "Skip this step and continue" \
                "log"      "View last 50 lines of log" \
                "abort"    "Abort installation") || choice="abort"
        else
            # No dialog (e.g. inside chroot) — simple text menu
            echo "" >&2
            echo "=== FAILED: ${desc} ===" >&2
            echo "  (r)etry  | (s)hell  | (c)ontinue  | (a)bort" >&2
            local _reply=""
            if [[ -e /dev/tty ]]; then
                read -r -p "Choice [r/s/c/a]: " _reply < /dev/tty || _reply="a"
            else
                # /dev/tty missing (broken chroot) — try stdin, fall back to abort
                read -r -p "Choice [r/s/c/a]: " _reply 2>/dev/null || _reply="a"
            fi
            case "${_reply}" in
                r*) choice="retry" ;;
                s*) choice="shell" ;;
                c*) choice="continue" ;;
                *)  choice="abort" ;;
            esac
        fi

        case "${choice}" in
            retry)
                ewarn "Retrying: ${desc}"
                [[ ${_stderr_redirected} -eq 1 ]] && exec 2>>"${LOG_FILE}"
                continue
                ;;
            shell)
                ewarn "Dropping to shell. Type 'exit' to return to installer."
                PS1="(gentoo-installer rescue) \w \$ " bash --norc --noprofile || true
                [[ ${_stderr_redirected} -eq 1 ]] && exec 2>>"${LOG_FILE}"
                continue
                ;;
            continue)
                ewarn "Skipping: ${desc} (user chose to continue)"
                [[ ${_stderr_redirected} -eq 1 ]] && exec 2>>"${LOG_FILE}"
                return 0
                ;;
            log)
                dialog_textbox "Log Output" "${LOG_FILE}" || true
                [[ ${_stderr_redirected} -eq 1 ]] && exec 2>>"${LOG_FILE}"
                continue
                ;;
            abort)
                die "Aborted by user after failure: ${desc}"
                ;;
        esac
    done
}

# countdown — Display a countdown timer
# Usage: countdown <seconds> <message>
countdown() {
    local seconds="${1:-${COUNTDOWN_DEFAULT}}"
    local msg="${2:-Continuing in}"

    if [[ "${NON_INTERACTIVE:-0}" == "1" ]]; then
        return 0
    fi

    local i
    for ((i = seconds; i > 0; i--)); do
        printf "\r%s %d seconds... " "${msg}" "${i}" >&2
        sleep 1
    done
    printf "\r%s\n" "$(printf '%-60s' '')" >&2
}

# check_dependencies — Verify required tools are available
check_dependencies() {
    local -a missing=()
    local dep

    local -a required_deps=(
        bash
        mkfs.ext4
        mkfs.vfat
        sfdisk
        mount
        umount
        blkid
        lsblk
        wget
        tar
        gpg
        sha512sum
        chroot
    )

    for dep in "${required_deps[@]}"; do
        if ! command -v "${dep}" &>/dev/null; then
            missing+=("${dep}")
        fi
    done

    # dialog or whiptail
    if ! command -v dialog &>/dev/null && ! command -v whiptail &>/dev/null; then
        missing+=("dialog|whiptail")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        eerror "Missing required dependencies:"
        local m
        for m in "${missing[@]}"; do
            eerror "  - ${m}"
        done
        return 1
    fi

    einfo "All dependencies satisfied"
    return 0
}

# is_efi — Check if booted in EFI mode
is_efi() {
    [[ -d /sys/firmware/efi ]]
}

# is_root — Check if running as root
is_root() {
    [[ "$(id -u)" -eq 0 ]]
}

# ensure_dns — Add fallback nameserver if DNS resolution fails
ensure_dns() {
    if ! ping -c 1 -W 3 gentoo.org &>/dev/null && ! ping -c 1 -W 3 google.com &>/dev/null; then
        # Ping failed — check if it's a DNS issue (raw IP works?)
        if ping -c 1 -W 3 8.8.8.8 &>/dev/null; then
            ewarn "DNS resolution failed, adding fallback nameserver 8.8.8.8"
            if ! grep -q '8.8.8.8' /etc/resolv.conf 2>/dev/null; then
                echo "nameserver 8.8.8.8" >> /etc/resolv.conf
            fi
        fi
    fi
}

# has_network — Check basic network connectivity
has_network() {
    ping -c 1 -W 3 gentoo.org &>/dev/null || \
    ping -c 1 -W 3 google.com &>/dev/null
}

# checkpoint_set — Mark a phase as completed
checkpoint_set() {
    local name="$1"
    mkdir -p "${CHECKPOINT_DIR}"
    touch "${CHECKPOINT_DIR}/${name}"
    einfo "Checkpoint set: ${name}"
}

# checkpoint_reached — Check if a phase is already completed
checkpoint_reached() {
    local name="$1"
    [[ -f "${CHECKPOINT_DIR}/${name}" ]]
}

# checkpoint_clear — Remove all checkpoints
checkpoint_clear() {
    rm -rf "${CHECKPOINT_DIR}"
    einfo "All checkpoints cleared"
}

# checkpoint_validate — Check if a checkpoint's artifact actually exists
# Returns 0 if checkpoint is valid, 1 if it should be re-run
checkpoint_validate() {
    local name="$1"
    case "${name}" in
        preflight)
            return 1 ;;  # always re-run (fast)
        disks)
            [[ -b "${ROOT_PARTITION:-}" ]] && mountpoint -q "${MOUNTPOINT}" 2>/dev/null ;;
        stage3_extract)
            [[ -f "${MOUNTPOINT}/etc/gentoo-release" ]] ;;
        portage_preconfig)
            [[ -f "${MOUNTPOINT}/etc/portage/make.conf" ]] ;;
        stage3_download|stage3_verify)
            ls "${MOUNTPOINT}"/stage3-*.tar.* &>/dev/null 2>&1 ;;
        chroot)
            [[ -f "${MOUNTPOINT}${CHECKPOINT_DIR_SUFFIX}/finalize" ]] ;;
        kernel)
            ls "${MOUNTPOINT}/boot/vmlinuz-"* &>/dev/null 2>&1 || ls /boot/vmlinuz-* &>/dev/null 2>&1 ;;
        *)
            return 0 ;;  # trust checkpoint for the rest
    esac
}

# checkpoint_migrate_to_target — Move checkpoints from /tmp to target disk
# Called after mounting filesystems so checkpoints survive reformat
checkpoint_migrate_to_target() {
    local target_dir="${MOUNTPOINT}${CHECKPOINT_DIR_SUFFIX}"
    [[ "${CHECKPOINT_DIR}" == "${target_dir}" ]] && return 0
    mkdir -p "${target_dir}"
    [[ -d "${CHECKPOINT_DIR}" ]] && cp -a "${CHECKPOINT_DIR}/"* "${target_dir}/" 2>/dev/null || true
    rm -rf "${CHECKPOINT_DIR}"
    CHECKPOINT_DIR="${target_dir}"
    export CHECKPOINT_DIR
}

# --- Resume from disk ---

# RESUME_FOUND_PARTITION — partition where resume data was found
RESUME_FOUND_PARTITION=""
# RESUME_FOUND_FSTYPE — filesystem type of that partition
RESUME_FOUND_FSTYPE=""
# RESUME_HAS_CONFIG — whether config file was found alongside checkpoints
RESUME_HAS_CONFIG=0

# _scan_partition_for_resume — Check a single partition for resume data
# Usage: _scan_partition_for_resume /dev/sdX2 ext4
# Sets: _SCAN_HAS_CHECKPOINTS, _SCAN_HAS_CONFIG, _SCAN_MOUNTPOINT
_scan_partition_for_resume() {
    local part="$1"
    local fstype="$2"
    _SCAN_HAS_CHECKPOINTS=0
    _SCAN_HAS_CONFIG=0
    _SCAN_MOUNTPOINT=""

    # For testing: use fake directory instead of real mount
    if [[ -n "${_RESUME_TEST_DIR:-}" ]]; then
        local fake_mp="${_RESUME_TEST_DIR}/mnt/${part##*/}"
        if [[ -d "${fake_mp}${CHECKPOINT_DIR_SUFFIX}" ]] && ls "${fake_mp}${CHECKPOINT_DIR_SUFFIX}/"* &>/dev/null 2>&1; then
            _SCAN_HAS_CHECKPOINTS=1
            _SCAN_MOUNTPOINT="${fake_mp}"
        fi
        if [[ -f "${fake_mp}/tmp/gentoo-installer.conf" ]]; then
            _SCAN_HAS_CONFIG=1
        fi
        return 0
    fi

    # Skip if already mounted somewhere
    if findmnt -rn -S "${part}" &>/dev/null; then
        local existing_mp
        existing_mp=$(findmnt -rn -o TARGET -S "${part}" | head -1) || true
        if [[ -n "${existing_mp}" ]]; then
            # Check in-place without mounting
            if [[ -d "${existing_mp}${CHECKPOINT_DIR_SUFFIX}" ]] && ls "${existing_mp}${CHECKPOINT_DIR_SUFFIX}/"* &>/dev/null 2>&1; then
                _SCAN_HAS_CHECKPOINTS=1
                _SCAN_MOUNTPOINT="${existing_mp}"
            fi
            if [[ -f "${existing_mp}/tmp/gentoo-installer.conf" ]]; then
                _SCAN_HAS_CONFIG=1
            fi
            return 0
        fi
    fi

    local mp
    mp=$(mktemp -d "${TMPDIR:-/tmp}/gentoo-resume-scan.XXXXXX")

    local mounted=0
    if mount -o ro "${part}" "${mp}" 2>/dev/null; then
        mounted=1
    elif [[ "${fstype}" == "btrfs" ]]; then
        # Btrfs: try mounting default subvolume @
        if mount -o ro,subvol=@ "${part}" "${mp}" 2>/dev/null; then
            mounted=1
        fi
    fi

    if [[ ${mounted} -eq 1 ]]; then
        if [[ -d "${mp}${CHECKPOINT_DIR_SUFFIX}" ]] && ls "${mp}${CHECKPOINT_DIR_SUFFIX}/"* &>/dev/null 2>&1; then
            _SCAN_HAS_CHECKPOINTS=1
            _SCAN_MOUNTPOINT="${mp}"
        fi
        if [[ -f "${mp}/tmp/gentoo-installer.conf" ]]; then
            _SCAN_HAS_CONFIG=1
        fi
        umount "${mp}" 2>/dev/null || true
    fi

    rmdir "${mp}" 2>/dev/null || true
    return 0
}

# _recover_resume_data — Copy checkpoints and config from partition
# Usage: _recover_resume_data /dev/sdX2 ext4
_recover_resume_data() {
    local part="$1"
    local fstype="$2"

    # For testing: use fake directory instead of real mount
    if [[ -n "${_RESUME_TEST_DIR:-}" ]]; then
        local fake_mp="${_RESUME_TEST_DIR}/mnt/${part##*/}"
        mkdir -p "${CHECKPOINT_DIR}"
        cp -a "${fake_mp}${CHECKPOINT_DIR_SUFFIX}/"* "${CHECKPOINT_DIR}/" 2>/dev/null || true
        if [[ -f "${fake_mp}/tmp/gentoo-installer.conf" ]]; then
            (umask 077; cp "${fake_mp}/tmp/gentoo-installer.conf" "${CONFIG_FILE}")
        fi
        return 0
    fi

    local mp
    mp=$(mktemp -d "${TMPDIR:-/tmp}/gentoo-resume-recover.XXXXXX")
    local mounted=0

    if findmnt -rn -S "${part}" &>/dev/null; then
        local existing_mp
        existing_mp=$(findmnt -rn -o TARGET -S "${part}" | head -1) || true
        if [[ -n "${existing_mp}" ]]; then
            mp="${existing_mp}"
            mounted=2  # already mounted, don't unmount
        fi
    fi

    if [[ ${mounted} -eq 0 ]]; then
        if mount -o ro "${part}" "${mp}" 2>/dev/null; then
            mounted=1
        elif [[ "${fstype}" == "btrfs" ]]; then
            if mount -o ro,subvol=@ "${part}" "${mp}" 2>/dev/null; then
                mounted=1
            fi
        fi
    fi

    if [[ ${mounted} -gt 0 ]]; then
        mkdir -p "${CHECKPOINT_DIR}"
        cp -a "${mp}${CHECKPOINT_DIR_SUFFIX}/"* "${CHECKPOINT_DIR}/" 2>/dev/null || true
        einfo "Recovered checkpoints from ${part}"

        if [[ -f "${mp}/tmp/gentoo-installer.conf" ]]; then
            (umask 077; cp "${mp}/tmp/gentoo-installer.conf" "${CONFIG_FILE}")
            einfo "Recovered config from ${part}"
        fi

        [[ ${mounted} -eq 1 ]] && umount "${mp}" 2>/dev/null || true
    fi

    [[ ${mounted} -ne 2 ]] && rmdir "${mp}" 2>/dev/null || true
    return 0
}

# try_resume_from_disk — Scan all partitions for resume data (checkpoints + config)
# Returns: 0 = config + checkpoints found, 1 = only checkpoints, 2 = nothing found
# Sets: RESUME_FOUND_PARTITION, RESUME_HAS_CONFIG
try_resume_from_disk() {
    RESUME_FOUND_PARTITION=""
    RESUME_HAS_CONFIG=0

    einfo "Scanning partitions for previous installation data..."

    local found_part="" found_fstype="" found_config=0

    if [[ -n "${_RESUME_TEST_DIR:-}" ]]; then
        # Testing mode: read fake partition list
        local part fstype
        while IFS=' ' read -r part fstype; do
            [[ -z "${part}" || -z "${fstype}" ]] && continue
            case "${fstype}" in
                ext4|ext3|xfs|btrfs) ;;
                *) continue ;;
            esac
            _scan_partition_for_resume "${part}" "${fstype}"
            if [[ ${_SCAN_HAS_CHECKPOINTS} -eq 1 ]]; then
                found_part="${part}"
                found_fstype="${fstype}"
                found_config=${_SCAN_HAS_CONFIG}
                break
            fi
        done < "${_RESUME_TEST_DIR}/partitions.list"
    else
        local part fstype
        while IFS=' ' read -r part fstype; do
            [[ -z "${part}" || -z "${fstype}" ]] && continue
            case "${fstype}" in
                ext4|ext3|xfs|btrfs) ;;
                *) continue ;;
            esac
            _scan_partition_for_resume "${part}" "${fstype}"
            if [[ ${_SCAN_HAS_CHECKPOINTS} -eq 1 ]]; then
                found_part="${part}"
                found_fstype="${fstype}"
                found_config=${_SCAN_HAS_CONFIG}
                break
            fi
        done < <(lsblk -lno PATH,FSTYPE 2>/dev/null || true)
    fi

    if [[ -z "${found_part}" ]]; then
        ewarn "No previous installation data found on any partition"
        return 2
    fi

    einfo "Found resume data on ${found_part} (${found_fstype})"
    RESUME_FOUND_PARTITION="${found_part}"
    RESUME_FOUND_FSTYPE="${found_fstype}"
    export RESUME_FOUND_PARTITION RESUME_FOUND_FSTYPE

    _recover_resume_data "${found_part}" "${found_fstype}"

    if [[ ${found_config} -eq 1 ]]; then
        RESUME_HAS_CONFIG=1
        export RESUME_HAS_CONFIG
        einfo "Resume: config + checkpoints recovered from ${found_part}"
        return 0
    else
        RESUME_HAS_CONFIG=0
        export RESUME_HAS_CONFIG
        ewarn "Resume: checkpoints recovered but no config found on ${found_part}"
        return 1
    fi
}

# --- Config inference from installed partition ---

# _partition_to_disk — Strip partition suffix to get disk device
# /dev/sda2 → /dev/sda, /dev/nvme0n1p3 → /dev/nvme0n1, /dev/mmcblk0p1 → /dev/mmcblk0
_partition_to_disk() {
    local part="$1"
    if [[ "${part}" =~ ^(/dev/nvme[0-9]+n[0-9]+)p[0-9]+$ ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "${part}" =~ ^(/dev/mmcblk[0-9]+)p[0-9]+$ ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "${part}" =~ ^(/dev/[a-z]+)[0-9]+$ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "${part}"
    fi
}

# _resolve_uuid — Resolve UUID to device path (test-aware)
_resolve_uuid() {
    local uuid="$1"
    if [[ -n "${_INFER_UUID_MAP:-}" && -f "${_INFER_UUID_MAP}" ]]; then
        sed -n "s/^${uuid} //p" "${_INFER_UUID_MAP}" || true
    else
        blkid -U "${uuid}" 2>/dev/null || true
    fi
}

# _infer_from_fstab — Parse /etc/fstab for partition and filesystem info
_infer_from_fstab() {
    local mp="$1"
    local fstab="${mp}/etc/fstab"
    [[ -f "${fstab}" ]] || return 0

    local line dev mpoint fstype opts rest
    while IFS= read -r line; do
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line}" || "${line}" =~ ^[[:space:]]*$ ]] && continue

        read -r dev mpoint fstype opts rest <<< "${line}" || true
        [[ -z "${dev}" || -z "${mpoint}" ]] && continue

        # Resolve UUID= to device path
        if [[ "${dev}" =~ ^UUID=(.+)$ ]]; then
            local uuid="${BASH_REMATCH[1]}"
            local resolved
            resolved=$(_resolve_uuid "${uuid}")
            [[ -n "${resolved}" ]] && dev="${resolved}"
        fi

        case "${mpoint}" in
            /)
                if [[ -n "${dev}" && ! "${dev}" =~ ^UUID= ]]; then
                    ROOT_PARTITION="${dev}"
                    export ROOT_PARTITION
                fi
                case "${fstype}" in
                    ext4|xfs)
                        FILESYSTEM="${fstype}"
                        export FILESYSTEM
                        ;;
                    btrfs)
                        FILESYSTEM="btrfs"
                        export FILESYSTEM
                        if [[ "${opts}" =~ subvol= ]]; then
                            BTRFS_SUBVOLUMES="yes"
                            export BTRFS_SUBVOLUMES
                        fi
                        ;;
                esac
                ;;
            /boot/efi|/boot|/efi)
                if [[ "${fstype}" == "vfat" && -n "${dev}" && ! "${dev}" =~ ^UUID= ]]; then
                    ESP_PARTITION="${dev}"
                    export ESP_PARTITION
                fi
                ;;
        esac

        # Swap detection by fstype
        if [[ "${fstype}" == "swap" && -n "${dev}" && ! "${dev}" =~ ^UUID= ]]; then
            SWAP_PARTITION="${dev}"
            SWAP_TYPE="partition"
            export SWAP_PARTITION SWAP_TYPE
        fi
    done < "${fstab}"
}

# _infer_from_make_conf — Extract settings from /etc/portage/make.conf
_infer_from_make_conf() {
    local mp="$1"
    local makeconf="${mp}/etc/portage/make.conf"
    [[ -f "${makeconf}" ]] || return 0

    local line varname value
    while IFS= read -r line; do
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line}" || "${line}" =~ ^[[:space:]]*$ ]] && continue
        [[ "${line}" == *=* ]] || continue

        varname="${line%%=*}"
        value="${line#*=}"
        # Strip surrounding quotes
        value="${value#\"}"
        value="${value%\"}"
        value="${value#\'}"
        value="${value%\'}"

        case "${varname}" in
            VIDEO_CARDS)
                VIDEO_CARDS="${value}"
                export VIDEO_CARDS
                # Detect hybrid GPU from multi-vendor VIDEO_CARDS
                local _has_nvidia=0 _has_amd=0 _has_intel=0
                [[ " ${value} " == *" nvidia "* || "${value}" == *"nvidia"* ]] && _has_nvidia=1
                [[ " ${value} " == *" amdgpu "* || "${value}" == *"amdgpu"* ]] && _has_amd=1
                [[ " ${value} " == *" intel "* || "${value}" == *"intel"* ]] && _has_intel=1
                if (( _has_nvidia + _has_amd + _has_intel >= 2 )); then
                    HYBRID_GPU="yes"
                    export HYBRID_GPU
                    if (( _has_intel && _has_nvidia )); then
                        IGPU_VENDOR="intel"; DGPU_VENDOR="nvidia"; GPU_VENDOR="nvidia"
                    elif (( _has_amd && _has_nvidia )); then
                        IGPU_VENDOR="amd"; DGPU_VENDOR="nvidia"; GPU_VENDOR="nvidia"
                    elif (( _has_intel && _has_amd )); then
                        IGPU_VENDOR="intel"; DGPU_VENDOR="amd"; GPU_VENDOR="amd"
                    fi
                    export IGPU_VENDOR DGPU_VENDOR GPU_VENDOR
                else
                    HYBRID_GPU="no"
                    export HYBRID_GPU
                    case "${value}" in
                        *nvidia*) GPU_VENDOR="nvidia" ;;
                        *amdgpu*) GPU_VENDOR="amd" ;;
                        *intel*)  GPU_VENDOR="intel" ;;
                    esac
                    export GPU_VENDOR
                fi
                ;;
            CPU_FLAGS_X86)
                CPU_FLAGS="${value}"
                export CPU_FLAGS
                ;;
            COMMON_FLAGS|CFLAGS)
                if [[ "${value}" =~ -march=([^[:space:]]+) ]]; then
                    CPU_MARCH="${BASH_REMATCH[1]}"
                    export CPU_MARCH
                fi
                ;;
            USE)
                if [[ " ${value} " == *" systemd "* ]]; then
                    INIT_SYSTEM="systemd"
                    export INIT_SYSTEM
                elif [[ " ${value} " == *" -systemd "* ]]; then
                    INIT_SYSTEM="openrc"
                    export INIT_SYSTEM
                fi
                ;;
            GENTOO_MIRRORS)
                # Take first mirror URL
                MIRROR_URL="${value%% *}"
                export MIRROR_URL
                ;;
        esac
    done < "${makeconf}"
}

# _infer_from_hostname — Read hostname from system config
_infer_from_hostname() {
    local mp="$1"

    # systemd: /etc/hostname
    if [[ -f "${mp}/etc/hostname" ]]; then
        local h
        h=$(sed -n '/^[[:space:]]*$/d; /^[[:space:]]*#/d; p; q' "${mp}/etc/hostname") || true
        h="${h%%[[:space:]]*}"
        if [[ -n "${h}" ]]; then
            HOSTNAME="${h}"
            export HOSTNAME
            return 0
        fi
    fi

    # openrc: /etc/conf.d/hostname (sed, not source — per CLAUDE.md)
    if [[ -f "${mp}/etc/conf.d/hostname" ]]; then
        local h
        h=$(sed -n "s/^hostname=[\"']*\([^\"']*\).*/\1/p; T; q" "${mp}/etc/conf.d/hostname") || true
        if [[ -n "${h}" ]]; then
            HOSTNAME="${h}"
            export HOSTNAME
            return 0
        fi
    fi
}

# _infer_from_timezone — Read timezone
_infer_from_timezone() {
    local mp="$1"

    if [[ -f "${mp}/etc/timezone" ]]; then
        local tz
        tz=$(sed -n '/^[[:space:]]*$/d; /^[[:space:]]*#/d; p; q' "${mp}/etc/timezone") || true
        tz="${tz%%[[:space:]]*}"
        if [[ -n "${tz}" ]]; then
            TIMEZONE="${tz}"
            export TIMEZONE
            return 0
        fi
    fi

    # Fallback: readlink /etc/localtime
    if [[ -L "${mp}/etc/localtime" ]]; then
        local target
        target=$(readlink "${mp}/etc/localtime" 2>/dev/null) || true
        if [[ "${target}" == *zoneinfo/* ]]; then
            TIMEZONE="${target#*zoneinfo/}"
            export TIMEZONE
            return 0
        fi
    fi
}

# _infer_from_locale — Read locale from locale.gen
_infer_from_locale() {
    local mp="$1"
    local localegen="${mp}/etc/locale.gen"
    [[ -f "${localegen}" ]] || return 0

    local line
    while IFS= read -r line; do
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line}" || "${line}" =~ ^[[:space:]]*$ ]] && continue
        # First uncommented line, e.g. "pl_PL.UTF-8 UTF-8"
        local loc="${line%% *}"
        if [[ -n "${loc}" ]]; then
            LOCALE="${loc}"
            export LOCALE
            return 0
        fi
    done < "${localegen}"
}

# _infer_from_keymap — Read keymap from vconsole.conf or conf.d/keymaps
_infer_from_keymap() {
    local mp="$1"

    # systemd: /etc/vconsole.conf
    if [[ -f "${mp}/etc/vconsole.conf" ]]; then
        local km
        km=$(sed -n "s/^KEYMAP=[\"']*\([^\"']*\).*/\1/p; T; q" "${mp}/etc/vconsole.conf") || true
        if [[ -n "${km}" ]]; then
            KEYMAP="${km}"
            export KEYMAP
            return 0
        fi
    fi

    # openrc: /etc/conf.d/keymaps
    if [[ -f "${mp}/etc/conf.d/keymaps" ]]; then
        local km
        km=$(sed -n "s/^keymap=[\"']*\([^\"']*\).*/\1/p; T; q" "${mp}/etc/conf.d/keymaps") || true
        if [[ -n "${km}" ]]; then
            KEYMAP="${km}"
            export KEYMAP
            return 0
        fi
    fi
}

# _infer_from_kernel_keywords — Detect kernel type from package.accept_keywords
_infer_from_kernel_keywords() {
    local mp="$1"
    local kwdir="${mp}/etc/portage/package.accept_keywords"
    [[ -d "${kwdir}" ]] || return 0

    if grep -rq "sys-kernel/gentoo-kernel-bin" "${kwdir}/" 2>/dev/null; then
        KERNEL_TYPE="dist-kernel"
        export KERNEL_TYPE
        return 0
    fi

    if grep -rq "sys-kernel/gentoo-sources" "${kwdir}/" 2>/dev/null; then
        KERNEL_TYPE="genkernel"
        export KERNEL_TYPE
        return 0
    fi
}

# _infer_rog_from_overlay — Detect zGentoo overlay (ASUS ROG tools)
_infer_rog_from_overlay() {
    local mp="$1"

    if [[ -f "${mp}/etc/portage/repos.conf/zgentoo.conf" ]] || \
       [[ -d "${mp}/var/db/repos/zgentoo" ]]; then
        ENABLE_ASUSCTL="yes"
        export ENABLE_ASUSCTL
    fi
}

# _infer_from_guru_noctalia — Detect GURU overlay and Noctalia shell
_infer_from_guru_noctalia() {
    local mp="$1"

    if [[ -f "${mp}/etc/portage/repos.conf/guru.conf" ]]; then
        ENABLE_GURU="yes"
        export ENABLE_GURU
    fi

    local kwdir="${mp}/etc/portage/package.accept_keywords"
    if [[ -d "${kwdir}" ]] && grep -rq "gui-apps/noctalia-shell" "${kwdir}/" 2>/dev/null; then
        ENABLE_NOCTALIA="yes"
        export ENABLE_NOCTALIA
    fi
}

# _infer_swap_type — Detect swap type if fstab didn't have swap partition
_infer_swap_type() {
    local mp="$1"

    # Already set from fstab?
    [[ -n "${SWAP_TYPE:-}" ]] && return 0

    # zram-generator (systemd)
    if [[ -f "${mp}/etc/systemd/zram-generator.conf" ]]; then
        SWAP_TYPE="zram"
        export SWAP_TYPE
        return 0
    fi

    # zram-init (openrc)
    if [[ -f "${mp}/etc/conf.d/zram-init" ]]; then
        SWAP_TYPE="zram"
        export SWAP_TYPE
        return 0
    fi

    # swap file
    if [[ -f "${mp}/var/swapfile" ]] || [[ -f "${mp}/swapfile" ]]; then
        SWAP_TYPE="file"
        export SWAP_TYPE
        return 0
    fi

    SWAP_TYPE="none"
    export SWAP_TYPE
}

# _infer_partition_scheme — Determine if auto or dual-boot
_infer_partition_scheme() {
    local esp_disk="" root_disk=""

    if [[ -n "${ESP_PARTITION:-}" ]]; then
        esp_disk=$(_partition_to_disk "${ESP_PARTITION}")
    fi
    if [[ -n "${TARGET_DISK:-}" ]]; then
        root_disk="${TARGET_DISK}"
    fi

    if [[ -n "${esp_disk}" && -n "${root_disk}" && "${esp_disk}" != "${root_disk}" ]]; then
        PARTITION_SCHEME="dual-boot"
        ESP_REUSE="yes"
        export PARTITION_SCHEME ESP_REUSE
    else
        PARTITION_SCHEME="auto"
        export PARTITION_SCHEME
    fi
}

# _infer_init_system_fallback — Detect init system from filesystem if make.conf didn't tell us
_infer_init_system_fallback() {
    local mp="$1"
    [[ -n "${INIT_SYSTEM:-}" ]] && return 0

    if [[ -d "${mp}/etc/systemd" ]]; then
        INIT_SYSTEM="systemd"
        export INIT_SYSTEM
    elif [[ -f "${mp}/etc/conf.d/hostname" ]]; then
        INIT_SYSTEM="openrc"
        export INIT_SYSTEM
    fi
}

# _infer_sufficient_config — Check if inferred config has minimum required vars
_infer_sufficient_config() {
    [[ -n "${ROOT_PARTITION:-}" ]] || return 1
    [[ -n "${ESP_PARTITION:-}" ]] || return 1
    [[ -n "${FILESYSTEM:-}" ]] || return 1
    [[ -n "${TARGET_DISK:-}" ]] || return 1
    [[ -n "${INIT_SYSTEM:-}" ]] || return 1
    return 0
}

# infer_config_from_partition — Read config from an installed system's files
# Usage: infer_config_from_partition /dev/sdX2 ext4
# Returns: 0 = sufficient config inferred, 1 = insufficient
infer_config_from_partition() {
    local part="$1"
    local fstype="$2"
    local mp="" need_unmount=0

    # Set direct values from arguments
    ROOT_PARTITION="${part}"
    FILESYSTEM="${fstype}"
    TARGET_DISK=$(_partition_to_disk "${part}")
    export ROOT_PARTITION FILESYSTEM TARGET_DISK

    if [[ -n "${_RESUME_TEST_DIR:-}" ]]; then
        mp="${_RESUME_TEST_DIR}/mnt/${part##*/}"
    else
        # Try to find/mount the partition
        if findmnt -rn -S "${part}" &>/dev/null; then
            mp=$(findmnt -rn -o TARGET -S "${part}" | head -1) || true
        fi
        if [[ -z "${mp}" ]]; then
            mp=$(mktemp -d "${TMPDIR:-/tmp}/gentoo-infer.XXXXXX")
            if mount -o ro "${part}" "${mp}" 2>/dev/null; then
                need_unmount=1
            elif [[ "${fstype}" == "btrfs" ]]; then
                if mount -o ro,subvol=@ "${part}" "${mp}" 2>/dev/null; then
                    need_unmount=1
                fi
            fi
        fi
    fi

    # Run all inference helpers (each is defensive — missing file = skip)
    _infer_from_fstab "${mp}"
    _infer_from_make_conf "${mp}"
    _infer_from_hostname "${mp}"
    _infer_from_timezone "${mp}"
    _infer_from_locale "${mp}"
    _infer_from_keymap "${mp}"
    _infer_from_kernel_keywords "${mp}"
    _infer_from_guru_noctalia "${mp}"
    _infer_rog_from_overlay "${mp}"
    _infer_swap_type "${mp}"
    _infer_init_system_fallback "${mp}"
    _infer_partition_scheme

    # Cleanup
    if [[ ${need_unmount} -eq 1 ]]; then
        umount "${mp}" 2>/dev/null || true
        rmdir "${mp}" 2>/dev/null || true
    elif [[ -z "${_RESUME_TEST_DIR:-}" && -d "${mp}" ]]; then
        rmdir "${mp}" 2>/dev/null || true
    fi

    if _infer_sufficient_config; then
        einfo "Config inference: sufficient configuration inferred from ${part}"
        return 0
    else
        ewarn "Config inference: insufficient data from ${part}"
        return 1
    fi
}

# bytes_to_human — Convert bytes to human readable
bytes_to_human() {
    local bytes="$1"
    if ((bytes >= 1073741824)); then
        printf "%.1f GiB" "$(echo "scale=1; ${bytes}/1073741824" | bc)"
    elif ((bytes >= 1048576)); then
        printf "%.1f MiB" "$(echo "scale=1; ${bytes}/1048576" | bc)"
    elif ((bytes >= 1024)); then
        printf "%.1f KiB" "$(echo "scale=1; ${bytes}/1024" | bc)"
    else
        printf "%d B" "${bytes}"
    fi
}

# get_cpu_count — Number of CPUs
get_cpu_count() {
    nproc 2>/dev/null || echo 4
}

# generate_password_hash — Create SHA-512 password hash
generate_password_hash() {
    local password="$1"
    openssl passwd -6 -stdin <<< "${password}" 2>/dev/null || \
    GENTOO_PW="${password}" python3 -c "import crypt, os; print(crypt.crypt(os.environ['GENTOO_PW'], crypt.mksalt(crypt.METHOD_SHA512)))" 2>/dev/null
}
