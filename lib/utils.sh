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
            read -r -p "Choice [r/s/c/a]: " _reply < /dev/tty || _reply="a"
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
            checkpoint_reached "stage3_extract" && return 0; return 1 ;;
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
    openssl passwd -6 "${password}" 2>/dev/null || \
    GENTOO_PW="${password}" python3 -c "import crypt, os; print(crypt.crypt(os.environ['GENTOO_PW'], crypt.mksalt(crypt.METHOD_SHA512)))" 2>/dev/null
}
