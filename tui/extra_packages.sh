#!/usr/bin/env bash
# tui/extra_packages.sh — Additional packages + optional repos selection
source "${LIB_DIR}/protection.sh"

screen_extra_packages() {
    # Step 1: Build checklist — base items + conditional ROG item
    local -a checklist_args=(
        "fastfetch"    "System info tool (like neofetch)"     "on"
        "btop"         "Resource monitor (top/htop alternative)" "on"
        "kitty"        "GPU-accelerated terminal emulator"   "on"
        "app-editors/vim"  "Vim text editor"                  "off"
        "dev-vcs/git"      "Git version control"              "off"
        "sys-process/htop"  "Interactive process viewer"       "off"
        "v4l-utils"        "Video4Linux webcam/capture utilities (libv4l)" "off"
    )

    # Conditional: ASUS ROG tools (only shown when ROG hardware detected)
    if [[ "${ASUS_ROG_DETECTED:-0}" == "1" ]]; then
        checklist_args+=("asusctl" "ASUS ROG control (fan, RGB, battery — requires systemd)" "on")
    fi

    # Conditional: Surface tools (only shown when Surface hardware detected)
    if [[ "${SURFACE_DETECTED:-0}" == "1" ]]; then
        checklist_args+=("surface-tools" "Surface tools: iptsd (touchscreen) + surface-control" "on")
    fi

    # Conditional: Fingerprint reader (only shown when fingerprint hardware detected)
    if [[ "${FINGERPRINT_DETECTED:-0}" == "1" ]]; then
        checklist_args+=("fingerprint" "Fingerprint auth (fprintd — best with systemd)" "on")
    fi

    # Conditional: Thunderbolt (only shown when Thunderbolt controller detected)
    if [[ "${THUNDERBOLT_DETECTED:-0}" == "1" ]]; then
        checklist_args+=("thunderbolt" "Thunderbolt device manager (bolt — requires systemd)" "on")
    fi

    # Conditional: IIO sensors (only shown when sensors detected)
    if [[ "${SENSORS_DETECTED:-0}" == "1" ]]; then
        checklist_args+=("iio-sensors" "Auto-rotation / ambient light sensor proxy" "on")
    fi

    # Conditional: WWAN LTE modem (only shown when WWAN hardware detected)
    if [[ "${WWAN_DETECTED:-0}" == "1" ]]; then
        checklist_args+=("wwan-tools" "WWAN LTE modem support (ModemManager)" "on")
    fi

    checklist_args+=(
        "guru-repo"        "Enable GURU community repository" "off"
    )

    # Hyprland ecosystem — standalone Wayland desktop (only offer with desktop)
    if [[ "${DESKTOP_TYPE:-plasma}" != "none" ]]; then
        checklist_args+=("hyprland-ecosystem" "Hyprland + ekosystem (waybar, wofi, mako, grim...)" "$( [[ "${ENABLE_HYPRLAND:-no}" == "yes" ]] && echo "on" || echo "off" )")
    fi

    # Noctalia requires a Wayland compositor — only offer with desktop
    if [[ "${DESKTOP_TYPE:-plasma}" != "none" ]]; then
        checklist_args+=("noctalia-shell" "Noctalia Shell (requires GURU)" "off")
    fi

    local selections
    selections=$(dialog_checklist "Extra Packages" "${checklist_args[@]}") || return "${TUI_BACK}"

    # Parse checklist selections
    local cleaned
    cleaned=$(echo "${selections}" | tr -d '"')

    local -a pkgs=()
    ENABLE_GURU="${ENABLE_GURU:-no}"
    ENABLE_HYPRLAND="${ENABLE_HYPRLAND:-no}"
    ENABLE_NOCTALIA="${ENABLE_NOCTALIA:-no}"
    ENABLE_ASUSCTL="${ENABLE_ASUSCTL:-no}"
    ENABLE_IPTSD="${ENABLE_IPTSD:-no}"
    ENABLE_SURFACE_CONTROL="${ENABLE_SURFACE_CONTROL:-no}"
    ENABLE_FINGERPRINT="${ENABLE_FINGERPRINT:-no}"
    ENABLE_THUNDERBOLT="${ENABLE_THUNDERBOLT:-no}"
    ENABLE_SENSORS="${ENABLE_SENSORS:-no}"
    ENABLE_WWAN="${ENABLE_WWAN:-no}"

    local item
    for item in ${cleaned}; do
        case "${item}" in
            asusctl)
                ENABLE_ASUSCTL="yes"
                ;;
            surface-tools)
                ENABLE_IPTSD="yes"
                ENABLE_SURFACE_CONTROL="yes"
                ;;
            fingerprint)
                ENABLE_FINGERPRINT="yes"
                ;;
            thunderbolt)
                ENABLE_THUNDERBOLT="yes"
                ;;
            iio-sensors)
                ENABLE_SENSORS="yes"
                ;;
            wwan-tools)
                ENABLE_WWAN="yes"
                ;;
            v4l-utils)
                pkgs+=("media-libs/libv4l")
                ;;
            guru-repo)
                ENABLE_GURU="yes"
                ;;
            hyprland-ecosystem)
                ENABLE_HYPRLAND="yes"
                ;;
            noctalia-shell)
                ENABLE_NOCTALIA="yes"
                ENABLE_GURU="yes"  # noctalia requires GURU
                # Ask which Wayland compositor to install
                local compositor
                compositor=$(dialog_radiolist "Select Wayland Compositor for Noctalia" \
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

    export ENABLE_GURU ENABLE_HYPRLAND ENABLE_NOCTALIA ENABLE_ASUSCTL ENABLE_IPTSD \
           ENABLE_SURFACE_CONTROL ENABLE_FINGERPRINT ENABLE_THUNDERBOLT ENABLE_SENSORS ENABLE_WWAN

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
    [[ "${ENABLE_HYPRLAND}" == "yes" ]] && einfo "Hyprland ecosystem: enabled"
    [[ "${ENABLE_NOCTALIA}" == "yes" ]] && einfo "Noctalia Shell: enabled"
    [[ "${ENABLE_ASUSCTL}" == "yes" ]] && einfo "ASUS ROG tools: enabled"
    [[ "${ENABLE_IPTSD}" == "yes" ]] && einfo "Surface tools: iptsd + surface-control"
    [[ "${ENABLE_FINGERPRINT}" == "yes" ]] && einfo "Fingerprint reader: fprintd enabled"
    [[ "${ENABLE_THUNDERBOLT}" == "yes" ]] && einfo "Thunderbolt: bolt enabled"
    [[ "${ENABLE_SENSORS}" == "yes" ]] && einfo "IIO sensors: iio-sensor-proxy enabled"
    [[ "${ENABLE_WWAN}" == "yes" ]] && einfo "WWAN LTE: ModemManager enabled"
    return "${TUI_NEXT}"
}
