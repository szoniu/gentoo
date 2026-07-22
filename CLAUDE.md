# CLAUDE.md — Kontekst projektu dla Claude Code

> Szczegóły wsparcia sprzętowego (Surface, ASUS ROG/hybrid GPU, UMPC/GPD/Chuwi, Secure Boot, peripherals, kernel hardware patches, AMD GPU+xorg, BitLocker) są w **[docs/HARDWARE.md](docs/HARDWARE.md)**. Ten plik trzyma architekturę, polityki budowania i pułapki.
> Notatki per-urządzenie z realnych instalacji na **GPD Pocket 4** (rola/kierunek OS, twarde fakty sprzętowe, pułapki resume, historia bugfixów, otwarte TODO) → **[docs/POCKET4.md](docs/POCKET4.md)**.
> **ThinkPad X1 Nano Gen 1** (fingerprint + WWAN, instalacja **przez SSH**) → **[docs/X1NANO.md](docs/X1NANO.md)**. Gdy user pisze „instalujemy na x1 nano" — przeczytaj ten plik i przeprowadź go przez **checklistę post-deploy** po pierwszym boocie (instalator kończy się przed nią).

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
├── utils.sh            — try (interaktywne recovery, text fallback bez dialog, LIVE_OUTPUT via tee), checkpoint_set/reached/validate/migrate_to_target, is_root/is_efi/has_network/ensure_dns, generate_password_hash, resume/inference helpers
├── dialog.sh           — Wrapper gum/dialog/whiptail, primitives (msgbox/yesno/menu/radiolist/checklist/gauge/infobox/inputbox/passwordbox), wizard runner (register_wizard_screens + run_wizard), bundled gum extraction
├── config.sh           — config_save/load/set/get/dump/diff (${VAR@Q} quoting), validate_config()
├── hardware.sh         — detect_cpu/gpu/disks/esp/installed_oses, detect_asus_rog, detect_surface, detect_umpc, detect_bitlocker, peripheral detect_*, serialize/deserialize_detected_oses, get_hardware_summary
├── disk.sh             — Dwufazowe: disk_plan_* → cleanup_target_disk + disk_execute_plan (sfdisk), mount/unmount_filesystems, get_uuid/partuuid, shrink helpers
├── network.sh          — check_network, install_network_manager, select_fastest_mirror
├── stage3.sh           — stage3_get_url/download/verify/extract
├── portage.sh          — generate_make_conf (_write_make_conf), portage_sync, profile/cpuflags, install_extra_packages, GURU/Noctalia/Hyprland/Surface/ROG/peripheral installers
├── kernel.sh           — kernel_install (dist-kernel, genkernel, surface-kernel, surface-genkernel), _patch_kernel_config, _configure_dracut_root
├── bootloader.sh       — bootloader_install, _configure_grub, os-prober mount, _verify_grub_config/_verify_efi_entries
├── secureboot.sh       — secureboot_setup, MOK keygen, kernel signing, shim, enrollment
├── system.sh           — system_set_timezone/locale/hostname/keymap, generate_fstab, install_filesystem_tools, system_create_users, system_finalize
├── desktop.sh          — desktop_install (GPU drivers, KDE Plasma/GNOME, SDDM/GDM, PipeWire, bluetooth, printing, apps)
├── swap.sh             — swap_setup (zram), ensure_build_swap/cleanup_build_swap
├── chroot.sh           — chroot_setup/teardown/exec, copy_dns_info, copy_installer_to_chroot
├── umpc.sh             — umpc_apply_quirks (ALC287 unmute, SDDM greeter rotation, GPD fan note)
├── hooks.sh            — maybe_exec 'before_X' / 'after_X'
└── preset.sh           — preset_export/import (hardware overlay)

tui/                    — Ekrany TUI (każdy plik = jedna funkcja screen_*)
data/                   — Statyczne bazy danych + bundled assets (cpu_march/gpu/mirrors DB,
                          use_flags_desktop, dialogrc, gum.tar.gz, grub-theme/)
presets/                — Przykładowe konfiguracje
tests/                  — Testy + shellcheck.sh (standalone, bez root/hardware)
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

Wszystkie zmienne konfiguracyjne są zdefiniowane w `CONFIG_VARS[]` w `lib/constants.sh`. Kluczowe (instalacja core):
- `INIT_SYSTEM` — systemd/openrc
- `TARGET_DISK` — /dev/sda, /dev/nvme0n1
- `PARTITION_SCHEME` — auto/dual-boot/manual
- `FILESYSTEM` — ext4/btrfs/xfs
- `SWAP_TYPE` — zram/partition/file/none
- `DESKTOP_TYPE` — plasma/gnome/none
- `KERNEL_TYPE` — dist-kernel/genkernel
- `SHRINK_PARTITION` / `SHRINK_PARTITION_FSTYPE` / `SHRINK_NEW_SIZE_MIB` — shrink dual-boot
- `WINDOWS_DETECTED` / `LINUX_DETECTED` / `DETECTED_OSES_SERIALIZED` — multi-boot

Zmienne specyficzne sprzętowo (GPU/Surface/ROG/UMPC/peripherals/Secure Boot) → tabela w **[docs/HARDWARE.md](docs/HARDWARE.md#device-specific-config_vars)**.

### Polityka `~amd64` (testing keywords)

NIGDY nie ustawiać `ACCEPT_KEYWORDS="~amd64"` globalnie — destabilizuje cały system. Zamiast tego per-pakiet w `/etc/portage/package.accept_keywords/`, dodawane w odpowiednim module `lib/` (nie w make.conf). Przykłady: `sys-kernel/gentoo-kernel-bin ~amd64` (kernel.sh), `gui-apps/noctalia-shell ~amd64` (portage.sh), `sys-kernel/surface-sources ~amd64` (kernel.sh). Nowe pakiety wymagające `~amd64` dodawać tym samym wzorcem.

### Konfiguracja kernela (per Gentoo Handbook)

- **installkernel**: wymaga `USE="grub"` (`package.use/installkernel`) żeby wiedział, że ma konfigurować GRUB
- **dracut**: wymaga `/etc/dracut.conf.d/root.conf` z `root=UUID=...` żeby initramfs znalazł root filesystem
- **Intel microcode**: `sys-firmware/intel-microcode` instalowany automatycznie na CPU Intel (sprawdzamy `/proc/cpuinfo`)
- **AMD microcode**: `sys-firmware/amd-microcode` instalowany automatycznie na CPU AMD
- **Intel SOF firmware**: `sys-firmware/sof-firmware` instalowany automatycznie na CPU Intel — wymagany dla audio na nowoczesnych ultrabookach (HP Dragonfly, Dell XPS, itp.)
- **PipeWire ALSA**: `media-video/pipewire` wymaga `pipewire-alsa sound-server` w package.use żeby ALSA apps routowały przez PipeWire; globalna flaga `alsa` w USE
- **cpuid2cpuflags**: uruchamiany w fazie portage_sync (PRZED @world) żeby pakiety budowały się z optymalizacjami CPU
- **Hardware patches** (genkernel/surface only): `_patch_kernel_config` robi `localmodconfig` + force-add krytycznych modułów (NVMe, WiFi by vendor, GPU, sensors, …). Pełna lista modułów → **[docs/HARDWARE.md](docs/HARDWARE.md#hardware-patches-kernela-libkernelsh-_patch_kernel_config)**.

### Time sync (chrony OpenRC)

Systemd ma `timesyncd` w bazie — działa od pierwszego boota. OpenRC nie ma nic — bez time-syncu pierwszy `emerge --sync` po reboocie umie paść na SSL handshake jeśli zegar dryfnął. `system_finalize()` w `lib/system.sh`:

- Tylko dla OpenRC: instaluje `net-misc/chrony`, `rc-update add chronyd default`, `rc-update add swclock boot` (load saved time przed chronyd discipline)
- Dla systemd: nic — timesyncd wystarczy

### Polityka pamięci dla emerge (`portage.sh` `generate_make_conf`)

Per-package MAKEOPTS limits są ZAWSZE aplikowane (nie tylko ≤8 GB RAM). Dwie warstwy w `/etc/portage/env/`:

- **`low-memory.conf`** — severe limit `-j${small_jobs}` (1-2 zależnie od RAM) dla pakietów co zjadają 4-8 GB RAM per build job: `net-libs/webkit-gtk`, `dev-qt/qtwebengine`, `dev-lang/rust`, `dev-lang/spidermonkey`
- **`heavy-memory.conf`** — moderate limit `-j${heavy_jobs}` (2-6 zależnie od RAM) dla Qt6/KDE (1-2 GB RAM per cc1plus, pełne `-j17` na 16-thread CPU OOM-killuje cc1plus nawet na 16 GB RAM): qtbase, qtdeclarative, networkmanager-qt, kio, kirigami, ktexteditor, libkscreen, plasma-workspace, plasma-desktop, kwin, plasma-vault, breeze, oxygen, kimageformats (cztery ostatnie: OOM na 12 GB GPD Pocket 4)

**Build swap (`lib/swap.sh` `ensure_build_swap`)**: Skonfigurowany swap (zram/swapfile) aktywuje się dopiero na ZBOOTOWANYM systemie — build w chroocie leci z tym co ma live env. Na 12 GB Pocket 4 = 0 swapu → cc1plus OOM-killed mimo throttle. `ensure_build_swap` dolewa tymczasowy swapfile do **24 GiB total** (RAM+swap) przed fazą chroot, usuwany przez `cleanup_build_swap` po. Idempotentny (sprawdza `swapon --show`). Pułapki naprawione: próg 12 GiB, btrfs COW (`btrfs filesystem mkswapfile`/`chattr +C`), wołany z OBU ścieżek (CLI `run_pre_chroot` + TUI `_execute_chroot_phase`).

Tier sizing scaled by RAM: >16 GB: small=-j2, heavy=-j6 · 8-16 GB: small=-j2, heavy=-j4 · 4-8 GB: small=-j2, heavy=-j2 · ≤4 GB: small=-j1, heavy=-j4. Mapowanie w `/etc/portage/package.env`.

### Plasma/GNOME emerge flags (`lib/desktop.sh`)

`_install_plasma_desktop` i `_install_gnome_desktop` używają `emerge --quiet --autounmask-write --autounmask-continue --keep-going`:
- **`--autounmask-write --autounmask-continue`** — Portage auto-zapisuje USE flag changes (np. `ngtcp2 gnutls` dla samba/kio-extras) i kontynuuje. Bez tego user wpada w try() recovery loop przy każdym change.
- **`--keep-going`** — pojedynczy failed package nie zabija 200+ pakietów emerge. Build idzie dalej, summary failed packages na końcu.

> AMD GPU + xorg-drivers (`-video_cards_radeon/radeonsi/ati` dla xorg-drivers) → szczegóły w **[docs/HARDWARE.md](docs/HARDWARE.md#amd-gpu--xorg-drivers)**.

### Dracut config dla btrfs (`lib/kernel.sh` `_configure_dracut_root`)

Wywoływane **PRZED** `kernel_install_dist` (nie po) — `emerge gentoo-kernel-bin` uruchamia dracut w postinst hook który WYMAGA `/etc/dracut.conf.d/root.conf` żeby zadziałać w chroot kontekście.

Dla btrfs dodaje `rootflags=subvol=@` (lub innego subvol jeśli `BTRFS_SUBVOLUMES` mapuje inny do `/`). Bez tego po reboocie kernel nie znajdzie roota — bootuje na top-level btrfs gdzie tylko subwoluminy widoczne jako foldery.

**GRUB cmdline NIE dubluje rootflags**: `_configure_grub` w `lib/bootloader.sh` celowo NIE wpisuje `rootflags=subvol=@` do `GRUB_CMDLINE_LINUX` — `grub-mkconfig`/`10_linux` sam wykrywa subwol zamontowanego roota i wstrzykuje **właściwy** `rootflags=subvol=<actual>`. Wpisywanie ręczne dawało duplikat (złapane na GPD Pocket 4), a zahardkodowane `@` byłoby błędne dla roota na innym subwolu. `bootloader_install` ma safety net: jeśli po `grub-mkconfig` BRAK `rootflags=subvol=` → wpisuje ręcznie do `/etc/default/grub` i regeneruje. (To osobne od dracut root.conf — dracut to initramfs, to jest kernel cmdline.)

### --resume na btrfs subvol (`lib/utils.sh`)

`_scan_partition_for_resume`, `_recover_resume_data`, `infer_config_from_partition` próbują `subvol=@` NAJPIERW dla btrfs partycji. Top-level mount succeeds ale gubi zawartość subwoluminu — checkpoints w `/tmp/gentoo-installer-checkpoints/` (na `@` subvol) niewidoczne z top-level. Pierwsza próba bez subvol = "Resume: Nothing Found" mimo że dane są na dysku. Fallback do top-level tylko gdy `subvol=@` nie istnieje.

### gum TUI backend

Trzeci backend TUI obok `dialog` i `whiptail`. Statyczny binary zaszyty w repo jako `data/gum.tar.gz` (gum v0.17.0, ~4.5 MB). Zero zależności od sieci.

- **Ekstrakcja**: `_extract_bundled_gum()` w `lib/dialog.sh` → `${GUM_CACHE_DIR}` (`/tmp/gentoo-installer-gum/gum`), `PATH` rozszerzony żeby `command -v gum` działał wszędzie (w tym w `try()`)
- **Priorytet detekcji**: gum > dialog > whiptail (`_detect_dialog_backend`). Opt-out: `GUM_BACKEND=0`. Uszkodzony tarball → automatyczny fallback
- **Theme**: `_setup_gum_theme()` — env vars (`GUM_CHOOSE_*`/`GUM_INPUT_*`/`GUM_CONFIRM_*`) z cyan (6) accent, matchując `data/dialogrc`
- **Kluczowy mechanizm**: Desc→tag mapping. `--label-delimiter` jest zepsuty w gum 0.17.0 (nigdy nie zwraca tagów). Zamiast tego osobne tablice `gum_tags[]`/`gum_descs[]`, wyświetlamy tylko opisy, po wyborze mapujemy opis z powrotem na tag. Dotyczy menu/radiolist/checklist
- **Terminal response handling**: `COLORFGBG="15;0"` zapobiega OSC 11, `stty -echo` przy init, `_gum_drain_tty()` czyści bufor /dev/tty przed każdym choose
- **Chroot**: gum nie potrzebny wewnątrz chroota — `try()` ma text fallback, wizard działa w outer process

### Dwufazowe operacje dyskowe

1. `disk_plan_auto()` / `disk_plan_dualboot()` — buduje `DISK_ACTIONS[]` + `DISK_STDIN[]`
2. `disk_execute_plan()` — iteruje i wykonuje przez `try` (stdin piped dla sfdisk)

Partycjonowanie używa `sfdisk` (util-linux) — atomowy skrypt stdin zamiast sekwencyjnych wywołań. Jedna komenda `sfdisk` tworzy GPT label + wszystkie partycje naraz. `disk_plan_add_stdin()` przechowuje dane stdin w `DISK_STDIN[]` (tablica równoległa do `DISK_ACTIONS[]`).

### Checkpointy

`checkpoint_set "nazwa"` tworzy plik w `$CHECKPOINT_DIR`. `checkpoint_reached "nazwa"` sprawdza. Po zamontowaniu dysku docelowego `checkpoint_migrate_to_target()` przenosi checkpointy z `/tmp` na `${MOUNTPOINT}/tmp/gentoo-installer-checkpoints/` — znikają automatycznie przy reformatowaniu dysku.

Wznowienie po awarii: `screen_progress()` sprawdza istniejące checkpointy i pyta użytkownika czy wznowić. `checkpoint_validate()` weryfikuje artefakty faz (np. czy stage3 jest rozpakowany, czy make.conf istnieje) — nieważne checkpointy są usuwane.

**`--resume` mode**: `try_resume_from_disk()` w `lib/utils.sh` skanuje partycje (ext4/xfs/btrfs) szukając checkpointów i configa. Zwraca: 0 = config + checkpointy, 1 = tylko checkpointy, 2 = nic. `_save_config_to_target()` w `tui/progress.sh` zapisuje config na dysk docelowy po fazie partycjonowania.

**Config inference (rc=1)**: Gdy `--resume` znajdzie checkpointy ale nie config, `infer_config_from_partition()` odczytuje konfigurację z plików na partycji: `/etc/fstab`, `make.conf` (GPU, CPU, init, mirror), `/etc/hostname`, `/etc/timezone`, `/etc/locale.gen`, `/etc/vconsole.conf`, `package.accept_keywords/` (kernel type), `repos.conf/guru.conf`. Zwraca 0 jeśli wystarczające (ROOT, ESP, FILESYSTEM, DISK, INIT_SYSTEM), 1 jeśli nie — wtedy wizard z pre-filled values. Testowanie: `_RESUME_TEST_DIR` + `_INFER_UUID_MAP`.

### Funkcja `try`

`try "opis" polecenie args...` — na błędzie wyświetla menu Retry/Shell/Continue/Log/Abort. Każde polecenie które może się nie udać MUSI iść przez `try`.

Dwa tryby działania:
- **Normalny**: output komendy → log file (silent). Dialog UI dla menu recovery.
- **`LIVE_OUTPUT=1`**: output komendy → `tee` (terminal + log). Ustawiany w fazie chroot.

Gdy `dialog` nie jest dostępny (np. wewnątrz chroota stage3), `try()` używa prostego textowego menu: `(r)etry | (s)hell | (c)ontinue | (a)bort`.

### Walidacja konfiguracji

`validate_config()` w `lib/config.sh` — lekka walidacja PRZED rozpoczęciem instalacji. Wywoływana na wejściu do `screen_summary()`. Jeśli walidacja się nie powiedzie, wyświetla listę błędów i zwraca `TUI_BACK`. Sprawdza:
1. **Wymagane zmienne** — INIT_SYSTEM, TARGET_DISK, FILESYSTEM, HOSTNAME, TIMEZONE, LOCALE, KERNEL_TYPE, GPU_VENDOR, USERNAME, ROOT_PASSWORD_HASH, USER_PASSWORD_HASH
2. **Wartości enum** — INIT_SYSTEM ∈ {systemd, openrc}, FILESYSTEM ∈ {ext4, btrfs, xfs}, itd.
3. **Format** — HOSTNAME (RFC 1123), LOCALE (xx_XX.UTF-8)
4. **Block devices** — TARGET_DISK, ESP_PARTITION, ROOT_PARTITION (pomijane w `DRY_RUN=1`)
5. **Spójność cross-field** — SWAP_TYPE=partition → SWAP_SIZE_MIB > 0, dual-boot → ESP_PARTITION

## Uruchamianie testów

Wszystkie testy są standalone — nie wymagają root ani hardware. Używają `DRY_RUN=1` i `NON_INTERACTIVE=1`. **Wymagają GNU coreutils + GNU sed** (środowisko docelowe = Gentoo Live ISO). Na macOS/BSD `test_resume.sh` (`stat -c` GNU-only) i `test_infer_config.sh` (`sed '...; T; q'` GNU-only `T`) zgłaszają fałszywe FAIL-e — weryfikację rób na Linuksie. `test_kernel_config.sh` radzi sobie sam: wykrywa nie-GNU `sed` i podstawia `gsed` przez shim w `PATH` (bez `gsed` → czysty SKIP zamiast fałszywego FAIL-a) — wzorzec do skopiowania, gdy kolejny test uderzy w ten sam problem.

```bash
bash tests/test_config.sh        # Config round-trip (13 assertions)
bash tests/test_hardware.sh      # CPU march + GPU database (16 assertions)
bash tests/test_disk.sh          # Disk planning dry-run with sfdisk (21 assertions)
bash tests/test_makeconf.sh      # make.conf generation (18 assertions)
bash tests/test_checkpoint.sh    # Checkpoint validate + migrate (16 assertions)
bash tests/test_resume.sh        # Resume from disk scanning + recovery (30 assertions)
bash tests/test_multiboot.sh     # Multi-boot OS detection + serialization (26 assertions)
bash tests/test_infer_config.sh  # Config inference from installed system (53 assertions)
bash tests/test_hybrid_gpu.sh    # Hybrid GPU + ASUS ROG + recommendation (27 assertions)
bash tests/test_validate.sh      # Config validation before install (31 assertions)
bash tests/test_shrink.sh        # Partition shrink planning and helpers (37 assertions)
bash tests/test_surface.sh       # Surface detection, config vars, kernel types, inference (25 assertions)
bash tests/test_peripherals.sh   # Peripheral detection, config vars, inference (30 assertions)
bash tests/test_umpc.sh          # UMPC detection (GPD/Chuwi) + GRUB cmdline (36 assertions)
bash tests/test_kernel_config.sh # _patch_kernel_config: promocja =m→=y, brak downgrade'u, WWAN/IOSM, idempotencja (23 assertions)

bash tests/shellcheck.sh         # Lint wszystkich *.sh (severity=warning, excl. SC1091/2034/2154/1090/2155)
```

Pojedynczy test = uruchom jego plik bezpośrednio (`bash tests/test_<x>.sh`). Brak runnera zbiorczego.

## Znane wzorce i pułapki

- `(( var++ ))` przy var=0 zwraca exit 1 pod `set -e` → zawsze dodawać `|| true`
- `lib/constants.sh` używa `: "${VAR:=default}"` zamiast `readonly` żeby testy mogły nadpisywać
- `lib/protection.sh` sprawdza `$_GENTOO_INSTALLER` — testy muszą to exportować
- `config_save` używa `${VAR@Q}` (bash 4.4+) do bezpiecznego quotingu, tworzy plik z `umask 077` (zawiera hashe haseł)
- `config_load` source'uje przefiltrowany plik tymczasowy (tylko znane CONFIG_VARS), nie surowy input — zapobiega injection
- Dialog: `2>&1 >/dev/tty` (dialog) vs `3>&1 1>&2 2>&3` (whiptail) — oba obsłużone w `lib/dialog.sh`
- Pliki lib/ NIGDY nie są uruchamiane bezpośrednio — zawsze sourcowane
- **`$*` vs `"$@"` vs `printf '%q '`**: Gdy komenda jest budowana jako string i później wykonywana przez `bash -c`, `$*` traci quoting argumentów ze spacjami (np. `"EFI System Partition"` → trzy osobne tokeny). Rozwiązanie: `printf '%q ' "$@"` zachowuje quoting. Dotyczy: `disk_plan_add()`, `disk_plan_add_stdin()`, `chroot_exec()`, `dialog_prgbox()`. Bezpośrednie wykonanie (`"$@"`) nie ma tego problemu.
- **Interpolacja zmiennych w stringach innych języków**: Nie wstawiać zmiennych bashowych bezpośrednio w kod Pythona/Perla. Znaki specjalne mogą złamać składnię lub umożliwić injection. Przekazywać przez zmienne środowiskowe (`GENTOO_PW="${password}" python3 -c "...os.environ['GENTOO_PW']..."`).
- **`grep -oP` (PCRE) niedostępny w stage3 Gentoo**: `grep` w stage3 jest skompilowany bez PCRE. Zawsze POSIX: `sed 's/.*\[//;s/\].*//'` zamiast `grep -oP '\[\K[^]]+'`.
- **Gentoo `.DIGESTS` format**: Plik jest GPG clearsigned. Sekcja BLAKE2B jest PRZED SHA512. Parsowanie SHA512: `awk` z tracking sekcji (`/^# SHA512/ { in_sha512=1 }`), nie `grep | head -1` (złapie BLAKE2B).
- **Checkpointy na dysku docelowym**: Po zamontowaniu migrowane z `/tmp` na `${MOUNTPOINT}/tmp/gentoo-installer-checkpoints/`. Reformatowanie dysku automatycznie kasuje checkpointy. Przy wznowieniu `checkpoint_validate()` weryfikuje artefakty przed pominięciem fazy.
- **stderr redirect a dialog UI**: Gdy stderr przekierowany do log file (`exec 2>>LOG`), `dialog` jest niewidoczny (pisze na stderr). `try()` musi tymczasowo przywrócić stderr (fd 4): `if { true >&4; } 2>/dev/null; then exec 2>&4; fi`.
- **`dialog` brak w chroot stage3**: Świeży stage3 nie ma `dialog`. `try()` musi mieć text fallback (`read -r` z `/dev/tty`) zamiast `dialog_menu`. Sprawdzanie: `command -v "${DIALOG_CMD:-dialog}"`.
- **Tworzenie usera/haseł MUSI być przed kernel/desktop**: `system_create_users` była w fazie `users` PO `desktop` (najdłuższa, najbardziej awaryjna faza). Gdy desktop padał, faza `users` nigdy nie ruszała → root z `*` (zablokowany), brak usera → **system bez logowania**. Zablokowało realny GPD Pocket 4. Fix: przeniesione do fazy `users` zaraz po `system_config`, przed `kernel`/`desktop`. Guard: gdy `ROOT_PASSWORD_HASH` puste (resume bez odzyskanych haseł — hashe nie są inferowalne) → `eerror` + NIE ustawia checkpointu `users` (retry zamiast cichego lockoutu). Recovery: Live USB → chroot → `passwd` + `useradd`.
- **Brak checkpointu `disks` ≠ pusty dysk → blind reformat / wipe (root-cause: walidacja PRZED mountem)**: Pre-mount w `screen_progress` (`tui/progress.sh`) był bramkowany na `checkpoint_reached "disks"`. Przy resume istniejącego systemu BEZ tego checkpointu dysk nie był montowany → `_validate_and_clean_checkpoints` sprawdzało puste `${MOUNTPOINT}` → **błędnie kasowało ważne** checkpointy → faza `disks` formatowała / `stage3_extract` re-run wymazywał system. Dwa razy o mało nie skasowało systemu (godziny buildu) na GPD Pocket 4. Fix (3 spójne): (1) `_resume_target_has_system()` — read-only probe `/etc/gentoo-release`; (2) pre-mount montuje też gdy `MODE=resume` i system istnieje; (3) faza `disks` w `tui/progress.sh` ORAZ `run_pre_chroot` w `install.sh` — gdy resume i system istnieje → NIE `disk_execute_plan`, tylko mount + kontynuacja. **Ścieżka TUI = `tui/progress.sh screen_progress`, NIE `run_pre_chroot` (CLI) — fixy muszą iść w obie.**
- **`/dev/tty` ENXIO w chroocie → recovery menu auto-abortowało**: W fazie chroot proces często NIE ma controlling terminala — `open(/dev/tty)` zwraca ENXIO mimo że `stdin` (fd 0) nadal jest terminalem (dziedziczonym przez `chroot`). Stary text-fallback `try()` czytał TYLKO z `/dev/tty` i na błędzie robił `_reply="a"` → **abort**: każdy fail w chroocie cicho ubijał całą instalację. Fix: próbować `/dev/tty`, potem fallback na `stdin` (`[[ -t 0 ]]`), a gdy nic nie czytelne — `retry` (NIGDY destrukcyjny abort). Tylko jawne `a*` = abort. Złapane na GPD Pocket 4 (plasma-vault fail → pełny teardown).
- **`set -euo pipefail` + `inherit_errexit` + `grep` w `$()`**: `grep` zwraca exit 1 na brak dopasowania. Z `pipefail` cały pipeline failuje, z `inherit_errexit` set -e działa wewnątrz `$()`. `var=$(cmd | grep pattern | head -1)` zabija skrypt PRZED `if [[ -z "$var" ]]`. Rozwiązanie: `|| true` na końcu `$()`.
- **Partycje z poprzedniej instalacji blokują `sfdisk`**: `cleanup_target_disk()` odmontowuje wszystkie partycje i deaktywuje swap przed `disk_execute_plan()`.
- **`eselect locale` format `utf8` nie `UTF-8`**: `eselect locale set "pl_PL.UTF-8"` → "target doesn't appear to be valid". Wymaga `pl_PL.utf8`. Rozwiązanie: `${locale/UTF-8/utf8}` w `system_set_locale()`.
- **Non-English locale + `myspell-en`**: L10N bez regionalnego wariantu angielskiego (np. `L10N="pl-PL en"`) powoduje REQUIRED_USE failure dla `myspell-en`. Zawsze dodawać `en-US` jako fallback w L10N.
- **`locale-gen` musi się zakończyć przed `eselect locale list`**: Jeśli nie dokończy (np. orphan tee), `eselect locale list` pokaże tylko `C`/`C.UTF-8`/`POSIX`. Ręczna naprawa: `echo "pl_PL.UTF-8 UTF-8" > /etc/locale.gen && locale-gen`.
- **Zabicie `tee` może kaskadowo ubić bieżącą komendę**: Gdy `try()` używa `| tee`, zabicie `tee` → broken pipe → SIGPIPE do komendy (np. genkernel). NIE zabijać tee podczas trwającej kompilacji — poczekać aż się zawiesi (brak aktywności w `top`).
- **`genkernel` przy retry buduje od nowa**: `genkernel all` robi `make mrproper` na początku — retry po padnięciu = pełna rekompilacja (20-60 min). Normalne zachowanie.
- **Exit code `0` przy faktycznym błędzie w `try()`**: Po `if cmd; then ...; fi` bez `else`, bash ustawia `$?` na 0 niezależnie od exit code komendy. `try()` wyświetla "Failed (exit 0)" mimo błędu. Bug kosmetyczny — detekcja błędu działa.
- **Hasła/hashe NIGDY w argumentach komend**: `openssl passwd -6 "${password}"` i `usermod -p "${hash}"` widoczne w `ps aux`. Używać: `openssl passwd -6 -stdin <<< "${password}"` i `bash -c 'echo "user:$1" | chpasswd -e' -- "${hash}"`.
- **`eval` na zewnętrznych danych**: Nie `eval "${line}"` na output `blkid` / plików konfig. Złośliwy label partycji może zawierać kod. Parsować przez `case`/`read` lub `declare`.
- **Hostname validation**: Hostname trafia do `/etc/conf.d/hostname` (source'owany przez OpenRC) i `/etc/hosts`. Walidować regex RFC 1123: `^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$`.
- **`eval echo "~${user}"` → injection**: Zamiast tego `getent passwd "${user}" | cut -d: -f6`.
- **`try_resume_from_disk()` zwraca 0/1/2, nie boolean**: Nie używać `if try_resume_from_disk` — zawsze `rc=0; try_resume_from_disk || rc=$?; case ${rc}`. Testowanie: `_RESUME_TEST_DIR`.
- **DNS na Live ISO**: Live ISO może nie mieć skonfigurowanego DNS. `ensure_dns()` w preflight automatycznie dodaje `8.8.8.8` jeśli ping po IP działa ale po nazwie nie.
- **Motyw dialog**: `data/dialogrc` ładowany przez `export DIALOGRC=` w `init_dialog()`. Whiptail ignoruje DIALOGRC. Gum używa `GUM_*` env vars.
- **NIGDY `source /etc/profile` w instalatorze**: Skrypty `/etc/profile.d/` mogą odwoływać się do niezdefiniowanych zmiennych — `set -u` zabija skrypt mimo `|| true` (błąd ekspansji zachodzi PRZED wykonaniem komendy). Ponadto resetuje PATH (gum znika) i LANG. Sam `env-update` wystarczy.
- **`stage3_extract` cleanup odmontowuje ESP**: Cleanup usuwał stare pliki przy retry, ale katalog `efi/` (mount point ESP) też był łapany przez `find`. Po ekstrakcji stage3 `grub-install --efi-directory=/efi` failował. Fix: cleanup pomija `efi`, ESP re-montowany po ekstrakcji; safety net w `_execute_chroot_phase()` re-montuje ESP przed chroot.
- **`STAGE3_FILE` unbound przy resume**: Gdy `stage3_download` checkpoint przetrwa ale faza pominięta, `STAGE3_FILE` nie ustawione. `stage3_verify()`/`stage3_extract()` używają `_find_stage3_file()` (szuka `stage3-amd64-*.tar.xz` na MOUNTPOINT).
- **`infer_config_from_partition` i testowanie**: Przy `_RESUME_TEST_DIR` używa `_RESUME_TEST_DIR/mnt/<part>`, UUID resolver czyta z `_INFER_UUID_MAP`. Parsowanie make.conf: single-line only (nie obsługuje backslash continuation).
- **`[[ -n "$x" ]] && cmd` pod `set -e` + `inherit_errexit` w funkcjach**: Gdy `x` puste, `[[ -n "" ]]` zwraca exit 1, `&&` short-circuituje, funkcja exituje z rc=1 → `set -e` zabija test. Użyć pełnego `if [[ -n "$x" ]]; then ...; fi`. (Łapał się w test_umpc.sh przy opcjonalnym board_name.)

## Debugowanie podczas instalacji na żywym sprzęcie

Gentoo Live ISO daje dostęp do wielu TTY (`Ctrl+Alt+F1`..`F6`). TTY1 = installer, TTY2-6 = wolne konsole. SSH na Live ISO można skonfigurować ręcznie — szczegóły w README.

### Multi-boot safety

Instalator wykrywa zainstalowane OS-y (Windows, Linux) skanując partycje. Wyniki w `DETECTED_OSES[]` (assoc array), serializowane do `DETECTED_OSES_SERIALIZED`. Zabezpieczenia:
- Dual-boot oferowany gdy wykryto Windows LUB innego Linuksa
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
