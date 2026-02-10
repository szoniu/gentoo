#!/usr/bin/env bash
# network.sh — Network checks, mirror selection, NetworkManager installation
source "${LIB_DIR}/protection.sh"

# check_network — Verify network connectivity
check_network() {
    einfo "Checking network connectivity..."

    if has_network; then
        einfo "Network connectivity OK"
        return 0
    else
        eerror "No network connectivity"
        return 1
    fi
}

# install_network_manager — Install and enable NetworkManager
install_network_manager() {
    einfo "Installing NetworkManager..."

    try "Installing NetworkManager" emerge --quiet net-misc/networkmanager

    if [[ "${INIT_SYSTEM:-systemd}" == "systemd" ]]; then
        try "Enabling NetworkManager" systemctl enable NetworkManager
    else
        try "Enabling NetworkManager" rc-update add NetworkManager default
    fi

    # Disable other network managers to avoid conflicts
    if [[ "${INIT_SYSTEM:-systemd}" == "openrc" ]]; then
        local iface
        for iface in /etc/init.d/net.*; do
            [[ -e "${iface}" ]] || continue
            local name
            name=$(basename "${iface}")
            [[ "${name}" == "net.lo" ]] && continue
            rc-update del "${name}" default 2>/dev/null || true
        done
    fi

    einfo "NetworkManager installed and enabled"
}

# select_fastest_mirror — Test mirrors and select the fastest one
# This is optional and can be time-consuming
select_fastest_mirror() {
    local -a results=()
    local entry

    einfo "Testing mirror speeds..."

    for entry in "${GENTOO_MIRRORS[@]}"; do
        local url
        IFS='|' read -r url _ _ <<< "${entry}"

        # Test download speed (small file)
        local start_time end_time elapsed
        start_time=$(date +%s%N)
        if wget -q --timeout=5 -O /dev/null "${url}/snapshots/portage-latest.tar.bz2.md5sum" 2>/dev/null; then
            end_time=$(date +%s%N)
            elapsed=$(( (end_time - start_time) / 1000000 ))  # ms
            results+=("${elapsed}|${url}")
        fi
    done

    if [[ ${#results[@]} -eq 0 ]]; then
        ewarn "No mirrors responded, using default"
        echo "$(get_default_mirror)"
        return
    fi

    # Sort by speed and return fastest
    local fastest
    fastest=$(printf '%s\n' "${results[@]}" | sort -t'|' -k1 -n | head -1 | cut -d'|' -f2)
    einfo "Fastest mirror: ${fastest}"
    echo "${fastest}"
}
