#!/usr/bin/env bash
# install.sh — Main entry point for the Gentoo TUI Installer
#
# Usage:
#   ./install.sh              — Run full installation (TUI wizard + install)
#   ./install.sh --configure  — Run only the TUI wizard (generate config)
#   ./install.sh --install    — Run only the installation (using existing config)
#   ./install.sh --dry-run    — Run wizard + simulate installation
#   ./install.sh __chroot_phase — (Internal) Run chroot phase
#
set -euo pipefail
shopt -s inherit_errexit

# Mark as the Gentoo installer (used by protection.sh)
export _GENTOO_INSTALLER=1

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR
export LIB_DIR="${SCRIPT_DIR}/lib"
export TUI_DIR="${SCRIPT_DIR}/tui"
export DATA_DIR="${SCRIPT_DIR}/data"

# --- Source library modules ---
source "${LIB_DIR}/constants.sh"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/utils.sh"
source "${LIB_DIR}/dialog.sh"
source "${LIB_DIR}/config.sh"
source "${LIB_DIR}/hardware.sh"
source "${LIB_DIR}/disk.sh"
source "${LIB_DIR}/network.sh"
source "${LIB_DIR}/stage3.sh"
source "${LIB_DIR}/portage.sh"
source "${LIB_DIR}/kernel.sh"
source "${LIB_DIR}/bootloader.sh"
source "${LIB_DIR}/system.sh"
source "${LIB_DIR}/desktop.sh"
source "${LIB_DIR}/swap.sh"
source "${LIB_DIR}/chroot.sh"
source "${LIB_DIR}/hooks.sh"
source "${LIB_DIR}/preset.sh"

# --- Source TUI screens ---
source "${TUI_DIR}/welcome.sh"
source "${TUI_DIR}/preset_load.sh"
source "${TUI_DIR}/hw_detect.sh"
source "${TUI_DIR}/init_select.sh"
source "${TUI_DIR}/disk_select.sh"
source "${TUI_DIR}/filesystem_select.sh"
source "${TUI_DIR}/swap_config.sh"
source "${TUI_DIR}/network_config.sh"
source "${TUI_DIR}/locale_config.sh"
source "${TUI_DIR}/kernel_select.sh"
source "${TUI_DIR}/gpu_config.sh"
source "${TUI_DIR}/desktop_config.sh"
source "${TUI_DIR}/user_config.sh"
source "${TUI_DIR}/extra_packages.sh"
source "${TUI_DIR}/preset_save.sh"
source "${TUI_DIR}/summary.sh"
source "${TUI_DIR}/progress.sh"

# --- Source data files ---
source "${DATA_DIR}/cpu_march_database.sh"
source "${DATA_DIR}/gpu_database.sh"
source "${DATA_DIR}/mirrors.sh"
source "${DATA_DIR}/use_flags_desktop.sh"

# --- Cleanup trap ---
cleanup() {
    local rc=$?

    # Restore stderr if it was redirected to log file (fd 4 saved by screen_progress)
    if { true >&4; } 2>/dev/null; then
        exec 2>&4
        exec 4>&-
    fi

    if [[ "${_IN_CHROOT:-0}" != "1" ]]; then
        # Only do cleanup in outer process
        if mountpoint -q "${MOUNTPOINT}/proc" 2>/dev/null; then
            ewarn "Cleaning up mount points..."
            chroot_teardown || true
        fi
    fi
    if [[ ${rc} -ne 0 ]]; then
        eerror "Installer exited with code ${rc}"
        eerror "Log file: ${LOG_FILE}"
    fi
    return ${rc}
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# --- Parse arguments ---
MODE="full"
DRY_RUN=0
FORCE=0
NON_INTERACTIVE=0
export DRY_RUN FORCE NON_INTERACTIVE

usage() {
    cat <<'EOF'
Gentoo TUI Installer

Usage:
  install.sh [OPTIONS] [COMMAND]

Commands:
  (default)       Run full installation (wizard + install)
  --configure     Run only the TUI configuration wizard
  --install       Run only the installation phase (requires config)
  __chroot_phase  Internal: execute chroot phase

Options:
  --config FILE   Use specified config file
  --dry-run       Simulate installation without destructive operations
  --force         Continue past failed prerequisite checks
  --non-interactive  Abort on any error (no recovery menu)
  --help          Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --configure)
            MODE="configure"
            shift
            ;;
        --install)
            MODE="install"
            shift
            ;;
        __chroot_phase)
            MODE="chroot"
            shift
            ;;
        --config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --force)
            FORCE=1
            shift
            ;;
        --non-interactive)
            NON_INTERACTIVE=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            eerror "Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

# --- Main functions ---

# run_configuration_wizard — Launch all TUI screens
run_configuration_wizard() {
    init_dialog

    register_wizard_screens \
        screen_welcome \
        screen_preset_load \
        screen_hw_detect \
        screen_init_select \
        screen_disk_select \
        screen_filesystem_select \
        screen_swap_config \
        screen_network_config \
        screen_locale_config \
        screen_kernel_select \
        screen_gpu_config \
        screen_desktop_config \
        screen_user_config \
        screen_extra_packages \
        screen_preset_save \
        screen_summary

    run_wizard

    config_save "${CONFIG_FILE}"
    einfo "Configuration complete. Saved to ${CONFIG_FILE}"
}

# run_pre_chroot — Execute pre-chroot installation phases
run_pre_chroot() {
    einfo "=== Pre-chroot installation ==="

    maybe_exec 'before_install'

    # Phase 1: Preflight
    if ! checkpoint_reached "preflight"; then
        einfo "--- Phase: Preflight checks ---"
        maybe_exec 'before_preflight'
        preflight_checks
        maybe_exec 'after_preflight'
        checkpoint_set "preflight"
    else
        einfo "Skipping preflight (checkpoint reached)"
    fi

    # Phase 2: Disk operations
    if ! checkpoint_reached "disks"; then
        einfo "--- Phase: Disk operations ---"
        maybe_exec 'before_disks'
        disk_execute_plan
        mount_filesystems
        maybe_exec 'after_disks'
        checkpoint_set "disks"
    else
        einfo "Skipping disks (checkpoint reached)"
        mount_filesystems
    fi

    # Phase 3: Stage3
    if ! checkpoint_reached "stage3"; then
        einfo "--- Phase: Stage3 download and extraction ---"
        maybe_exec 'before_stage3'
        stage3_download
        stage3_verify
        stage3_extract
        maybe_exec 'after_stage3'
        checkpoint_set "stage3"
    else
        einfo "Skipping stage3 (checkpoint reached)"
    fi

    # Phase 4: Portage preconfig
    if ! checkpoint_reached "portage_preconfig"; then
        einfo "--- Phase: Portage pre-configuration ---"
        maybe_exec 'before_portage_preconfig'
        generate_make_conf
        copy_dns_info
        copy_installer_to_chroot
        maybe_exec 'after_portage_preconfig'
        checkpoint_set "portage_preconfig"
    else
        einfo "Skipping portage preconfig (checkpoint reached)"
    fi

    # Enter chroot and run chroot phase
    einfo "=== Entering chroot ==="
    chroot_setup
    run_chroot_phase
    chroot_teardown
    einfo "=== Chroot phase complete ==="

    maybe_exec 'after_install'
}

# run_chroot_phase — Execute inside chroot (re-invoked by install.sh __chroot_phase)
run_chroot_phase() {
    if [[ "${_IN_CHROOT:-0}" == "1" ]]; then
        _do_chroot_phases
    else
        # Re-invoke ourselves inside chroot
        chroot_exec "${CHROOT_INSTALLER_DIR}/install.sh" __chroot_phase \
            --config "${CHROOT_INSTALLER_DIR}/$(basename "${CONFIG_FILE}")"
    fi
}

# _do_chroot_phases — Actual chroot work
_do_chroot_phases() {
    export _IN_CHROOT=1
    einfo "=== Chroot installation phases ==="

    # Phase 5: Portage sync
    if ! checkpoint_reached "portage_sync"; then
        einfo "--- Phase: Portage sync ---"
        maybe_exec 'before_portage_sync'
        portage_sync
        portage_select_profile
        portage_install_cpuflags
        maybe_exec 'after_portage_sync'
        checkpoint_set "portage_sync"
    else
        einfo "Skipping portage sync (checkpoint reached)"
    fi

    # Phase 6: @world update
    if ! checkpoint_reached "world_update"; then
        einfo "--- Phase: @world update ---"
        maybe_exec 'before_world_update'
        try "Updating @world" emerge --update --deep --changed-use @world
        maybe_exec 'after_world_update'
        checkpoint_set "world_update"
    else
        einfo "Skipping @world update (checkpoint reached)"
    fi

    # Phase 7: System config
    if ! checkpoint_reached "system_config"; then
        einfo "--- Phase: System configuration ---"
        maybe_exec 'before_system_config'
        system_set_timezone
        system_set_locale
        system_set_hostname
        system_set_keymap
        maybe_exec 'after_system_config'
        checkpoint_set "system_config"
    else
        einfo "Skipping system config (checkpoint reached)"
    fi

    # Phase 8: Kernel
    if ! checkpoint_reached "kernel"; then
        einfo "--- Phase: Kernel ---"
        maybe_exec 'before_kernel'
        kernel_install
        maybe_exec 'after_kernel'
        checkpoint_set "kernel"
    else
        einfo "Skipping kernel (checkpoint reached)"
    fi

    # Phase 9: Filesystem tools + fstab
    if ! checkpoint_reached "fstab"; then
        einfo "--- Phase: Filesystem tools and fstab ---"
        maybe_exec 'before_fstab'
        install_filesystem_tools
        generate_fstab
        maybe_exec 'after_fstab'
        checkpoint_set "fstab"
    else
        einfo "Skipping fstab (checkpoint reached)"
    fi

    # Phase 10: Networking
    if ! checkpoint_reached "networking"; then
        einfo "--- Phase: Networking ---"
        maybe_exec 'before_networking'
        install_network_manager
        maybe_exec 'after_networking'
        checkpoint_set "networking"
    else
        einfo "Skipping networking (checkpoint reached)"
    fi

    # Phase 11: Bootloader
    if ! checkpoint_reached "bootloader"; then
        einfo "--- Phase: Bootloader ---"
        maybe_exec 'before_bootloader'
        bootloader_install
        maybe_exec 'after_bootloader'
        checkpoint_set "bootloader"
    else
        einfo "Skipping bootloader (checkpoint reached)"
    fi

    # Phase 12: Swap
    if ! checkpoint_reached "swap_setup"; then
        einfo "--- Phase: Swap ---"
        maybe_exec 'before_swap'
        swap_setup
        maybe_exec 'after_swap'
        checkpoint_set "swap_setup"
    else
        einfo "Skipping swap setup (checkpoint reached)"
    fi

    # Phase 13: Desktop
    if ! checkpoint_reached "desktop"; then
        einfo "--- Phase: Desktop ---"
        maybe_exec 'before_desktop'
        desktop_install
        maybe_exec 'after_desktop'
        checkpoint_set "desktop"
    else
        einfo "Skipping desktop (checkpoint reached)"
    fi

    # Phase 14: Users
    if ! checkpoint_reached "users"; then
        einfo "--- Phase: Users ---"
        maybe_exec 'before_users'
        system_create_users
        maybe_exec 'after_users'
        checkpoint_set "users"
    else
        einfo "Skipping users (checkpoint reached)"
    fi

    # Phase 15: Extras
    if ! checkpoint_reached "extras"; then
        einfo "--- Phase: Extra packages ---"
        maybe_exec 'before_extras'
        install_extra_packages
        maybe_exec 'after_extras'
        checkpoint_set "extras"
    else
        einfo "Skipping extras (checkpoint reached)"
    fi

    # Phase 16: Finalize
    if ! checkpoint_reached "finalize"; then
        einfo "--- Phase: Finalization ---"
        maybe_exec 'before_finalize'
        system_finalize
        maybe_exec 'after_finalize'
        checkpoint_set "finalize"
    else
        einfo "Skipping finalization (checkpoint reached)"
    fi

    einfo "=== All chroot phases complete ==="
}

# run_post_install — Final steps after chroot
run_post_install() {
    einfo "=== Post-installation ==="

    # Unmount everything
    unmount_filesystems

    dialog_msgbox "Installation Complete" \
        "Gentoo Linux has been successfully installed!\n\n\
You can now reboot into your new system.\n\n\
Remember to remove the installation media.\n\n\
Log file saved to: ${LOG_FILE}"

    if dialog_yesno "Reboot" "Would you like to reboot now?"; then
        einfo "Rebooting..."
        if [[ "${DRY_RUN}" != "1" ]]; then
            reboot
        else
            einfo "[DRY-RUN] Would reboot now"
        fi
    else
        einfo "You can reboot manually when ready."
        einfo "Log file: ${LOG_FILE}"
    fi
}

# preflight_checks — Verify system readiness
preflight_checks() {
    einfo "Running preflight checks..."

    if [[ "${DRY_RUN}" != "1" ]]; then
        is_root || die "Must run as root"
        is_efi || die "UEFI boot mode required"
        has_network || die "Network connectivity required"
    fi

    # Sync clock
    if command -v ntpd &>/dev/null && [[ "${DRY_RUN}" != "1" ]]; then
        try "Syncing system clock" ntpd -q -g || true
    elif command -v chronyd &>/dev/null && [[ "${DRY_RUN}" != "1" ]]; then
        try "Syncing system clock" chronyd -q || true
    fi

    einfo "Preflight checks passed"
}

# --- Entry point ---
main() {
    init_logging

    einfo "========================================="
    einfo "${INSTALLER_NAME} v${INSTALLER_VERSION}"
    einfo "========================================="
    einfo "Mode: ${MODE}"
    [[ "${DRY_RUN}" == "1" ]] && ewarn "DRY-RUN mode enabled"

    case "${MODE}" in
        full)
            run_configuration_wizard
            screen_progress
            run_post_install
            ;;
        configure)
            run_configuration_wizard
            ;;
        install)
            config_load "${CONFIG_FILE}"
            init_dialog
            screen_progress
            run_post_install
            ;;
        chroot)
            # Running inside chroot
            export _IN_CHROOT=1
            config_load "${CONFIG_FILE}"
            _do_chroot_phases
            ;;
        *)
            die "Unknown mode: ${MODE}"
            ;;
    esac

    einfo "Done."
}

main "$@"
