# GPD Pocket 4 — notatki per-urządzenie

Skonsolidowane notatki z sesji instalacyjnych/testowych (2026-05-14 → 2026-05-28) na realnym
GPD Pocket 4 (AMD Ryzen 7 8840U, Radeon 780M, ~12 GB RAM, 8.8" 2560×1600 portret, btrfs+subvol,
OpenRC, KDE Plasma, dist-kernel). Wsparcie UMPC w instalatorze: [HARDWARE.md](HARDWARE.md#umpc-support-gpd--chuwi).

## Rola urządzenia i kierunek OS (decyzja 2026-05-28)

- Pocket 4 = **maszyna robocza na co dzień** („roboczy malec"), nie tylko mule testowy instalatora.
  Priorytet: niezawodność pracy; gaming drugorzędny (starsze gry, Steam/Proton).
- Kierunek dystrybucji (skłonność, nie decyzja ostateczna): **openSUSE Tumbleweed + GNOME** —
  kompilowanie wszystkiego na 12 GB low-power UMPC boli; TW daje rolling kernel/Mesa pod świeże
  780M, snapper+btrfs rollback; host użytkownika już na openSUSE. Dystrybucje gamingowe
  (PikaOS/Bazzite/Nobara) odrzucone — zła oś priorytetów dla maszyny roboczej.
- Stack gamingowy jest **przenośny między dystrybucjami** i dokładany NA system roboczy:
  Steam przez **Flatpak** (własny multilib runtime, zero konfliktów z systemem), natywnie
  gamemode + MangoHud + **gamescope** (jedyny element form-factor-specific: render w niższej
  rozdzielczości + skalowanie, ogarnia rotację panelu, FPS cap pod baterię/termikę).
  Szczegółowy plan Gentoo/OpenRC (Flatpaki + natywne narzędzia, power-profiles-daemon nie działa
  na OpenRC → TLP z governor=performance na zasilaniu) ma sens tylko jeśli Gentoo zostaje jako OS.

## Twarde fakty sprzętowe

- **Touchpad = USB mysz (HAILUCK USB KEYBOARD Mouse), firmware-level.** Emituje tylko zdarzenia
  HID mouse — multitouch NIGDY nie dociera do OS, więc gesty wielopalcowe touchpada są
  niemożliwe na KAŻDYM DE (warstwa libinput; potwierdzone ArchWiki/libinput-gestures #171).
  Scroll „pulsuje", two-finger right-click nie do włączenia; tap-to-click działa. Nie ma fixa
  udev/hwdb. Ergonomię opierać o **ekran dotykowy** (GNOME edge-swipes, lisgd na wlroots).
- **Wiatrak: `gpd_fan` jest mainline od kernela 6.18** (drivers/hwmon/gpd-fan.c; DMI alias
  `pn*G1628-04-L*` — Pocket 4 to wariant `-L`). Zero DKMS/Rust. Setup: modules-load + local.d
  ustawiający `pwm1_enable=2` (auto, krzywa EC). `sensors` → `gpdfan-isa-0000 fan1 ~2400 RPM`.
- **Rotacja, pełny łańcuch** (zweryfikowane na sprzęcie): kernel param
  `fbcon=rotate:1 video=eDP-1:panel_orientation=right_side_up` rotuje TTY + Plasma Wayland;
  **greeter SDDM leci na Xorg, który IGNORUJE panel_orientation** → potrzebny `xrandr --rotate`
  w SDDM Xsetup. Dwie pułapki: Xorg nazywa panel **`eDP`** (nie DRM-owe `eDP-1`); `x11-apps/xrandr`
  NIE jest w plasma-meta (bez niego Xsetup cicho pada exit 127). Zautomatyzowane w
  `umpc_quirks::_umpc_rotate_sddm_greeter`. GRUB menu zawsze portret (renderuje przed kernelem).
- **Akcelerometr MXC6655**: moduł `CONFIG_MXC4005=m` jest; auto-rotacja wymaga hwdb mount-matrix
  (`/etc/udev/hwdb.d/61-sensor-pocket4.hwdb`, `ACCEL_MOUNT_MATRIX=0, -1, 0; -1, 0, 0; 0, 0, 1`,
  znaki macierzy do stestowania) + iio-sensor-proxy w default runlevel.
- **Termika**: peak ~25 W, 85–90°C w grach, throttling po dłuższej sesji — akceptowalne casual.
- **eGPU/USB4**: host router działa; autoryzacja urządzeń TB ręcznie `boltctl enroll`
  (CLI ok na OpenRC, GUI bolt nie wystartuje).
- Ekran 8.8" ~330 DPI → Plasma scale 175–200%; gry w niższych rozdzielczościach per-tytuł.

## Pułapki operacyjne instalatora (na sprzęcie — nie powtarzać)

- **NIGDY nie montować ręcznie dysku docelowego przed `./install.sh --resume`** — skaner resume
  nie zamontuje zajętej partycji → fallback do świeżej instalacji → format. Także `tail -F`
  na plikach z targetu trzyma mount busy (`fuser -vm` do diagnozy).
- Przy resume na istniejącym systemie pilnować, że faza `disks` odmawia formatowania
  (`_resume_target_has_system()` — fix po dwóch niemal-wipe'ach; ścieżka TUI =
  `tui/progress.sh screen_progress`, NIE tylko CLI `run_pre_chroot`).
- Przed switchem kernela: btrfs snapshot `/` (`btrfs subvolume snapshot / /.snapshots/...`)
  — rollback w 10 sekund.

## Historia bugfixów instalatora znalezionych na tym sprzęcie

Szczegóły w historii gita (commity wyłącznie `lib/`):

- **Iteracja 1 (2026-05-14, 8 bugów):** `e8f9d4e` amd-microcode nie istnieje jako pakiet +
  dracut przed kernel_install + rootflags subvol; `47e16ee` low/heavy-memory.conf per-package
  (OOM cc1plus) + `-video_cards_ati` + złagodzony notice bolt/OpenRC; `6bd1741` autounmask dla
  desktop emerge; `97a334d` shim search path; `c9fab1c` czyszczenie DETECTED_OSES po auto-partition;
  `b1661db` resume probe z `subvol=@` najpierw.
- **Iteracja 2 (2026-05-18):** `f0566e6`/`9c20476` xorg-drivers pełny zestaw flag
  `-video_cards_{radeon,radeonsi,ati}` (każda z osobna NIE wystarcza — mapowania DDX) +
  plasma-vault heavy-memory + try() w chroocie (ENXIO na /dev/tty → fallback stdin → default
  retry, nie abort); `df43c86`+`3809960` resume-wipe guard (obie ścieżki!); `6587131` build swap
  na btrfs (`btrfs filesystem mkswapfile`, próg 24 GiB, wpięcie w TUI); `a2a10ba` faza users
  PRZED desktop (lockout gdy build padł na desktop); `369a4d9` rotacja SDDM; `dc71477` podwójny
  rootflags.

## Otwarte TODO (następne sesje na tym urządzeniu)

1. **Switch dist-kernel → genkernel** (jeśli Gentoo zostaje): wizard → Narzędzia → Konserwacja
   kernela (commit `c9bfff2`). Pre-flight: ≥4 GB RAM free, ≥6 GB na /usr/src, `/proc/config.gz`
   dostępny (fallback `/boot/config-$(uname -r)`); zostawić dist-kernel jako fallback do
   potwierdzenia bootu `-custom`; po reboocie `lsmod | wc -l` ~150–250.
2. **Instalator, fan na genkernel**: dodać `CONFIG_SENSORS_GPD_FAN=m` do `_patch_kernel_config`
   dla UMPC + zaktualizować `_umpc_write_gpd_fan_note` (na 6.18+ mainline, nie DKMS).
3. **Post-install checklist** (część już zautomatyzowana przez UMPC support — weryfikować przy
   kolejnym boocie): scale+rotate w Plasma, hwdb akcelerometru, ew. shim/Secure Boot ręcznie,
   `grub-mkconfig` po wyjęciu pendrive (phantom wpis os-probera), `--deselect` xf86-video-ati
   i switcheroo-control, weryfikacja microcode w dmesg, `bluetoothctl show` → Powered: yes.
