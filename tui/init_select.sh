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

    einfo "Selected init system: ${INIT_SYSTEM}"
    return "${TUI_NEXT}"
}
