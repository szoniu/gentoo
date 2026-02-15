#!/usr/bin/env bash
# tui/extra_packages.sh — Additional packages + optional repos selection
source "${LIB_DIR}/protection.sh"

screen_extra_packages() {
    # Step 1: Checklist with popular packages and optional repos
    local selections
    selections=$(dialog_checklist "Extra Packages" \
        "fastfetch"    "System info tool (like neofetch)"     "on"  \
        "btop"         "Resource monitor (top/htop alternative)" "on"  \
        "kitty"        "GPU-accelerated terminal emulator"   "on"  \
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
                # Ask which Wayland compositor to install
                local compositor
                compositor=$(dialog_radiolist "Noctalia Compositor" \
                    "Noctalia Shell requires a Wayland compositor.\nSelect one:" \
                    "hyprland" "Hyprland — dynamic tiling Wayland compositor" "on"  \
                    "niri"     "Niri — scrollable-tiling Wayland compositor"  "off" \
                    "sway"     "Sway — i3-compatible Wayland compositor"      "off" \
                ) || return "${TUI_BACK}"
                NOCTALIA_COMPOSITOR=$(echo "${compositor}" | tr -d '"')
                export NOCTALIA_COMPOSITOR
                ;;
            fastfetch)
                pkgs+=("app-misc/fastfetch")
                ;;
            btop)
                pkgs+=("sys-process/btop")
                ;;
            kitty)
                pkgs+=("x11-terms/kitty")
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
