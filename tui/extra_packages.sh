#!/usr/bin/env bash
# tui/extra_packages.sh — Additional packages selection
source "${LIB_DIR}/protection.sh"

screen_extra_packages() {
    local packages
    packages=$(dialog_inputbox "Extra Packages" \
        "Enter any additional packages to install (space-separated).\n\n\
Examples: app-editors/vim dev-vcs/git app-misc/htop\n\n\
Leave empty to skip:" \
        "${EXTRA_PACKAGES:-}") || return "${TUI_BACK}"

    EXTRA_PACKAGES="${packages}"
    export EXTRA_PACKAGES

    einfo "Extra packages: ${EXTRA_PACKAGES:-none}"
    return "${TUI_NEXT}"
}
