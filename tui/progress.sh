#!/usr/bin/env bash
# tui/progress.sh — Installation progress screen (all within dialog UI)
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

# screen_progress — Run installation with dialog_infobox status display
screen_progress() {
    local total=${#INSTALL_PHASES[@]}
    local i=0

    # Redirect stderr to log file so log messages don't bleed through dialog
    exec 4>&2
    exec 2>>"${LOG_FILE}"

    for entry in "${INSTALL_PHASES[@]}"; do
        local phase_name phase_desc
        IFS='|' read -r phase_name phase_desc <<< "${entry}"
        (( i++ )) || true

        if checkpoint_reached "${phase_name}"; then
            einfo "Phase ${phase_name} already completed (checkpoint)"
            continue
        fi

        if [[ "${phase_name}" == "chroot" ]]; then
            # Chroot phase — show live log output instead of static infobox
            _run_chroot_with_live_output
        else
            # Short phases — show status in dialog infobox
            _show_phase_status "${i}" "${total}" "${phase_desc}"
            _execute_phase "${phase_name}" "${phase_desc}"
        fi
    done

    # Restore stderr
    exec 2>&4
    exec 4>&-

    dialog_msgbox "Installation Complete" \
        "Gentoo Linux has been successfully installed!\n\n\
You can now reboot into your new system.\n\
Remember to remove the installation media.\n\n\
Log file: ${LOG_FILE}"

    return "${TUI_NEXT}"
}

# _run_chroot_with_live_output — Run chroot phase with visible log output
_run_chroot_with_live_output() {
    # Restore stderr so user sees live output
    exec 2>&4

    clear 2>/dev/null
    echo -e "\033[1;36m══════════════════════════════════════════════════════════════════\033[0m"
    echo -e "\033[1;37m  Gentoo TUI Installer — Installing system                       \033[0m"
    echo -e "\033[1;36m══════════════════════════════════════════════════════════════════\033[0m"
    echo -e "\033[0;33m  Live output below. This will take a while (1-4 hours).         \033[0m"
    echo -e "\033[0;33m  Full log: ${LOG_FILE}                    \033[0m"
    echo -e "\033[1;36m══════════════════════════════════════════════════════════════════\033[0m"
    echo ""

    einfo "=== Phase: Chroot installation ==="

    chroot_setup
    run_chroot_phase
    chroot_teardown

    checkpoint_set "chroot"

    echo ""
    echo -e "\033[1;32m══════════════════════════════════════════════════════════════════\033[0m"
    echo -e "\033[1;32m  Chroot installation complete!                                   \033[0m"
    echo -e "\033[1;32m══════════════════════════════════════════════════════════════════\033[0m"
    sleep 2

    # Re-redirect stderr for any remaining phases
    exec 2>>"${LOG_FILE}"
}

# _show_phase_status — Display current phase in dialog_infobox
_show_phase_status() {
    local current="$1" total="$2" desc="$3"

    # Build a simple text progress indicator
    local bar=""
    local j
    for (( j = 1; j <= total; j++ )); do
        if (( j < current )); then
            bar+="[done] "
        elif (( j == current )); then
            bar+="[>>>>] "
        else
            bar+="[    ] "
        fi
    done

    dialog_infobox "Installing Gentoo Linux  [${current}/${total}]" \
        "${bar}\n\n${desc}...\n\nPlease wait. See ${LOG_FILE} for details."
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
            # Disk reformatted — all downstream checkpoints are stale
            local cp
            for cp in stage3_download stage3_verify stage3_extract portage_preconfig chroot \
                      portage_sync world_update system_config kernel fstab networking \
                      bootloader swap_setup desktop users extras finalize; do
                rm -f "${CHECKPOINT_DIR}/${cp}" 2>/dev/null || true
            done
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
