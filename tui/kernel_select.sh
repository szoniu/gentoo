#!/usr/bin/env bash
# tui/kernel_select.sh — Kernel type: dist-kernel vs genkernel
source "${LIB_DIR}/protection.sh"

screen_kernel_select() {
    local current="${KERNEL_TYPE:-dist-kernel}"
    local on_dist="off" on_gen="off"
    [[ "${current}" == "dist-kernel" ]] && on_dist="on"
    [[ "${current}" == "genkernel" ]] && on_gen="on"

    local choice
    choice=$(dialog_radiolist "Kernel Selection" \
        "dist-kernel" "Distribution kernel — fast, pre-configured, recommended" "${on_dist}" \
        "genkernel"   "genkernel — custom built, more control, slower" "${on_gen}") \
        || return "${TUI_BACK}"

    if [[ -z "${choice}" ]]; then
        return "${TUI_BACK}"
    fi

    KERNEL_TYPE="${choice}"
    export KERNEL_TYPE

    einfo "Kernel type: ${KERNEL_TYPE}"
    return "${TUI_NEXT}"
}
