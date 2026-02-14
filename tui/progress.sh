#!/usr/bin/env bash
# tui/progress.sh — Installation progress screen with gauge
source "${LIB_DIR}/protection.sh"

# Phase definitions: "phase_name|description|weight"
readonly -a INSTALL_PHASES=(
    "preflight|Preflight checks|2"
    "disks|Disk operations|5"
    "stage3|Stage3 download and extraction|15"
    "portage_preconfig|Portage pre-configuration|3"
    "portage_sync|Portage sync|10"
    "world_update|@world update|20"
    "system_config|System configuration|3"
    "kernel|Kernel installation|15"
    "fstab|Filesystem tools and fstab|2"
    "networking|Network configuration|3"
    "bootloader|Bootloader installation|3"
    "swap_setup|Swap configuration|2"
    "desktop|Desktop installation|12"
    "users|User configuration|2"
    "extras|Extra packages|2"
    "finalize|Finalization|1"
)

# screen_progress — Show installation progress with gauge
screen_progress() {
    local total_weight=0
    local entry
    for entry in "${INSTALL_PHASES[@]}"; do
        local weight
        IFS='|' read -r _ _ weight <<< "${entry}"
        (( total_weight += weight ))
    done

    # Start progress tracking in background
    local progress_pipe="/tmp/gentoo-progress-$$"
    mkfifo "${progress_pipe}" 2>/dev/null || true

    # Launch gauge in background
    dialog_gauge "Installing Gentoo Linux" \
        "Preparing installation..." 0 < "${progress_pipe}" &
    local gauge_pid=$!

    # Open pipe for writing
    exec 3>"${progress_pipe}"

    # Redirect stderr to log file to prevent log messages bleeding through gauge
    exec 4>&2
    exec 2>>"${LOG_FILE}"

    # Run actual installation with progress updates
    local completed_weight=0
    for entry in "${INSTALL_PHASES[@]}"; do
        local phase_name phase_desc weight
        IFS='|' read -r phase_name phase_desc weight <<< "${entry}"

        # Update gauge
        local percent=$(( completed_weight * 100 / total_weight ))
        echo "XXX" >&3 2>/dev/null || true
        echo "${percent}" >&3 2>/dev/null || true
        echo "${phase_desc}..." >&3 2>/dev/null || true
        echo "XXX" >&3 2>/dev/null || true

        # Check if phase already completed
        if checkpoint_reached "${phase_name}"; then
            einfo "Phase ${phase_name} already completed (checkpoint)"
        else
            # Execute the phase
            _execute_phase "${phase_name}" "${phase_desc}"
        fi

        (( completed_weight += weight ))
    done

    # Final 100%
    echo "XXX" >&3 2>/dev/null || true
    echo "100" >&3 2>/dev/null || true
    echo "Installation complete!" >&3 2>/dev/null || true
    echo "XXX" >&3 2>/dev/null || true

    # Restore stderr
    exec 2>&4
    exec 4>&-

    # Cleanup
    exec 3>&-
    wait "${gauge_pid}" 2>/dev/null || true
    rm -f "${progress_pipe}"

    dialog_msgbox "Complete" "Gentoo Linux installation has finished successfully!"

    return "${TUI_NEXT}"
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
            ;;
        stage3)
            stage3_download
            stage3_verify
            stage3_extract
            ;;
        portage_preconfig)
            generate_make_conf
            copy_dns_info
            copy_installer_to_chroot
            ;;
        portage_sync|world_update|system_config|kernel|fstab| \
        networking|bootloader|swap_setup|desktop|users|extras|finalize)
            # These run inside chroot — handled by chroot phase
            chroot_setup
            run_chroot_phase
            chroot_teardown
            # After the first chroot phase runs, all remaining phases
            # are handled inside chroot, so we skip them here
            return 0
            ;;
    esac

    checkpoint_set "${phase_name}"
}
