#!/usr/bin/env bash
# tui/extra_packages.sh — Additional packages + optional repos selection
source "${LIB_DIR}/protection.sh"

screen_extra_packages() {
    # Step 1: Checklist with popular packages and optional repos
    local selections
    selections=$(dialog_checklist "Extra Packages" \
        "fastfetch"    "System info tool (like neofetch)"     "on"  \
        "app-editors/vim"  "Vim text editor"                  "off" \
        "dev-vcs/git"      "Git version control"              "off" \
        "app-misc/htop"    "Interactive process viewer"       "off" \
        "guru-repo"        "Enable GURU community repository" "off" \
        "noctalia-shell"   "Noctalia Shell (requires GURU)"   "off" \
    ) || return "${TUI_BACK}"

    # Parse checklist selections
    local cleaned
    cleaned=$(echo "${selections}" | tr -d '"')

    local -a pkgs=()
    ENABLE_GURU="${ENABLE_GURU:-no}"
    ENABLE_NOCTALIA="${ENABLE_NOCTALIA:-no}"

    local item
    for item in ${cleaned}; do
        case "${item}" in
            guru-repo)
                ENABLE_GURU="yes"
                ;;
            noctalia-shell)
                ENABLE_NOCTALIA="yes"
                ENABLE_GURU="yes"  # noctalia requires GURU
                ;;
            fastfetch)
                pkgs+=("app-misc/fastfetch")
                ;;
            *)
                pkgs+=("${item}")
                ;;
        esac
    done

    export ENABLE_GURU ENABLE_NOCTALIA

    # Step 2: Free-form input for additional packages
    local extra
    extra=$(dialog_inputbox "Additional Packages" \
        "Enter any additional packages (space-separated).\n\n\
Examples: app-editors/nano sys-process/lsof net-misc/curl\n\n\
Leave empty to skip:" \
        "") || return "${TUI_BACK}"

    # Combine checklist + free-form packages
    local all_pkgs="${pkgs[*]}"
    [[ -n "${extra}" ]] && all_pkgs="${all_pkgs:+${all_pkgs} }${extra}"

    EXTRA_PACKAGES="${all_pkgs}"
    export EXTRA_PACKAGES

    einfo "Extra packages: ${EXTRA_PACKAGES:-none}"
    [[ "${ENABLE_GURU}" == "yes" ]] && einfo "GURU repository: enabled"
    [[ "${ENABLE_NOCTALIA}" == "yes" ]] && einfo "Noctalia Shell: enabled"
    return "${TUI_NEXT}"
}
