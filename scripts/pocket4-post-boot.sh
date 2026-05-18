#!/bin/bash
#
# pocket4-post-boot.sh — Manual post-install fixes for GPD Pocket 4
#
# Run ONCE as root after the first successful boot into the installed
# Gentoo system (and after removing the install USB stick).
#
# What the installer ALREADY does automatically (do NOT redo here):
#   - GRUB / early-boot landscape rotation (fbcon + panel_orientation
#     kernel cmdline, lib/bootloader.sh)
#   - Plasma/KWin orientation (DRM panel_orientation property)
#   - ALC287 audio Auto-Mute fix (umpc_quirks phase)
#   - MXC4005 accelerometer kernel module
#
# What is STILL manual and handled by this script:
#   1. Accelerometer mount-matrix hwdb (auto-rotation calibration)
#   2. iio-sensor-proxy service enablement on OpenRC
#   3. Phantom GRUB entry cleanup (os-prober on the USB Live ISO)
#   4. Deselect cosmetic packages unused on Pocket 4 (iGPU-only AMD)
#
# Not covered (decision / GUI / separate topic):
#   - Plasma display scale: System Settings -> Display -> Scale -> 175%
#   - GPD fan daemon: see /root/POST-INSTALL-NOTES.txt
#
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
	echo "Run as root." >&2
	exit 1
fi

echo ">> 1/4 Accelerometer mount-matrix hwdb (MXC6655)"
mkdir -p /etc/udev/hwdb.d
cat > /etc/udev/hwdb.d/61-sensor-pocket4.hwdb << 'EOF'
# GPD Pocket 4 (product_name G1628-04) — Memsic MXC6655 accelerometer.
# If auto-rotation goes the wrong way, swap signs in the matrix below
# (4 combinations cover every orientation), then re-run:
#   udevadm hwdb --update && udevadm trigger
sensor:modalias:acpi:MXC6655*:dmi:*svnGPD*pn*G1628-04*
 ACCEL_MOUNT_MATRIX=0, -1, 0; -1, 0, 0; 0, 0, 1
EOF
udevadm hwdb --update
udevadm trigger

echo ">> 2/4 iio-sensor-proxy service"
if command -v rc-update >/dev/null 2>&1; then
	# OpenRC: iio-sensor-proxy does not auto-start (no systemd/udev unit).
	rc-update add iio-sensor-proxy default || true
	rc-service iio-sensor-proxy start || true
else
	echo "   systemd: iio-sensor-proxy auto-started via udev, nothing to do"
fi

echo ">> 3/4 Regenerating grub.cfg (drops phantom os-prober USB entry)"
grub-mkconfig -o /boot/grub/grub.cfg

echo ">> 4/4 Deselecting cosmetic packages unused on Pocket 4"
# Pocket 4 is iGPU-only AMD: legacy ATI DDX and hybrid-GPU switcher are
# dead weight. Deselect only — depclean is left for the user to review.
emerge --deselect x11-drivers/xf86-video-ati sys-power/switcheroo-control || true

cat << 'EOF'

Done. Manual follow-ups:
  - Review/remove now-orphaned deps:   emerge --ask --depclean
  - Plasma scale (8.8" ~330 DPI):      System Settings -> Display -> Scale -> 175%
  - GPD fan daemon:                    cat /root/POST-INSTALL-NOTES.txt

Verification (checks, not actions):
  dmesg | grep -i microcode    # expect "microcode updated early"
  bluetoothctl show            # expect Powered: yes
EOF
