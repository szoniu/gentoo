#!/usr/bin/env bash
# desktop.sh — Desktop environment installation (KDE Plasma / GNOME)
source "${LIB_DIR}/protection.sh"

# desktop_install — Install desktop environment (skipped when DESKTOP_TYPE=none)
desktop_install() {
    if [[ "${DESKTOP_TYPE:-plasma}" == "none" ]]; then
        einfo "Skipping desktop installation (server/minimal mode)"
        return 0
    fi

    # Install GPU drivers first (shared by all desktops)
    _install_gpu_drivers

    # Install PipeWire audio (shared)
    _install_pipewire

    # Install Bluetooth support (only if hardware detected)
    if [[ "${BLUETOOTH_DETECTED:-0}" == "1" ]]; then
        _install_bluetooth
    fi

    # Install printing support (shared)
    _install_printing

    # Desktop-specific installation
    case "${DESKTOP_TYPE}" in
        plasma)
            _install_kde_desktop
            ;;
        gnome)
            _install_gnome_desktop
            ;;
    esac

    # Install Gentoo artwork (icons, logos, wallpapers)
    try "Installing Gentoo artwork" emerge --quiet --keep-going x11-themes/gentoo-artwork || true

    einfo "Desktop installation complete"
}

# --- KDE Plasma ---

# _install_kde_desktop — Install KDE Plasma + SDDM
_install_kde_desktop() {
    einfo "Installing KDE Plasma desktop..."

    # KDE dependency prerequisites
    # avahi needs mdnsresponder-compat for kdnssd (KDE DNS-SD support)
    mkdir -p /etc/portage/package.use
    grep -qxF "net-dns/avahi mdnsresponder-compat" /etc/portage/package.use/kde 2>/dev/null || \
        echo "net-dns/avahi mdnsresponder-compat" >> /etc/portage/package.use/kde 2>/dev/null || true

    # dev-lang/go has a circular build dependency (needs itself to bootstrap)
    # Install it first as a one-shot to break the cycle
    try "Bootstrapping Go compiler" emerge --oneshot --quiet dev-lang/go

    # Install KDE Plasma
    try "Installing KDE Plasma" emerge --quiet kde-plasma/plasma-meta

    # Install SDDM display manager
    try "Installing SDDM" emerge --quiet x11-misc/sddm

    # Install KDE applications
    _install_kde_apps

    # Enable SDDM
    _enable_sddm

    # Configure Plasma defaults
    _configure_plasma

    einfo "KDE Plasma installed"
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
                spectacle)     try "Installing ${pkg}" emerge --quiet kde-plasma/spectacle ;;
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

# _enable_sddm — Enable SDDM display manager
_enable_sddm() {
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
        # display-manager init script comes from gui-libs/display-manager-init
        try "Installing display-manager-init" emerge --quiet gui-libs/display-manager-init
        try "Enabling display-manager" rc-update add display-manager default
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
RememberLastSession=false

[Users]
DefaultSession=plasma.desktop
SDDMEOF

    # Ensure dbus and elogind are started (OpenRC needs explicit enable)
    if [[ "${INIT_SYSTEM:-systemd}" == "openrc" ]]; then
        try "Enabling dbus" rc-update add dbus default
        try "Enabling elogind" rc-update add elogind boot
    fi

    einfo "Plasma defaults configured"
}

# --- GNOME ---

# _install_gnome_desktop — Install GNOME + GDM
_install_gnome_desktop() {
    einfo "Installing GNOME desktop..."

    # dev-lang/go has a circular build dependency (needs itself to bootstrap)
    try "Bootstrapping Go compiler" emerge --oneshot --quiet dev-lang/go

    # Install GNOME (meta package pulls gnome-shell, mutter, gnome-session, etc.)
    try "Installing GNOME" emerge --quiet gnome-base/gnome

    # Install GDM display manager
    try "Installing GDM" emerge --quiet gnome-base/gdm

    # Install GNOME applications
    _install_gnome_apps

    # Enable GDM
    _enable_gdm

    # Configure GNOME defaults
    _configure_gnome

    einfo "GNOME installed"
}

# _install_gnome_apps — Install selected GNOME applications
_install_gnome_apps() {
    local extras="${DESKTOP_EXTRAS:-}"

    # Install selected extras
    if [[ -n "${extras}" ]]; then
        local cleaned
        cleaned=$(echo "${extras}" | tr -d '"')
        local pkg
        for pkg in ${cleaned}; do
            case "${pkg}" in
                gnome-terminal)    try "Installing ${pkg}" emerge --quiet gnome-extra/gnome-terminal ;;
                nautilus)          try "Installing ${pkg}" emerge --quiet gnome-base/nautilus ;;
                gnome-text-editor) try "Installing ${pkg}" emerge --quiet app-editors/gnome-text-editor ;;
                firefox-bin)       try "Installing ${pkg}" emerge --quiet www-client/firefox-bin ;;
                loupe)             try "Installing ${pkg}" emerge --quiet media-gfx/loupe ;;
                evince)            try "Installing ${pkg}" emerge --quiet app-text/evince ;;
                file-roller)       try "Installing ${pkg}" emerge --quiet app-arch/file-roller ;;
                gnome-screenshot)  try "Installing ${pkg}" emerge --quiet media-gfx/gnome-screenshot ;;
                gnome-calculator)  try "Installing ${pkg}" emerge --quiet gnome-extra/gnome-calculator ;;
                gnome-weather)     try "Installing ${pkg}" emerge --quiet gnome-extra/gnome-weather ;;
                gnome-calendar)    try "Installing ${pkg}" emerge --quiet gnome-extra/gnome-calendar ;;
                gnome-clocks)      try "Installing ${pkg}" emerge --quiet gnome-extra/gnome-clocks ;;
                vlc)               try "Installing ${pkg}" emerge --quiet media-video/vlc ;;
                libreoffice)       try "Installing ${pkg}" emerge --quiet app-office/libreoffice ;;
                thunderbird)       try "Installing ${pkg}" emerge --quiet mail-client/thunderbird-bin ;;
                *)                 try "Installing ${pkg}" emerge --quiet "${pkg}" ;;
            esac
        done
    fi
}

# _enable_gdm — Enable GDM display manager
_enable_gdm() {
    einfo "Enabling GDM display manager..."

    if [[ "${INIT_SYSTEM:-systemd}" == "systemd" ]]; then
        try "Enabling GDM" systemctl enable gdm
    else
        # OpenRC: set display manager
        local conf="/etc/conf.d/display-manager"
        if [[ -f "${conf}" ]]; then
            sed -i 's/DISPLAYMANAGER=.*/DISPLAYMANAGER="gdm"/' "${conf}"
        else
            echo 'DISPLAYMANAGER="gdm"' > "${conf}"
        fi
        try "Installing display-manager-init" emerge --quiet gui-libs/display-manager-init
        try "Enabling display-manager" rc-update add display-manager default
    fi

    einfo "GDM enabled"
}

# _configure_gnome — Set up GNOME defaults
_configure_gnome() {
    einfo "Configuring GNOME defaults..."

    # GDM configuration
    mkdir -p /etc/gdm
    cat > /etc/gdm/custom.conf << 'GDMEOF'
[daemon]
WaylandEnable=true
AutomaticLoginEnable=false

[security]

[xdmcp]

[chooser]

[debug]
GDMEOF

    # Ensure dbus and elogind are started (OpenRC needs explicit enable)
    if [[ "${INIT_SYSTEM:-systemd}" == "openrc" ]]; then
        try "Enabling dbus" rc-update add dbus default
        try "Enabling elogind" rc-update add elogind boot
    fi

    einfo "GNOME defaults configured"
}

# --- Shared (desktop-agnostic) ---

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
    try "Installing libva-intel-media-driver (Gen9+)" emerge --quiet media-libs/libva-intel-media-driver
    try "Installing libva-intel-driver (Gen8-)" emerge --quiet media-libs/libva-intel-driver
    try "Installing vulkan-loader" emerge --quiet media-libs/vulkan-loader

    einfo "Intel GPU drivers installed"
}

# _install_pipewire — Install PipeWire audio system
_install_pipewire() {
    einfo "Installing PipeWire audio..."

    # pipewire-alsa: ALSA plugin so ALSA apps route through PipeWire
    # sound-server is now set by desktop profile (2026-01-15 news item)
    mkdir -p /etc/portage/package.use
    grep -qxF "media-video/pipewire pipewire-alsa" /etc/portage/package.use/pipewire 2>/dev/null || \
        echo "media-video/pipewire pipewire-alsa" >> /etc/portage/package.use/pipewire 2>/dev/null || true

    try "Installing PipeWire" emerge --quiet media-video/pipewire
    try "Installing WirePlumber" emerge --quiet media-video/wireplumber

    if [[ "${INIT_SYSTEM:-systemd}" == "systemd" ]]; then
        # Enable PipeWire user services globally (for all users)
        # --global enables for all users, avoiding need to run as specific user in chroot
        systemctl --global enable pipewire.service pipewire.socket \
            pipewire-pulse.service pipewire-pulse.socket \
            wireplumber.service 2>/dev/null || true
        einfo "PipeWire systemd user services enabled globally"
    else
        # For OpenRC, PipeWire needs XDG autostart via gentoo-pipewire-launcher
        mkdir -p /etc/xdg/autostart
        cat > /etc/xdg/autostart/pipewire.desktop << 'PWEOF'
[Desktop Entry]
Type=Application
Name=PipeWire
Comment=PipeWire multimedia service
Exec=gentoo-pipewire-launcher
X-GNOME-Autostart-Phase=EarlyInitialization
X-KDE-autostart-phase=0
PWEOF
        einfo "PipeWire XDG autostart configured for OpenRC"
    fi

    einfo "PipeWire installed"
}

# _install_bluetooth — Install Bluetooth stack (bluez)
_install_bluetooth() {
    einfo "Installing Bluetooth support..."
    try "Installing bluez" emerge --quiet net-wireless/bluez
    if [[ "${INIT_SYSTEM:-systemd}" == "systemd" ]]; then
        try "Enabling bluetooth" systemctl enable bluetooth
    else
        try "Enabling bluetooth" rc-update add bluetooth default
    fi

    # Enable Bluetooth adapter at boot (default is powered off)
    local bt_conf="/etc/bluetooth/main.conf"
    if [[ -f "${bt_conf}" ]]; then
        if grep -q '^#\?AutoEnable' "${bt_conf}" 2>/dev/null; then
            sed -i 's/^#\?AutoEnable.*/AutoEnable=true/' "${bt_conf}"
        else
            sed -i '/^\[Policy\]/a AutoEnable=true' "${bt_conf}" 2>/dev/null || \
                printf '\n[Policy]\nAutoEnable=true\n' >> "${bt_conf}"
        fi
        einfo "Bluetooth AutoEnable=true set"
    fi
}

# _install_printing — Install printing support (CUPS)
_install_printing() {
    einfo "Installing printing support (CUPS)..."
    try "Installing CUPS" emerge --quiet net-print/cups
    try "Installing CUPS filters" emerge --quiet net-print/cups-filters
    if [[ "${INIT_SYSTEM:-systemd}" == "systemd" ]]; then
        try "Enabling cupsd" systemctl enable cups.socket cups.path
    else
        try "Enabling cupsd" rc-update add cupsd default
    fi
}
