#!/usr/bin/env bash
# tui/hw_detect.sh — Hardware detection summary screen
source "${LIB_DIR}/protection.sh"

screen_hw_detect() {
    dialog_infobox "Hardware Detection" \
        "Scanning your hardware...\n\nThis may take a moment."

    # Run detection
    detect_all_hardware

    # Show summary
    local summary
    summary=$(get_hardware_summary)

    dialog_yesno "Hardware Detected" \
        "${summary}\n\nDoes this look correct? Press Yes to continue, No to go back." \
        && : \
        || return "${TUI_BACK}"

    # After preset load with skip: jump past config screens to user_config (passwords)
    if [[ "${_PRESET_SKIP_TO_USER:-0}" == "1" ]]; then
        unset _PRESET_SKIP_TO_USER
        # Find user_config index in wizard screens
        local i
        for (( i=0; i<${#_WIZARD_SCREENS[@]}; i++ )); do
            if [[ "${_WIZARD_SCREENS[i]}" == "screen_user_config" ]]; then
                # Set to i-1 because run_wizard will increment after we return TUI_NEXT
                _WIZARD_INDEX=$(( i - 1 ))
                einfo "Preset loaded — skipping to password setup"
                break
            fi
        done
    fi

    return "${TUI_NEXT}"
}
