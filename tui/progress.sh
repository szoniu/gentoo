#!/usr/bin/env bash
# tui/progress.sh — Installation progress screen with live log preview
source "${LIB_DIR}/protection.sh"

# Phase definitions: "phase_name|description"
readonly -a INSTALL_PHASES=(
    "preflight|Preflight checks"
    "disks|Partitioning and formatting disk"
    "stage3_download|Downloading stage3 tarball (~700 MB)"
    "stage3_verify|Verifying stage3 integrity"
    "stage3_extract|Extracting stage3 tarball"
    "portage_preconfig|Configuring Portage"
    "chroot|Installing system (this will take a while)"
)

# _save_config_to_target — Persist config file to target disk for --resume recovery
_save_config_to_target() {
    if [[ -n "${MOUNTPOINT:-}" ]] && mountpoint -q "${MOUNTPOINT}" 2>/dev/null; then
        config_save "${MOUNTPOINT}/tmp/$(basename "${CONFIG_FILE}")"
    fi
}

# _detect_and_handle_resume — Check for previous progress and ask user
# Returns 0 if resuming, 1 if starting fresh
_detect_and_handle_resume() {
    local has_checkpoints=0

    # Check /tmp checkpoints
    if [[ -d "${CHECKPOINT_DIR}" ]] && ls "${CHECKPOINT_DIR}/"* &>/dev/null 2>&1; then
        has_checkpoints=1
    fi

    # Check target disk checkpoints
    local target_checkpoint_dir="${MOUNTPOINT}${CHECKPOINT_DIR_SUFFIX}"
    if [[ -d "${target_checkpoint_dir}" ]] && ls "${target_checkpoint_dir}/"* &>/dev/null 2>&1; then
        has_checkpoints=1
        # Adopt target checkpoints if they exist and /tmp ones don't
        if [[ ! -d "${CHECKPOINT_DIR}" ]] || ! ls "${CHECKPOINT_DIR}/"* &>/dev/null 2>&1; then
            CHECKPOINT_DIR="${target_checkpoint_dir}"
            export CHECKPOINT_DIR
        fi
    fi

    if [[ "${has_checkpoints}" -eq 0 ]]; then
        return 1  # no previous progress
    fi

    # List completed checkpoints for display
    local completed_list=""
    local cp_name
    for cp_name in "${CHECKPOINTS[@]}"; do
        if checkpoint_reached "${cp_name}"; then
            completed_list+="  - ${cp_name}\n"
        fi
    done

    if [[ "${NON_INTERACTIVE:-0}" == "1" ]]; then
        # Non-interactive: default to resume
        einfo "Non-interactive mode — resuming from previous progress"
        _validate_and_clean_checkpoints
        return 0
    fi

    if dialog_yesno "Resume Installation" \
        "Previous installation progress detected:\n\n${completed_list}\nResume from where it left off?\n\nChoose 'No' to start fresh (all progress will be lost)."; then
        _validate_and_clean_checkpoints
        return 0
    else
        checkpoint_clear
        return 1
    fi
}

# _validate_and_clean_checkpoints — Validate each checkpoint, remove invalid ones
_validate_and_clean_checkpoints() {
    local cp_name
    for cp_name in "${CHECKPOINTS[@]}"; do
        if checkpoint_reached "${cp_name}" && ! checkpoint_validate "${cp_name}"; then
            ewarn "Checkpoint '${cp_name}' failed validation — will re-run"
            rm -f "${CHECKPOINT_DIR}/${cp_name}"
        fi
    done
}

# --- Live preview: pinned header + VT100 scroll region ---

# Globals for live preview state
_LP_CURRENT=""
_LP_TOTAL=""
_LP_DESC=""
_LP_HEADER_LINES=""

# _live_preview_header — Render progress header to stdout
_live_preview_header() {
    local current="$1" total="$2" desc="$3"

    # Build progress bar (█ = done, ░ = remaining)
    local bar_width=30
    local filled=$(( (current - 1) * bar_width / total ))
    local empty=$(( bar_width - filled ))
    local bar=""
    local j
    for (( j = 0; j < filled; j++ )); do bar+="█"; done
    for (( j = 0; j < empty; j++ )); do bar+="░"; done

    local phase_info="Phase ${current}/${total}"

    if [[ "${DIALOG_CMD:-}" == "gum" ]] && command -v gum &>/dev/null; then
        local title_line
        title_line=$(gum style --bold --foreground 6 "${INSTALLER_NAME} v${INSTALLER_VERSION}")
        local content
        content=$(printf '%s\n%s  %s\n%s' "${title_line}" "${bar}" "${phase_info}" "${desc}")
        gum style --border rounded --border-foreground 6 \
            --padding "0 2" --width "${DIALOG_WIDTH:-76}" \
            "${content}"
    else
        echo "=== ${INSTALLER_NAME} v${INSTALLER_VERSION} ==="
        echo "[${bar}] ${phase_info}"
        echo "${desc}"
        printf '%.0s─' $(seq 1 "${DIALOG_WIDTH:-76}")
        echo
    fi
}

# _live_preview_start — Clear screen, render header, set VT100 scroll region
_live_preview_start() {
    local current="$1" total="$2" desc="$3"

    _LP_CURRENT="${current}"
    _LP_TOTAL="${total}"
    _LP_DESC="${desc}"

    clear 2>/dev/null

    local header
    header=$(_live_preview_header "${current}" "${total}" "${desc}")
    printf '%s\n' "${header}"

    _LP_HEADER_LINES=$(printf '%s\n' "${header}" | wc -l)

    local term_lines
    term_lines=$(tput lines 2>/dev/null || echo 24)

    # VT100 scroll region: header stays pinned, everything below scrolls
    local scroll_top=$(( _LP_HEADER_LINES + 1 ))
    printf '\e[%d;%dr' "${scroll_top}" "${term_lines}"

    # Position cursor at start of scroll region
    tput cup "${_LP_HEADER_LINES}" 0 2>/dev/null
}

# _live_preview_update — Redraw header for new phase, preserve scroll content
_live_preview_update() {
    local current="$1" total="$2" desc="$3"

    _LP_CURRENT="${current}"
    _LP_TOTAL="${total}"
    _LP_DESC="${desc}"

    tput sc 2>/dev/null

    # Temporarily reset scroll region to write in header area
    printf '\e[r'
    tput cup 0 0 2>/dev/null

    # Clear old header lines
    local j
    for (( j = 0; j < _LP_HEADER_LINES; j++ )); do
        printf '\e[2K'
        (( j < _LP_HEADER_LINES - 1 )) && printf '\n'
    done
    tput cup 0 0 2>/dev/null

    # Render updated header
    local header
    header=$(_live_preview_header "${current}" "${total}" "${desc}")
    printf '%s\n' "${header}"

    _LP_HEADER_LINES=$(printf '%s\n' "${header}" | wc -l)

    # Restore scroll region
    local term_lines
    term_lines=$(tput lines 2>/dev/null || echo 24)
    local scroll_top=$(( _LP_HEADER_LINES + 1 ))
    printf '\e[%d;%dr' "${scroll_top}" "${term_lines}"

    tput rc 2>/dev/null
}

# _live_preview_stop — Reset scroll region, clear state
_live_preview_stop() {
    printf '\e[r' 2>/dev/null
    _LP_CURRENT=""
    _LP_TOTAL=""
    _LP_DESC=""
    _LP_HEADER_LINES=""
}

# _live_preview_redraw — Full redraw after terminal disruption (dialog recovery, shell drop)
_live_preview_redraw() {
    [[ -z "${_LP_CURRENT:-}" ]] && return 0
    _live_preview_start "${_LP_CURRENT}" "${_LP_TOTAL}" "${_LP_DESC}"
}

# --- Main progress screen ---

# screen_progress — Run installation with live log preview
screen_progress() {
    local total=${#INSTALL_PHASES[@]}
    local i=0

    # Check for previous progress and handle resume
    if ! _detect_and_handle_resume; then
        einfo "Starting fresh installation"
    else
        einfo "Resuming installation from previous progress"
    fi

    # Enable live output globally — commands output via tee (terminal + log)
    export LIVE_OUTPUT=1

    local _lp_started=0

    for entry in "${INSTALL_PHASES[@]}"; do
        local phase_name phase_desc
        IFS='|' read -r phase_name phase_desc <<< "${entry}"
        (( i++ )) || true

        if checkpoint_reached "${phase_name}"; then
            einfo "Phase ${phase_name} already completed (checkpoint)"

            # Re-mount filesystems if disks phase is skipped (needed after reboot)
            if [[ "${phase_name}" == "disks" ]]; then
                mount_filesystems
                checkpoint_migrate_to_target
                _save_config_to_target
            fi

            continue
        fi

        # Start or update live preview header
        if [[ "${NON_INTERACTIVE:-0}" != "1" ]]; then
            if [[ ${_lp_started} -eq 0 ]]; then
                _live_preview_start "${i}" "${total}" "${phase_desc}"
                _lp_started=1
            else
                _live_preview_update "${i}" "${total}" "${phase_desc}"
            fi
        fi

        if [[ "${phase_name}" == "chroot" ]]; then
            _execute_chroot_phase
        else
            _execute_phase "${phase_name}" "${phase_desc}"
        fi
    done

    # Cleanup live preview
    if [[ ${_lp_started} -eq 1 ]]; then
        _live_preview_stop
    fi

    unset LIVE_OUTPUT

    local complete_msg=""
    complete_msg+="Gentoo Linux has been successfully installed!\n\n"
    complete_msg+="You can now reboot into your new system.\n"
    complete_msg+="Remember to remove the installation media.\n\n"
    if [[ "${ENABLE_SECUREBOOT:-no}" == "yes" ]]; then
        complete_msg+="SECURE BOOT: At first reboot, MokManager will appear.\n"
        complete_msg+="Select 'Enroll MOK' -> verify key -> enter password: gentoo -> Reboot\n\n"
    fi
    complete_msg+="Log file: ${LOG_FILE}"

    dialog_msgbox "Installation Complete" "${complete_msg}"

    return "${TUI_NEXT}"
}

# _execute_chroot_phase — Run chroot installation (live preview handles the header)
_execute_chroot_phase() {
    einfo "=== Phase: Chroot installation ==="

    # Always refresh installer copy in chroot (user may have git-pulled fixes)
    copy_installer_to_chroot
    copy_dns_info

    chroot_setup
    run_chroot_phase
    chroot_teardown

    checkpoint_set "chroot"
}

# _execute_phase — Execute a single installation phase
_execute_phase() {
    local phase_name="$1"
    local phase_desc="$2"

    einfo "=== Phase: ${phase_desc} ==="

    case "${phase_name}" in
        preflight)
            preflight_checks
            ;;
        disks)
            disk_execute_plan
            mount_filesystems
            checkpoint_migrate_to_target
            _save_config_to_target
            ;;
        stage3_download)
            stage3_download
            ;;
        stage3_verify)
            stage3_verify
            ;;
        stage3_extract)
            stage3_extract
            ;;
        portage_preconfig)
            generate_make_conf
            copy_dns_info
            copy_installer_to_chroot
            ;;
    esac

    checkpoint_set "${phase_name}"
}
