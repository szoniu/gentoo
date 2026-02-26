#!/usr/bin/env bash
# desktop.sh — KDE Plasma, SDDM, PipeWire, GPU drivers
source "${LIB_DIR}/protection.sh"

# desktop_install — Install full KDE Plasma desktop
desktop_install() {
    einfo "Installing KDE Plasma desktop..."

    # Install GPU drivers first
    _install_gpu_drivers

    # Install KDE Plasma
    try "Installing KDE Plasma" emerge --quiet kde-plasma/plasma-meta

    # Install SDDM display manager
    try "Installing SDDM" emerge --quiet x11-misc/sddm

    # Install PipeWire audio
    _install_pipewire

    # Install KDE applications
    _install_kde_apps

    # Enable display manager
    _enable_display_manager

    # Configure Plasma defaults
    _configure_plasma

    einfo "Desktop installation complete"
}

# _install_gpu_drivers — Install GPU-specific drivers
_install_gpu_drivers() {
    local vendor="${GPU_VENDOR:-unknown}"

    if [[ "${HYBRID_GPU:-no}" == "yes" ]]; then
        _install_hybrid_gpu_drivers
        return
    fi

    case "${vendor}" in
        nvidia)
            _install_nvidia_drivers
            ;;
        amd)
            _install_amd_drivers
            ;;
        intel)
            _install_intel_drivers
            ;;
        *)
            einfo "No specific GPU driver to install"
            ;;
    esac
}

# _install_hybrid_gpu_drivers — Install drivers for hybrid iGPU + dGPU setup
_install_hybrid_gpu_drivers() {
    local igpu="${IGPU_VENDOR:-unknown}"
    local dgpu="${DGPU_VENDOR:-unknown}"

    einfo "Installing hybrid GPU drivers: ${igpu} iGPU + ${dgpu} dGPU..."

    # Install iGPU driver (mesa for Intel/AMD)
    case "${igpu}" in
        intel)
            _install_intel_drivers
            ;;
        amd)
            _install_amd_drivers
            ;;
    esac

    # Install dGPU driver
    case "${dgpu}" in
        nvidia)
            _install_nvidia_drivers
            ;;
        amd)
            _install_amd_drivers
            ;;
    esac

    # Install prime-run for NVIDIA PRIME render offload
    if [[ "${dgpu}" == "nvidia" ]]; then
        try "Installing prime-run" emerge --quiet x11-misc/prime-run
        _configure_nvidia_power_management
    fi

    einfo "Hybrid GPU drivers installed"
}

# _configure_nvidia_power_management — Set up NVIDIA dynamic power management for hybrid laptops
_configure_nvidia_power_management() {
    einfo "Configuring NVIDIA power management for hybrid GPU..."

    # Dynamic power management (RTD3) — allows dGPU to power off when idle
    mkdir -p /etc/modprobe.d
    cat > /etc/modprobe.d/nvidia-pm.conf << 'PMEOF'
# NVIDIA Dynamic Power Management (RTD3)
# Allows discrete GPU to power off when not in use
options nvidia NVreg_DynamicPowerManagement=0x02
PMEOF

    # udev rules for runtime PM on NVIDIA PCI devices
    mkdir -p /etc/udev/rules.d
    cat > /etc/udev/rules.d/80-nvidia-pm.rules << 'UDEVEOF'
# Enable runtime PM for NVIDIA VGA/3D controller devices
ACTION=="bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030000", TEST=="power/control", ATTR{power/control}="auto"
ACTION=="bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030200", TEST=="power/control", ATTR{power/control}="auto"
UDEVEOF

    einfo "NVIDIA power management configured"
}

# _install_nvidia_drivers — Install NVIDIA proprietary drivers
_install_nvidia_drivers() {
    einfo "Installing NVIDIA drivers..."

    # Accept license
    mkdir -p /etc/portage/package.license
    echo "x11-drivers/nvidia-drivers NVIDIA-r2" > \
        /etc/portage/package.license/nvidia

    # Configure for open kernel module if supported
    if [[ "${GPU_USE_NVIDIA_OPEN:-no}" == "yes" ]]; then
        mkdir -p /etc/portage/package.use
        echo "x11-drivers/nvidia-drivers kernel-open" > \
            /etc/portage/package.use/nvidia
        einfo "Using NVIDIA open kernel module"
    fi

    try "Installing nvidia-drivers" emerge --quiet x11-drivers/nvidia-drivers

    # Load nvidia module at boot
    if [[ "${INIT_SYSTEM:-systemd}" == "systemd" ]]; then
        mkdir -p /etc/modules-load.d
        echo "nvidia" > /etc/modules-load.d/nvidia.conf
        echo "nvidia_modeset" >> /etc/modules-load.d/nvidia.conf
        echo "nvidia_uvm" >> /etc/modules-load.d/nvidia.conf
        echo "nvidia_drm" >> /etc/modules-load.d/nvidia.conf
    else
        mkdir -p /etc/modules-load.d
        echo "nvidia" > /etc/modules-load.d/nvidia.conf
    fi

    # Enable DRM KMS for Wayland
    mkdir -p /etc/modprobe.d
    echo "options nvidia_drm modeset=1 fbdev=1" > /etc/modprobe.d/nvidia.conf

    einfo "NVIDIA drivers installed"
}

# _install_amd_drivers — Install AMD GPU drivers (mesa)
_install_amd_drivers() {
    einfo "Installing AMD GPU drivers..."

    try "Installing mesa (amdgpu)" emerge --quiet media-libs/mesa
    try "Installing vulkan-loader" emerge --quiet media-libs/vulkan-loader

    # AMD-specific firmware
    try "Installing linux-firmware" emerge --quiet sys-kernel/linux-firmware

    einfo "AMD GPU drivers installed"
}

# _install_intel_drivers — Install Intel GPU drivers
_install_intel_drivers() {
    einfo "Installing Intel GPU drivers..."

    try "Installing mesa (intel)" emerge --quiet media-libs/mesa
    try "Installing intel-media-driver" emerge --quiet media-libs/intel-media-driver
    try "Installing vulkan-loader" emerge --quiet media-libs/vulkan-loader

    einfo "Intel GPU drivers installed"
}

# _install_pipewire — Install PipeWire audio system
_install_pipewire() {
    einfo "Installing PipeWire audio..."

    try "Installing PipeWire" emerge --quiet media-video/pipewire
    try "Installing WirePlumber" emerge --quiet media-video/wireplumber

    if [[ "${INIT_SYSTEM:-systemd}" == "systemd" ]]; then
        # PipeWire will be auto-started by systemd user services
        einfo "PipeWire will be started as a systemd user service"
    else
        # For OpenRC, PipeWire needs to be started in the user session
        einfo "PipeWire should be started from the desktop session"
    fi

    einfo "PipeWire installed"
}

# _install_kde_apps — Install selected KDE applications
_install_kde_apps() {
    local extras="${DESKTOP_EXTRAS:-}"

    # Always install some basics
    local -a base_apps=(
        kde-apps/kio-extras
    )

    local pkg
    for pkg in "${base_apps[@]}"; do
        try "Installing ${pkg}" emerge --quiet "${pkg}"
    done

    # Install selected extras
    if [[ -n "${extras}" ]]; then
        # extras is space-separated from dialog checklist (may have quotes)
        local cleaned
        cleaned=$(echo "${extras}" | tr -d '"')
        for pkg in ${cleaned}; do
            case "${pkg}" in
                konsole)       try "Installing ${pkg}" emerge --quiet kde-apps/konsole ;;
                dolphin)       try "Installing ${pkg}" emerge --quiet kde-apps/dolphin ;;
                kate)          try "Installing ${pkg}" emerge --quiet kde-apps/kate ;;
                firefox-bin)   try "Installing ${pkg}" emerge --quiet www-client/firefox-bin ;;
                gwenview)      try "Installing ${pkg}" emerge --quiet kde-apps/gwenview ;;
                okular)        try "Installing ${pkg}" emerge --quiet kde-apps/okular ;;
                ark)           try "Installing ${pkg}" emerge --quiet kde-apps/ark ;;
                spectacle)     try "Installing ${pkg}" emerge --quiet kde-apps/spectacle ;;
                kcalc)         try "Installing ${pkg}" emerge --quiet kde-apps/kcalc ;;
                kwalletmanager) try "Installing ${pkg}" emerge --quiet kde-apps/kwalletmanager ;;
                elisa)         try "Installing ${pkg}" emerge --quiet media-sound/elisa ;;
                vlc)           try "Installing ${pkg}" emerge --quiet media-video/vlc ;;
                libreoffice)   try "Installing ${pkg}" emerge --quiet app-office/libreoffice ;;
                thunderbird)   try "Installing ${pkg}" emerge --quiet mail-client/thunderbird-bin ;;
                *)             try "Installing ${pkg}" emerge --quiet "${pkg}" ;;
            esac
        done
    fi
}

# _enable_display_manager — Enable SDDM
_enable_display_manager() {
    einfo "Enabling SDDM display manager..."

    if [[ "${INIT_SYSTEM:-systemd}" == "systemd" ]]; then
        try "Enabling SDDM" systemctl enable sddm
    else
        # OpenRC: set display manager
        local conf="/etc/conf.d/display-manager"
        if [[ -f "${conf}" ]]; then
            sed -i 's/DISPLAYMANAGER=.*/DISPLAYMANAGER="sddm"/' "${conf}"
        else
            echo 'DISPLAYMANAGER="sddm"' > "${conf}"
        fi
        try "Enabling display-manager" rc-update add display-manager default

        # Install XDM init script if not present
        try "Installing xdm" emerge --quiet x11-base/xorg-server 2>/dev/null || true
    fi

    einfo "SDDM enabled"
}

# _configure_plasma — Set up KDE Plasma defaults
_configure_plasma() {
    einfo "Configuring Plasma defaults..."

    # Set SDDM theme
    mkdir -p /etc/sddm.conf.d
    cat > /etc/sddm.conf.d/gentoo.conf << SDDMEOF
[Theme]
Current=breeze

[General]
InputMethod=
SDDMEOF

    # Ensure dbus is started
    if [[ "${INIT_SYSTEM:-systemd}" == "openrc" ]]; then
        try "Enabling dbus" rc-update add dbus default
    fi

    einfo "Plasma defaults configured"
}
