# TODO

## Zrobione

- [x] **`--resume` — wznowienie po awarii** — skanuje partycje dysku w poszukiwaniu checkpointów i configa z przerwanej instalacji. Jedna komenda zamiast ręcznego mount/cp/umount.
- [x] **ASUS ROG + Hybrid GPU** — detekcja wielu GPU (iGPU/dGPU) z klasyfikacją PCI slot, combined VIDEO_CARDS, NVIDIA PRIME render offload z power management. Detekcja ASUS ROG/TUF via DMI, opcjonalny asusctl/supergfxctl z overlay zGentoo (systemd), warning przy ROG + OpenRC.
- [x] **gum (Charm.sh) jako alternatywny backend TUI** — statyczny binary zaszyty w repo (`data/gum.tar.gz`, 4.5 MB). Automatyczna ekstrakcja na starcie, priorytet: gum > dialog > whiptail. Opt-out: `GUM_BACKEND=0`. Zaokrąglone ramki, cyan accent, `▸` kursor, `█░` progress bar.
- [x] **Fix: `source /etc/profile` crash** — `set -u` zabijał skrypt na niezdefiniowanych zmiennych w `/etc/profile.d/`. Usunięto — `env-update` wystarczy.

## Przyszłe ulepszenia

- [ ] **Live preview w instalatorze** — wyświetlanie podglądu tail/log przed chrootem i w chroota (jak teraz LIVE_OUTPUT, ale ładniejszy — z gum spin/log). Powiązane z gum backend.
- [ ] **Walidacja konfiguracji przed instalacją** — sprawdzanie spójności wybranych opcji (np. czy dysk ma wystarczająco miejsca, czy ESP istnieje dla dual-boot).
- [ ] **Automatyczne `emerge @preserved-rebuild`** — po `@world` update, automatycznie przebudować pakiety z preserved libs zamiast zostawiać ostrzeżenie.
- [ ] **Wsparcie dla Secure Boot** — podpisywanie kernela i modułów (MOK enrollment), GRUB z Secure Boot shim.
- [ ] **ARM64 / RISC-V** — wsparcie dla architektur poza amd64 (inne stage3, inny gum binary, profile).
