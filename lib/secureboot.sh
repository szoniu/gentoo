#!/usr/bin/env bash
# secureboot.sh — Secure Boot: MOK key generation, kernel signing, shim setup
source "${LIB_DIR}/protection.sh"

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

    # 4. Sign existing kernels
    _sign_kernels "${key_dir}"

    # 5. Setup shim on ESP
    _setup_shim "${key_dir}"

    # 6. Queue MOK enrollment (password: gentoo)
    _enroll_mok "${key_dir}"

    einfo "Secure Boot setup complete"
    einfo "At first reboot: MokManager will appear → Enroll MOK → password: gentoo"
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

    # Find shim binaries (location varies by package version)
    local shim_src=""
    local mm_src=""
    local shimdir
    for shimdir in /usr/share/shim /usr/lib/shim /usr/lib64/shim; do
        if [[ -f "${shimdir}/shimx64.efi" ]]; then
            shim_src="${shimdir}/shimx64.efi"
            mm_src="${shimdir}/mmx64.efi"
            break
        fi
    done

    if [[ -z "${shim_src}" ]]; then
        ewarn "shim EFI binary not found — Secure Boot chainloading may not work"
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
    # Ensure temp file is cleaned up on exit (contains sensitive hash)
    trap 'rm -f "${pw_hash_file}"' EXIT
    mokutil --generate-hash=gentoo > "${pw_hash_file}" 2>/dev/null || true

    if [[ -s "${pw_hash_file}" ]]; then
        try "Queuing MOK enrollment" \
            mokutil --import "${der}" --hash-file "${pw_hash_file}"
        rm -f "${pw_hash_file}"
        trap - EXIT
        einfo "MOK queued for enrollment (password: gentoo)"
    else
        rm -f "${pw_hash_file}"
        trap - EXIT
        ewarn "Could not generate MOK password hash — manual enrollment required"
        ewarn "Run: mokutil --import '${der}'"
    fi
}
