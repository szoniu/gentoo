# TODO

## Zrobione

- [x] **`--resume` — wznowienie po awarii** — skanuje partycje dysku w poszukiwaniu checkpointów i configa z przerwanej instalacji. Jedna komenda zamiast ręcznego mount/cp/umount.
- [x] **ASUS ROG + Hybrid GPU** — detekcja wielu GPU (iGPU/dGPU) z klasyfikacją PCI slot, combined VIDEO_CARDS, NVIDIA PRIME render offload z power management. Detekcja ASUS ROG/TUF via DMI, opcjonalny asusctl/supergfxctl z overlay zGentoo (systemd), warning przy ROG + OpenRC.
- [x] **gum (Charm.sh) jako alternatywny backend TUI** — statyczny binary zaszyty w repo (`data/gum.tar.gz`, 4.5 MB). Automatyczna ekstrakcja na starcie, priorytet: gum > dialog > whiptail. Opt-out: `GUM_BACKEND=0`. Zaokrąglone ramki, cyan accent, `▸` kursor, `█░` progress bar.
- [x] **Fix: `source /etc/profile` crash** — `set -u` zabijał skrypt na niezdefiniowanych zmiennych w `/etc/profile.d/`. Usunięto — `env-update` wystarczy.
- [x] **Automatyczne `emerge @preserved-rebuild`** — nowa faza po `@world` update, przebudowuje pakiety linkujące do starych preserved libs. Własny checkpoint `preserved_rebuild`.
- [x] **Microsoft Surface support** — detekcja Surface via DMI (`sys_vendor=Microsoft Corporation` + `product_name=Surface*`). Cztery opcje kernela: surface-kernel (overlay), surface-genkernel (git patches), dist-kernel, genkernel. Surface overlay `linux-surface`, narzędzia iptsd + surface-control. Warning Surface + OpenRC (iptsd wymaga systemd). Config inference z overlay + keywords. Testy: `test_surface.sh`.
- [x] **Secure Boot (MOK signing)** — generacja kluczy MOK, podpisywanie kernela sbsign, shim chainloader na ESP, automatyczny MOK enrollment (password: gentoo). Ekran TUI `secureboot_config`, faza `secureboot` z checkpointem po bootloaderze. Portage `USE=secureboot` + `SECUREBOOT_SIGN_KEY/CERT`.
- [x] **Server/minimal mode (bez KDE)** — `DESKTOP_TYPE=none` pomija KDE Plasma, SDDM, PipeWire, GPU drivers. Profil `default/linux/amd64/23.0/systemd` zamiast `desktop/plasma/systemd`. Minimalne USE flags. Ekrany `gpu_config` i `desktop_config` auto-skip. Instalacja ~30-40 min zamiast 2-4h.

## Przyszłe ulepszenia

- [ ] **Live preview w instalatorze** — wyświetlanie podglądu tail/log przed chrootem i w chroota (jak teraz LIVE_OUTPUT, ale ładniejszy — z gum spin/log). Powiązane z gum backend.
- [x] **Walidacja konfiguracji przed instalacją** — `validate_config()` w `lib/config.sh` sprawdza wymagane zmienne, dozwolone wartości enum, format hostname/locale, istnienie block devices i spójność cross-field. Wywoływana w `tui/summary.sh` przed wyświetleniem podsumowania.
- [x] **Wsparcie dla Secure Boot** — podpisywanie kernela i modułów (MOK enrollment), GRUB z Secure Boot shim.
- [ ] **ARM64 / RISC-V** — wsparcie dla architektur poza amd64 (inne stage3, inny gum binary, profile).
