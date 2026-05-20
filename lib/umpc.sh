#!/usr/bin/env bash
# umpc.sh — Runtime quirks for UMPCs (GPD Pocket/Win, Chuwi MiniBook X).
# Panel rotation for console + Wayland session is handled via GRUB cmdline
# in bootloader.sh. This module installs:
#   - ALC287 Auto-Mute disable (Pocket 4 speakers are silent without it)
#   - SDDM X11 greeter rotation (Xorg ignores the kernel panel_orientation
#     quirk, so the login screen alone stays portrait without this)
#   - POST-INSTALL note for gpd-fan-daemon (no Gentoo ebuild yet)
source "${LIB_DIR}/protection.sh"

# umpc_apply_quirks — Entry point called from chroot phase.
# All paths are relative to chroot root (we're already inside via chroot_exec).
umpc_apply_quirks() {
    [[ "${UMPC_DETECTED:-0}" == "1" ]] || return 0

    einfo "Applying UMPC runtime quirks for ${UMPC_VENDOR} ${UMPC_MODEL}..."

    if [[ "${UMPC_ALC287_QUIRK:-0}" == "1" ]]; then
        _umpc_install_alc287_unmute
    fi

    # SDDM's X11 greeter doesn't honor the kernel panel_orientation quirk
    # (only the console + Wayland session do), so the login screen stays
    # portrait. Rotate it explicitly via xrandr in Xsetup.
    if [[ -n "${UMPC_FBCON_ROTATE:-}" ]] && [[ "${UMPC_FBCON_ROTATE}" != "0" ]]; then
        _umpc_rotate_sddm_greeter
    fi

    if [[ "${UMPC_GPD_FAN:-0}" == "1" ]]; then
        _umpc_write_gpd_fan_note
    fi

    # Always emit a generic UMPC summary so users see what was done
    _umpc_append_summary
}

# _umpc_install_alc287_unmute — Auto-Mute Mode = Disabled at every boot.
# ALC287 on Pocket 4 (and many AMD Phoenix laptops) ships with Auto-Mute
# enabled by default, which routes audio nowhere unless a headphone jack
# is sensed correctly. The driver's jack detection is unreliable on this
# codec, so speakers stay silent. Fix: disable Auto-Mute via amixer at
# boot. amixer comes from media-sound/alsa-utils, which is pulled in by
# media-video/pipewire via RDEPEND on alsa-plugins.
_umpc_install_alc287_unmute() {
    einfo "  Installing ALC287 Auto-Mute disable service..."

    # The script itself — runs amixer commands. Card index 0 is the usual
    # internal HDA on these devices. Tolerate failure if the control names
    # differ on this specific codec revision.
    local script_path="/usr/local/sbin/alc287-unmute"
    cat > "${script_path}" << 'SCRIPTEOF'
#!/bin/sh
# alc287-unmute — Disable ALC287 Auto-Mute Mode and unmute Master/Speaker.
# Installed by the Gentoo installer for UMPCs with ALC287 quirks (GPD Pocket 4).
# Runs at every boot via systemd unit / OpenRC local.d.
set -u

# Wait briefly for the sound card to be enumerated (race with udev on boot).
for _ in 1 2 3 4 5; do
    if [ -e /proc/asound/card0 ]; then break; fi
    sleep 1
done

# Disable Auto-Mute (the actual fix). Tolerant of missing control.
amixer -c 0 sset 'Auto-Mute Mode' Disabled >/dev/null 2>&1 || true

# Unmute and raise common output controls. PipeWire sets userspace volumes
# separately; this just makes sure the hardware mixer isn't gating audio.
for ctl in 'Master' 'Speaker' 'Headphone' 'PCM'; do
    amixer -c 0 sset "${ctl}" unmute >/dev/null 2>&1 || true
    amixer -c 0 sset "${ctl}" '100%' >/dev/null 2>&1 || true
done

# Persist state so alsactl restore on next boot keeps it if alsa-restore runs.
alsactl store >/dev/null 2>&1 || true

exit 0
SCRIPTEOF
    chmod 0755 "${script_path}"

    if [[ "${INIT_SYSTEM}" == "systemd" ]]; then
        # Oneshot unit triggered after sound.target. RemainAfterExit so the
        # unit stays "active" once it succeeds (no repeated runs on probes).
        cat > /etc/systemd/system/alc287-unmute.service << 'UNITEOF'
[Unit]
Description=Disable ALC287 Auto-Mute and unmute outputs
After=sound.target
Wants=sound.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/alc287-unmute

[Install]
WantedBy=multi-user.target
UNITEOF
        try "Enabling alc287-unmute.service" systemctl enable alc287-unmute.service
    else
        # OpenRC: drop into local.d which is run by the 'local' service.
        # local is part of OpenRC and enabled by default in the default runlevel.
        mkdir -p /etc/local.d
        cat > /etc/local.d/alc287-unmute.start << 'LOCALEOF'
#!/bin/sh
/usr/local/sbin/alc287-unmute
LOCALEOF
        chmod 0755 /etc/local.d/alc287-unmute.start
    fi
}

# _umpc_rotate_sddm_greeter — Rotate the SDDM X11 login greeter.
# The kernel panel_orientation quirk (set in the GRUB cmdline) rotates the
# fbcon console and is honored by the Plasma *Wayland* session, but SDDM's
# greeter runs on Xorg, which ignores panel_orientation — so the login
# screen alone stays portrait on a UMPC. Fix: rotate it with xrandr from
# Xsetup. Two gotchas learned on a GPD Pocket 4:
#   - Xorg names the panel "eDP" (NOT the DRM name "eDP-1") — auto-detect
#     the connected output instead of hardcoding it.
#   - x11-apps/xrandr is NOT pulled in by plasma-meta; without it Xsetup
#     fails silently (command not found) and nothing rotates.
# fbcon rotate value -> xrandr rotation: 1=right (90 CW), 2=inverted,
# 3=left (90 CCW). Verified: Pocket 4 fbcon=rotate:1 <-> xrandr right.
_umpc_rotate_sddm_greeter() {
    # Only meaningful when SDDM is the display manager (Plasma). GDM's
    # Wayland greeter honors panel_orientation on its own.
    if [[ ! -d /usr/share/sddm ]]; then
        einfo "  No SDDM present — skipping greeter rotation"
        return 0
    fi

    local rot
    case "${UMPC_FBCON_ROTATE}" in
        1) rot="right" ;;
        2) rot="inverted" ;;
        3) rot="left" ;;
        *) return 0 ;;
    esac

    einfo "  Rotating SDDM greeter (xrandr --rotate ${rot})..."

    # xrandr is required and not pulled by plasma-meta.
    try "Installing x11-apps/xrandr (SDDM greeter rotation)" \
        emerge --quiet x11-apps/xrandr

    mkdir -p /usr/share/sddm/scripts
    cat > /usr/share/sddm/scripts/Xsetup << XSETUPEOF
#!/bin/sh
# Xsetup — rotate the SDDM X11 greeter to match the UMPC panel.
# Xorg names the internal panel "eDP" (not the DRM "eDP-1"), so detect
# the connected output rather than hardcoding it. Written by the Gentoo
# installer (umpc_quirks) for UMPCs with a rotated panel.
_out=\$(xrandr | awk '/ connected/{print \$1; exit}')
[ -n "\${_out}" ] && xrandr --output "\${_out}" --rotate ${rot}
XSETUPEOF
    chmod 0755 /usr/share/sddm/scripts/Xsetup
    einfo "  SDDM greeter rotation configured (output auto-detected, --rotate ${rot})"
}

# _umpc_write_gpd_fan_note — Append manual install instructions for
# gpd-fan-daemon to /root/POST-INSTALL-NOTES.txt. No ebuild exists in
# main or GURU, so we cannot auto-emerge. Without the daemon, fans run
# on ACPI defaults — usable but louder than Windows. The daemon enable
# step is init-system-specific: upstream ships a systemd unit only, so
# for OpenRC we document a hand-written openrc-run service instead.
_umpc_write_gpd_fan_note() {
    einfo "  Writing GPD fan daemon POST-INSTALL note..."

    mkdir -p /root
    local notes=/root/POST-INSTALL-NOTES.txt
    touch "${notes}"
    chmod 0600 "${notes}"

    cat >> "${notes}" << NOTEEOF

=== GPD Fan Control (${UMPC_MODEL}) ===

The installer did NOT install a userspace fan daemon — there is no
Gentoo ebuild for gpd-fan-daemon yet. Fans currently run on ACPI table
defaults: usable, but louder/more aggressive than under Windows.

To set up smarter fan curves manually post-install:

1. Kernel module (gpd-fan):
     # emerge --ask sys-kernel/dkms
     git clone https://github.com/Cryolitia/gpd-fan-driver /usr/src/gpd-fan-1.0.0
     dkms add -m gpd-fan -v 1.0.0
     dkms autoinstall

2. Userspace daemon (gpd-fan-daemon):
     # emerge --ask dev-lang/rust virtual/cargo
     git clone https://github.com/Cryolitia/gpd-fan-daemon
     cd gpd-fan-daemon
     cargo build --release
     install -m 0755 target/release/gpd-fan-daemon /usr/local/sbin/

NOTEEOF

    if [[ "${INIT_SYSTEM}" == "openrc" ]]; then
        cat >> "${notes}" << 'NOTEEOF'
3. Enable the daemon (OpenRC) — upstream ships only a systemd unit,
   so create an openrc-run service. Paste this block flush-left:

cat > /etc/init.d/gpd-fan-daemon << 'EOF'
#!/sbin/openrc-run
name="gpd-fan-daemon"
description="GPD fan curve daemon"
command="/usr/local/sbin/gpd-fan-daemon"
command_background="yes"
pidfile="/run/gpd-fan-daemon.pid"

depend() {
	after modules
}
EOF
chmod 0755 /etc/init.d/gpd-fan-daemon
rc-update add gpd-fan-daemon default
rc-service gpd-fan-daemon start

NOTEEOF
    else
        cat >> "${notes}" << 'NOTEEOF'
3. Enable the daemon (systemd):
     install -m 0644 gpd-fan-daemon.service /etc/systemd/system/
     systemctl enable --now gpd-fan-daemon.service

NOTEEOF
    fi

    cat >> "${notes}" << 'NOTEEOF'
For temperature/fan monitoring without the daemon:
     # emerge --ask sys-apps/lm-sensors
     sensors-detect --auto
     sensors

NOTEEOF
}

# _umpc_append_summary — Document everything we applied so the user can
# audit it after reboot.
_umpc_append_summary() {
    mkdir -p /root
    local notes=/root/POST-INSTALL-NOTES.txt
    touch "${notes}"
    chmod 0600 "${notes}"

    cat >> "${notes}" << NOTEEOF

=== UMPC Quirks Applied (${UMPC_VENDOR} ${UMPC_MODEL}) ===

NOTEEOF

    if [[ -n "${UMPC_PANEL_ORIENTATION:-}" ]]; then
        cat >> "${notes}" << NOTEEOF
- Panel rotation: added to /etc/default/grub:
    fbcon=rotate:${UMPC_FBCON_ROTATE} video=${UMPC_VIDEO_CONNECTOR}:panel_orientation=${UMPC_PANEL_ORIENTATION}
  If rotation is wrong: try left_side_up instead of right_side_up, or
  change fbcon=rotate to 3. Edit /etc/default/grub, then
  'grub-mkconfig -o /boot/grub/grub.cfg'.

NOTEEOF
    fi

    if [[ "${UMPC_ALC287_QUIRK:-0}" == "1" ]]; then
        cat >> "${notes}" << NOTEEOF
- ALC287 speakers: alc287-unmute service installed
  (/usr/local/sbin/alc287-unmute, runs at every boot)
  If still quiet: 'alsamixer' → F6 select card → unmute everything,
  then 'alsactl store'.

NOTEEOF
    fi
}
