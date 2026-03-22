#!/usr/bin/env bash
# kernel.sh — Kernel installation: genkernel (custom) and dist-kernel (fast)
source "${LIB_DIR}/protection.sh"

# _set_kernel_extraversion — Append suffix to EXTRAVERSION in kernel Makefile
# Genkernel reads this and includes it in the kernel name.
# Example: EXTRAVERSION = -gentoo  →  EXTRAVERSION = -gentoo-surface
# Result:  vmlinuz-6.19.6-gentoo-surface-x86_64
_set_kernel_extraversion() {
    local suffix="$1"
    local makefile="/usr/src/linux/Makefile"

    [[ -f "${makefile}" ]] || return 0

    local current
    current=$(sed -n 's/^EXTRAVERSION = *//p' "${makefile}") || true

    # Don't add suffix if already present
    if [[ "${current}" == *"${suffix}"* ]]; then
        einfo "EXTRAVERSION already contains '${suffix}': ${current}"
        return 0
    fi

    sed -i "s/^EXTRAVERSION = .*/EXTRAVERSION = ${current}${suffix}/" "${makefile}"
    einfo "Kernel EXTRAVERSION set to: ${current}${suffix}"
}

# _patch_kernel_config — Enable essential modules that genkernel defconfig misses
# Genkernel uses defconfig which may lack drivers for modern laptop hardware.
# This patches .config BEFORE genkernel builds, so modules are included.
_patch_kernel_config() {
    local kconfig="/usr/src/linux/.config"

    # Generate default config if not present
    if [[ ! -f "${kconfig}" ]]; then
        make -C /usr/src/linux defconfig &>/dev/null || true
    fi

    [[ -f "${kconfig}" ]] || return 0

    einfo "Patching kernel config based on detected hardware..."

    # Always-on: essential for any modern laptop
    local -A required_modules=(
        # I2C HID touchpads (ThinkPad, Dell XPS, HP, Framework, most modern laptops)
        [CONFIG_I2C_HID_ACPI]="m"
        [CONFIG_I2C_DESIGNWARE_PLATFORM]="m"
        [CONFIG_I2C_DESIGNWARE_CORE]="m"
        # HID multitouch (touchscreens, precision touchpads)
        [CONFIG_HID_MULTITOUCH]="m"
        # Synaptics RMI4 (ThinkPad trackpads)
        [CONFIG_HID_RMI]="m"
        [CONFIG_RMI4_SMB]="m"
        [CONFIG_RMI4_I2C]="m"
        # USB Type-C (display output, charging, alt mode)
        [CONFIG_TYPEC]="m"
        [CONFIG_TYPEC_UCSI]="m"
        [CONFIG_UCSI_ACPI]="m"
        # ACPI backlight (screen brightness control)
        [CONFIG_ACPI_VIDEO]="m"
        [CONFIG_BACKLIGHT_CLASS_DEVICE]="y"
        # UVC webcam
        [CONFIG_USB_VIDEO_CLASS]="m"
    )

    # Conditional: based on detected hardware from detect_all_hardware()

    # Intel CPU → Intel GPU, SOF audio, thermald support
    if grep -qi 'GenuineIntel' /proc/cpuinfo 2>/dev/null; then
        einfo "  Intel CPU detected — adding i915, SOF audio"
        required_modules[CONFIG_DRM_I915]="m"
        required_modules[CONFIG_SND_SOC_SOF_TOPLEVEL]="y"
        required_modules[CONFIG_SND_SOC_SOF_PCI_DEV]="m"
        required_modules[CONFIG_SND_SOC_SOF_INTEL_TOPLEVEL]="y"
    fi

    # AMD CPU → pinctrl for I2C bus
    if grep -qi 'AuthenticAMD' /proc/cpuinfo 2>/dev/null; then
        einfo "  AMD CPU detected — adding PINCTRL_AMD"
        required_modules[CONFIG_PINCTRL_AMD]="m"
    fi

    # Bluetooth detected
    if [[ "${BLUETOOTH_DETECTED:-0}" == "1" ]]; then
        einfo "  Bluetooth detected — adding BT modules"
        required_modules[CONFIG_BT]="m"
        required_modules[CONFIG_BT_HCIBTUSB]="m"
        # MediaTek Bluetooth quirk (Framework AMD, many AMD laptops)
        if grep -qi 'AuthenticAMD' /proc/cpuinfo 2>/dev/null; then
            required_modules[CONFIG_BT_HCIBTUSB_MTK]="y"
        fi
    fi

    # Thunderbolt detected
    if [[ "${THUNDERBOLT_DETECTED:-0}" == "1" ]]; then
        einfo "  Thunderbolt detected — adding TB module"
        required_modules[CONFIG_THUNDERBOLT]="m"
    fi

    # ThinkPad detected (via thinkpad_acpi or DMI)
    if [[ -d /sys/devices/platform/thinkpad_acpi ]] || \
       grep -qi 'ThinkPad' /sys/class/dmi/id/product_family 2>/dev/null; then
        einfo "  ThinkPad detected — adding THINKPAD_ACPI"
        required_modules[CONFIG_THINKPAD_ACPI]="m"
    fi

    local key val current changed=0
    for key in "${!required_modules[@]}"; do
        val="${required_modules[${key}]}"
        if grep -q "# ${key} is not set" "${kconfig}" 2>/dev/null; then
            sed -i "s/# ${key} is not set/${key}=${val}/" "${kconfig}"
            einfo "  Enabled ${key}=${val}"
            (( changed++ )) || true
        elif ! grep -q "^${key}=" "${kconfig}" 2>/dev/null; then
            echo "${key}=${val}" >> "${kconfig}"
            einfo "  Added ${key}=${val}"
            (( changed++ )) || true
        fi
    done

    if [[ ${changed} -gt 0 ]]; then
        # Resolve dependencies after manual config changes
        make -C /usr/src/linux olddefconfig &>/dev/null || true
        einfo "Kernel config patched (${changed} options)"
    else
        einfo "Kernel config already has required options"
    fi
}

# kernel_install — Install kernel based on KERNEL_TYPE
kernel_install() {
    local kernel_type="${KERNEL_TYPE:-dist-kernel}"

    einfo "Installing kernel (${kernel_type})..."

    # Always install linux-firmware first
    try "Installing linux-firmware" emerge --quiet sys-kernel/linux-firmware

    # Install Intel microcode for Intel CPUs (security + stability patches)
    if grep -qi 'GenuineIntel' /proc/cpuinfo 2>/dev/null; then
        try "Installing Intel microcode" emerge --quiet sys-firmware/intel-microcode
        # SOF firmware for Intel HDA/SOF audio (HP Dragonfly, modern ultrabooks, etc.)
        try "Installing SOF audio firmware" emerge --quiet sys-firmware/sof-firmware
    fi

    # Install AMD microcode for AMD CPUs (security + stability patches)
    if grep -qi 'AuthenticAMD' /proc/cpuinfo 2>/dev/null; then
        try "Installing AMD microcode" emerge --quiet sys-firmware/amd-microcode
    fi

    # Configure installkernel with GRUB support
    mkdir -p /etc/portage/package.use
    grep -qxF "sys-kernel/installkernel grub" /etc/portage/package.use/installkernel 2>/dev/null || \
        echo "sys-kernel/installkernel grub" >> /etc/portage/package.use/installkernel 2>/dev/null || true

    # Install installkernel for automatic kernel installation
    try "Installing installkernel" emerge --quiet sys-kernel/installkernel

    case "${kernel_type}" in
        dist-kernel)
            kernel_install_dist
            ;;
        genkernel)
            kernel_install_genkernel
            ;;
        surface-kernel)
            kernel_install_surface
            ;;
        surface-genkernel)
            kernel_install_surface_genkernel
            ;;
        *)
            die "Unknown kernel type: ${kernel_type}"
            ;;
    esac

    # Configure dracut with root filesystem UUID (dist-kernel + surface-kernel use dracut;
    # genkernel/surface-genkernel generate their own initramfs)
    case "${kernel_type}" in
        dist-kernel|surface-kernel)
            _configure_dracut_root
            ;;
    esac

    einfo "Kernel installation complete"
}

# _configure_dracut_root — Tell dracut where the root filesystem is
_configure_dracut_root() {
    local root_uuid
    root_uuid=$(get_uuid "${ROOT_PARTITION}" 2>/dev/null) || root_uuid=""

    if [[ -n "${root_uuid}" ]]; then
        mkdir -p /etc/dracut.conf.d
        echo "kernel_cmdline=\"root=UUID=${root_uuid} rootfstype=${FILESYSTEM:-ext4}\"" \
            > /etc/dracut.conf.d/root.conf
        einfo "Dracut root configured: UUID=${root_uuid}"
    else
        ewarn "Could not determine root UUID for dracut config"
    fi
}

# kernel_install_dist — Install distribution kernel (pre-configured)
kernel_install_dist() {
    einfo "Installing distribution kernel..."

    # Accept ~amd64 for latest kernel if needed
    mkdir -p /etc/portage/package.accept_keywords
    grep -qxF "sys-kernel/gentoo-kernel-bin ~amd64" /etc/portage/package.accept_keywords/kernel 2>/dev/null || \
        echo "sys-kernel/gentoo-kernel-bin ~amd64" >> /etc/portage/package.accept_keywords/kernel 2>/dev/null || true

    # Try binary kernel first (much faster)
    # --autounmask-write --autounmask-continue: deps may also need ~amd64,
    # let portage accept keyword changes automatically instead of stopping
    if try "Installing gentoo-kernel-bin" emerge --quiet --autounmask-write --autounmask-continue sys-kernel/gentoo-kernel-bin; then
        einfo "Binary distribution kernel installed"
    else
        ewarn "Binary kernel failed, trying source-based dist-kernel"
        try "Installing gentoo-kernel" emerge --quiet --autounmask-write --autounmask-continue sys-kernel/gentoo-kernel
    fi

    # Ensure initramfs is generated
    if command -v dracut &>/dev/null; then
        einfo "Dracut initramfs should be auto-generated"
    fi

    # Clean old kernels (optional — don't fail on fresh install)
    emerge --depclean --quiet sys-kernel/gentoo-kernel-bin &>/dev/null || true
}

# kernel_install_genkernel — Build kernel with genkernel
kernel_install_genkernel() {
    einfo "Installing kernel with genkernel..."

    # Accept ~amd64 for latest kernel sources
    mkdir -p /etc/portage/package.accept_keywords
    grep -qxF "sys-kernel/gentoo-sources ~amd64" /etc/portage/package.accept_keywords/kernel 2>/dev/null || \
        echo "sys-kernel/gentoo-sources ~amd64" >> /etc/portage/package.accept_keywords/kernel 2>/dev/null || true

    # Install gentoo-sources
    # --autounmask-write --autounmask-continue: deps may also need ~amd64
    try "Installing gentoo-sources" emerge --quiet --autounmask-write --autounmask-continue sys-kernel/gentoo-sources

    # Install genkernel (generates its own initramfs — dracut not needed)
    try "Installing genkernel" emerge --quiet sys-kernel/genkernel

    # Set kernel symlink
    try "Setting kernel symlink" eselect kernel set 1

    # Enable essential hardware modules that genkernel defconfig misses
    _patch_kernel_config

    # Build kernel with genkernel
    local genkernel_opts=(
        --makeopts="-j$(get_cpu_count)"
        --no-menuconfig
        --lvm
        --luks
    )

    # Add filesystem support
    case "${FILESYSTEM:-ext4}" in
        btrfs)
            genkernel_opts+=(--btrfs)
            ;;
        xfs)
            # XFS is built-in by default
            ;;
    esac

    genkernel_opts+=(all)

    try "Building kernel with genkernel" genkernel "${genkernel_opts[@]}"

    einfo "Kernel built with genkernel"
}

# kernel_install_surface — Install Surface kernel from linux-surface overlay
kernel_install_surface() {
    einfo "Installing Surface kernel from overlay..."

    # Ensure overlay is available before installing surface-sources
    setup_surface_overlay

    # Accept ~amd64 for surface-sources
    mkdir -p /etc/portage/package.accept_keywords
    echo "sys-kernel/surface-sources ~amd64" > /etc/portage/package.accept_keywords/surface-kernel

    # Install surface-sources from overlay
    try "Installing surface-sources" emerge --quiet --autounmask-write --autounmask-continue sys-kernel/surface-sources

    # Install genkernel + dracut
    try "Installing genkernel" emerge --quiet sys-kernel/genkernel
    try "Installing dracut" emerge --quiet sys-kernel/dracut

    # Set kernel symlink
    try "Setting kernel symlink" eselect kernel set 1

    # Enable essential hardware modules that genkernel defconfig misses
    _patch_kernel_config

    # Set Surface suffix in kernel version (e.g. 6.19.6-gentoo-surface-x86_64)
    _set_kernel_extraversion "-surface"

    # Build kernel with genkernel
    local genkernel_opts=(
        --makeopts="-j$(get_cpu_count)"
        --no-menuconfig
        --lvm
        --luks
    )

    case "${FILESYSTEM:-ext4}" in
        btrfs) genkernel_opts+=(--btrfs) ;;
    esac

    genkernel_opts+=(all)

    try "Building Surface kernel with genkernel" genkernel "${genkernel_opts[@]}"

    # Cleanup old kernels
    emerge --depclean --quiet sys-kernel/surface-sources &>/dev/null || true

    einfo "Surface kernel (overlay) installed"
}

# kernel_install_surface_genkernel — Build kernel with linux-surface patches
kernel_install_surface_genkernel() {
    einfo "Installing kernel with linux-surface patches..."

    # Install gentoo-sources
    mkdir -p /etc/portage/package.accept_keywords
    grep -qxF "sys-kernel/gentoo-sources ~amd64" /etc/portage/package.accept_keywords/kernel 2>/dev/null || \
        echo "sys-kernel/gentoo-sources ~amd64" >> /etc/portage/package.accept_keywords/kernel 2>/dev/null || true

    # Mark as surface-genkernel type for resume inference
    echo "# surface-genkernel" > /etc/portage/package.accept_keywords/surface-kernel

    try "Installing gentoo-sources" emerge --quiet --autounmask-write --autounmask-continue sys-kernel/gentoo-sources

    # Install genkernel (generates its own initramfs — dracut not needed)
    try "Installing genkernel" emerge --quiet sys-kernel/genkernel

    # Set kernel symlink
    try "Setting kernel symlink" eselect kernel set 1

    # Clone linux-surface patches
    if ! command -v git &>/dev/null; then
        try "Installing git" emerge --quiet dev-vcs/git
    fi
    try "Cloning linux-surface patches" git clone --depth 1 https://github.com/linux-surface/linux-surface.git /tmp/linux-surface

    # Detect kernel version from sources
    local kernel_version
    kernel_version=$(sed -n 's/^VERSION = //p' /usr/src/linux/Makefile) || true
    local patchlevel
    patchlevel=$(sed -n 's/^PATCHLEVEL = //p' /usr/src/linux/Makefile) || true
    local patch_dir="/tmp/linux-surface/patches/${kernel_version}.${patchlevel}"

    if [[ ! -d "${patch_dir}" ]]; then
        # Find the highest available patch directory
        patch_dir=$(ls -d /tmp/linux-surface/patches/[0-9]* 2>/dev/null | sort -V | tail -1) || true
        local patches_version
        patches_version=$(basename "${patch_dir}") || true
        ewarn "No patches for kernel ${kernel_version}.${patchlevel} — using ${patches_version} (latest available)"
        ewarn "Some patches may not apply cleanly. This is expected."
    fi

    if [[ -n "${patch_dir}" && -d "${patch_dir}" ]]; then
        einfo "Applying patches from ${patch_dir} to kernel ${kernel_version}.${patchlevel}..."
        local p patch_name patch_ok=0 patch_skip=0
        for p in "${patch_dir}"/*.patch; do
            [[ -f "${p}" ]] || continue
            patch_name=$(basename "${p}")

            # Dry-run first — only apply if ALL hunks succeed
            # Partial apply (--force) is dangerous: can leave code referencing
            # undefined symbols when define hunks fail but usage hunks succeed
            if patch -d /usr/src/linux -p1 -N --dry-run < "${p}" &>/dev/null; then
                patch -d /usr/src/linux -p1 -N < "${p}" >> "${LOG_FILE}" 2>&1
                einfo "Applied: ${patch_name}"
                (( patch_ok++ )) || true
            else
                ewarn "Skipped: ${patch_name} (does not apply cleanly to ${kernel_version}.${patchlevel})"
                (( patch_skip++ )) || true
            fi
        done
        einfo "Patches: ${patch_ok} applied, ${patch_skip} skipped"
        if [[ ${patch_skip} -gt 0 ]]; then
            ewarn "Some patches did not apply cleanly. This is normal when kernel"
            ewarn "sources are newer than available linux-surface patches."
            ewarn "Core functionality (WiFi, display, battery) should still work."
        fi
    else
        ewarn "No linux-surface patches found — building unpatched kernel"
    fi

    # Enable essential hardware modules that genkernel defconfig misses
    _patch_kernel_config

    # Set Surface suffix in kernel version (e.g. 6.19.6-gentoo-surface-x86_64)
    _set_kernel_extraversion "-surface"

    # Build kernel with genkernel
    local genkernel_opts=(
        --makeopts="-j$(get_cpu_count)"
        --no-menuconfig
        --lvm
        --luks
    )

    case "${FILESYSTEM:-ext4}" in
        btrfs) genkernel_opts+=(--btrfs) ;;
    esac

    genkernel_opts+=(all)

    try "Building patched kernel with genkernel" genkernel "${genkernel_opts[@]}"

    # Cleanup
    rm -rf /tmp/linux-surface

    einfo "Surface kernel (patched) installed"
}
