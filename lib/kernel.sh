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

# _set_kernel_keyword — Record the ~amd64 keyword for the chosen kernel source
# package and DROP the keyword line of the other one. The keyword file was
# previously append-only: switching dist-kernel ⇄ genkernel left BOTH
# "sys-kernel/gentoo-kernel-bin ~amd64" and "sys-kernel/gentoo-sources ~amd64"
# behind, which then made _infer_from_kernel_keywords (resume/inference)
# mis-detect the kernel type (it checks gentoo-kernel-bin first and returns).
# Surface keywords live in a separate file (package.accept_keywords/surface-*)
# and are intentionally untouched here.
_set_kernel_keyword() {
    local keep="$1" drop="$2"
    local kw_file="/etc/portage/package.accept_keywords/kernel"
    mkdir -p /etc/portage/package.accept_keywords
    if [[ -f "${kw_file}" ]]; then
        sed -i "\|^${drop} |d" "${kw_file}" 2>/dev/null || true
    fi
    grep -qxF "${keep} ~amd64" "${kw_file}" 2>/dev/null || \
        echo "${keep} ~amd64" >> "${kw_file}" 2>/dev/null || true
}

# _apply_surface_config_fragment — Apply official linux-surface config fragment
# The fragment sets critical options like SERIAL_DEV_BUS=y, SAM modules,
# camera drivers, IPTS/ITHC, sensors, etc. Without this, battery and other
# Surface hardware may not work even with patches applied.
_apply_surface_config_fragment() {
    local kconfig="/usr/src/linux/.config"
    [[ -f "${kconfig}" ]] || return 0

    # Find config fragment from linux-surface (overlay or /tmp clone)
    local kernel_version patchlevel surface_config=""
    kernel_version=$(sed -n 's/^VERSION = //p' /usr/src/linux/Makefile 2>/dev/null) || true
    patchlevel=$(sed -n 's/^PATCHLEVEL = //p' /usr/src/linux/Makefile 2>/dev/null) || true

    # Check linux-surface overlay first, then /tmp clone
    local search_dirs=(
        "/var/db/repos/linux-surface/configs"
        "/tmp/linux-surface/configs"
    )
    local dir
    for dir in "${search_dirs[@]}"; do
        if [[ -f "${dir}/surface-${kernel_version}.${patchlevel}.config" ]]; then
            surface_config="${dir}/surface-${kernel_version}.${patchlevel}.config"
            break
        fi
    done
    # Fallback to highest available
    if [[ -z "${surface_config}" ]]; then
        for dir in "${search_dirs[@]}"; do
            surface_config=$(ls "${dir}"/surface-*.config 2>/dev/null | sort -V | tail -1) || true
            [[ -n "${surface_config}" ]] && break
        done
    fi

    if [[ -n "${surface_config}" && -f "${surface_config}" ]]; then
        einfo "Applying surface config fragment: $(basename "${surface_config}")"
        # Remove conflicting keys then append fragment
        while IFS= read -r line; do
            [[ -z "${line}" || "${line}" == \#* ]] && continue
            local key="${line%%=*}"
            sed -i "/^${key}[=]/d" "${kconfig}" 2>/dev/null
            sed -i "/^# ${key} /d" "${kconfig}" 2>/dev/null
        done < "${surface_config}"
        cat "${surface_config}" >> "${kconfig}"
        # Force critical options
        sed -i 's/^CONFIG_SERIAL_DEV_BUS=m/CONFIG_SERIAL_DEV_BUS=y/' "${kconfig}"
        grep -q "CONFIG_SERIAL_DEV_CTRL_TTYPORT=y" "${kconfig}" || echo "CONFIG_SERIAL_DEV_CTRL_TTYPORT=y" >> "${kconfig}"
    else
        ewarn "No linux-surface config fragment found — applying manual fixes"
        sed -i 's/^CONFIG_SERIAL_DEV_BUS=m/CONFIG_SERIAL_DEV_BUS=y/' "${kconfig}"
        echo "CONFIG_SERIAL_DEV_CTRL_TTYPORT=y" >> "${kconfig}"
    fi
}

# _patch_kernel_config — Enable essential modules that genkernel defconfig misses
# Genkernel uses defconfig which may lack drivers for modern laptop hardware.
# This patches .config BEFORE genkernel builds, so modules are included.
_patch_kernel_config() {
    local kconfig="/usr/src/linux/.config"

    # Generate config if not present. During first install, defconfig is fine
    # because there's no previous kernel. For updates, dotfiles wizard uses
    # the previous kernel's config from /etc/kernels/ instead.
    if [[ ! -f "${kconfig}" ]]; then
        make -C /usr/src/linux defconfig &>/dev/null || true
    fi

    [[ -f "${kconfig}" ]] || return 0

    # localmodconfig — restrict build to currently loaded modules (lsmod).
    # Reduces module count from ~3000 (defconfig default) to ~200-400, cutting
    # genkernel build time from 30-60 min to 5-10 min. Safe because the hardware
    # patch below re-adds essential drivers (NVMe, I2C HID, BT, ThinkPad,
    # Surface, etc.) regardless of lsmod, so critical modules can't get pruned.
    #
    # Heuristic: skip if lsmod shows < 50 modules (degenerate live ISO or
    # pre-chroot context where /proc/modules might not be representative of
    # what target needs). Most Gentoo Minimal Install ISOs load 100+ modules,
    # so this triggers in practice only when something is wrong.
    #
    # Edge case: a user installing from a non-Gentoo live ISO with different
    # hardware drivers than target — niche modules may be cut. The hardware
    # patch covers common laptop scenarios; truly niche cases require a kernel
    # rebuild post-install (which dotfiles wizard's _gentoo_update handles).
    local _mod_count
    _mod_count=$(lsmod 2>/dev/null | tail -n +2 | wc -l 2>/dev/null || echo 0)
    if [[ "${_mod_count}" -ge 50 ]]; then
        local _before _after
        _before=$(grep -c '=m$' "${kconfig}" 2>/dev/null || echo 0)
        einfo "Optimizing config: localmodconfig (${_mod_count} modules currently loaded)..."
        yes "" | make -C /usr/src/linux localmodconfig &>/dev/null || true
        _after=$(grep -c '=m$' "${kconfig}" 2>/dev/null || echo 0)
        einfo "  Modules: ${_before} → ${_after} (only currently used retained)"
    else
        einfo "Skipping localmodconfig — only ${_mod_count} modules loaded (live ISO not representative)"
    fi

    einfo "Patching kernel config based on detected hardware..."

    # Always-on: essential for any modern laptop
    local -A required_modules=(
        # NVMe storage (must be built-in, not module — needed before root mount)
        [CONFIG_BLK_DEV_NVME]="y"
        # Intel VMD / RST "RAID On" — Dell XPS, many Lenovo/HP laptops ship
        # with the NVMe behind the VMD controller by default; without this
        # the disk is invisible. Built-in (same reason as NVMe). The common
        # footgun: user installs after switching BIOS to AHCI, then reverts
        # to RAID On for a Windows dual-boot → unbootable. Harmless w/o VMD.
        [CONFIG_VMD]="y"
        # eMMC storage — UMPCs/tablets (Chuwi MiniBook X, GPD, x86 tablets) boot
        # from /dev/mmcblk0, not NVMe. Must be built-in for the same reason as
        # NVMe: defconfig ships SDHCI_ACPI as =m and localmodconfig (run from a
        # USB-booted live ISO that never touched the eMMC) prunes it → kernel
        # panic "unable to mount root fs". Harmless on machines without eMMC.
        [CONFIG_MMC]="y"
        [CONFIG_MMC_BLOCK]="y"
        [CONFIG_MMC_SDHCI]="y"
        [CONFIG_MMC_SDHCI_PCI]="y"
        [CONFIG_MMC_SDHCI_ACPI]="y"
        # I2C HID touchpads (ThinkPad, Dell XPS, HP, Framework, most modern laptops)
        [CONFIG_I2C_HID_ACPI]="m"
        [CONFIG_I2C_DESIGNWARE_PLATFORM]="m"
        [CONFIG_I2C_DESIGNWARE_CORE]="m"
        # HID multitouch (touchscreens, precision touchpads)
        [CONFIG_HID_MULTITOUCH]="m"
        # Wacom AES/EMR pen (2-in-1 / convertible digitizers — Yoga, etc.).
        # Harmless without a Wacom digitizer.
        [CONFIG_HID_WACOM]="m"
        # 2-in-1 convertible: SW_TABLET_MODE switch (laptop/tablet/tent/
        # stand), rotation-lock + volume/power buttons in tablet mode. Bind
        # only via the ACPI HID — harmless on regular clamshells. Without
        # these a convertible behaves like a plain laptop.
        [CONFIG_INTEL_VBTN]="m"
        [CONFIG_INTEL_HID]="m"
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
        einfo "  Intel CPU detected — adding i915, SOF audio, pinctrl"
        required_modules[CONFIG_DRM_I915]="m"
        required_modules[CONFIG_SND_SOC_SOF_TOPLEVEL]="y"
        required_modules[CONFIG_SND_SOC_SOF_PCI_DEV]="m"
        required_modules[CONFIG_SND_SOC_SOF_INTEL_TOPLEVEL]="y"
        # Intel pinctrl — symmetric to CONFIG_PINCTRL_AMD below. The I2C/GPIO
        # controller behind the I2C-HID touchpad needs this; without it the
        # touchpad IRQ never fires (e.g. Dell XPS 13 Plus on a stray ISO).
        required_modules[CONFIG_PINCTRL_INTEL]="y"
        required_modules[CONFIG_PINCTRL_ALDERLAKE]="m"
        required_modules[CONFIG_PINCTRL_TIGERLAKE]="m"
        # Meteor/Lunar Lake (Core Ultra — ROG Zephyrus G16 GU605 2024 etc.)
        # have their own pinctrl; without it the I2C-HID touchpad/sensors
        # GPIO never comes up on a genkernel build.
        required_modules[CONFIG_PINCTRL_METEORLAKE]="m"
        required_modules[CONFIG_PINCTRL_LUNARLAKE]="m"
    fi

    # UMPC audio: Chuwi MiniBook X (and many low-cost Intel UMPCs/x86 tablets)
    # use the Everest ES8336 codec on an SSP/I2C link driven by SOF. The
    # generic SOF toplevel above is necessary but NOT sufficient — the speakers
    # stay silent without the ES8336 machine driver + ES8316 codec, which
    # defconfig leaves =n and localmodconfig can't recover. olddefconfig pulls
    # in the SOF/HDA machine deps. Harmless module on devices without ES8336.
    if [[ "${UMPC_DETECTED:-0}" == "1" ]]; then
        einfo "  UMPC detected — adding ES8336 SOF audio machine driver"
        required_modules[CONFIG_SND_SOC_ES8316]="m"
        required_modules[CONFIG_SND_SOC_INTEL_SOF_ES8336_MACH]="m"
    fi

    # Cirrus CS35L41 smart-amp speakers (Dell XPS 13 Plus, many Dell/Lenovo
    # /HP laptops) — exposed as the ACPI HID CSC3551 with multiple amp
    # instances bound via serial-multi-instantiate. Vendor-agnostic gate on
    # the ACPI device. Without these the speakers are silent (headphone jack
    # via plain HDA/SOF may still work). olddefconfig pulls the machine deps.
    # CSC335x (Dell/ASUS/HP) or CLSA01xx (Lenovo ThinkPad X1 / Yoga —
    # CLSA0100/CLSA0101 depending on SKU).
    if ls -d /sys/bus/acpi/devices/CSC335*:* &>/dev/null 2>&1 || \
       ls -d /sys/bus/acpi/devices/CLSA01*:* &>/dev/null 2>&1; then
        einfo "  CS35L41 smart-amp detected — adding codec + SSP AMP machine"
        required_modules[CONFIG_SND_SOC_CS35L41]="m"
        required_modules[CONFIG_SND_SOC_CS35L41_SPI]="m"
        required_modules[CONFIG_SND_SOC_CS35L41_I2C]="m"
        required_modules[CONFIG_SERIAL_MULTI_INSTANTIATE]="m"
        required_modules[CONFIG_SND_SOC_INTEL_SOF_CS35L41_MACH]="m"
    fi

    # Intel IPU6 MIPI camera (Tiger/Alder/Raptor/Meteor/Lunar Lake — modern
    # ThinkPad X1, Dell, HP). NOT a USB UVC webcam; needs the IPU6 driver +
    # the INT3472 power/clock bridge + IPU bridge + the MEI Visual Sensing
    # Controller + the actual sensor driver. defconfig leaves these =n and
    # localmodconfig can't recover them. userspace (libcamera/pipewire) is
    # handled in desktop.sh; this just makes the kernel side present.
    if lspci -nn 2>/dev/null | grep -qiE '\[8086:(7d19|9a19|465d|a75d|645d|7d99)\]|image (signal )?process'; then
        einfo "  Intel IPU6 camera detected — adding ipu6/INT3472/VSC + sensors"
        required_modules[CONFIG_VIDEO_INTEL_IPU6]="m"
        required_modules[CONFIG_IPU_BRIDGE]="m"
        required_modules[CONFIG_INTEL_SKL_INT3472]="m"
        required_modules[CONFIG_INTEL_MEI_VSC]="m"
        required_modules[CONFIG_INTEL_MEI_VSC_HW]="m"
        required_modules[CONFIG_INTEL_VSC]="m"
        # Common X1/Dell/HP front sensors
        required_modules[CONFIG_VIDEO_OV02C10]="m"
        required_modules[CONFIG_VIDEO_OV2740]="m"
        required_modules[CONFIG_VIDEO_OV01A10]="m"
        required_modules[CONFIG_VIDEO_HI556]="m"
        # Dell Latitude/Precision and some Lenovo/HP SKUs use other sensors
        required_modules[CONFIG_VIDEO_OV05C10]="m"
        required_modules[CONFIG_VIDEO_OV08X40]="m"
        required_modules[CONFIG_VIDEO_OV13B10]="m"
    fi

    # AMD CPU → pinctrl for I2C bus + SOF/ACP audio. Modern AMD laptops
    # (Framework 13 AMD, Ryzen 7040 "Phoenix"/Rembrandt/Renoir) route audio
    # through the AMD Audio Co-Processor via SOF. Symmetric to the Intel SOF
    # block above — without these genkernel builds a kernel with no sound.
    # olddefconfig pulls the ACP machine deps. Harmless on AMD without ACP.
    if grep -qi 'AuthenticAMD' /proc/cpuinfo 2>/dev/null; then
        einfo "  AMD CPU detected — adding PINCTRL_AMD, SOF/ACP audio"
        required_modules[CONFIG_PINCTRL_AMD]="m"
        required_modules[CONFIG_SND_SOC_SOF_AMD_TOPLEVEL]="y"
        required_modules[CONFIG_SND_SOC_SOF_AMD_RENOIR]="m"
        required_modules[CONFIG_SND_SOC_SOF_AMD_REMBRANDT]="m"
        required_modules[CONFIG_SND_SOC_SOF_AMD_ACP63]="m"
        required_modules[CONFIG_SND_SOC_AMD_ACP_COMMON]="m"
    fi

    # AMD GPU detected — force amdgpu/radeon DRM so localmodconfig can't prune
    # them when installing from a live ISO that doesn't load them (rare but possible)
    if [[ "${GPU_VENDOR:-}" == "amd" ]] || [[ "${IGPU_VENDOR:-}" == "amd" ]] || [[ "${DGPU_VENDOR:-}" == "amd" ]]; then
        einfo "  AMD GPU detected — adding DRM_AMDGPU, DRM_RADEON"
        required_modules[CONFIG_DRM]="y"
        required_modules[CONFIG_DRM_AMDGPU]="m"
        required_modules[CONFIG_DRM_RADEON]="m"
        required_modules[CONFIG_FB_EFI]="y"
    fi

    # Fingerprint reader detected — UHID needed for libfprint communication
    if [[ "${FINGERPRINT_DETECTED:-0}" == "1" ]]; then
        einfo "  Fingerprint reader detected — adding UHID"
        required_modules[CONFIG_UHID]="m"
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

    # HP detected (DMI) — hp-wmi drives Fn keys, keyboard backlight, rfkill
    # and the thermal platform_profile (performance/quiet — important on HP
    # Omen gaming laptops). localmodconfig on a live ISO that never loaded
    # hp_wmi would otherwise prune it. Symmetric to ThinkPad/ASUS above.
    if grep -qiE 'HP|Hewlett-Packard' /sys/class/dmi/id/sys_vendor 2>/dev/null; then
        einfo "  HP detected — adding HP_WMI"
        required_modules[CONFIG_HP_WMI]="m"
    fi

    # Dell detected (DMI) — dell-laptop/dell-wmi/dell-smbios drive Fn keys,
    # keyboard backlight, battery charge thresholds, rfkill, and on Latitude/
    # Precision the hardware Privacy mic/camera mute LED + kill switch.
    # localmodconfig on a live ISO that never loaded them would prune them.
    # Symmetric to ThinkPad/HP/ASUS above.
    if grep -qi 'Dell' /sys/class/dmi/id/sys_vendor 2>/dev/null; then
        einfo "  Dell detected — adding DELL_LAPTOP/WMI/SMBIOS"
        required_modules[CONFIG_DELL_LAPTOP]="m"
        required_modules[CONFIG_DELL_WMI]="m"
        required_modules[CONFIG_DELL_SMBIOS]="m"
        required_modules[CONFIG_DELL_SMBIOS_WMI]="y"
        required_modules[CONFIG_DELL_SMBIOS_SMM]="y"
        required_modules[CONFIG_DELL_RBTN]="m"
        required_modules[CONFIG_DELL_WMI_PRIVACY]="y"
    fi

    # Lenovo non-ThinkPad (Yoga/IdeaPad/Legion) — ideapad-laptop drives Fn
    # keys, battery conservation mode, rfkill/airplane, camera privacy
    # toggle and FnLock. The ThinkPad block above is gated on "ThinkPad" in
    # product_family so it never fires here. Harmless on ThinkPad (won't
    # bind). Symmetric to HP/Dell/ASUS.
    if grep -qi 'LENOVO' /sys/class/dmi/id/sys_vendor 2>/dev/null; then
        einfo "  Lenovo detected — adding IDEAPAD_LAPTOP"
        required_modules[CONFIG_IDEAPAD_LAPTOP]="m"
    fi

    # NVIDIA GPU detected — ensure DRM support for nvidia-drivers
    if [[ "${GPU_VENDOR:-}" == "nvidia" ]] || [[ "${DGPU_VENDOR:-}" == "nvidia" ]]; then
        einfo "  NVIDIA GPU detected — adding DRM, FB_EFI"
        required_modules[CONFIG_DRM]="y"
        required_modules[CONFIG_DRM_FBDEV_EMULATION]="y"
        required_modules[CONFIG_FB_EFI]="y"
    fi

    # IIO sensors — accelerometer/gyro/ALS for screen auto-rotation. Also
    # force this for a detected convertible even if the live ISO didn't
    # load the accel (hid-sensor-hub/ISH): otherwise SENSORS_DETECTED=0 and
    # a 2-in-1 ships with no auto-rotation (chicken-and-egg).
    if [[ "${SENSORS_DETECTED:-0}" == "1" || "${CONVERTIBLE_DETECTED:-0}" == "1" ]]; then
        einfo "  IIO sensors / convertible — adding HID_SENSOR + accel modules"
        required_modules[CONFIG_HID_SENSOR_HUB]="m"
        required_modules[CONFIG_HID_SENSOR_ACCEL_3D]="m"
        required_modules[CONFIG_HID_SENSOR_GYRO_3D]="m"
        required_modules[CONFIG_HID_SENSOR_ALS]="m"
        required_modules[CONFIG_HID_SENSOR_INCLINOMETER_3D]="m"
        # Intel Sensor Hub (ISH) — modern ThinkPad/Yoga route orientation
        # through ISH, not raw i2c-hid.
        required_modules[CONFIG_INTEL_ISH_HID]="m"
        # Memsic MXC4005/MXC6655 — Goodix-era I2C accelerometer used by GPD Pocket,
        # Surface Go 1, many low-cost x86 tablets. Not covered by HID_SENSOR_*.
        required_modules[CONFIG_MXC4005]="m"
        required_modules[CONFIG_BMA180]="m"
        required_modules[CONFIG_KXCJK1013]="m"
    fi

    # WiFi by vendor — defconfig has these, but localmodconfig can prune them
    # when installing from a live ISO with a different WiFi chip loaded.
    # Match "Wireless"/"Wi-Fi"/bare "WiFi" (Meteor Lake CNVi reports
    # "...CNVi WiFi" — no separator) and the Intel CNVi/BE200/AX PCI ids
    # (8086:272b BE200, 7e40/7f70 MTL CNVi, 51f0/54f0 ADL/RPL) so a stale
    # pci.ids on the live ISO ("Device [8086:272b]") doesn't lose WiFi.
    if lspci -nn 2>/dev/null | grep -qiE 'intel.*(wireless|wi-?fi)|\[8086:(272b|7e40|7f70|51f0|54f0|7af0|a0f0|43f0|2725)\]'; then
        einfo "  Intel WiFi detected — adding iwlwifi"
        required_modules[CONFIG_IWLWIFI]="m"
        required_modules[CONFIG_IWLMVM]="m"
    fi
    # Match bare "mediatek" or the 14c3 PCI vendor id too — on a live ISO
    # without a fresh pci.ids, MT7922 shows as "MEDIATEK Corp. Device 0616"
    # (no Wireless/Wi-Fi/MT79 string) and the old regex missed it → no WiFi.
    if lspci -nn 2>/dev/null | grep -qiE 'mediatek|\[14c3:'; then
        einfo "  MediaTek WiFi detected — adding mt76 (MT7921E/MT7925E)"
        required_modules[CONFIG_MT7921E]="m"
        required_modules[CONFIG_MT7925E]="m"
    fi
    if lspci -nn 2>/dev/null | grep -qiE 'realtek.*(8852|8821|8822)'; then
        einfo "  Realtek WiFi detected — adding rtw89 (all 8852 variants)"
        required_modules[CONFIG_RTW89]="m"
        required_modules[CONFIG_RTW89_8852CE]="m"
        # Lenovo Legion and many others ship 8852BE/8852AE, not only CE.
        # localmodconfig keeps just the loaded one; force all so genkernel
        # has WiFi regardless of the exact card variant.
        required_modules[CONFIG_RTW89_8852BE]="m"
        required_modules[CONFIG_RTW89_8852AE]="m"
        required_modules[CONFIG_RTW89_8822CE]="m"
        required_modules[CONFIG_RTW89_8821CE]="m"
    fi
    # Broadcom WiFi (Intel MacBooks: BCM4360/BCM43602/BCM4364, also some PC
    # laptops). brcmfmac covers BCM43602/4364; BCM4360 often still needs the
    # proprietary net-wireless/broadcom-sta (wl) — see the Apple POST-INSTALL
    # note. Gate on a Broadcom *network controller* (not tg3 ethernet) or Mac.
    if [[ "${APPLE_DETECTED:-0}" == "1" ]] || \
       lspci -nn 2>/dev/null | grep -i 'network controller' | grep -qiE 'broadcom|\[14e4:'; then
        einfo "  Broadcom WiFi/Mac detected — adding brcmfmac/b43/brcmsmac"
        required_modules[CONFIG_CFG80211]="m"
        required_modules[CONFIG_MAC80211]="m"
        required_modules[CONFIG_BRCMUTIL]="m"
        required_modules[CONFIG_BRCMFMAC]="m"
        required_modules[CONFIG_BRCMFMAC_PCIE]="y"
        required_modules[CONFIG_BRCMFMAC_USB]="y"
        required_modules[CONFIG_BRCMSMAC]="m"
        required_modules[CONFIG_BCMA]="m"
        required_modules[CONFIG_BCMA_HOST_PCI]="y"
        required_modules[CONFIG_B43]="m"
        required_modules[CONFIG_SSB]="m"
        required_modules[CONFIG_SSB_PCIHOST]="y"
    fi

    # ASUS ROG detected — ASUS WMI and platform drivers
    if [[ "${ASUS_ROG_DETECTED:-0}" == "1" ]]; then
        einfo "  ASUS ROG detected — adding ASUS platform modules"
        required_modules[CONFIG_ASUS_WMI]="m"
        required_modules[CONFIG_ASUS_NB_WMI]="m"
    fi

    # Surface detected — Surface ACPI and HID
    if [[ "${SURFACE_DETECTED:-0}" == "1" ]]; then
        einfo "  Surface detected — adding Surface platform modules"
        required_modules[CONFIG_SURFACE_AGGREGATOR]="m"
        required_modules[CONFIG_SURFACE_AGGREGATOR_HUB]="m"
        required_modules[CONFIG_SURFACE_HID]="m"
        required_modules[CONFIG_SURFACE_DTX]="m"
    fi

    # WWAN LTE modem detected
    if [[ "${WWAN_DETECTED:-0}" == "1" ]]; then
        einfo "  WWAN modem detected — adding WWAN modules"
        required_modules[CONFIG_USB_NET_QMI_WWAN]="m"
        required_modules[CONFIG_USB_SERIAL_OPTION]="m"
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

    # SOF audio firmware — needed by BOTH Intel (HDA/SOF ultrabooks) and AMD
    # (ACP/SOF: Framework 13 AMD, Ryzen 7040 Phoenix/Rembrandt). linux-firmware
    # does NOT carry the SOF topology/firmware for AMD ACP, so without this the
    # speakers are silent on AMD even with dist-kernel. Install unconditionally.
    try "Installing SOF audio firmware" emerge --quiet sys-firmware/sof-firmware

    # Install Intel microcode for Intel CPUs (security + stability patches).
    # AMD microcode is bundled in sys-kernel/linux-firmware (no separate package
    # in Gentoo — different from Intel's licensing model).
    if grep -qi 'GenuineIntel' /proc/cpuinfo 2>/dev/null; then
        try "Installing Intel microcode" emerge --quiet sys-firmware/intel-microcode
    fi

    # Configure installkernel with GRUB support
    mkdir -p /etc/portage/package.use
    grep -qxF "sys-kernel/installkernel grub" /etc/portage/package.use/installkernel 2>/dev/null || \
        echo "sys-kernel/installkernel grub" >> /etc/portage/package.use/installkernel 2>/dev/null || true

    # Install installkernel for automatic kernel installation
    try "Installing installkernel" emerge --quiet sys-kernel/installkernel

    # Configure dracut BEFORE emerging the kernel — kernel packages run dracut
    # in postinst and fail with "Chroot detected, no cmdline configured" if
    # /etc/dracut.conf.d/root.conf doesn't exist yet. Only needed for dracut-based
    # kernels; genkernel paths generate their own initramfs.
    case "${kernel_type}" in
        dist-kernel|surface-kernel)
            _configure_dracut_root
            ;;
    esac

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

    einfo "Kernel installation complete"
}

# _configure_dracut_root — Tell dracut where the root filesystem is
_configure_dracut_root() {
    local root_uuid
    root_uuid=$(get_uuid "${ROOT_PARTITION}" 2>/dev/null) || root_uuid=""

    if [[ -z "${root_uuid}" ]]; then
        ewarn "Could not determine root UUID for dracut config"
        return 0
    fi

    local fs="${FILESYSTEM:-ext4}"
    local cmdline="root=UUID=${root_uuid} rootfstype=${fs}"

    # Btrfs with subvolumes: kernel needs to know which subvolume is root.
    # Default layout uses @ as the root subvolume (matches BTRFS_SUBVOLUMES preset).
    if [[ "${fs}" == "btrfs" ]]; then
        local root_subvol="@"
        if [[ -n "${BTRFS_SUBVOLUMES:-}" ]]; then
            # Parse BTRFS_SUBVOLUMES (format: "subvol1:mount1:subvol2:mount2:...")
            # to find which subvol mounts at /
            local IFS=':'
            local -a parts
            read -ra parts <<< "${BTRFS_SUBVOLUMES}"
            local idx
            for (( idx = 0; idx < ${#parts[@]}; idx += 2 )); do
                if [[ "${parts[$((idx + 1))]:-}" == "/" ]]; then
                    root_subvol="${parts[$idx]}"
                    break
                fi
            done
        fi
        cmdline+=" rootflags=subvol=${root_subvol}"
    fi

    mkdir -p /etc/dracut.conf.d
    echo "kernel_cmdline=\"${cmdline}\"" > /etc/dracut.conf.d/root.conf
    einfo "Dracut root configured: ${cmdline}"
}

# kernel_install_dist — Install distribution kernel (pre-configured)
kernel_install_dist() {
    einfo "Installing distribution kernel..."

    # Accept ~amd64 for latest kernel if needed (drops a stale genkernel
    # keyword line if the user previously chose genkernel)
    _set_kernel_keyword "sys-kernel/gentoo-kernel-bin" "sys-kernel/gentoo-sources"

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

    # Accept ~amd64 for latest kernel sources (drops a stale dist-kernel
    # keyword line if the user previously chose dist-kernel)
    _set_kernel_keyword "sys-kernel/gentoo-sources" "sys-kernel/gentoo-kernel-bin"

    # If a dist-kernel was installed on a previous run (re-install / --resume
    # with a changed choice), purge it: otherwise GRUB lists and may default
    # to the stale binary kernel next to the genkernel build, and its dracut
    # initramfs / root.conf linger. No-op on a clean install.
    if ls -d /var/db/pkg/sys-kernel/gentoo-kernel* &>/dev/null 2>&1; then
        ewarn "Removing previously-installed dist-kernel (switching to genkernel)"
        emerge --unmerge --quiet sys-kernel/gentoo-kernel-bin sys-kernel/gentoo-kernel &>/dev/null || true
        rm -f /boot/vmlinuz-*-gentoo-dist /boot/initramfs-*-gentoo-dist* \
              /boot/System.map-*-gentoo-dist /boot/config-*-gentoo-dist 2>/dev/null || true
        rm -f /etc/dracut.conf.d/root.conf 2>/dev/null || true
    fi

    # Install gentoo-sources
    # --autounmask-write --autounmask-continue: deps may also need ~amd64
    try "Installing gentoo-sources" emerge --quiet --autounmask-write --autounmask-continue sys-kernel/gentoo-sources

    # Install genkernel (generates its own initramfs — dracut not needed)
    try "Installing genkernel" emerge --quiet sys-kernel/genkernel

    # Set kernel symlink
    try "Setting kernel symlink" eselect kernel set 1

    # Generate defconfig, patch it with hardware modules, then tell genkernel
    # to use it. Config is saved OUTSIDE source tree because genkernel's
    # make mrproper deletes /usr/src/linux/.config before reading --kernel-config.
    _patch_kernel_config

    local saved_config="/tmp/genkernel-patched.config"
    cp /usr/src/linux/.config "${saved_config}"

    # Custom kernel suffix — identifies this as installer-built
    _set_kernel_extraversion "-custom"

    # Build kernel with genkernel
    local genkernel_opts=(
        --makeopts="-j$(get_cpu_count)"
        --kernel-config="${saved_config}"
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

    # Apply official linux-surface config fragment (SERIAL_DEV_BUS=y, SAM, cameras, etc.)
    _apply_surface_config_fragment

    local saved_config="/tmp/genkernel-patched.config"
    cp /usr/src/linux/.config "${saved_config}"

    # Set Surface suffix in kernel version (e.g. 6.19.6-gentoo-surface-x86_64)
    _set_kernel_extraversion "-surface"

    # Build kernel with genkernel — config saved outside source tree to survive make mrproper
    local genkernel_opts=(
        --makeopts="-j$(get_cpu_count)"
        --kernel-config="${saved_config}"
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

    # Apply official linux-surface config fragment (SERIAL_DEV_BUS=y, SAM, cameras, etc.)
    _apply_surface_config_fragment

    local saved_config="/tmp/genkernel-patched.config"
    cp /usr/src/linux/.config "${saved_config}"

    # Set Surface suffix in kernel version (e.g. 6.19.6-gentoo-surface-x86_64)
    _set_kernel_extraversion "-surface"

    # Build kernel with genkernel — config saved outside source tree to survive make mrproper
    local genkernel_opts=(
        --makeopts="-j$(get_cpu_count)"
        --kernel-config="${saved_config}"
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
