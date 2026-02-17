#!/usr/bin/env bash
# tui/ssh_monitor.sh — Optional SSH server on Live ISO for remote monitoring
source "${LIB_DIR}/protection.sh"

screen_ssh_monitor() {
    # Skip if no network or no sshd binary
    if ! has_network 2>/dev/null; then
        einfo "No network — skipping SSH monitor setup"
        return "${TUI_NEXT}"
    fi

    if ! command -v sshd &>/dev/null; then
        einfo "sshd not available — skipping SSH monitor setup"
        return "${TUI_NEXT}"
    fi

    # Ask user
    if ! dialog_yesno "Live SSH Monitor" \
        "Enable SSH on this Live ISO for remote monitoring?\n\n\
This lets you monitor the installation from another computer\n\
(tail logs, check top, etc.).\n\n\
This is NOT the same as enabling SSH on the installed system.\n\
It only affects this live session."; then
        return "${TUI_NEXT}"
    fi

    # Password setup
    local ssh_pass1 ssh_pass2
    while true; do
        ssh_pass1=$(dialog_passwordbox "SSH Password" \
            "Set a temporary root password for SSH access:") || return "${TUI_NEXT}"

        if [[ -z "${ssh_pass1}" ]]; then
            dialog_msgbox "Error" "Password cannot be empty."
            continue
        fi

        ssh_pass2=$(dialog_passwordbox "SSH Password" \
            "Confirm password:") || return "${TUI_NEXT}"

        if [[ "${ssh_pass1}" != "${ssh_pass2}" ]]; then
            dialog_msgbox "Error" "Passwords do not match. Try again."
            continue
        fi

        break
    done

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        einfo "[DRY-RUN] Would start sshd on Live ISO"
        dialog_msgbox "SSH (Dry Run)" \
            "Would start SSH server on Live ISO.\n\nSkipped in dry-run mode."
        return "${TUI_NEXT}"
    fi

    # Set root password
    echo "root:${ssh_pass1}" | chpasswd 2>/dev/null

    # Enable PermitRootLogin
    local sshd_config="/etc/ssh/sshd_config"
    if [[ -f "${sshd_config}" ]]; then
        sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' "${sshd_config}"
    fi

    # Start sshd
    local sshd_started=0
    if command -v rc-service &>/dev/null; then
        rc-service sshd start 2>/dev/null && sshd_started=1
    elif command -v systemctl &>/dev/null; then
        systemctl start sshd 2>/dev/null && sshd_started=1
    fi

    if [[ "${sshd_started}" -eq 0 ]]; then
        # Direct fallback
        /usr/sbin/sshd 2>/dev/null && sshd_started=1
    fi

    # Detect IP address
    local ip_addr
    ip_addr=$(ip -4 addr show 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | grep -v '^127\.' | head -1) || true

    if [[ "${sshd_started}" -eq 1 ]]; then
        dialog_msgbox "SSH Active" \
            "SSH server is running on this Live ISO.\n\n\
Connect from another computer:\n\
  ssh root@${ip_addr:-<your-IP>}\n\n\
Useful commands once connected:\n\
  tail -f /tmp/gentoo-installer.log\n\
  tail -f /mnt/gentoo/tmp/gentoo-installer.log\n\
  tail -f /mnt/gentoo/var/log/genkernel.log\n\
  top\n\
  dmesg | grep -i 'oom\\|killed'"
    else
        dialog_msgbox "SSH Failed" \
            "Could not start SSH server automatically.\n\n\
You can start it manually on TTY2 (Ctrl+Alt+F2):\n\
  echo 'root:yourpassword' | chpasswd\n\
  rc-service sshd start\n\
  ip addr"
    fi

    einfo "SSH monitor setup complete"
    return "${TUI_NEXT}"
}
