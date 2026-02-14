# CLAUDE.md — Kontekst projektu dla Claude Code

## Co to jest

Interaktywny TUI installer Gentoo Linux w Bashu. Cel: sklonować repo z dowolnego live ISO, uruchomić `./install.sh` i zostać przeprowadzonym przez cały proces od partycjonowania dysku po działający desktop KDE Plasma.

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
├── utils.sh            — try (interaktywne recovery), checkpoint_set/reached, is_root/is_efi/has_network
├── dialog.sh           — Wrapper dialog/whiptail, primitives (msgbox/yesno/menu/radiolist/checklist/gauge/inputbox/passwordbox), wizard runner (register_wizard_screens + run_wizard)
├── config.sh           — config_save/load/set/get/dump (${VAR@Q} quoting)
├── hardware.sh         — detect_cpu/gpu/disks/esp, get_hardware_summary
├── disk.sh             — Dwufazowe: disk_plan_add/show/auto/dualboot → disk_execute_plan, mount/unmount_filesystems, get_uuid
├── network.sh          — check_network, install_network_manager, select_fastest_mirror
├── stage3.sh           — stage3_get_url/download/verify/extract
├── portage.sh          — generate_make_conf (_write_make_conf), portage_sync, portage_select_profile, portage_install_cpuflags, install_extra_packages, setup_guru_repository, install_noctalia_shell
├── kernel.sh           — kernel_install (dist-kernel vs genkernel)
├── bootloader.sh       — bootloader_install, _configure_grub (dual-boot os-prober)
├── system.sh           — system_set_timezone/locale/hostname/keymap, generate_fstab, install_filesystem_tools, system_create_users, system_finalize
├── desktop.sh          — desktop_install (GPU drivers, KDE Plasma, SDDM, PipeWire, KDE apps)
├── swap.sh             — swap_setup (zram-generator/zram-init, swap file)
├── chroot.sh           — chroot_setup/teardown/exec, copy_dns_info, copy_installer_to_chroot
├── hooks.sh            — maybe_exec 'before_X' / 'after_X'
└── preset.sh           — preset_export/import (hardware overlay)

tui/                    — Ekrany TUI
├── welcome.sh          — screen_welcome: branding + prereq check
├── preset_load.sh      — screen_preset_load: skip/file/browse
├── hw_detect.sh        — screen_hw_detect: detect_all_hardware + summary
├── init_select.sh      — screen_init_select: systemd/openrc radiolist
├── disk_select.sh      — screen_disk_select: dysk + scheme (auto/dual-boot/manual)
├── filesystem_select.sh — screen_filesystem_select: ext4/btrfs/xfs + btrfs subvolumes
├── swap_config.sh      — screen_swap_config: zram/partition/file/none
├── network_config.sh   — screen_network_config: hostname + mirror
├── locale_config.sh    — screen_locale_config: timezone + locale + keymap
├── kernel_select.sh    — screen_kernel_select: dist-kernel/genkernel
├── gpu_config.sh       — screen_gpu_config: auto/nvidia/amd/intel/none + nvidia-open
├── desktop_config.sh   — screen_desktop_config: KDE apps checklist
├── user_config.sh      — screen_user_config: root pwd, user, grupy, SSH
├── extra_packages.sh   — screen_extra_packages: checklist (fastfetch, GURU, noctalia) + wolne pole tekstowe
├── preset_save.sh      — screen_preset_save: opcjonalny eksport
├── summary.sh          — screen_summary: pełne podsumowanie + "YES" + countdown
└── progress.sh         — screen_progress: gauge + fazowa instalacja

data/                   — Statyczne bazy danych
├── cpu_march_database.sh — CPU_MARCH_MAP[vendor:family:model] → -march flag
├── gpu_database.sh     — nvidia_generation(), get_gpu_recommendation()
├── mirrors.sh          — GENTOO_MIRRORS[], get_mirror_list_for_dialog()
└── use_flags_desktop.sh — USE_FLAGS_DESKTOP/SYSTEMD/OPENRC/NVIDIA/AMD/INTEL, get_use_flags()

presets/                — Przykładowe konfiguracje
tests/                  — Testy (bash, standalone)
hooks/                  — *.sh.example
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

### Dwufazowe operacje dyskowe

1. `disk_plan_auto()` / `disk_plan_dualboot()` — buduje `DISK_ACTIONS[]`
2. `disk_execute_plan()` — iteruje i wykonuje przez `try`

### Checkpointy

`checkpoint_set "nazwa"` tworzy plik w `$CHECKPOINT_DIR`. `checkpoint_reached "nazwa"` sprawdza. Pozwala wznowić po awarii.

### Funkcja `try`

`try "opis" polecenie args...` — na błędzie wyświetla menu Retry/Shell/Continue/Log/Abort. Każde polecenie które może się nie udać MUSI iść przez `try`.

## Uruchamianie testów

```bash
bash tests/test_config.sh      # Config round-trip (13 assertions)
bash tests/test_hardware.sh    # CPU march + GPU database (16 assertions)
bash tests/test_disk.sh        # Disk planning dry-run (12 assertions)
bash tests/test_makeconf.sh    # make.conf generation (18 assertions)
```

Wszystkie testy są standalone — nie wymagają root ani hardware. Używają `DRY_RUN=1` i `NON_INTERACTIVE=1`.

## Znane wzorce i pułapki

- `(( var++ ))` przy var=0 zwraca exit 1 pod `set -e` → zawsze dodawać `|| true`
- `lib/constants.sh` używa `: "${VAR:=default}"` zamiast `readonly` żeby testy mogły nadpisywać
- `lib/protection.sh` sprawdza `$_GENTOO_INSTALLER` — testy muszą to exportować
- `config_save` używa `${VAR@Q}` (bash 4.4+) do bezpiecznego quotingu
- Dialog: `2>&1 >/dev/tty` (dialog) vs `3>&1 1>&2 2>&3` (whiptail) — oba obsłużone w `lib/dialog.sh`
- Pliki lib/ NIGDY nie są uruchamiane bezpośrednio — zawsze sourcowane
- **`$*` vs `"$@"` vs `printf '%q '`**: Gdy komenda jest budowana jako string i później wykonywana przez `bash -c`, `$*` traci quoting argumentów ze spacjami (np. `"EFI System Partition"` → trzy osobne tokeny). Rozwiązanie: `printf '%q ' "$@"` zachowuje quoting. Dotyczy: `disk_plan_add()`, `chroot_exec()`, `dialog_prgbox()`. Bezpośrednie wykonanie (`"$@"`) nie ma tego problemu (np. `try()` linia 20).
- **Interpolacja zmiennych w stringach innych języków**: Nie wstawiać zmiennych bashowych bezpośrednio w kod Pythona/Perla (np. `python3 -c "...('${password}')..."`). Znaki specjalne mogą złamać składnię lub umożliwić injection. Przekazywać przez zmienne środowiskowe (`GENTOO_PW="${password}" python3 -c "...os.environ['GENTOO_PW']..."`).

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
