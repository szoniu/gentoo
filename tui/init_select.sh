#!/usr/bin/env bash
# tui/init_select.sh — Init system selection: systemd vs OpenRC
source "${LIB_DIR}/protection.sh"

screen_init_select() {
    local current="${INIT_SYSTEM:-systemd}"
    local on_systemd="off" on_openrc="off"
    [[ "${current}" == "systemd" ]] && on_systemd="on"
    [[ "${current}" == "openrc" ]] && on_openrc="on"

    local choice
    choice=$(dialog_radiolist "Init System" \
        "systemd" "systemd — modern, KDE recommended, wider support" "${on_systemd}" \
        "openrc"  "OpenRC — traditional, lightweight, Gentoo classic" "${on_openrc}") \
        || return "${TUI_BACK}"

    if [[ -z "${choice}" ]]; then
        return "${TUI_BACK}"
    fi

    INIT_SYSTEM="${choice}"
    export INIT_SYSTEM

    # Warn ASUS ROG users about OpenRC limitations
    if [[ "${choice}" == "openrc" && "${ASUS_ROG_DETECTED:-0}" == "1" ]]; then
        local rog_warning=""
        rog_warning+="ASUS ROG/TUF hardware detected with OpenRC.\n\n"
        rog_warning+="Basic hardware works fine:\n"
        rog_warning+="  - GPU drivers, WiFi, keyboard, display\n\n"
        rog_warning+="NOT available with OpenRC:\n"
        rog_warning+="  - asusctl (fan profiles, RGB, battery limit)\n"
        rog_warning+="  - supergfxctl (GPU switching)\n"
        rog_warning+="  These tools require systemd.\n\n"
        rog_warning+="You can continue with OpenRC — this is just a notice."
        dialog_msgbox "ASUS ROG + OpenRC" "${rog_warning}" || true
    fi

    einfo "Selected init system: ${INIT_SYSTEM}"
    return "${TUI_NEXT}"
}
