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

    if [[ "${KERNEL_TYPE}" == "dist-kernel" ]]; then
        dialog_msgbox "Distribution Kernel" \
            "The distribution kernel (sys-kernel/gentoo-kernel-bin or\n\
sys-kernel/gentoo-kernel) will be installed.\n\n\
This is the fastest option and provides a well-tested\n\
configuration that works on most hardware."
    else
        dialog_msgbox "genkernel" \
            "genkernel will be used to build a custom kernel from\n\
sys-kernel/gentoo-sources.\n\n\
This takes longer but allows full control over the\n\
kernel configuration.\n\n\
Note: genkernel --menuconfig will be available for\n\
advanced users during the build process."
    fi

    einfo "Kernel type: ${KERNEL_TYPE}"
    return "${TUI_NEXT}"
}
