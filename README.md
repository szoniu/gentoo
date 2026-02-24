# Gentoo TUI Installer

Interaktywny installer Gentoo Linux z interfejsem TUI (dialog). Przeprowadza za rękę przez cały proces instalacji — od partycjonowania dysku po działający desktop KDE Plasma.

## Krok po kroku (od zera do działającego systemu)

### 1. Przygotuj bootowalny pendrive

Pobierz Gentoo Live GUI ISO (ma `dialog`, `git`, sterowniki WiFi — wszystko co trzeba):

- https://www.gentoo.org/downloads/ → **amd64** → **LiveGUI USB Image**

Nagraj na pendrive (Linux/macOS):

```bash
# UWAGA: /dev/sdX to twój pendrive, nie dysk systemowy!
sudo dd if=livegui-amd64-*.iso of=/dev/sdX bs=4M status=progress
sync
```

Na Windows użyj [Rufus](https://rufus.ie) lub [balenaEtcher](https://etcher.balena.io).

### 2. Bootuj z pendrive

- Wejdź do BIOS/UEFI (zwykle F2, F12, Del przy starcie)
- **Wyłącz Secure Boot** (NVIDIA drivers tego wymagają)
- Ustaw boot z USB
- Wybierz opcję **UEFI** (nie Legacy/CSM!)

### 3. Połącz się z internetem

#### Kabel LAN (ethernet)

Powinno działać od razu. Sprawdź:

```bash
ping -c 3 gentoo.org
```

#### WiFi (bezprzewodowo)

**Opcja A: `iwctl` (iwd)** — dostępny na większości live ISO:

```bash
iwctl
# W interaktywnej konsoli iwctl:
station wlan0 scan
station wlan0 get-networks
station wlan0 connect "NazwaTwojejSieci"
# Wpisz hasło WiFi gdy zapyta
exit
```

**Opcja B: `nmcli` (NetworkManager)** — dostępny na Gentoo LiveGUI:

```bash
nmcli device wifi list
nmcli device wifi connect "NazwaTwojejSieci" password "TwojeHaslo"
```

**Opcja C: `wpa_supplicant`** — zawsze dostępny, bardziej manualny:

```bash
# Znajdź interfejs WiFi
ip link show

# Włącz interfejs
ip link set wlan0 up

# Połącz
wpa_supplicant -B -i wlan0 -c <(wpa_passphrase "NazwaTwojejSieci" "TwojeHaslo")
dhcpcd wlan0
```

**Sprawdź połączenie:**

```bash
ping -c 3 gentoo.org
```

### 4. Sklonuj repo i uruchom installer

```bash
sudo su
git clone https://github.com/szoniu/gentoo.git
cd gentoo
./install.sh
```

Installer poprowadzi Cię przez 18 ekranów konfiguracji, a potem zainstaluje wszystko automatycznie.

### 5. Po instalacji

Po zakończeniu installer zapyta czy chcesz rebootować. Wyjmij pendrive i uruchom komputer — powinieneś zobaczyć GRUB, a potem ekran logowania SDDM z KDE Plasma.

## Alternatywne sposoby uruchomienia

```bash
# Tylko konfiguracja (generuje plik .conf, nic nie instaluje)
./install.sh --configure

# Instalacja z gotowego configa (bez wizarda)
./install.sh --config moj-config.conf --install

# Dry-run — przechodzi cały flow BEZ dotykania dysków
./install.sh --dry-run

# Z presetu (np. dla kolegi z NVIDIA + systemd)
./install.sh --config presets/desktop-nvidia-systemd.conf --install
```

## Wymagania

- Komputer z **UEFI** (nie Legacy BIOS)
- **Secure Boot wyłączony**
- Minimum **60 GiB** wolnego miejsca na dysku docelowym
- Połączenie z internetem (LAN lub WiFi)
- Bootowalny pendrive z Gentoo Live ISO (lub dowolne live z `dialog` i `git`)

## Co robi installer

17 ekranów TUI prowadzi przez:

| # | Ekran | Co konfigurujesz |
|---|-------|-------------------|
| 1 | Welcome | Sprawdzenie wymagań (root, UEFI, sieć) |
| 2 | Preset | Opcjonalne załadowanie gotowej konfiguracji |
| 3 | Hardware | Podgląd wykrytego CPU, GPU, dysków, zainstalowanych OS-ów |
| 4 | Init system | systemd (zalecany dla KDE) lub OpenRC |
| 5 | Dysk | Wybór dysku + schemat (auto/dual-boot/manual) |
| 6 | Filesystem | ext4 / btrfs (ze snapshotami) / XFS |
| 7 | Swap | zram (domyślnie) / partycja / plik / brak |
| 8 | Sieć | Hostname + mirror Gentoo |
| 9 | Locale | Timezone, język, keymap |
| 10 | Kernel | dist-kernel (szybki) lub genkernel (custom) |
| 11 | GPU | Auto-wykryty sterownik + możliwość zmiany |
| 12 | Desktop | KDE Plasma + wybór aplikacji (Dolphin, Firefox, Kate...) |
| 13 | Użytkownicy | Hasło root, konto użytkownika, grupy |
| 14 | Pakiety | Dodatkowe pakiety do zainstalowania |
| 15 | Preset save | Opcjonalny eksport konfiguracji na przyszłość |
| 16 | Podsumowanie | Pełny przegląd + potwierdzenie "YES" |
| 17 | Instalacja | Live output w terminalu — siedź i czekaj |

## Dual-boot (Windows, Linux, multi-boot)

Installer automatycznie:
- Wykrywa zainstalowane OS-y (Windows, openSUSE, Ubuntu, Fedora, etc.)
- Wykrywa istniejący ESP z Windows Boot Manager i innymi bootloaderami
- Reuse'uje ESP (nigdy go nie formatuje!)
- GRUB instaluje się do `EFI/Gentoo/` obok `EFI/Microsoft/` i innych
- `os-prober` dodaje wszystkie wykryte OS-y do menu GRUB
- Partycje z istniejącymi OS-ami są oznaczone w menu — przypadkowe nadpisanie wymaga potwierdzenia `ERASE`
- Po instalacji weryfikuje czy GRUB i wpisy EFI zawierają wszystkie OS-y

Wystarczy wybrać "Dual-boot" w ekranie partycjonowania. Opcja pojawia się automatycznie gdy installer wykryje inny OS na dysku.

## Presety (konfiguracja wielokrotnego użytku)

Gotowe presety w `presets/`:

```
presets/desktop-nvidia-systemd.conf   # NVIDIA + systemd + ext4
presets/desktop-amd-openrc.conf       # AMD + OpenRC + btrfs
presets/desktop-intel-systemd.conf    # Intel + systemd + ext4
```

Presety są **przenośne między maszynami** — wartości sprzętowe (CPU, GPU, dysk) są automatycznie re-wykrywane przy imporcie. Czyli: konfigurujesz raz, instalujesz na wielu komputerach.

Możesz też wyeksportować własny preset w ekranie 15 wizarda.

## Co jeśli coś pójdzie nie tak

### Recovery menu

Gdy komenda się nie powiedzie, installer wyświetli menu recovery:

- **(r)etry** — ponów komendę (np. po naprawieniu problemu w shellu)
- **(s)hell** — wejdź do shella, napraw ręcznie, wpisz `exit` żeby wrócić
- **(c)ontinue** — pomiń ten krok i kontynuuj (ostrożnie!)
- **(a)bort** — przerwij instalację

### Drugie TTY — twój najlepszy przyjaciel

Podczas instalacji masz dostęp do wielu konsol. Przełączaj się przez **Ctrl+Alt+F1**...**F6**:

- **TTY1** — installer (tu lecą kompilacje)
- **TTY2-6** — wolne konsole do debugowania

Na drugim TTY możesz:

```bash
# Podgląd co się kompiluje w czasie rzeczywistym
top

# Log installera
tail -f /tmp/gentoo-installer.log                   # przed chroot
tail -f /mnt/gentoo/tmp/gentoo-installer.log        # w chroot

# Log genkernel (jeśli wybrałeś genkernel)
tail -f /mnt/gentoo/var/log/genkernel.log

# Sprawdź czy coś nie zawiesiło się
ps aux | grep -E "tee|emerge|make"
```

### Zdalna instalacja przez SSH

Możesz odpalić instalację zdalnie — uruchom SSH na Live ISO, połącz się z innego komputera i odpal installer przez SSH. To pozwala wygodnie monitorować instalację, kopiować/wklejać, a nawet odejść od maszyny docelowej.

#### Konfiguracja SSH na Live ISO

Na maszynie docelowej (bootowanej z Live ISO), otwórz konsolę (TTY lub terminal) i:

```bash
# 1. Ustaw hasło root (Live ISO domyślnie nie ma hasła)
echo "root:twojehaslo" | chpasswd

# 2. Uruchom sshd
#    Gentoo LiveGUI (OpenRC):
rc-service sshd start

#    Jeśli live ISO ma systemd:
systemctl start sshd

# 3. Sprawdź IP
ip -4 addr show | grep inet
```

#### Zdalna instalacja z innego komputera

```bash
# Połącz się
ssh root@<IP-live-ISO>

# Sklonuj repo i uruchom installer
git clone https://github.com/szoniu/gentoo.git
cd gentoo
./install.sh
```

Installer działa normalnie przez SSH — dialog TUI renderuje się w terminalu SSH.

#### Monitorowanie z drugiego połączenia

Otwórz drugie okno terminala i połącz się ponownie:

```bash
ssh root@<IP-live-ISO>

# Logi w czasie rzeczywistym
tail -f /tmp/gentoo-installer.log                   # przed chroot
tail -f /mnt/gentoo/tmp/gentoo-installer.log        # w chroot

# Log genkernel (jeśli wybrałeś genkernel)
tail -f /mnt/gentoo/var/log/genkernel.log

# Co się kompiluje
top

# OOM killer
dmesg | grep -i "oom\|killed"
```

### Typowe problemy

- **Installer zawisł, nic się nie dzieje** — sprawdź na TTY2 czy `cc1`/`gcc`/`make` działają w `top`. Jeśli tak — kompilacja trwa, po prostu czekaj. Gentoo kompiluje WSZYSTKO ze źródeł. Kernel: 20-60 min. KDE Plasma: 1-4h.
- **Przerwa w prądzie / reboot** — uruchom installer ponownie, zapyta czy wznowić od ostatniego checkpointu. Fazy takie jak kompilacja kernela czy @world nie będą powtarzane.
- **Log** — pełny log instalacji: `/tmp/gentoo-installer.log`
- **Coś jest nie tak z konfiguracją** — użyj `./install.sh --configure` żeby przejść wizarda ponownie

## Hooki (zaawansowane)

Własne skrypty uruchamiane przed/po fazach instalacji:

```bash
cp hooks/before_install.sh.example hooks/before_install.sh
chmod +x hooks/before_install.sh
# Edytuj hook...
```

Dostępne hooki: `before_install`, `after_install`, `before_disks`, `after_disks`, `before_kernel`, `after_kernel`, itd.

## Opcje CLI

```
./install.sh [OPCJE] [POLECENIE]

Polecenia:
  (domyślnie)      Pełna instalacja (wizard + install)
  --configure       Tylko wizard konfiguracyjny
  --install         Tylko instalacja (wymaga configa)

Opcje:
  --config PLIK     Użyj podanego pliku konfiguracji
  --dry-run         Symulacja bez destrukcyjnych operacji
  --force           Kontynuuj mimo nieudanych prereq
  --non-interactive Przerwij na każdym błędzie (bez recovery menu)
  --help            Pokaż pomoc
```

## Uruchamianie testów

```bash
bash tests/test_config.sh      # Config round-trip
bash tests/test_hardware.sh    # CPU march + GPU database
bash tests/test_disk.sh        # Disk planning dry-run
bash tests/test_makeconf.sh    # make.conf generation
bash tests/test_checkpoint.sh  # Checkpoint validate + migrate
bash tests/test_multiboot.sh   # Multi-boot OS detection + serialization
```

## Struktura projektu

```
install.sh              — Główny entry point
configure.sh            — Wrapper: tylko wizard TUI
gentoo.conf.example     — Przykładowa konfiguracja z komentarzami

lib/                    — Moduły biblioteczne (sourcowane, nie uruchamiane)
tui/                    — Ekrany TUI (każdy = funkcja, return 0/1/2)
data/                   — Bazy danych (CPU march, GPU, mirrory, USE flags)
presets/                — Gotowe presety
hooks/                  — Hooki (*.sh.example)
tests/                  — Testy
```

## FAQ

**P: Jak długo trwa instalacja?**
Zależy od CPU i łącza. `dist-kernel` (binarny) to ~30-60 min. `genkernel` (kompilacja) to 1-3h. Kompilacja KDE Plasma to dodatkowe 1-4h.

**P: Mogę zainstalować na VM?**
Tak, ale upewnij się że VM jest w trybie UEFI. W VirtualBox: Settings → System → Enable EFI. W QEMU: dodaj `-bios /usr/share/ovmf/OVMF.fd`.

**P: Co jeśli mam Secure Boot?**
Wyłącz Secure Boot w BIOS. NVIDIA proprietary drivers i wiele modułów kernela nie są podpisane.

**P: Mogę użyć innego live ISO niż Gentoo?**
Tak, dowolne live ISO z Linuxem zadziała, pod warunkiem że ma `bash`, `dialog` (lub `whiptail`), `git`, `sfdisk`, `wget`, `gpg`. Ubuntu/Fedora live zazwyczaj mają wszystko albo można doinstalować.

**P: Co jeśli nie mam `dialog`?**
Na większości live ISO: `apt install dialog` (Debian/Ubuntu), `pacman -S dialog` (Arch), `dnf install dialog` (Fedora). Gentoo LiveGUI ma go domyślnie.
