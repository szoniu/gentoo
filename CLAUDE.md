# CLAUDE.md — Kontekst projektu dla Claude Code

## Co to jest

Interaktywny TUI installer Gentoo Linux w Bashu. Cel: sklonować repo z dowolnego live ISO, uruchomić `./install.sh` i zostać przeprowadzonym przez cały proces od partycjonowania dysku po działający desktop KDE Plasma. Po awarii: `./install.sh --resume` skanuje dyski i wznawia od ostatniego checkpointu.

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
├── config.sh           — config_save/load/set/get/dump (${VAR@Q} quoting)
├── hardware.sh         — detect_cpu/gpu/disks/esp/installed_oses, detect_asus_rog, serialize/deserialize_detected_oses, get_hardware_summary
├── disk.sh             — Dwufazowe: disk_plan_add/add_stdin/show/auto/dualboot → cleanup_target_disk + disk_execute_plan (sfdisk), mount/unmount_filesystems, get_uuid
├── network.sh          — check_network, install_network_manager, select_fastest_mirror
├── stage3.sh           — stage3_get_url/download/verify/extract
├── portage.sh          — generate_make_conf (_write_make_conf), portage_sync, portage_select_profile, portage_install_cpuflags, install_extra_packages, setup_guru_repository, install_noctalia_shell
├── kernel.sh           — kernel_install (dist-kernel vs genkernel)
├── bootloader.sh       — bootloader_install, _configure_grub, _mount/_unmount_osprober, _verify_grub_config, _verify_efi_entries
├── system.sh           — system_set_timezone/locale/hostname/keymap, generate_fstab, install_filesystem_tools, system_create_users, system_finalize
├── desktop.sh          — desktop_install (GPU drivers, KDE Plasma, SDDM, PipeWire, KDE apps)
├── swap.sh             — swap_setup (zram-generator/zram-init, swap file)
├── chroot.sh           — chroot_setup/teardown/exec, copy_dns_info, copy_installer_to_chroot
├── hooks.sh            — maybe_exec 'before_X' / 'after_X'
└── preset.sh           — preset_export/import (hardware overlay)

tui/                    — Ekrany TUI
├── welcome.sh          — screen_welcome: branding + prereq check
├── preset_load.sh      — screen_preset_load: skip/file/browse
├── hw_detect.sh        — screen_hw_detect: detect_all_hardware + summary (infobox auto-advance)
├── init_select.sh      — screen_init_select: systemd/openrc radiolist
├── disk_select.sh      — screen_disk_select: dysk + scheme (auto/dual-boot/manual)
├── filesystem_select.sh — screen_filesystem_select: ext4/btrfs/xfs + btrfs subvolumes
├── swap_config.sh      — screen_swap_config: zram/partition/file/none
├── network_config.sh   — screen_network_config: hostname + mirror
├── locale_config.sh    — screen_locale_config: timezone + locale + keymap
├── kernel_select.sh    — screen_kernel_select: dist-kernel/genkernel
├── gpu_config.sh       — screen_gpu_config: auto/nvidia/amd/intel/none + nvidia-open
├── desktop_config.sh   — screen_desktop_config: KDE apps checklist
├── user_config.sh      — screen_user_config: root pwd, user, grupy
├── extra_packages.sh   — screen_extra_packages: checklist (fastfetch, btop, kitty, GURU, noctalia) + wolne pole tekstowe
├── preset_save.sh      — screen_preset_save: opcjonalny eksport
├── summary.sh          — screen_summary: pełne podsumowanie + "YES" + countdown
└── progress.sh         — screen_progress: resume detection + infobox (krótkie fazy) + live terminal (chroot)

data/                   — Statyczne bazy danych + bundled assets
├── cpu_march_database.sh — CPU_MARCH_MAP[vendor:family:model] → -march flag
├── gpu_database.sh     — nvidia_generation(), get_gpu_recommendation()
├── mirrors.sh          — GENTOO_MIRRORS[], get_mirror_list_for_dialog()
├── use_flags_desktop.sh — USE_FLAGS_DESKTOP/SYSTEMD/OPENRC/NVIDIA/AMD/INTEL, get_use_flags()
├── dialogrc            — Ciemny motyw TUI (ładowany przez DIALOGRC w init_dialog)
└── gum.tar.gz          — Bundled gum v0.17.0 binary (statyczny ELF x86-64, ~4.5 MB)

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
- `KERNEL_TYPE` — dist-kernel/genkernel
- `GPU_VENDOR` — nvidia/amd/intel/none/unknown
- `ENABLE_GURU` — yes/no (repozytorium GURU community)
- `ENABLE_NOCTALIA` — yes/no (Noctalia Shell z GURU)
- `WINDOWS_DETECTED` — 0/1 (auto-detected)
- `LINUX_DETECTED` — 0/1 (auto-detected)
- `DETECTED_OSES_SERIALIZED` — serialized map of partition→OS name

### Polityka `~amd64` (testing keywords)

NIGDY nie ustawiać `ACCEPT_KEYWORDS="~amd64"` globalnie — destabilizuje cały system. Zamiast tego per-pakiet w `/etc/portage/package.accept_keywords/`:
- `sys-kernel/gentoo-kernel-bin ~amd64` — dist-kernel (kernel.sh)
- `sys-kernel/gentoo-sources ~amd64` — genkernel (kernel.sh)
- `gui-apps/noctalia-shell ~amd64` — Noctalia Shell (portage.sh)
- `gui-apps/quickshell ~amd64` — zależność Noctalia (portage.sh)
- `media-video/gpu-screen-recorder ~amd64` — zależność Noctalia (portage.sh)

Nowe pakiety wymagające `~amd64` dodawać w odpowiednim module `lib/`, nie w make.conf.

### Konfiguracja kernela (per Gentoo Handbook)

- **installkernel**: wymaga `USE="grub"` (`package.use/installkernel`) żeby wiedział, że ma konfigurować GRUB
- **dracut**: wymaga `/etc/dracut.conf.d/root.conf` z `root=UUID=...` żeby initramfs znalazł root filesystem
- **Intel microcode**: `sys-firmware/intel-microcode` instalowany automatycznie na CPU Intel (sprawdzamy `/proc/cpuinfo`)
- **cpuid2cpuflags**: uruchamiany w fazie portage_sync (PRZED @world) żeby pakiety budowały się z optymalizacjami CPU

### Noctalia Shell

Noctalia Shell to shell do **Wayland compositorów** (Niri/Hyprland/Sway), NIE do KDE Plasma. Instalowanie go obok KDE nie szkodzi, ale nie będzie działać bez osobnego compositora. GURU overlay wymaga `dev-vcs/git` do synca.

- **Quickshell** (`gui-apps/quickshell`) jest ściągany automatycznie jako RDEPEND noctalia-shell
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

**Kluczowy mechanizm**: `--label-delimiter " | "` (gum 0.14+) — wyświetla `tag | description` ale zwraca tylko `tag`. Eliminuje parsowanie tag/desc w menu, radiolist, checklist.

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
```

Wszystkie testy są standalone — nie wymagają root ani hardware. Używają `DRY_RUN=1` i `NON_INTERACTIVE=1`.

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
- **`STAGE3_FILE` unbound przy resume**: Gdy `stage3_download` checkpoint przetrwa ale faza jest pominięta, `STAGE3_FILE` nie jest ustawione. `stage3_verify()`/`stage3_extract()` używają `_find_stage3_file()` do fallback — szuka `stage3-amd64-*.tar.xz` na `MOUNTPOINT`.
- **`infer_config_from_partition` i testowanie**: Przy `_RESUME_TEST_DIR` ustawionym, `infer_config_from_partition` używa `_RESUME_TEST_DIR/mnt/<part>` zamiast prawdziwego mount. UUID resolver (`_resolve_uuid`) czyta z `_INFER_UUID_MAP` file zamiast `blkid -U`. Parsowanie make.conf: single-line only (nie obsługuje backslash continuation).

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
