#!/usr/bin/env bash
# tui/desktop_select.sh — Desktop type: KDE Plasma, GNOME, or none (server/minimal)
source "${LIB_DIR}/protection.sh"

screen_desktop_select() {
    local current="${DESKTOP_TYPE:-plasma}"
    local on_plasma="off" on_gnome="off" on_none="off"
    [[ "${current}" == "plasma" ]] && on_plasma="on"
    [[ "${current}" == "gnome" ]] && on_gnome="on"
    [[ "${current}" == "none" ]] && on_none="on"

    local choice
    choice=$(dialog_radiolist "Desktop Environment" \
        "plasma" "KDE Plasma — full desktop, SDDM, PipeWire" "${on_plasma}" \
        "gnome"  "GNOME — full desktop, GDM, PipeWire"       "${on_gnome}" \
        "none"   "None — server/minimal, CLI only"            "${on_none}") \
        || return "${TUI_BACK}"

    if [[ -z "${choice}" ]]; then
        return "${TUI_BACK}"
    fi

    DESKTOP_TYPE="${choice}"
    export DESKTOP_TYPE

    if [[ "${DESKTOP_TYPE}" == "none" ]]; then
        # Set GPU defaults for headless — skip GPU config screen later
        GPU_VENDOR="none"
        GPU_DRIVER="none"
        VIDEO_CARDS="fbdev"
        GPU_USE_NVIDIA_OPEN="no"
        HYBRID_GPU="no"
        IGPU_VENDOR="" ; IGPU_DEVICE_NAME=""
        DGPU_VENDOR="" ; DGPU_DEVICE_NAME=""
        DESKTOP_EXTRAS=""
        export GPU_VENDOR GPU_DRIVER VIDEO_CARDS GPU_USE_NVIDIA_OPEN
        export HYBRID_GPU IGPU_VENDOR IGPU_DEVICE_NAME DGPU_VENDOR DGPU_DEVICE_NAME
        export DESKTOP_EXTRAS
    fi

    einfo "Desktop type: ${DESKTOP_TYPE}"
    return "${TUI_NEXT}"
}
