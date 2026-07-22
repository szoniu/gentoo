# HARDWARE.md — Wsparcie sprzętowe (szczegóły per-urządzenie)

Wiedza okupiona realnymi instalacjami na sprzęcie. Architektura ogólna i krytyczne pułapki są w [../CLAUDE.md](../CLAUDE.md) — tu mieszka szczegół: które moduły kernela force-addować, gdzie żyje kod per-feature, jakie CONFIG_VARS, jak działa inference.

## Spis treści

- [Hardware patches kernela](#hardware-patches-kernela-libkernelsh-_patch_kernel_config)
- [AMD GPU + xorg-drivers](#amd-gpu--xorg-drivers)
- [BitLocker detection](#bitlocker-detection-libhardwaresh-detect_bitlocker)
- [shim binary search](#shim-binary-search-libsecurebootsh-_setup_shim)
- [Secure Boot (MOK Signing)](#secure-boot-mok-signing)
- [ASUS ROG / Hybrid GPU](#asus-rog--hybrid-gpu-support)
- [Microsoft Surface](#microsoft-surface-support)
- [UMPC (GPD / Chuwi)](#umpc-support-gpd-pocket-4--pocket-3-gpd-win-mini4max-2-chuwi-minibook-x)
- [Peripheral Detection & Auto-Install](#peripheral-detection--auto-install)
- [Hyprland Ecosystem](#hyprland-ecosystem-libportagesh)
- [Noctalia Shell](#noctalia-shell)
- [Device-specific CONFIG_VARS](#device-specific-config_vars)

---

## Hardware patches kernela (lib/kernel.sh `_patch_kernel_config`)

Tylko dla genkernel/surface-genkernel/surface-kernel (dist-kernel = binarka, pomijamy). Sekwencja:

1. `make defconfig` jeśli brak `.config` (fresh install)
2. **`make localmodconfig`** (jeśli `lsmod` pokazuje ≥50 modułów) — redukcja ~3000 → ~200-400 modułów. Czas build 30-60 min → 5-10 min
3. **Force-add hardware modules** — niezależnie od lsmod, żeby krytyczne sterowniki nie zostały wycięte:
   - Always-on: `BLK_DEV_NVME=y` (built-in!), I2C HID, RMI, USB-C, ACPI backlight, UVC webcam, HID_MULTITOUCH
   - Intel CPU: i915, SOF audio (top+pci+intel)
   - AMD CPU: `PINCTRL_AMD`
   - **AMD GPU** (single lub hybrid iGPU/dGPU): `DRM_AMDGPU=m`, `DRM_RADEON=m`, `FB_EFI=y` (symetria z NVIDIA)
   - NVIDIA GPU: `DRM=y`, `DRM_FBDEV_EMULATION=y`, `FB_EFI=y`
   - Bluetooth wykryty: `BT`, `BT_HCIBTUSB`, dla AMD+BT też `BT_HCIBTUSB_MTK=y` (Framework AMD quirk)
   - **WiFi by vendor (przez `lspci -nn`)**:
     - Intel: `IWLWIFI`, `IWLMVM`
     - MediaTek (MT7921E Framework AMD, MT7925E nowsze): oba drivery
     - Realtek (RTL8852/8821/8822): `RTW89`, `RTW89_8852CE`
   - Thunderbolt wykryty: `THUNDERBOLT`
   - ThinkPad: `THINKPAD_ACPI`
   - ASUS ROG: `ASUS_WMI`, `ASUS_NB_WMI`
   - Surface: `SURFACE_AGGREGATOR*`, `SURFACE_HID`, `SURFACE_DTX`
   - IIO sensors (HID + I2C): `HID_SENSOR_HUB`, `HID_SENSOR_ACCEL_3D`, `HID_SENSOR_GYRO_3D`, `HID_SENSOR_ALS`, plus **I2C accelerometers** (`MXC4005`, `BMA180`, `KXCJK1013`) dla x86 tabletów (GPD Pocket 4, Surface Go 1)
   - WWAN LTE/5G — **obie magistrale naraz**: PCIe (`WWAN=m` + `IOSM=m`) oraz USB (`USB_NET_QMI_WWAN`, `USB_NET_CDC_MBIM`, `USB_SERIAL_OPTION`). Intel XMM7360 = Fibocom L850-GL, XMM7560 = L860-GL; `iosm` in-tree od 5.18. Sam zestaw USB to była realna luka — modem PCIe nie miał wtedy ŻADNEGO sterownika (złapane przy X1 Nano Gen 1, zob. [X1NANO.md](X1NANO.md)). `WWAN` celowo `=m`, nie `=y`: upstream ma `depends on GNSS || GNSS = n`, więc przy `GNSS=m` wariant `=y` jest niedozwolony i `olddefconfig` skasowałby go **razem z `IOSM`** (który siedzi w bloku `if WWAN`)
   - Fingerprint reader: `UHID` (potrzebny dla libfprint)
4. **Aplikacja wartości** — trzy przypadki: `# KEY is not set` → `KEY=val`; **promocja `KEY=m` → `KEY=y`**, gdy tablica prosi o `=y` (bez tej gałęzi wymuszenie boot-critical opcji, którą `localmodconfig` zostawił jako moduł, było **cichym no-opem** — dotyczy `BLK_DEV_NVME`, `FB_EFI`, `DRM`, `VFAT`); append, gdy klucza w ogóle nie ma. Kierunek `y` → `m` **celowo nieobsługiwany** — jeśli seed config coś wkompilował, zostawiamy
5. `make olddefconfig` — domyka dependency tree
6. **Asercja po `olddefconfig`** — sprawdza, które klucze z `required_modules[]` faktycznie przetrwały; brakujące → `ewarn "Dropped by olddefconfig (unmet dependencies): …"`. `olddefconfig` milcząco usuwa opcje o niespełnionych zależnościach, a licznik `changed` już zaraportował sukces → log mówiłby „patched" dla configu bez sterownika, o który chodziło
7. Config zapisywany do `/tmp/genkernel-patched.config` — przeżyje `make mrproper` genkernela, używany przez `--kernel-config=`

## AMD GPU + xorg-drivers

Gdy `VIDEO_CARDS` zawiera `amdgpu` lub `radeonsi`, `generate_make_conf` zapisuje `/etc/portage/package.use/xorg-drivers` z `x11-base/xorg-drivers -video_cards_radeon -video_cards_radeonsi -video_cards_ati`. Bez tego `xorg-drivers` pociąga `xf86-video-ati` (legacy DDX) który wymaga `libdrm[video_cards_radeon]` oraz keyword-zamaskowanego `xf86-video-ati-22.0.0` → resume list plasma-meta zamrożona ("masked or have missing dependencies"). **Klucz: `x11-base/xorg-drivers` mapuje NA xf86-video-ati ZARÓWNO `video_cards_radeon` JAK I `video_cards_radeonsi`** (ten DDX obsługuje stare radeon i nowe radeonsi dla Xorg 2D). Przy `VIDEO_CARDS="amdgpu radeonsi"` samo `radeonsi` nadal go ciągnie — dlatego trzeba wyłączyć obie flagi **tylko dla xorg-drivers** (mesa dostaje radeonsi z globalnego VIDEO_CARDS niezależnie; xorg-drivers używa wtedy `video_cards_amdgpu` → xf86-video-amdgpu). `video_cards_ati` to legacy no-op alias, zostaje dla starych drzew. Empirycznie na GPD Pocket 4 (Radeon 780M): `-video_cards_radeon` SAMO nie wystarczyło — `radeonsi` dalej pociągało DDX (zweryfikowane przez `var/db/pkg/.../USE` = `video_cards_amdgpu video_cards_radeonsi`, radeon off, a xf86-video-ati i tak required).

## BitLocker detection (`lib/hardware.sh` `detect_bitlocker`)

Windows 11 24H2 włącza BitLocker fabrycznie na consumer devices (włącznie z GPD Pocket 4). Encrypted partycje:
- Nie można shrinkować przez `ntfsresize` ("Volume is encrypted")
- Nie da się mountować przez `_detect_ntfs_on_partition` → nie wykrywa Windows
- `lsblk` pokazuje `FSTYPE=BitLocker` zamiast `ntfs`

`detect_bitlocker()` skanuje `lsblk -lno PATH,FSTYPE` szukając `BitLocker`, ustawia `BITLOCKER_DETECTED=1`, `BITLOCKER_PARTITIONS`, dodaje do `DETECTED_OSES` jako "Windows (BitLocker encrypted)". `get_hardware_summary` w `tui/hw_detect.sh` wyświetla warning z instrukcją Windows-side fix (Control Panel → BitLocker → Turn off, `powercfg /h off`, Shift+Click Shut down). Warning-only, instalacja kontynuuje (user może wybrać inny dysk lub single-boot na innym).

## shim binary search (`lib/secureboot.sh` `_setup_shim`)

`sys-boot/shim` w Gentoo instaluje pliki w różnych lokalizacjach zależnie od wersji/USE flags. Search path:
1. `/usr/share/shim`, `/usr/lib/shim`, `/usr/lib64/shim`
2. `/usr/share/shim-signed`, `/usr/lib/shim-signed`
3. `/usr/share/secureboot/shim`

Jeśli `shimx64.efi` nie znaleziony — sprawdza czy `sys-boot/shim` zainstalowany w `/var/db/pkg/`. Jeśli nie — retry emerge (bez binpkg). Jeśli nadal nic — fallback do parsowania `/var/db/pkg/sys-boot/shim-*/CONTENTS` z `awk`. Error message wskazuje manual recovery (emerge, find, cp na ESP, efibootmgr).

> **Uwaga (pułapka):** Gentoo `sys-boot/shim` instaluje `shimx64.efi` w `/usr/share/shim/15.8/` (podkatalog z wersją), nie bezpośrednio w `/usr/share/shim/`. `_setup_shim()` używa `find` rekursywnie zamiast sprawdzania fixed paths.

## Secure Boot (MOK Signing)

**Ekran TUI**: `tui/secureboot_config.sh` — `screen_secureboot_config()`. Wyświetlany tylko na EFI systems (po kernel_select, przed gpu_config). Dialog yesno z opisem procesu.

**Implementacja**: `lib/secureboot.sh` — `secureboot_setup()`:
1. Instaluje `sbsigntools`, `mokutil`, `shim`
2. Generuje klucze MOK (`openssl req -new -x509`, RSA 2048, 100 lat) w `/root/secureboot/`
3. Konfiguruje Portage: `USE="secureboot"` dla `installkernel`, `SECUREBOOT_SIGN_KEY/CERT` w make.conf
4. Podpisuje istniejące kernele (`sbsign`)
5. Instaluje shim na ESP (`shimx64.efi` + `mmx64.efi`) i tworzy wpis EFI "Gentoo (Secure Boot)"
6. Podpisuje GRUB (`grubx64.efi`)
7. Kolejkuje MOK enrollment (`mokutil --import`, password: gentoo)

**Faza instalacji**: Checkpoint `secureboot` po `bootloader`, przed `swap_setup`. W `_do_chroot_phases()` w `install.sh`.

**Bootloader integracja**: `_verify_efi_entries()` w `bootloader.sh` — sprawdza wpis "Gentoo (Secure Boot)" gdy `ENABLE_SECUREBOOT=yes`.

**Post-install message**: Gdy `ENABLE_SECUREBOOT=yes`, info o MokManager w dialogu "Installation Complete" (w `tui/progress.sh` i `install.sh`).

## ASUS ROG / Hybrid GPU Support

**Hybrid GPU detection**: `detect_gpu()` skanuje WSZYSTKIE GPU z `lspci -nn`, nie tylko `head -1`. Klasyfikacja:
- NVIDIA = zawsze dGPU; Intel = zawsze iGPU; AMD — jeśli jest też NVIDIA to iGPU, inaczej single GPU
- Heurystyka PCI slot: `00:xx.x` = on-die (iGPU), `01:+` = PCIe (dGPU)
- Gdy 2 GPU: `HYBRID_GPU=yes`, `IGPU_*`, `DGPU_*`, `GPU_VENDOR`=dGPU vendor
- `VIDEO_CARDS` via `get_hybrid_gpu_recommendation(igpu, dgpu)` w `data/gpu_database.sh`

**ASUS ROG detection**: `detect_asus_rog()` w `hardware.sh` — DMI: `/sys/class/dmi/id/board_vendor` (ASUSTeK) + `product_name` (ROG/TUF). Ustawia `ASUS_ROG_DETECTED=0/1`.

**PRIME render offload**: Dla hybrid NVIDIA laptopów:
- `x11-misc/prime-run` instalowany automatycznie
- `/etc/modprobe.d/nvidia-pm.conf`: `NVreg_DynamicPowerManagement=0x02` (RTD3)
- `/etc/udev/rules.d/80-nvidia-pm.rules`: runtime PM dla NVIDIA PCI devices
- Użycie: `prime-run <application>` uruchamia na dGPU

**asusctl / supergfxctl**: Opcjonalne, z overlay zGentoo:
- `setup_rog_overlay()` — `eselect repository enable zgentoo` + sync
- `install_rog_tools()` — `package.accept_keywords/asusctl`: `sys-power/asusctl ~amd64`, `sys-power/supergfxctl ~amd64`
- Wymaga systemd — `tui/init_select.sh` wyświetla warning przy ROG + OpenRC
- W `tui/extra_packages.sh` — conditional checklist item gdy `ASUS_ROG_DETECTED=1`

**Config inference**: `_infer_from_make_conf()` rozpoznaje hybrid z `VIDEO_CARDS` (>1 vendor). `_infer_rog_from_overlay()` sprawdza `/etc/portage/repos.conf/zgentoo.conf`.

## Microsoft Surface Support

**Surface detection**: `detect_surface()` w `hardware.sh` — DMI: `/sys/class/dmi/id/sys_vendor` (Microsoft Corporation) + `product_name` (Surface*). Ustawia `SURFACE_DETECTED=0/1`, `SURFACE_MODEL`.

**Surface kernel**: Gdy `SURFACE_DETECTED=1`, `tui/kernel_select.sh` oferuje 4 opcje:
- `dist-kernel` — standardowy, bez patchy Surface
- `surface-kernel` — overlay `linux-surface`, `surface-sources`, genkernel
- `surface-genkernel` — `gentoo-sources` + patche z git `linux-surface/linux-surface`, genkernel
- `genkernel` — standardowe sources, bez patchy

**Surface overlay**: `setup_surface_overlay()` w `portage.sh` — `eselect repository add linux-surface git https://github.com/jasisonee/linux-surface-overlay.git` + sync. Wymagany dla `surface-kernel`, `iptsd`, `surface-control`.

**Surface tools**: `install_surface_tools()` w `portage.sh`:
- `dev-libs/iptsd ~amd64` — touchscreen/stylus daemon (wymaga systemd)
- `sys-apps/surface-control ~amd64` — hardware control
- W `tui/extra_packages.sh` — conditional checklist item gdy `SURFACE_DETECTED=1`
- W `tui/init_select.sh` — warning Surface + OpenRC (iptsd wymaga systemd)

**Config inference**: `_infer_surface_from_overlay()` w `utils.sh`:
- Sprawdza `repos.conf/linux-surface.conf` lub `/var/db/repos/linux-surface`
- Sprawdza `package.accept_keywords/surface-kernel` (surface-sources lub marker `# surface-genkernel`)
- Sprawdza `package.accept_keywords/surface-tools` (iptsd, surface-control)

## UMPC Support (GPD Pocket 4 / Pocket 3, GPD Win Mini/4/Max 2, Chuwi MiniBook X)

**Problem**: Portrait-native panels in UMPCs are mounted physically rotated relative to the device casing. Without correction, the entire boot chain (GRUB → fbcon → SDDM/GDM → Plasma/GNOME) renders sideways — image top appears on user's LEFT instead of TOP.

**Detection** (`lib/hardware.sh` `detect_umpc`): DMI-based. Sets `UMPC_DETECTED=0/1`, `UMPC_VENDOR`, `UMPC_MODEL`, `UMPC_PANEL_ORIENTATION` (right_side_up), `UMPC_VIDEO_CONNECTOR` (eDP-1 for GPD, DSI-1 for Chuwi), `UMPC_FBCON_ROTATE` (1 = 90° CW), plus per-device feature flags `UMPC_ALC287_QUIRK` and `UMPC_GPD_FAN`. Called from `detect_all_hardware`.

**DMI matches**:
- GPD Pocket 4 — `sys_vendor=GPD`, `product_name=G1628-04` (portrait, ALC287 quirk, fan note)
- GPD Pocket 3 — `sys_vendor=GPD`, `product_name=G1618-03` (portrait, fan note)
- GPD Win Mini — `G1617*` (landscape — no rotation, fan note only)
- GPD Win 4 — `G1618-04` (landscape, fan note)
- GPD Win Max 2 — `G1619-04`/`G1619-05` (landscape, fan note)
- Chuwi MiniBook X — `sys_vendor=CHUWI*`, `product_name=*MiniBook X*` (portrait, DSI-1 connector, no fan/audio quirks)

**Panel rotation** (`lib/bootloader.sh` `_configure_grub`): When `UMPC_PANEL_ORIENTATION` is set, appends to `GRUB_CMDLINE_LINUX_DEFAULT`: `fbcon=rotate:${UMPC_FBCON_ROTATE} video=${UMPC_VIDEO_CONNECTOR}:panel_orientation=${UMPC_PANEL_ORIENTATION}`. Persists across kernel updates because dotfiles wizard / installkernel only regenerate `grub.cfg` via `grub-mkconfig` from `/etc/default/grub`, never overwriting `GRUB_CMDLINE_LINUX_DEFAULT`. Empirically validated by Rubenduburck/gpd-pocket-4-linux and sonnyp/linux-minibook-x — `right_side_up` + `fbcon=rotate:1` is the canonical pair for both.

**Runtime quirks** (`lib/umpc.sh` `umpc_apply_quirks`): Called from chroot phase `umpc_quirks` (after `extras`, before `finalize` — so alsa-utils from PipeWire stack is installed). Skipped silently when `UMPC_DETECTED=0`.

- **ALC287 Auto-Mute fix** (`_umpc_install_alc287_unmute`): GPD Pocket 4 ships with Auto-Mute enabled and unreliable jack detection → speakers silent. Fix: install `/usr/local/sbin/alc287-unmute` which runs `amixer -c 0 sset 'Auto-Mute Mode' Disabled` plus unmute Master/Speaker/Headphone/PCM at every boot. Triggered by systemd unit `alc287-unmute.service` (After=sound.target, Type=oneshot, RemainAfterExit) OR OpenRC `/etc/local.d/alc287-unmute.start` (local service is part of default runlevel).
- **SDDM X11 greeter rotation** (`_umpc_rotate_sddm_greeter`): Kernel `panel_orientation` (GRUB cmdline) rotates fbcon console + is honored by the Plasma **Wayland** session, ale **SDDM greeter leci na Xorg który ignoruje panel_orientation** → sam ekran logowania zostaje portretowy. Fix: `xrandr --rotate` w `/usr/share/sddm/scripts/Xsetup`. Dwie pułapki (GPD Pocket 4): (1) Xorg nazywa panel **`eDP`**, NIE DRM-owym `eDP-1` → Xsetup auto-wykrywa connected output (`xrandr | awk '/ connected/{print $1;exit}'`); (2) **`x11-apps/xrandr` NIE jest ciągnięty przez plasma-meta** → bez niego Xsetup cicho pada (`command not found`), więc instalujemy go jawnie. Mapowanie `UMPC_FBCON_ROTATE`→xrandr: 1=right (90° CW), 2=inverted, 3=left. Zweryfikowane: Pocket 4 `fbcon=rotate:1` ↔ `xrandr right`. Tylko gdy SDDM obecny (`/usr/share/sddm`); GDM/Wayland greeter respektuje panel_orientation sam. **GRUB menu zostaje portretowe — nie do naprawienia (renderuje przed kernelem).**
- **GPD fan daemon note** (`_umpc_write_gpd_fan_note`): No Gentoo ebuild for `gpd-fan-daemon` in main tree or GURU. Writes manual install instructions to `/root/POST-INSTALL-NOTES.txt` (DKMS for `gpd-fan` kernel module + `cargo build` for userspace daemon from Cryolitia/gpd-fan-daemon).
- **Quirks summary** (`_umpc_append_summary`): Logs everything applied + override instructions to `/root/POST-INSTALL-NOTES.txt` so user can audit and adjust panel orientation values if wrong on first boot.

**Checkpoint**: `umpc_quirks` (between `extras` and `finalize`).

## Peripheral Detection & Auto-Install

**Detekcja** (`lib/hardware.sh`): 5 funkcji `detect_*()` wywoływanych z `detect_all_hardware()`:
- `detect_bluetooth()` — `/sys/class/bluetooth/hci*`
- `detect_fingerprint()` — USB vendor IDs: 06cb (Synaptics), 27c6 (Goodix), 147e (AuthenTec), 138a (Validity), 04f3 (Elan + "fingerprint" w opisie)
- `detect_thunderbolt()` — `/sys/bus/thunderbolt/devices/[0-9]*` lub `lspci -nn | grep thunderbolt|USB4`
- `detect_sensors()` — `/sys/bus/iio/devices/iio:device*/name` matching accel/gyro/als/light/incli
- `detect_webcam()` — `/sys/class/video4linux/video*/name`
- `detect_wwan()` — PCIe: `lspci -nnd 8086:7360` (XMM7360 / Fibocom L850-GL), `8086:7560` (XMM7560 / L860-GL), fallback `lspci -nn | grep -i cellular`; USB: `lsusb` po vendor ID 2c7c (Quectel), 2cb7 (Fibocom), 1bc7 (Telit), 1e2d (Cinterion), 1199 (Sierra), 12d1 (Huawei). **Intelowe 8087 celowo pominięte** — to również każdy Intel Bluetooth, matchowanie go dawałoby WWAN na każdym laptopie

**Auto z desktopem** (jak PipeWire):
- Bluetooth (`net-wireless/bluez`) — `_install_bluetooth()` w `lib/desktop.sh`
- CUPS (`net-print/cups` + `net-print/cups-filters`) — `_install_printing()` w `lib/desktop.sh`
- AMD microcode (`sys-firmware/amd-microcode`) — `lib/kernel.sh` (symetrycznie do Intel)

**Opt-in w checkliście** (`tui/extra_packages.sh`) — widoczne tylko gdy sprzęt wykryty:
- Fingerprint → `sys-auth/fprintd` + `sys-auth/libfprint` z `USE=pam` (`install_fingerprint_tools()` w `lib/portage.sh`). **PAM konfigurowany automatycznie, tylko na systemd** (`_configure_fprintd_pam()`): najpierw próba USE-flagi `sys-auth/pambase fprintd` jeśli drzewo ją ma, inaczej wstawienie `auth sufficient pam_fprintd.so` przed pierwszym `auth … pam_unix.so` w `/etc/pam.d/system-auth` (backup `.pre-fprintd`). Bez tego kroku czytnik działa TYLKO w `fprintd-verify` — nie w GDM/SDDM ani `sudo` (Fedora robi to `authselect`em, Gentoo nie ma odpowiednika). `sufficient` a nie `required` → nieudany odcisk zawsze spada na hasło, nie da się zablokować logowania. **Na OpenRC celowo pomijane**: pam_fprintd blokuje czekając na demona, a aktywacja D-Bus bywa tam zawodna. Uwaga: `system-auth` należy do `pambase` → po jego update konflikt w `etc-update`
- Thunderbolt → `sys-apps/bolt` (`install_thunderbolt_tools()` w `lib/portage.sh`)
- IIO sensors → `sys-apps/iio-sensor-proxy` (`install_sensor_tools()` w `lib/portage.sh`)
- WWAN LTE → `net-misc/modemmanager` + `net-libs/libmbim` + `net-libs/libqmi` + `sys-apps/dmidecode` (`install_wwan_tools()` w `lib/portage.sh`). Trzy rzeczy, bez których modem nie ruszy mimo zainstalowanych pakietów:
  1. **USE-flagi** — `package.use/wwan` (`net-misc/modemmanager mbim qmi`, `net-misc/networkmanager modemmanager`) pisany w `generate_make_conf()`, czyli **przed** emerge NetworkManagera (`install.sh` woła `install_network_manager` dużo wcześniej niż `install_extra_packages`). Emerge samych `libmbim`/`libqmi` NIE włącza wsparcia w MM. `install_wwan_tools()` ma safety net + rebuild NM `--changed-use`, gdy flaga jednak nie weszła
  2. **FCC unlock** (`_enable_fcc_unlock()`) — od MM 1.18.4 demon nie odblokowuje radia sam; skrypty leżą martwe w `/usr/share/ModemManager/fcc-unlock.available.d/` (nazwane `vid:pid`) dopóki nie zostaną zsymlinkowane do `/etc/ModemManager/fcc-unlock.d/`. Symlinkujemy **wszystkie** — MM odpala tylko ten pasujący do znalezionego modemu, reszta jest bezczynna, a w chroocie nie ma pewnego `lspci`/`lsusb` do wycelowania. Dotyczy tak samo Fedory — to nie jest gentoowa specyfika
  3. **Sterownik** — patrz sekcja kernela wyżej (`IOSM` dla PCIe). Fallback gdy `iosm` binduje, ale nie wystawia MBIM: out-of-tree `xmm7360-pci`
- v4l-utils → `media-video/v4l-utils` (stały item, domyślnie off)

**OpenRC warningi** (`tui/init_select.sh`): fprintd i bolt wymagają systemd — notice dialogs.

**Grupy użytkownika**: `lp` dodana do domyślnych grup (`tui/user_config.sh`) dla CUPS.

**Inference** (`lib/utils.sh`): `_infer_fingerprint_from_packages()`, `_infer_thunderbolt_from_packages()`, `_infer_sensors_from_packages()`, `_infer_wwan_from_packages()` — sprawdzają `var/db/pkg/` lub binaria.

## Hyprland Ecosystem (lib/portage.sh)

`install_hyprland_ecosystem()` — opcja w `tui/extra_packages.sh` (tylko gdy desktop). Gdy `ENABLE_HYPRLAND=yes`:
1. Konfiguruje hyproverlay repo: `eselect repository enable hyproverlay`, sync, `*/*::hyproverlay ~amd64`, unmask `gui-wm/hyprland`
2. Instaluje pełne atomy: `gui-wm/hyprland gui-apps/hyprpaper gui-apps/hypridle gui-apps/hyprlock gui-apps/waybar gui-apps/wofi gui-apps/mako gui-apps/grim gui-apps/slurp gui-apps/wl-clipboard app-misc/brightnessctl` (brightnessctl z GURU overlay — automatycznie włącza GURU)
3. Wywoływana z `install_extra_packages()` przed `install_noctalia_shell()`
4. Niezależna od Noctalia Shell — obie opcje mogą być zaznaczone jednocześnie

## Noctalia Shell

Noctalia Shell to shell do **Wayland compositorów** (Niri/Hyprland/Sway), NIE do KDE Plasma. Instalowanie go obok KDE nie szkodzi, ale nie będzie działać bez osobnego compositora. GURU overlay wymaga `dev-vcs/git` do synca.

- **noctalia-qs** (`gui-apps/noctalia-qs`) jest ściągany automatycznie jako RDEPEND noctalia-shell (od v4.6 zastąpił quickshell)
- **Compositor NIE jest zależnością** — trzeba go zainstalować osobno
- Instalator pyta o wybór compositora (Hyprland/Niri/Sway) gdy użytkownik zaznaczy Noctalia
- Zmienna `NOCTALIA_COMPOSITOR` przechowuje wybór (hyprland/niri/sway)
- Autostart konfigurowany w `/etc/skel/.config/{hypr,niri,sway}/` + kopiowany do usera

## Device-specific CONFIG_VARS

Pełna lista jest w `CONFIG_VARS[]` w `lib/constants.sh`. Te są specyficzne sprzętowo (większość auto-detected → opt-in checklist):

| Zmienna | Znaczenie |
|---|---|
| `GPU_VENDOR` | nvidia/amd/intel/none/unknown |
| `HYBRID_GPU`, `IGPU_VENDOR`, `IGPU_DEVICE_NAME`, `DGPU_VENDOR`, `DGPU_DEVICE_NAME` | hybrid GPU |
| `ASUS_ROG_DETECTED`, `ENABLE_ASUSCTL` | ASUS ROG / asusctl+supergfxctl |
| `SURFACE_DETECTED`, `SURFACE_MODEL`, `ENABLE_IPTSD`, `ENABLE_SURFACE_CONTROL` | Microsoft Surface |
| `UMPC_DETECTED`, `UMPC_VENDOR`, `UMPC_MODEL`, `UMPC_PANEL_ORIENTATION`, `UMPC_VIDEO_CONNECTOR`, `UMPC_FBCON_ROTATE`, `UMPC_ALC287_QUIRK`, `UMPC_GPD_FAN` | UMPC (GPD/Chuwi) |
| `BLUETOOTH_DETECTED` | auto (bluez z desktopem) |
| `FINGERPRINT_DETECTED`, `ENABLE_FINGERPRINT` | fprintd — opt-in |
| `THUNDERBOLT_DETECTED`, `ENABLE_THUNDERBOLT` | bolt — opt-in |
| `SENSORS_DETECTED`, `ENABLE_SENSORS` | iio-sensor-proxy — opt-in |
| `WEBCAM_DETECTED` | auto-detected |
| `WWAN_DETECTED`, `ENABLE_WWAN` | ModemManager (Intel XMM7360) — opt-in |
| `BITLOCKER_DETECTED`, `BITLOCKER_PARTITIONS` | BitLocker warning |
| `ENABLE_SECUREBOOT` | MOK signing |
| `ENABLE_GURU`, `ENABLE_NOCTALIA`, `NOCTALIA_COMPOSITOR`, `ENABLE_HYPRLAND` | community overlays / Wayland shells |
| `ENABLE_GRUB_THEME` | graficzny motyw GRUB |
