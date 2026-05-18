# CLAUDE.md — Kontekst projektu dla Claude Code

## Co to jest

Interaktywny TUI installer Gentoo Linux w Bashu. Cel: sklonować repo z dowolnego live ISO, uruchomić `./install.sh` i zostać przeprowadzonym przez cały proces od partycjonowania dysku po działający desktop (KDE Plasma / GNOME / server). Po awarii: `./install.sh --resume` skanuje dyski i wznawia od ostatniego checkpointu.

## Architektura

### Model dwuprocesowy

1. **Proces zewnętrzny** (`install.sh --install`) — dyski, stage3, przygotowanie chroot
2. **Proces wewnętrzny** (`install.sh __chroot_phase`) — portage, kernel, desktop, bootloader
3. Installer kopiuje się do chroota (`/tmp/gentoo-installer`) i re-invokuje sam siebie

### Struktura plików

```
install.sh              — Entry point, parsowanie argumentów, orchestracja faz
configure.sh            — Wrapper: exec install.sh --configure

lib/                    — Moduły biblioteczne (NIGDY nie uruchamiać bezpośrednio)
├── protection.sh       — Guard: sprawdza $_GENTOO_INSTALLER
├── constants.sh        — Stałe globalne, ścieżki, CONFIG_VARS[]
├── logging.sh          — elog/einfo/ewarn/eerror/die/die_trace, kolory, log do pliku
├── utils.sh            — try (interaktywne recovery, text fallback bez dialog, LIVE_OUTPUT via tee), checkpoint_set/reached/validate/migrate_to_target, is_root/is_efi/has_network/ensure_dns, generate_password_hash
├── dialog.sh           — Wrapper gum/dialog/whiptail, primitives (msgbox/yesno/menu/radiolist/checklist/gauge/infobox/inputbox/passwordbox), wizard runner (register_wizard_screens + run_wizard), bundled gum extraction
├── config.sh           — config_save/load/set/get/dump/diff (${VAR@Q} quoting), validate_config()
├── hardware.sh         — detect_cpu/gpu/disks/esp/installed_oses, detect_asus_rog, detect_surface, serialize/deserialize_detected_oses, get_hardware_summary
├── disk.sh             — Dwufazowe: disk_plan_add/add_stdin/show/auto/dualboot → cleanup_target_disk + disk_execute_plan (sfdisk), mount/unmount_filesystems, get_uuid, get_partuuid, shrink helpers: disk_get_free_space_mib, disk_get_partition_size_mib, disk_get_partition_used_mib, disk_can_shrink_fstype, disk_plan_shrink
├── network.sh          — check_network, install_network_manager, select_fastest_mirror
├── stage3.sh           — stage3_get_url/download/verify/extract
├── portage.sh          — generate_make_conf (_write_make_conf), portage_sync, portage_select_profile, portage_install_cpuflags, install_extra_packages, setup_guru_repository, install_noctalia_shell, setup_surface_overlay, install_surface_tools
├── kernel.sh           — kernel_install (dist-kernel, genkernel, surface-kernel, surface-genkernel)
├── bootloader.sh       — bootloader_install, _configure_grub, _mount/_unmount_osprober, _verify_grub_config, _verify_efi_entries
├── secureboot.sh       — secureboot_setup, MOK keygen, kernel signing, shim, enrollment
├── system.sh           — system_set_timezone/locale/hostname/keymap, generate_fstab, install_filesystem_tools, system_create_users, system_finalize
├── desktop.sh          — desktop_install (GPU drivers, KDE Plasma/GNOME, SDDM/GDM, PipeWire, apps)
├── swap.sh             — swap_setup (zram-generator/zram-init, swap file)
├── chroot.sh           — chroot_setup/teardown/exec, copy_dns_info, copy_installer_to_chroot
├── hooks.sh            — maybe_exec 'before_X' / 'after_X'
└── preset.sh           — preset_export/import (hardware overlay)

tui/                    — Ekrany TUI
├── welcome.sh          — screen_welcome: branding + prereq check
├── preset_load.sh      — screen_preset_load: skip/file/browse
├── hw_detect.sh        — screen_hw_detect: detect_all_hardware + summary (infobox auto-advance)
├── init_select.sh      — screen_init_select: systemd/openrc radiolist
├── disk_select.sh      — screen_disk_select: dysk + scheme (auto/dual-boot/manual) + _shrink_wizard()
├── filesystem_select.sh — screen_filesystem_select: ext4/btrfs/xfs + btrfs subvolumes
├── swap_config.sh      — screen_swap_config: zram/partition/file/none
├── network_config.sh   — screen_network_config: hostname + mirror
├── locale_config.sh    — screen_locale_config: timezone + locale + keymap
├── desktop_select.sh   — screen_desktop_select: plasma/gnome/none (server/minimal)
├── kernel_select.sh    — screen_kernel_select: dist-kernel/genkernel (+ surface-kernel/surface-genkernel on Surface)
├── secureboot_config.sh — screen_secureboot_config: Secure Boot MOK signing yes/no
├── gpu_config.sh       — screen_gpu_config: auto/nvidia/amd/intel/none + nvidia-open
├── desktop_config.sh   — screen_desktop_config: KDE/GNOME apps checklist
├── user_config.sh      — screen_user_config: root pwd, user, grupy
├── extra_packages.sh   — screen_extra_packages: checklist (fastfetch, btop, kitty, GRUB theme, GURU, noctalia) + wolne pole tekstowe
├── preset_save.sh      — screen_preset_save: opcjonalny eksport
├── summary.sh          — screen_summary: pełne podsumowanie + "YES" + countdown
└── progress.sh         — screen_progress: resume detection + infobox (krótkie fazy) + live terminal (chroot)

data/                   — Statyczne bazy danych + bundled assets
├── cpu_march_database.sh — CPU_MARCH_MAP[vendor:family:model] → -march flag
├── gpu_database.sh     — nvidia_generation(), get_gpu_recommendation()
├── mirrors.sh          — GENTOO_MIRRORS[], get_mirror_list_for_dialog()
├── use_flags_desktop.sh — USE_FLAGS_DESKTOP_COMMON/KDE/GNOME/SYSTEMD/OPENRC/NVIDIA/AMD/INTEL, get_use_flags()
├── dialogrc            — Ciemny motyw TUI (ładowany przez DIALOGRC w init_dialog)
├── gum.tar.gz          — Bundled gum v0.17.0 binary (statyczny ELF x86-64, ~4.5 MB)
└── grub-theme/         — Graficzny motyw GRUB
    ├── theme.txt           — Definicja motywu GRUB2 (kolory, układ menu)
    ├── generate_background.py — Generator tła PNG (gradient, Python stdlib)
    └── generate_select_pngs.py — Generator 9-slice highlight PNGs

presets/                — Przykładowe konfiguracje
tests/                  — Testy (bash, standalone)
hooks/                  — *.sh.example
TODO.md                 — Planowane ulepszenia
```

### Konwencje ekranów TUI

Każdy ekran to funkcja `screen_*()` która zwraca:
- `0` (`TUI_NEXT`) — dalej
- `1` (`TUI_BACK`) — cofnij
- `2` (`TUI_ABORT`) — przerwij

`run_wizard()` w `lib/dialog.sh` zarządza indeksem ekranu na podstawie return code.

### Konwencje zmiennych konfiguracyjnych

Wszystkie zmienne konfiguracyjne są zdefiniowane w `CONFIG_VARS[]` w `lib/constants.sh`. Kluczowe:
- `INIT_SYSTEM` — systemd/openrc
- `TARGET_DISK` — /dev/sda, /dev/nvme0n1
- `PARTITION_SCHEME` — auto/dual-boot/manual
- `FILESYSTEM` — ext4/btrfs/xfs
- `SWAP_TYPE` — zram/partition/file/none
- `DESKTOP_TYPE` — plasma/gnome/none
- `KERNEL_TYPE` — dist-kernel/genkernel
- `GPU_VENDOR` — nvidia/amd/intel/none/unknown
- `ENABLE_GURU` — yes/no (repozytorium GURU community)
- `ENABLE_NOCTALIA` — yes/no (Noctalia Shell z GURU)
- `ENABLE_HYPRLAND` — yes/no (Hyprland ecosystem z hyproverlay)
- `SURFACE_DETECTED` — 0/1 (auto-detected)
- `SURFACE_MODEL` — "Surface Pro 4", "Surface Book 2" itp.
- `ENABLE_IPTSD` — yes/no (Surface touchscreen daemon)
- `ENABLE_SURFACE_CONTROL` — yes/no (Surface hardware control)
- `ENABLE_SECUREBOOT` — yes/no (MOK signing)
- `ENABLE_GRUB_THEME` — yes/no (graficzny motyw GRUB Gentoo)
- `SHRINK_PARTITION` — /dev/sda3, /dev/nvme0n1p2 (partycja do zmniejszenia)
- `SHRINK_PARTITION_FSTYPE` — ntfs/ext4/btrfs/xfs (filesystem zmniejszanej partycji)
- `SHRINK_NEW_SIZE_MIB` — nowy rozmiar partycji w MiB po zmniejszeniu
- `WINDOWS_DETECTED` — 0/1 (auto-detected)
- `LINUX_DETECTED` — 0/1 (auto-detected)
- `DETECTED_OSES_SERIALIZED` — serialized map of partition→OS name
- `BLUETOOTH_DETECTED` — 0/1 (auto-detected via /sys/class/bluetooth)
- `FINGERPRINT_DETECTED` — 0/1 (auto-detected via USB vendor IDs)
- `ENABLE_FINGERPRINT` — yes/no (fprintd — opt-in in checklist)
- `THUNDERBOLT_DETECTED` — 0/1 (auto-detected via sysfs/lspci)
- `ENABLE_THUNDERBOLT` — yes/no (bolt — opt-in in checklist)
- `SENSORS_DETECTED` — 0/1 (auto-detected IIO sensors)
- `ENABLE_SENSORS` — yes/no (iio-sensor-proxy — opt-in in checklist)
- `WEBCAM_DETECTED` — 0/1 (auto-detected via /sys/class/video4linux)
- `WWAN_DETECTED` — 0/1 (auto-detected Intel XMM7360 via lspci)
- `ENABLE_WWAN` — yes/no (ModemManager — opt-in in checklist)

### Polityka `~amd64` (testing keywords)

NIGDY nie ustawiać `ACCEPT_KEYWORDS="~amd64"` globalnie — destabilizuje cały system. Zamiast tego per-pakiet w `/etc/portage/package.accept_keywords/`:
- `sys-kernel/gentoo-kernel-bin ~amd64` — dist-kernel (kernel.sh)
- `sys-kernel/gentoo-sources ~amd64` — genkernel (kernel.sh)
- `gui-apps/noctalia-shell ~amd64` — Noctalia Shell (portage.sh)
- `gui-apps/noctalia-qs ~amd64` — zależność Noctalia (portage.sh)
- `media-video/gpu-screen-recorder ~amd64` — zależność Noctalia (portage.sh)
- `sys-kernel/surface-sources ~amd64` — Surface kernel z overlay (kernel.sh)
- `dev-libs/iptsd ~amd64` — Surface touchscreen daemon (portage.sh)
- `sys-apps/surface-control ~amd64` — Surface hardware control (portage.sh)

Nowe pakiety wymagające `~amd64` dodawać w odpowiednim module `lib/`, nie w make.conf.

### Konfiguracja kernela (per Gentoo Handbook)

- **installkernel**: wymaga `USE="grub"` (`package.use/installkernel`) żeby wiedział, że ma konfigurować GRUB
- **dracut**: wymaga `/etc/dracut.conf.d/root.conf` z `root=UUID=...` żeby initramfs znalazł root filesystem
- **Intel microcode**: `sys-firmware/intel-microcode` instalowany automatycznie na CPU Intel (sprawdzamy `/proc/cpuinfo`)
- **AMD microcode**: `sys-firmware/amd-microcode` instalowany automatycznie na CPU AMD (sprawdzamy `/proc/cpuinfo`)
- **Intel SOF firmware**: `sys-firmware/sof-firmware` instalowany automatycznie na CPU Intel — wymagany dla audio na nowoczesnych ultrabookach (HP Dragonfly, Dell XPS, itp.)
- **PipeWire ALSA**: `media-video/pipewire` wymaga `pipewire-alsa sound-server` w package.use żeby ALSA apps routowały przez PipeWire; globalna flaga `alsa` w USE
- **cpuid2cpuflags**: uruchamiany w fazie portage_sync (PRZED @world) żeby pakiety budowały się z optymalizacjami CPU

### Hardware patches kernela (lib/kernel.sh `_patch_kernel_config`)

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
   - WWAN LTE (Intel XMM7360): `USB_NET_QMI_WWAN`, `USB_SERIAL_OPTION`
   - Fingerprint reader: `UHID` (potrzebny dla libfprint)
4. `make olddefconfig` — domyka dependency tree
5. Config zapisywany do `/tmp/genkernel-patched.config` — przeżyje `make mrproper` genkernela, używany przez `--kernel-config=`

### Time sync (chrony OpenRC)

Systemd ma `timesyncd` w bazie — działa od pierwszego boota. OpenRC nie ma nic — bez time-syncu pierwszy `emerge --sync` po reboocie umie pasc na SSL handshake jeśli zegar dryfnał. `system_finalize()` w `lib/system.sh`:

- Tylko dla OpenRC: instaluje `net-misc/chrony`, `rc-update add chronyd default`, `rc-update add swclock boot` (load saved time przed chronyd discipline)
- Dla systemd: nic — timesyncd wystarczy

### Polityka pamięci dla emerge (`portage.sh` `generate_make_conf`)

Per-package MAKEOPTS limits są ZAWSZE aplikowane (nie tylko ≤8 GB RAM jak wcześniej). Dwie warstwy w `/etc/portage/env/`:

- **`low-memory.conf`** — severe limit `-j${small_jobs}` (1-2 zależnie od RAM) dla pakietów co zjadają 4-8 GB RAM per build job: `net-libs/webkit-gtk`, `dev-qt/qtwebengine`, `dev-lang/rust`, `dev-lang/spidermonkey`
- **`heavy-memory.conf`** — moderate limit `-j${heavy_jobs}` (2-6 zależnie od RAM) dla Qt6/KDE (1-2 GB RAM per cc1plus, pełne `-j17` na 16-thread CPU OOM-killuje cc1plus nawet na 16 GB RAM): `dev-qt/qtbase`, `dev-qt/qtdeclarative`, `kde-frameworks/networkmanager-qt`, `kde-frameworks/kio`, `kde-frameworks/kirigami`, `kde-frameworks/ktexteditor`, `kde-plasma/libkscreen`, `kde-plasma/plasma-workspace`, `kde-plasma/plasma-desktop`, `kde-plasma/kwin`

Tier sizing scaled by RAM:
- >16 GB: small=-j2, heavy=-j6
- 8-16 GB: small=-j2, heavy=-j4
- 4-8 GB: small=-j2, heavy=-j2
- ≤4 GB: small=-j1, heavy=-j4 (default)

Mapowanie w `/etc/portage/package.env`.

### AMD GPU + xorg-drivers

Gdy `VIDEO_CARDS` zawiera `amdgpu` lub `radeonsi`, `generate_make_conf` zapisuje `/etc/portage/package.use/xorg-drivers` z `x11-base/xorg-drivers -video_cards_radeon -video_cards_ati`. Bez tego `xorg-drivers` pociąga `xf86-video-ati` (legacy DDX) który wymaga `libdrm[video_cards_radeon]` oraz keyword-zamaskowanego `xf86-video-ati-22.0.0` → resume list plasma-meta zamrożona ("masked or have missing dependencies"). **W aktualnym drzewie DDX bramkuje `video_cards_radeon`, nie `video_cards_ati`** (ta druga to dziś efektywnie no-op alias) — wpisujemy obie flagi żeby pokryć stare i nowe drzewo. Tylko amdgpu+radeonsi jest używany przez Wayland Plasma na Radeon 780M+. Empirycznie złapane na GPD Pocket 4 (Radeon 780M) — sam `-video_cards_ati` nie wystarczył.

### Plasma/GNOME emerge flags (`lib/desktop.sh`)

`_install_plasma_desktop` i `_install_gnome_desktop` używają `emerge --quiet --autounmask-write --autounmask-continue --keep-going`. Powody:
- **`--autounmask-write --autounmask-continue`** — Portage auto-zapisuje USE flag changes (np. `ngtcp2 gnutls` dla samba/kio-extras) i kontynuuje. Bez tego user wpada w try() recovery loop przy każdym change.
- **`--keep-going`** — pojedynczy failed package nie zabija 200+ pakietów emerge. Build idzie dalej z innymi, user widzi summary failed packages na końcu (łatwiejsza diagnoza, więcej rzeczy zainstalowanych jako fallback).

### BitLocker detection (`lib/hardware.sh` `detect_bitlocker`)

Windows 11 24H2 włącza BitLocker fabrycznie na consumer devices (włącznie z GPD Pocket 4). Encrypted partycje:
- Nie można shrinkować przez `ntfsresize` ("Volume is encrypted")
- Nie da się mountować przez `_detect_ntfs_on_partition` → nie wykrywa Windows
- `lsblk` pokazuje `FSTYPE=BitLocker` zamiast `ntfs`

`detect_bitlocker()` skanuje `lsblk -lno PATH,FSTYPE` szukając `BitLocker`, ustawia `BITLOCKER_DETECTED=1`, `BITLOCKER_PARTITIONS`, dodaje do `DETECTED_OSES` jako "Windows (BitLocker encrypted)". `get_hardware_summary` w `tui/hw_detect.sh` wyświetla warning z instrukcją Windows-side fix (Control Panel → BitLocker → Turn off, `powercfg /h off`, Shift+Click Shut down). Warning-only, instalacja kontynuuje (user może wybrać inny dysk lub single-boot na innym).

### Dracut config dla btrfs (`lib/kernel.sh` `_configure_dracut_root`)

Wywoływane **PRZED** `kernel_install_dist` (nie po) — `emerge gentoo-kernel-bin` uruchamia dracut w postinst hook który WYMAGA `/etc/dracut.conf.d/root.conf` żeby zadziałać w chroot kontekście.

Dla btrfs dodaje `rootflags=subvol=@` (lub innego subvol jeśli `BTRFS_SUBVOLUMES` mapuje inny do `/`). Bez tego po reboocie kernel nie znajdzie roota — bootuje na top-level btrfs gdzie tylko subwoluminy widoczne jako foldery.

### --resume na btrfs subvol (`lib/utils.sh`)

`_scan_partition_for_resume`, `_recover_resume_data`, `infer_config_from_partition` próbują `subvol=@` NAJPIERW dla btrfs partycji. Top-level mount succeeds ale gubi zawartość subwoluminu — checkpoints w `/tmp/gentoo-installer-checkpoints/` (na `@` subvol) niewidoczne z top-level. Pierwsza próba bez subvol = "Resume: Nothing Found" mimo że dane są na dysku. Fallback do top-level tylko gdy `subvol=@` nie istnieje.

### shim binary search (`lib/secureboot.sh` `_setup_shim`)

`sys-boot/shim` w Gentoo instaluje pliki w różnych lokalizacjach zależnie od wersji/USE flags. Search path:
1. `/usr/share/shim`, `/usr/lib/shim`, `/usr/lib64/shim`
2. `/usr/share/shim-signed`, `/usr/lib/shim-signed`
3. `/usr/share/secureboot/shim`

Jeśli `shimx64.efi` nie znaleziony — sprawdza czy `sys-boot/shim` zainstalowany w `/var/db/pkg/`. Jeśli nie — retry emerge (bez binpkg). Jeśli nadal nic — fallback do parsowania `/var/db/pkg/sys-boot/shim-*/CONTENTS` z `awk`. Error message wskazuje manual recovery (emerge, find, cp na ESP, efibootmgr).

### Hyprland Ecosystem (lib/portage.sh)

`install_hyprland_ecosystem()` — opcja w `tui/extra_packages.sh` (tylko gdy desktop). Gdy `ENABLE_HYPRLAND=yes`:
1. Konfiguruje hyproverlay repo: `eselect repository enable hyproverlay`, sync, `*/*::hyproverlay ~amd64`, unmask `gui-wm/hyprland`
2. Instaluje pełne atomy: `gui-wm/hyprland gui-apps/hyprpaper gui-apps/hypridle gui-apps/hyprlock gui-apps/waybar gui-apps/wofi gui-apps/mako gui-apps/grim gui-apps/slurp gui-apps/wl-clipboard app-misc/brightnessctl` (brightnessctl z GURU overlay — automatycznie włącza GURU)
3. Wywoływana z `install_extra_packages()` przed `install_noctalia_shell()`
4. Niezależna od Noctalia Shell — obie opcje mogą być zaznaczone jednocześnie

### Noctalia Shell

Noctalia Shell to shell do **Wayland compositorów** (Niri/Hyprland/Sway), NIE do KDE Plasma. Instalowanie go obok KDE nie szkodzi, ale nie będzie działać bez osobnego compositora. GURU overlay wymaga `dev-vcs/git` do synca.

- **noctalia-qs** (`gui-apps/noctalia-qs`) jest ściągany automatycznie jako RDEPEND noctalia-shell (od v4.6 zastąpił quickshell)
- **Compositor NIE jest zależnością** — trzeba go zainstalować osobno
- Instalator pyta o wybór compositora (Hyprland/Niri/Sway) gdy użytkownik zaznaczy Noctalia
- Zmienna `NOCTALIA_COMPOSITOR` przechowuje wybór (hyprland/niri/sway)
- Autostart konfigurowany w `/etc/skel/.config/{hypr,niri,sway}/` + kopiowany do usera

### ASUS ROG / Hybrid GPU Support

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

**Nowe CONFIG_VARS**: `HYBRID_GPU`, `IGPU_VENDOR`, `IGPU_DEVICE_NAME`, `DGPU_VENDOR`, `DGPU_DEVICE_NAME`, `ASUS_ROG_DETECTED`, `ENABLE_ASUSCTL`

### Microsoft Surface Support

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

**Nowe CONFIG_VARS**: `SURFACE_DETECTED`, `SURFACE_MODEL`, `ENABLE_IPTSD`, `ENABLE_SURFACE_CONTROL`

### Secure Boot (MOK Signing)

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

**Nowe CONFIG_VARS**: `ENABLE_SECUREBOOT`

### Peripheral Detection & Auto-Install

**Detekcja** (`lib/hardware.sh`): 5 funkcji `detect_*()` wywoływanych z `detect_all_hardware()`:
- `detect_bluetooth()` — `/sys/class/bluetooth/hci*`
- `detect_fingerprint()` — USB vendor IDs: 06cb (Synaptics), 27c6 (Goodix), 147e (AuthenTec), 138a (Validity), 04f3 (Elan + "fingerprint" w opisie)
- `detect_thunderbolt()` — `/sys/bus/thunderbolt/devices/[0-9]*` lub `lspci -nn | grep thunderbolt|USB4`
- `detect_sensors()` — `/sys/bus/iio/devices/iio:device*/name` matching accel/gyro/als/light/incli
- `detect_webcam()` — `/sys/class/video4linux/video*/name`
- `detect_wwan()` — `lspci -nnd 8086:7360` (Intel XMM7360 LTE Advanced)

**Auto z desktopem** (jak PipeWire):
- Bluetooth (`net-wireless/bluez`) — `_install_bluetooth()` w `lib/desktop.sh`
- CUPS (`net-print/cups` + `net-print/cups-filters`) — `_install_printing()` w `lib/desktop.sh`
- AMD microcode (`sys-firmware/amd-microcode`) — `lib/kernel.sh` (symetrycznie do Intel)

**Opt-in w checkliście** (`tui/extra_packages.sh`) — widoczne tylko gdy sprzęt wykryty:
- Fingerprint → `sys-auth/fprintd` + `sys-auth/libfprint` (`install_fingerprint_tools()` w `lib/portage.sh`)
- Thunderbolt → `sys-apps/bolt` (`install_thunderbolt_tools()` w `lib/portage.sh`)
- IIO sensors → `sys-apps/iio-sensor-proxy` (`install_sensor_tools()` w `lib/portage.sh`)
- WWAN LTE → `net-misc/modemmanager` + `net-libs/libmbim` + `net-libs/libqmi` (`install_wwan_tools()` w `lib/portage.sh`) — warning: MM >= 1.26 dla XMM7360, FCC unlock
- v4l-utils → `media-video/v4l-utils` (stały item, domyślnie off)

**OpenRC warningi** (`tui/init_select.sh`): fprintd i bolt wymagają systemd — notice dialogs.

**Grupy użytkownika**: `lp` dodana do domyślnych grup (`tui/user_config.sh`) dla CUPS.

**Inference** (`lib/utils.sh`): `_infer_fingerprint_from_packages()`, `_infer_thunderbolt_from_packages()`, `_infer_sensors_from_packages()`, `_infer_wwan_from_packages()` — sprawdzają `var/db/pkg/` lub binaria.

**Nowe CONFIG_VARS**: `BLUETOOTH_DETECTED`, `FINGERPRINT_DETECTED`, `ENABLE_FINGERPRINT`, `THUNDERBOLT_DETECTED`, `ENABLE_THUNDERBOLT`, `SENSORS_DETECTED`, `ENABLE_SENSORS`, `WEBCAM_DETECTED`, `WWAN_DETECTED`, `ENABLE_WWAN`

### UMPC Support (GPD Pocket 4 / Pocket 3, GPD Win Mini/4/Max 2, Chuwi MiniBook X)

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
- **GPD fan daemon note** (`_umpc_write_gpd_fan_note`): No Gentoo ebuild for `gpd-fan-daemon` in main tree or GURU. Writes manual install instructions to `/root/POST-INSTALL-NOTES.txt` (DKMS for `gpd-fan` kernel module + `cargo build` for userspace daemon from Cryolitia/gpd-fan-daemon).
- **Quirks summary** (`_umpc_append_summary`): Logs everything applied + override instructions to `/root/POST-INSTALL-NOTES.txt` so user can audit and adjust panel orientation values if wrong on first boot.

**New CONFIG_VARS**: `UMPC_DETECTED`, `UMPC_VENDOR`, `UMPC_MODEL`, `UMPC_PANEL_ORIENTATION`, `UMPC_VIDEO_CONNECTOR`, `UMPC_FBCON_ROTATE`, `UMPC_ALC287_QUIRK`, `UMPC_GPD_FAN`. **New checkpoint**: `umpc_quirks` (between `extras` and `finalize`).

### gum TUI backend

Trzeci backend TUI obok `dialog` i `whiptail`. Statyczny binary zaszyty w repo jako `data/gum.tar.gz` (gum v0.17.0, ~4.5 MB). Zero zależności od sieci.

**Bundling i ekstrakcja**:
- `data/gum.tar.gz` — tarball z `gum_0.17.0_Linux_x86_64/gum` (statyczny ELF x86-64)
- `_extract_bundled_gum()` w `lib/dialog.sh` — ekstrakt do `${GUM_CACHE_DIR}` (`/tmp/gentoo-installer-gum/gum`), `chmod +x`, weryfikacja `gum --version`
- `PATH` rozszerzony o `GUM_CACHE_DIR` — `command -v gum` działa wszędzie (w tym w `try()`)
- Stałe: `GUM_VERSION`, `GUM_CACHE_DIR` w `lib/constants.sh`

**Priorytet detekcji**: gum > dialog > whiptail (w `_detect_dialog_backend()`).

**Opt-out**: `GUM_BACKEND=0` env → pomiń gum, użyj dialog/whiptail. Uszkodzony tarball → automatyczny fallback.

**Theme**: `_setup_gum_theme()` ustawia env vars (`GUM_CHOOSE_*`, `GUM_INPUT_*`, `GUM_CONFIRM_*`) z cyan (6) accent, matchując istniejący `data/dialogrc`.

**Wizualia**: `_gum_backtitle()` — pasek tytułowy na górze (jak dialog `--backtitle`). `_gum_style_box()` — `gum style --border rounded --border-foreground 6 --padding "1 2" --width 76`. Menu/radiolist/checklist: kursor `▸`, podświetlenie `--selected.foreground 0 --selected.background 6`. Gauge: `█░` progress bar.

**Kluczowy mechanizm**: Desc→tag mapping. `--label-delimiter` jest zepsuty w gum 0.17.0 (nigdy nie zwraca tagów). Zamiast tego: osobne tablice `gum_tags[]` i `gum_descs[]`, wyświetlamy tylko opisy, a po wyborze mapujemy wybrany opis z powrotem na tag. Dotyczy dialog_menu, dialog_radiolist, dialog_checklist.

**Terminal response handling**: gum/termenv wysyła OSC 11 (background color query) i CPR (cursor position). `COLORFGBG="15;0"` zapobiega OSC 11. `stty -echo` przy init gum zapobiega wyświetlaniu odpowiedzi terminala. `_gum_drain_tty()` czyści bufor /dev/tty przed każdym interaktywnym gum choose.

**Chroot**: gum nie potrzebny wewnątrz chroota — `try()` ma text fallback, TUI wizard działa w outer process.

### Dwufazowe operacje dyskowe

1. `disk_plan_auto()` / `disk_plan_dualboot()` — buduje `DISK_ACTIONS[]` + `DISK_STDIN[]`
2. `disk_execute_plan()` — iteruje i wykonuje przez `try` (stdin piped dla sfdisk)

Partycjonowanie używa `sfdisk` (util-linux) — atomowy skrypt stdin zamiast sekwencyjnych wywołań. Jedna komenda `sfdisk` tworzy GPT label + wszystkie partycje naraz. `disk_plan_add_stdin()` przechowuje dane stdin w `DISK_STDIN[]` (tablica równoległa do `DISK_ACTIONS[]`).

### Checkpointy

`checkpoint_set "nazwa"` tworzy plik w `$CHECKPOINT_DIR`. `checkpoint_reached "nazwa"` sprawdza. Po zamontowaniu dysku docelowego `checkpoint_migrate_to_target()` przenosi checkpointy z `/tmp` na `${MOUNTPOINT}/tmp/gentoo-installer-checkpoints/` — znikają automatycznie przy reformatowaniu dysku.

Wznowienie po awarii: `screen_progress()` sprawdza istniejące checkpointy i pyta użytkownika czy wznowić. `checkpoint_validate()` weryfikuje artefakty faz (np. czy stage3 jest rozpakowany, czy make.conf istnieje) — nieważne checkpointy są usuwane.

**`--resume` mode**: `try_resume_from_disk()` w `lib/utils.sh` skanuje partycje (ext4/xfs/btrfs) szukając checkpointów i configa. Zwraca: 0 = config + checkpointy, 1 = tylko checkpointy, 2 = nic nie znaleziono. `_save_config_to_target()` w `tui/progress.sh` zapisuje config na dysk docelowy po fazie partycjonowania — dzięki temu `--resume` może go odzyskać.

**Config inference (rc=1)**: Gdy `--resume` znajdzie checkpointy ale nie config, `infer_config_from_partition()` w `lib/utils.sh` odczytuje konfigurację z plików na partycji docelowej: `/etc/fstab` (partycje, filesystem), `/etc/portage/make.conf` (GPU, CPU, init system, mirror), `/etc/hostname`, `/etc/timezone`, `/etc/locale.gen`, `/etc/vconsole.conf`, `package.accept_keywords/` (kernel type), `repos.conf/guru.conf` (GURU). Zwraca 0 jeśli wystarczające (ROOT, ESP, FILESYSTEM, DISK, INIT_SYSTEM), 1 jeśli nie — wtedy wizard jest uruchamiany z pre-filled values. Testowanie: `_RESUME_TEST_DIR` + `_INFER_UUID_MAP` (fake filesystem zamiast prawdziwego mount/blkid).

### Funkcja `try`

`try "opis" polecenie args...` — na błędzie wyświetla menu Retry/Shell/Continue/Log/Abort. Każde polecenie które może się nie udać MUSI iść przez `try`.

Dwa tryby działania:
- **Normalny**: output komendy → log file (silent). Dialog UI dla menu recovery.
- **`LIVE_OUTPUT=1`**: output komendy → `tee` (terminal + log). Ustawiany w fazie chroot.

Gdy `dialog` nie jest dostępny (np. wewnątrz chroota stage3), `try()` używa prostego textowego menu: `(r)etry | (s)hell | (c)ontinue | (a)bort`.

### Walidacja konfiguracji

`validate_config()` w `lib/config.sh` — lekka walidacja PRZED rozpoczęciem instalacji. Wywoływana na wejściu do `screen_summary()` w `tui/summary.sh`. Jeśli walidacja się nie powiedzie, wyświetla listę błędów i zwraca `TUI_BACK`.

Sprawdza:
1. **Wymagane zmienne** — INIT_SYSTEM, TARGET_DISK, FILESYSTEM, HOSTNAME, TIMEZONE, LOCALE, KERNEL_TYPE, GPU_VENDOR, USERNAME, ROOT_PASSWORD_HASH, USER_PASSWORD_HASH
2. **Wartości enum** — INIT_SYSTEM ∈ {systemd, openrc}, FILESYSTEM ∈ {ext4, btrfs, xfs}, itd.
3. **Format** — HOSTNAME (RFC 1123), LOCALE (xx_XX.UTF-8)
4. **Block devices** — TARGET_DISK, ESP_PARTITION, ROOT_PARTITION (pomijane w `DRY_RUN=1`)
5. **Spójność cross-field** — SWAP_TYPE=partition → SWAP_SIZE_MIB > 0, dual-boot → ESP_PARTITION

## Uruchamianie testów

```bash
bash tests/test_config.sh      # Config round-trip (13 assertions)
bash tests/test_hardware.sh    # CPU march + GPU database (16 assertions)
bash tests/test_disk.sh        # Disk planning dry-run with sfdisk (21 assertions)
bash tests/test_makeconf.sh    # make.conf generation (18 assertions)
bash tests/test_checkpoint.sh  # Checkpoint validate + migrate (16 assertions)
bash tests/test_resume.sh      # Resume from disk scanning + recovery (30 assertions)
bash tests/test_multiboot.sh   # Multi-boot OS detection + serialization (26 assertions)
bash tests/test_infer_config.sh # Config inference from installed system (53 assertions)
bash tests/test_hybrid_gpu.sh  # Hybrid GPU + ASUS ROG + recommendation (27 assertions)
bash tests/test_validate.sh    # Config validation before install (31 assertions)
bash tests/test_shrink.sh      # Partition shrink planning and helpers (37 assertions)
bash tests/test_surface.sh     # Surface detection, config vars, kernel types, inference (25 assertions)
bash tests/test_peripherals.sh # Peripheral detection, config vars, inference (30 assertions)
bash tests/test_umpc.sh        # UMPC detection (GPD Pocket/Win, Chuwi MiniBook X) + GRUB cmdline (36 assertions)
```

Wszystkie testy są standalone — nie wymagają root ani hardware. Używają `DRY_RUN=1` i `NON_INTERACTIVE=1`. **Wymagają GNU coreutils + GNU sed** (środowisko docelowe = Gentoo Live ISO). Na macOS/BSD `test_resume.sh` (assertion permissji — `stat -c` to GNU-only) i `test_infer_config.sh` (parsowanie HOSTNAME/KEYMAP — `sed '...; T; q'` używa GNU-only `T`) zgłaszają fałszywe FAIL-e mimo poprawnego kodu. Weryfikację zmian rób na Linuksie.

## Znane wzorce i pułapki

- `(( var++ ))` przy var=0 zwraca exit 1 pod `set -e` → zawsze dodawać `|| true`
- `lib/constants.sh` używa `: "${VAR:=default}"` zamiast `readonly` żeby testy mogły nadpisywać
- `lib/protection.sh` sprawdza `$_GENTOO_INSTALLER` — testy muszą to exportować
- `config_save` używa `${VAR@Q}` (bash 4.4+) do bezpiecznego quotingu, tworzy plik z `umask 077` (zawiera hashe haseł)
- `config_load` source'uje przefiltrowany plik tymczasowy (tylko znane CONFIG_VARS), nie surowy input — zapobiega injection
- Dialog: `2>&1 >/dev/tty` (dialog) vs `3>&1 1>&2 2>&3` (whiptail) — oba obsłużone w `lib/dialog.sh`
- Pliki lib/ NIGDY nie są uruchamiane bezpośrednio — zawsze sourcowane
- **`$*` vs `"$@"` vs `printf '%q '`**: Gdy komenda jest budowana jako string i później wykonywana przez `bash -c`, `$*` traci quoting argumentów ze spacjami (np. `"EFI System Partition"` → trzy osobne tokeny). Rozwiązanie: `printf '%q ' "$@"` zachowuje quoting. Dotyczy: `disk_plan_add()`, `disk_plan_add_stdin()`, `chroot_exec()`, `dialog_prgbox()`. Bezpośrednie wykonanie (`"$@"`) nie ma tego problemu (np. `try()` linia 20).
- **Interpolacja zmiennych w stringach innych języków**: Nie wstawiać zmiennych bashowych bezpośrednio w kod Pythona/Perla (np. `python3 -c "...('${password}')..."`). Znaki specjalne mogą złamać składnię lub umożliwić injection. Przekazywać przez zmienne środowiskowe (`GENTOO_PW="${password}" python3 -c "...os.environ['GENTOO_PW']..."`).
- **`grep -oP` (PCRE) niedostępny w stage3 Gentoo**: `grep` w stage3 jest skompilowany bez PCRE. Zawsze używać POSIX alternatyw: `sed 's/.*\[//;s/\].*//'` zamiast `grep -oP '\[\K[^]]+'`, `grep -o '\[pattern\]'` zamiast `grep -oP`.
- **Gentoo `.DIGESTS` format**: Plik `.DIGESTS` jest GPG clearsigned. Sekcja BLAKE2B jest PRZED SHA512. Nie ma oddzielnego `.DIGESTS.asc`. Parsowanie SHA512: użyć `awk` z tracking sekcji (`/^# SHA512/ { in_sha512=1 }`), nie `grep | head -1` (złapie BLAKE2B).
- **Checkpointy na dysku docelowym**: Po zamontowaniu dysku docelowego checkpointy są migrowane z `/tmp` na `${MOUNTPOINT}/tmp/gentoo-installer-checkpoints/`. Dzięki temu reformatowanie dysku automatycznie kasuje checkpointy. Przy wznowieniu `checkpoint_validate()` weryfikuje artefakty przed pominięciem fazy.
- **stderr redirect a dialog UI**: Gdy stderr jest przekierowany do log file (`exec 2>>LOG`), `dialog` jest niewidoczny (bo pisze na stderr). `try()` musi tymczasowo przywrócić stderr (fd 4) żeby pokazać menu recovery. Wzorzec: `if { true >&4; } 2>/dev/null; then exec 2>&4; fi`.
- **`dialog` brak w chroot stage3**: Świeży stage3 nie ma `dialog`. `try()` musi mieć text fallback (`read -r` z `/dev/tty`) zamiast `dialog_menu`. Sprawdzanie: `command -v "${DIALOG_CMD:-dialog}"`.
- **`/dev/tty` ENXIO w chroocie → recovery menu auto-abortowało**: W fazie chroot proces często NIE ma controlling terminala — `open(/dev/tty)` zwraca ENXIO mimo że `stdin` (fd 0) nadal jest prawdziwym terminalem (dziedziczonym przez `chroot`). Stary text-fallback `try()` czytał TYLKO z `/dev/tty` i na błędzie robił `_reply="a"` → **abort**: każdy fail w chroocie (np. jeden pakiet KDE) cicho ubijał całą instalację + teardown zanim operator zdążył wybrać. Fix: próbować `/dev/tty`, potem fallback na `stdin` (`[[ -t 0 ]]`), a gdy nic nie czytelne — `retry` (widoczne, przerywalne Ctrl-C, naprawialne z drugiej konsoli), NIGDY destrukcyjny abort. Tylko jawne `a*` = abort. Złapane empirycznie na GPD Pocket 4 (plasma-vault fail → pełny teardown).
- **`set -euo pipefail` + `inherit_errexit` + `grep` w `$()`**: `grep` zwraca exit 1 na brak dopasowania. Z `pipefail` cały pipeline failuje. Z `inherit_errexit` set -e działa wewnątrz `$()`. Efekt: `var=$(cmd | grep pattern | head -1)` zabija skrypt PRZED dotarciem do `if [[ -z "$var" ]]`. Rozwiązanie: `|| true` na końcu `$()`.
- **Partycje z poprzedniej instalacji blokują `sfdisk`**: Przy ponownej próbie instalacji, partycje docelowego dysku mogą być nadal zamontowane. `sfdisk` odmawia zapisu jeśli partycje są w użyciu. Rozwiązanie: `cleanup_target_disk()` odmontowuje wszystkie partycje i deaktywuje swap przed `disk_execute_plan()`.
- **`eselect locale` format `utf8` nie `UTF-8`**: `eselect locale set "pl_PL.UTF-8"` → "target doesn't appear to be valid". eselect wymaga formatu `pl_PL.utf8`. Rozwiązanie: `${locale/UTF-8/utf8}` w `system_set_locale()`.
- **Non-English locale + `myspell-en`**: L10N bez regionalnego wariantu angielskiego (np. `L10N="pl-PL en"` bez `en-US`) powoduje REQUIRED_USE failure dla `myspell-en`. Rozwiązanie: zawsze dodawać `en-US` jako fallback w L10N.
- **`locale-gen` musi się zakończyć przed `eselect locale list`**: Jeśli `locale-gen` nie dokończy (np. przez orphan tee), `eselect locale list` pokaże tylko `C`, `C.UTF-8`, `POSIX` — wygenerowane locale nie pojawią się. Ręczne naprawienie: `echo "pl_PL.UTF-8 UTF-8" > /etc/locale.gen && locale-gen`.
- **Zabicie `tee` może kaskadowo ubić bieżącą komendę**: Gdy `try()` używa `| tee`, zabicie procesu `tee` powoduje broken pipe → SIGPIPE do komendy (np. genkernel). Efekt: komenda pada w trakcie pracy. NIE zabijać tee podczas trwającej kompilacji — poczekać aż się zawiesi (brak aktywności w `top`).
- **`genkernel` przy retry buduje od nowa**: `genkernel all` robi `make mrproper` na początku, co kasuje poprzedni build. Retry po padnięciu = pełna rekompilacja (20-60 min). To normalne zachowanie genkernel.
- **Exit code `0` przy faktycznym błędzie w `try()`**: Po `if cmd; then ...; fi` bez `else`, bash ustawia `$?` na 0 niezależnie od exit code komendy ("if no condition tested true" → exit 0). Efekt: `try()` wyświetla "Failed (exit 0)" mimo faktycznego błędu. Bug kosmetyczny — detekcja błędu działa poprawnie.
- **Hasła/hashe NIGDY w argumentach komend**: `openssl passwd -6 "${password}"` i `usermod -p "${hash}"` są widoczne w `ps aux`. Używać: `openssl passwd -6 -stdin <<< "${password}"` i `bash -c 'echo "user:$1" | chpasswd -e' -- "${hash}"`.
- **`eval` na zewnętrznych danych**: Nie używać `eval "${line}"` na output `blkid` / plików konfiguracyjnych. Złośliwy label partycji może zawierać kod. Parsować przez `case`/`read` lub `declare`.
- **Hostname validation**: Hostname trafia do `/etc/conf.d/hostname` (source'owany przez OpenRC) i `/etc/hosts`. Walidować regex RFC 1123: `^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$`.
- **`eval echo "~${user}"` → injection**: Zamiast tego `getent passwd "${user}" | cut -d: -f6`.
- **`try_resume_from_disk()` zwraca 0/1/2, nie boolean**: 0 = config + checkpointy, 1 = tylko checkpointy, 2 = nic. Testowanie: `_RESUME_TEST_DIR` przełącza na fake katalogi zamiast prawdziwego mount. Nie używać `if try_resume_from_disk` — zawsze `rc=0; try_resume_from_disk || rc=$?; case ${rc}`.
- **DNS na Live ISO**: Live ISO może nie mieć skonfigurowanego DNS. `ensure_dns()` w preflight automatycznie dodaje `8.8.8.8` jeśli ping po IP działa ale po nazwie nie.
- **Motyw dialog**: `data/dialogrc` ładowany przez `export DIALOGRC=` w `init_dialog()`. Whiptail ignoruje DIALOGRC. Gum używa `GUM_CHOOSE_*`/`GUM_INPUT_*` env vars.
- **NIGDY `source /etc/profile` w instalatorze**: Skrypty `/etc/profile.d/` mogą odwoływać się do niezdefiniowanych zmiennych — `set -u` zabija skrypt mimo `|| true` (błąd ekspansji zachodzi PRZED wykonaniem komendy, `||` tego nie łapie). Ponadto resetuje PATH (gum znika) i LANG (parsowanie locale-dependent). Sam `env-update` wystarczy — zapisuje pliki na dysk, system załaduje je przy starcie.
- **`stage3_extract` cleanup odmontowuje ESP**: Cleanup w `stage3_extract()` usuwał stare pliki przy retry. Problem: katalog `efi/` (mount point ESP) też był usuwany, bo `find` go łapał. Po ekstrakcji stage3 (który nie zawiera `/efi`), `grub-install --efi-directory=/efi` failował. Rozwiązanie: cleanup pomija `efi` w find/rm, a po ekstrakcji ESP jest re-montowany. Dodatkowy safety net w `_execute_chroot_phase()` — sprawdza i re-montuje ESP przed wejściem do chroot.
- **Shim binary w podkatalogu z wersją**: Gentoo `sys-boot/shim` instaluje `shimx64.efi` w `/usr/share/shim/15.8/` (podkatalog z wersją), nie bezpośrednio w `/usr/share/shim/`. `_setup_shim()` w `secureboot.sh` używa `find` rekursywnie zamiast sprawdzania fixed paths.
- **`STAGE3_FILE` unbound przy resume**: Gdy `stage3_download` checkpoint przetrwa ale faza jest pominięta, `STAGE3_FILE` nie jest ustawione. `stage3_verify()`/`stage3_extract()` używają `_find_stage3_file()` do fallback — szuka `stage3-amd64-*.tar.xz` na `MOUNTPOINT`.
- **`infer_config_from_partition` i testowanie**: Przy `_RESUME_TEST_DIR` ustawionym, `infer_config_from_partition` używa `_RESUME_TEST_DIR/mnt/<part>` zamiast prawdziwego mount. UUID resolver (`_resolve_uuid`) czyta z `_INFER_UUID_MAP` file zamiast `blkid -U`. Parsowanie make.conf: single-line only (nie obsługuje backslash continuation).
- **`[[ -n "$x" ]] && cmd` pod `set -e` + `inherit_errexit` w funkcjach testowych**: Gdy `x` jest pustym stringiem, `[[ -n "" ]]` zwraca exit 1, `&&` short-circuituje, ostatnia komenda funkcji ma rc=1 → funkcja exituje z rc=1 → `set -e` zabija test. Rozwiązanie: użyć pełnego `if [[ -n "$x" ]]; then ...; fi`. Bug łapał się w test_umpc.sh przy opcjonalnym board_name.

## Debugowanie podczas instalacji na żywym sprzęcie

Gentoo Live ISO daje dostęp do wielu TTY (`Ctrl+Alt+F1`..`F6`). TTY1 = installer, TTY2-6 = wolne konsole. SSH na Live ISO można skonfigurować ręcznie — szczegóły w README.

### Multi-boot safety

Instalator wykrywa zainstalowane OS-y (Windows, Linux) skanując partycje. Wyniki są przechowywane w `DETECTED_OSES[]` (assoc array) i serializowane do `DETECTED_OSES_SERIALIZED` na potrzeby config save/load.

Zabezpieczenia:
- Dual-boot oferowany gdy wykryto Windows LUB innego Linuksa (nie tylko Windows)
- Partycje w menu pokazują: rozmiar, fstype, label, [nazwa OS]
- Wybór partycji z OS-em wymaga wpisania `ERASE`
- Summary w trybie dual-boot wymaga `YES` i pokazuje co przetrwa
- GRUB: os-prober mountuje inne OS-y, weryfikacja grub.cfg, weryfikacja wpisów EFI
- `efibootmgr` sprawdza czy wpisy Windows/Gentoo przetrwały

## Jak dodawać nowy ekran TUI

1. Utwórz `tui/nowy_ekran.sh` z funkcją `screen_nowy_ekran()`
2. Dodaj `source "${TUI_DIR}/nowy_ekran.sh"` w `install.sh`
3. Dodaj `screen_nowy_ekran` do `register_wizard_screens` w `run_configuration_wizard()`
4. Ekran musi zwracać `TUI_NEXT`/`TUI_BACK`/`TUI_ABORT`

## Jak dodawać nową zmienną konfiguracyjną

1. Dodaj nazwę do `CONFIG_VARS[]` w `lib/constants.sh`
2. Ustaw wartość w odpowiednim ekranie TUI + `export`
3. Użyj w odpowiednim module `lib/`

## Jak dodawać nową fazę instalacji

1. Dodaj checkpoint name do `CHECKPOINTS[]` w `lib/constants.sh`
2. Dodaj logikę w `_do_chroot_phases()` (chroot) lub `run_pre_chroot()` (outer) w `install.sh`
3. Dodaj entry w `INSTALL_PHASES[]` w `tui/progress.sh`
4. Opatrz blok `if ! checkpoint_reached "nazwa"; then ... checkpoint_set "nazwa"; fi`
