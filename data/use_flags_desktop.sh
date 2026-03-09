#!/usr/bin/env bash
# use_flags_desktop.sh — USE flags for desktop environments
source "${LIB_DIR}/protection.sh"

# Common desktop USE flags (shared by KDE and GNOME)
readonly USE_FLAGS_DESKTOP_COMMON="X wayland dbus policykit udisks upower \
networkmanager bluetooth pulseaudio pipewire sound-server \
widgets gui \
vulkan opengl egl gles2 \
fontconfig truetype unicode nls \
jpeg png svg webp gif tiff \
mp3 mp4 flac vorbis opus aac \
pdf djvu \
cups colord \
samba"

# KDE Plasma specific USE flags
readonly USE_FLAGS_KDE="kde plasma qt5 qt6 -gnome -gtk -gtk3"

# GNOME specific USE flags
readonly USE_FLAGS_GNOME="gnome gtk introspection -kde -plasma -qt5 -qt6"

# Systemd-specific USE flags
readonly USE_FLAGS_SYSTEMD="systemd -elogind -consolekit"

# OpenRC-specific USE flags
readonly USE_FLAGS_OPENRC="-systemd elogind -consolekit"

# NVIDIA-specific USE flags
readonly USE_FLAGS_NVIDIA="nvenc cuda"

# AMD-specific USE flags
readonly USE_FLAGS_AMD="vaapi"

# Intel-specific USE flags
readonly USE_FLAGS_INTEL="vaapi"

# Minimal USE flags (server/no desktop)
readonly USE_FLAGS_MINIMAL="unicode nls"

# Legacy alias
readonly USE_FLAGS_DESKTOP="${USE_FLAGS_DESKTOP_COMMON} ${USE_FLAGS_KDE}"

# get_use_flags — Build complete USE flag string based on configuration
get_use_flags() {
    local init_system="${1:-systemd}"
    local gpu_vendor="${2:-}"

    local use_flags
    case "${DESKTOP_TYPE:-plasma}" in
        plasma)
            use_flags="${USE_FLAGS_DESKTOP_COMMON} ${USE_FLAGS_KDE}"
            ;;
        gnome)
            use_flags="${USE_FLAGS_DESKTOP_COMMON} ${USE_FLAGS_GNOME}"
            ;;
        none)
            use_flags="${USE_FLAGS_MINIMAL}"
            ;;
    esac

    # Init system
    case "${init_system}" in
        systemd)
            use_flags+=" ${USE_FLAGS_SYSTEMD}"
            ;;
        openrc)
            use_flags+=" ${USE_FLAGS_OPENRC}"
            ;;
    esac

    # GPU-specific
    case "${gpu_vendor}" in
        nvidia)
            use_flags+=" ${USE_FLAGS_NVIDIA}"
            ;;
        amd)
            use_flags+=" ${USE_FLAGS_AMD}"
            ;;
        intel)
            use_flags+=" ${USE_FLAGS_INTEL}"
            ;;
    esac

    echo "${use_flags}"
}
