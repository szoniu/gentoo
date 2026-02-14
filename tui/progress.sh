#!/usr/bin/env bash
# tui/progress.sh — Installation progress screen
source "${LIB_DIR}/protection.sh"

# Phase definitions: "phase_name|description"
readonly -a INSTALL_PHASES=(
    "preflight|Preflight checks"
    "disks|Disk operations"
    "stage3|Stage3 download and extraction"
    "portage_preconfig|Portage pre-configuration"
    "chroot|Chroot installation"
)

# screen_progress — Run installation with phase status display
screen_progress() {
    local total=${#INSTALL_PHASES[@]}
    local i=0

    for entry in "${INSTALL_PHASES[@]}"; do
        local phase_name phase_desc
        IFS='|' read -r phase_name phase_desc <<< "${entry}"
        (( i++ )) || true

        if checkpoint_reached "${phase_name}"; then
            einfo "Phase ${phase_name} already completed (checkpoint)"
            continue
        fi

        dialog_infobox "Installing Gentoo Linux [${i}/${total}]" \
            "${phase_desc}...\n\nPlease wait."

        # Execute the phase
        _execute_phase "${phase_name}" "${phase_desc}"
    done

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
            _phase_stage3
            ;;
        portage_preconfig)
            generate_make_conf
            copy_dns_info
            copy_installer_to_chroot
            ;;
        chroot)
            chroot_setup
            run_chroot_phase
            chroot_teardown
            ;;
    esac

    checkpoint_set "${phase_name}"
}

# _phase_stage3 — Stage3 with visible download progress
_phase_stage3() {
    # Show wget progress on screen (not through try which hides output)
    clear 2>/dev/null
    echo "=== Downloading Stage3 tarball ==="
    echo ""
    stage3_download
    echo ""

    dialog_infobox "Installing Gentoo Linux [3/${#INSTALL_PHASES[@]}]" \
        "Verifying stage3 integrity...\n\nPlease wait."
    stage3_verify

    dialog_infobox "Installing Gentoo Linux [3/${#INSTALL_PHASES[@]}]" \
        "Extracting stage3 tarball...\n\nThis may take a few minutes."
    stage3_extract
}
