#!/usr/bin/env bash
# tui/kernel_select.sh — Kernel type selection (with Surface kernel options)
source "${LIB_DIR}/protection.sh"

screen_kernel_select() {
    local current="${KERNEL_TYPE:-dist-kernel}"

    if [[ "${SURFACE_DETECTED:-0}" == "1" ]]; then
        # Surface hardware: show 4 kernel options
        local on_dist="off" on_surface="off" on_surface_gen="off" on_gen="off"
        [[ "${current}" == "dist-kernel" ]] && on_dist="on"
        [[ "${current}" == "surface-kernel" ]] && on_surface="on"
        [[ "${current}" == "surface-genkernel" ]] && on_surface_gen="on"
        [[ "${current}" == "genkernel" ]] && on_gen="on"
        # Default to surface-kernel if nothing selected yet
        if [[ "${on_dist}" == "off" && "${on_surface}" == "off" && \
              "${on_surface_gen}" == "off" && "${on_gen}" == "off" ]]; then
            on_surface="on"
        fi

        local choice
        choice=$(dialog_radiolist "Kernel Selection (Surface)" \
            "surface-kernel"    "Surface kernel — overlay, compiled (recommended)" "${on_surface}" \
            "surface-genkernel" "Surface kernel — source + patches, genkernel"     "${on_surface_gen}" \
            "dist-kernel"       "Distribution kernel — fast, no Surface patches"   "${on_dist}" \
            "genkernel"         "genkernel — standard sources, no Surface patches" "${on_gen}") \
            || return "${TUI_BACK}"
    else
        # Standard hardware: 2 kernel options
        local on_dist="off" on_gen="off"
        [[ "${current}" == "dist-kernel" ]] && on_dist="on"
        [[ "${current}" == "genkernel" ]] && on_gen="on"

        local choice
        choice=$(dialog_radiolist "Kernel Selection" \
            "dist-kernel" "Distribution kernel — fast, pre-configured, recommended" "${on_dist}" \
            "genkernel"   "genkernel — custom built, more control, slower" "${on_gen}") \
            || return "${TUI_BACK}"
    fi

    if [[ -z "${choice}" ]]; then
        return "${TUI_BACK}"
    fi

    KERNEL_TYPE="${choice}"
    export KERNEL_TYPE

    einfo "Kernel type: ${KERNEL_TYPE}"
    return "${TUI_NEXT}"
}
