#!/usr/bin/env bash
# kernel.sh — Kernel installation: genkernel (custom) and dist-kernel (fast)
source "${LIB_DIR}/protection.sh"

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
        *)
            die "Unknown kernel type: ${kernel_type}"
            ;;
    esac

    # Configure dracut with root filesystem UUID
    _configure_dracut_root

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

    # Clean old kernels
    try "Cleaning old kernels" emerge --depclean sys-kernel/gentoo-kernel-bin 2>/dev/null || true
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

    # Install genkernel
    try "Installing genkernel" emerge --quiet sys-kernel/genkernel

    # Install dracut for initramfs
    try "Installing dracut" emerge --quiet sys-kernel/dracut

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
