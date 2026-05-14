#!/usr/bin/env bash
# secureboot.sh — Secure Boot: MOK key generation, kernel signing, shim setup
source "${LIB_DIR}/protection.sh"

# is_secureboot_active — Check if Secure Boot is currently enabled in firmware
# Returns 0 if enabled, 1 if disabled or unknown
is_secureboot_active() {
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        return 1
    fi

    # Method 1: read EFI variable directly (works without mokutil)
    local sb_var
    sb_var=$(find /sys/firmware/efi/efivars/ -name 'SecureBoot-*' 2>/dev/null | head -1) || true
    if [[ -n "${sb_var}" ]]; then
        # EFI variable: 4 bytes attributes + 1 byte value (01=enabled, 00=disabled)
        local val
        val=$(od -An -tx1 -j4 -N1 "${sb_var}" 2>/dev/null | tr -d ' ') || true
        [[ "${val}" == "01" ]] && return 0
        return 1
    fi

    # Method 2: mokutil (may not be available on live ISO)
    if command -v mokutil &>/dev/null; then
        mokutil --sb-state 2>/dev/null | grep -qi "SecureBoot enabled" && return 0
    fi

    return 1
}

# secureboot_setup — Full Secure Boot setup: keys, signing, shim, enrollment
secureboot_setup() {
    [[ "${ENABLE_SECUREBOOT:-no}" != "yes" ]] && return 0

    einfo "Setting up Secure Boot (MOK)..."

    local key_dir="/root/secureboot"
    mkdir -p "${key_dir}"
    chmod 700 "${key_dir}"

    # 1. Install required packages
    try "Installing sbsigntools" emerge --quiet app-crypt/sbsigntools
    try "Installing mokutil" emerge --quiet sys-boot/mokutil
    try "Installing shim" emerge --quiet sys-boot/shim

    # 2. Generate MOK key pair (if not already present)
    if [[ ! -f "${key_dir}/MOK.priv" || ! -f "${key_dir}/MOK.der" ]]; then
        einfo "Generating MOK key pair..."
        try "Generating MOK key pair" \
            openssl req -new -x509 -newkey rsa:2048 -nodes -days 36500 \
            -subj "/CN=Gentoo Machine Owner Key/" \
            -keyout "${key_dir}/MOK.priv" -outform DER -out "${key_dir}/MOK.der"

        # Also create PEM version for sbsign
        try "Converting MOK to PEM" \
            openssl x509 -in "${key_dir}/MOK.der" -inform DER \
            -outform PEM -out "${key_dir}/MOK.pem"

        chmod 600 "${key_dir}/MOK.priv"
        einfo "MOK keys generated in ${key_dir}"
    else
        einfo "MOK keys already exist in ${key_dir}"
        # Ensure PEM exists
        if [[ ! -f "${key_dir}/MOK.pem" ]]; then
            openssl x509 -in "${key_dir}/MOK.der" -inform DER \
                -outform PEM -out "${key_dir}/MOK.pem" 2>/dev/null || true
        fi
    fi

    # 3. Configure Portage for automatic kernel signing
    _configure_secureboot_portage "${key_dir}"

    # 4. Rebuild GRUB with SBAT section (shim 15.8+ requires it)
    _rebuild_grub_with_sbat "${key_dir}"

    # 5. Sign existing kernels
    _sign_kernels "${key_dir}"

    # 6. Setup shim on ESP
    _setup_shim "${key_dir}"

    # 7. Queue MOK enrollment (password: gentoo)
    _enroll_mok "${key_dir}"

    einfo "Secure Boot setup complete"
    if is_secureboot_active; then
        einfo "At first reboot: MokManager will appear → Enroll MOK → password: gentoo"
    else
        einfo "Secure Boot is currently DISABLED in firmware"
        einfo "After installation: enable Secure Boot in BIOS/UEFI → reboot"
        einfo "MokManager will appear → Enroll MOK → password: gentoo"
        einfo "If MokManager does not appear, run: mokutil --import /root/secureboot/MOK.der"
    fi
}

# _configure_secureboot_portage — Add USE=secureboot + signing keys to make.conf
_configure_secureboot_portage() {
    local key_dir="$1"
    local make_conf="/etc/portage/make.conf"

    # Add secureboot USE flag for installkernel
    mkdir -p /etc/portage/package.use
    if ! grep -q "secureboot" /etc/portage/package.use/installkernel 2>/dev/null; then
        echo "sys-kernel/installkernel secureboot" >> /etc/portage/package.use/installkernel
    fi

    # Add signing keys to make.conf (if not already there)
    if ! grep -q "SECUREBOOT_SIGN_KEY" "${make_conf}" 2>/dev/null; then
        cat >> "${make_conf}" << SBEOF

# --- Secure Boot signing ---
SECUREBOOT_SIGN_KEY="${key_dir}/MOK.priv"
SECUREBOOT_SIGN_CERT="${key_dir}/MOK.pem"
SBEOF
        einfo "Secure Boot signing keys added to make.conf"
    fi
}

# _rebuild_grub_with_sbat — Rebuild GRUB as standalone EFI with SBAT section
# Shim 15.8+ rejects any EFI binary without .sbat section, even if properly signed.
_rebuild_grub_with_sbat() {
    local key_dir="$1"
    local priv="${key_dir}/MOK.priv"
    local cert="${key_dir}/MOK.pem"
    local efi_dir="/efi/EFI/gentoo"
    local sbat_csv="/usr/share/grub/sbat.csv"

    # Create SBAT metadata if missing
    if [[ ! -f "${sbat_csv}" ]]; then
        mkdir -p /usr/share/grub
        cat > "${sbat_csv}" << 'SBATEOF'
sbat,1,SBAT Version,sbat,1,https://github.com/rhboot/shim/blob/main/SBAT.md
grub,4,Free Software Foundation,grub,2.12,https://www.gnu.org/software/grub/
SBATEOF
    fi

    einfo "Rebuilding GRUB with SBAT section..."
    local grub_tmp="/tmp/grubx64-sbat.efi"

    try "Building standalone GRUB with SBAT" \
        grub-mkstandalone --format=x86_64-efi --output="${grub_tmp}" \
        --sbat="${sbat_csv}" \
        --modules="part_gpt part_msdos fat ext2 btrfs xfs normal boot linux search search_fs_uuid search_fs_file configfile echo test" \
        "boot/grub/grub.cfg=/boot/grub/grub.cfg"

    # Sign with MOK key
    try "Signing GRUB with SBAT" \
        sbsign --key "${priv}" --cert "${cert}" --output "${grub_tmp}" "${grub_tmp}"

    # Replace on ESP
    mkdir -p "${efi_dir}"
    cp "${grub_tmp}" "${efi_dir}/grubx64.efi"
    rm -f "${grub_tmp}"

    einfo "GRUB rebuilt with SBAT and signed"
}

# _sign_kernels — Sign all existing kernel images
_sign_kernels() {
    local key_dir="$1"
    local priv="${key_dir}/MOK.priv"
    local cert="${key_dir}/MOK.pem"

    local kernel
    for kernel in /boot/vmlinuz-*; do
        [[ -f "${kernel}" ]] || continue

        # Check if already signed
        if sbverify --cert "${cert}" "${kernel}" &>/dev/null; then
            einfo "Already signed: ${kernel}"
            continue
        fi

        einfo "Signing: ${kernel}"
        try "Signing kernel $(basename "${kernel}")" \
            sbsign --key "${priv}" --cert "${cert}" --output "${kernel}" "${kernel}"
    done
}

# _setup_shim — Install shim and signed GRUB on ESP
_setup_shim() {
    local key_dir="$1"
    local priv="${key_dir}/MOK.priv"
    local cert="${key_dir}/MOK.pem"
    local efi_dir="/efi/EFI/gentoo"

    mkdir -p "${efi_dir}"

    # Find shim binaries. Gentoo's sys-boot/shim installs under /usr/share/shim/
    # with a versioned subdir (e.g. /usr/share/shim/15.8/shimx64.efi), but a few
    # other paths exist depending on USE flags and overlays. Search broadly.
    local shim_src=""
    local mm_src=""
    local search_root
    for search_root in /usr/share/shim /usr/lib/shim /usr/lib64/shim \
                       /usr/share/shim-signed /usr/lib/shim-signed \
                       /usr/share/secureboot/shim; do
        [[ -d "${search_root}" ]] || continue
        shim_src=$(find "${search_root}" -name 'shimx64.efi' 2>/dev/null | head -1) || true
        [[ -n "${shim_src}" ]] && break
    done

    # If not found anywhere — verify the package is installed at all
    if [[ -z "${shim_src}" ]]; then
        if ! ls /var/db/pkg/sys-boot/shim-* &>/dev/null; then
            ewarn "sys-boot/shim package not installed — retrying emerge"
            try "Re-installing shim" emerge --quiet --usepkg=n sys-boot/shim || true
            # Search again post-emerge
            for search_root in /usr/share/shim /usr/lib/shim /usr/lib64/shim; do
                [[ -d "${search_root}" ]] || continue
                shim_src=$(find "${search_root}" -name 'shimx64.efi' 2>/dev/null | head -1) || true
                [[ -n "${shim_src}" ]] && break
            done
        fi
    fi

    # Last resort: dump where shim package thinks its files are
    if [[ -z "${shim_src}" ]] && command -v qfile &>/dev/null; then
        shim_src=$(qfile -Cf sys-boot/shim 2>/dev/null | grep -E 'shimx64\.efi$' | head -1) || true
    fi
    if [[ -z "${shim_src}" ]]; then
        local contents
        contents=$(ls /var/db/pkg/sys-boot/shim-*/CONTENTS 2>/dev/null | head -1) || true
        if [[ -n "${contents}" ]]; then
            shim_src=$(awk '/shimx64\.efi/ {print $2; exit}' "${contents}") || true
        fi
    fi

    if [[ -n "${shim_src}" ]]; then
        local shimdir
        shimdir=$(dirname "${shim_src}")
        mm_src="${shimdir}/mmx64.efi"
        einfo "Found shim at: ${shim_src}"
    fi

    if [[ -z "${shim_src}" ]]; then
        ewarn "shim EFI binary not found — Secure Boot chainloading may not work"
        ewarn "Manual fix post-install: emerge sys-boot/shim, find shimx64.efi,"
        ewarn "  cp to ${efi_dir}/shimx64.efi, efibootmgr --create with shim loader"
        return 0
    fi

    # Copy shim and MokManager to ESP
    cp "${shim_src}" "${efi_dir}/shimx64.efi"
    [[ -f "${mm_src}" ]] && cp "${mm_src}" "${efi_dir}/mmx64.efi"

    # Sign GRUB with our MOK key
    local grub_efi="${efi_dir}/grubx64.efi"
    if [[ -f "${grub_efi}" ]]; then
        try "Signing GRUB" \
            sbsign --key "${priv}" --cert "${cert}" --output "${grub_efi}" "${grub_efi}"
    fi

    # Create EFI boot entry for shim (chainloads signed GRUB)
    if command -v efibootmgr &>/dev/null; then
        # Find ESP disk and partition number
        local esp_dev="${ESP_PARTITION:-}"
        if [[ -n "${esp_dev}" ]]; then
            local esp_disk esp_partnum
            if [[ "${esp_dev}" =~ ^(/dev/nvme[0-9]+n[0-9]+)p([0-9]+)$ ]]; then
                esp_disk="${BASH_REMATCH[1]}"
                esp_partnum="${BASH_REMATCH[2]}"
            elif [[ "${esp_dev}" =~ ^(/dev/[a-z]+)([0-9]+)$ ]]; then
                esp_disk="${BASH_REMATCH[1]}"
                esp_partnum="${BASH_REMATCH[2]}"
            fi

            if [[ -n "${esp_disk:-}" && -n "${esp_partnum:-}" ]]; then
                # Remove existing "Gentoo (Secure Boot)" entries
                local bootnum
                while bootnum=$(efibootmgr 2>/dev/null | grep -i "Gentoo (Secure Boot)" | \
                    sed -n 's/^Boot\([0-9A-Fa-f]\{4\}\).*/\1/p' | head -1) && [[ -n "${bootnum}" ]]; do
                    efibootmgr --delete-bootnum --bootnum "${bootnum}" &>/dev/null || break
                done

                try "Creating Secure Boot EFI entry" \
                    efibootmgr --create --disk "${esp_disk}" --part "${esp_partnum}" \
                    --label "Gentoo (Secure Boot)" \
                    --loader "\\EFI\\gentoo\\shimx64.efi"
            fi
        fi
    fi

    einfo "Shim installed on ESP"
}

# _enroll_mok — Queue MOK key for enrollment at next reboot
_enroll_mok() {
    local key_dir="$1"
    local der="${key_dir}/MOK.der"

    if ! command -v mokutil &>/dev/null; then
        ewarn "mokutil not available — manual MOK enrollment required"
        return 0
    fi

    # Generate password hash for MOK enrollment (password: gentoo)
    # mokutil --import prompts for password — use --hash-file to automate
    local pw_hash_file
    pw_hash_file=$(mktemp /tmp/mok-pw-hash.XXXXXX)
    mokutil --generate-hash=gentoo > "${pw_hash_file}" 2>/dev/null || true

    if [[ -s "${pw_hash_file}" ]]; then
        # mokutil --import may fail when Secure Boot is disabled in firmware
        # (EFI variables not writable). This is expected — enrollment happens
        # via MokManager at first boot instead. Never abort on failure here.
        if mokutil --import "${der}" --hash-file "${pw_hash_file}" 2>/dev/null; then
            einfo "MOK queued for enrollment (password: gentoo)"
        else
            ewarn "mokutil --import failed (expected if Secure Boot is disabled)"
            ewarn "MOK enrollment will happen via MokManager at first boot"
        fi
        rm -f "${pw_hash_file}"
        if ! is_secureboot_active; then
            ewarn "Secure Boot is disabled — after enabling in BIOS/UEFI:"
            ewarn "  MokManager will appear -> Enroll MOK -> password: gentoo"
        fi
    else
        rm -f "${pw_hash_file}"
        ewarn "Could not generate MOK password hash — manual enrollment required"
        ewarn "MokManager will appear at first boot -> Enroll key from disk"
    fi
}
