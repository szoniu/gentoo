#!/usr/bin/env bash
# tui/secureboot_config.sh — Secure Boot (MOK signing) configuration
source "${LIB_DIR}/protection.sh"

screen_secureboot_config() {
    # Only show on EFI systems
    if [[ "${DRY_RUN:-0}" != "1" ]] && ! is_efi; then
        ENABLE_SECUREBOOT="no"
        export ENABLE_SECUREBOOT
        return "${TUI_NEXT}"
    fi

    local sb_text=""
    sb_text+="Enable Secure Boot signing?\n\n"
    sb_text+="This will:\n"
    sb_text+="  - Generate MOK (Machine Owner Key) signing keys\n"
    sb_text+="  - Sign the kernel and GRUB bootloader\n"
    sb_text+="  - Set up shim as chainloader\n\n"
    sb_text+="At first reboot, MokManager will appear.\n"
    sb_text+="Select 'Enroll MOK', verify the key, and enter\n"
    sb_text+="password: gentoo\n\n"
    sb_text+="Required packages: shim, mokutil, sbsigntools"

    if dialog_yesno "Secure Boot" "${sb_text}"; then
        ENABLE_SECUREBOOT="yes"
    else
        ENABLE_SECUREBOOT="no"
    fi

    export ENABLE_SECUREBOOT
    einfo "Secure Boot: ${ENABLE_SECUREBOOT}"
    return "${TUI_NEXT}"
}
