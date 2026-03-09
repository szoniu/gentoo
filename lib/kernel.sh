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

# kernel_install — Install kernel based on KERNEL_TYPE
kernel_install() {
    local kernel_type="${KERNEL_TYPE:-dist-kernel}"

    einfo "Installing kernel (${kernel_type})..."

    # Always install linux-firmware first
    try "Installing linux-firmware" emerge --quiet sys-kernel/linux-firmware

    # Install Intel microcode for Intel CPUs (security + stability patches)
    if grep -qi 'GenuineIntel' /proc/cpuinfo 2>/dev/null; then
        try "Installing Intel microcode" emerge --quiet sys-firmware/intel-microcode
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
        local p patch_name patch_ok=0 patch_partial=0 patch_fail=0
        for p in "${patch_dir}"/*.patch; do
            [[ -f "${p}" ]] || continue
            patch_name=$(basename "${p}")

            # Dry-run first to check if patch applies cleanly
            if patch -d /usr/src/linux -p1 -N --dry-run < "${p}" &>/dev/null; then
                # Clean apply
                patch -d /usr/src/linux -p1 -N < "${p}" >> "${LOG_FILE}" 2>&1
                einfo "Applied: ${patch_name}"
                (( patch_ok++ )) || true
            elif patch -d /usr/src/linux -p1 -N --force < "${p}" >> "${LOG_FILE}" 2>&1; then
                # Partial apply with --force (applies what it can, skips failed hunks)
                ewarn "Partially applied: ${patch_name} (some hunks failed — see log)"
                (( patch_partial++ )) || true
            else
                ewarn "Skipped: ${patch_name} (does not apply to this kernel version)"
                (( patch_fail++ )) || true
            fi
        done
        einfo "Patches: ${patch_ok} applied, ${patch_partial} partial, ${patch_fail} skipped"
        if [[ ${patch_partial} -gt 0 || ${patch_fail} -gt 0 ]]; then
            ewarn "Some patches did not apply cleanly. This is normal when kernel"
            ewarn "sources are newer than available linux-surface patches."
            ewarn "Core functionality (WiFi, display, battery) should still work."
        fi
    else
        ewarn "No linux-surface patches found — building unpatched kernel"
    fi

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
