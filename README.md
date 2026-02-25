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
nmcli device wifi connect 'NazwaTwojejSieci' password 'TwojeHaslo'
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

### 4. Ustaw datę systemową

Live ISO może mieć przestarzały zegar (np. z 2021 roku). Bez poprawnej daty SSL nie zadziała i `git clone` / `emerge` będą failować.

```bash
# Sprawdź aktualną datę
date

# Jeśli data jest nieprawidłowa, ustaw ręcznie (wstaw aktualną datę):
date -s "2026-02-25 09:00:00"
```

### 5. Sklonuj repo i uruchom installer

```bash
sudo su
git clone https://github.com/szoniu/gentoo.git
cd gentoo
./install.sh
```

> **Błąd SSL przy `git clone`?** Najprawdopodobniej zły zegar systemowy — wróć do kroku 4.
>
> **`Permission denied (publickey)`?** Użyj adresu HTTPS (jak wyżej), nie SSH (`git@github.com:...`). Live ISO nie ma Twoich kluczy SSH.

Installer poprowadzi Cię przez 18 ekranów konfiguracji, a potem zainstaluje wszystko automatycznie.

### 6. Po instalacji

Po zakończeniu installer zapyta czy chcesz rebootować. Wyjmij pendrive i uruchom komputer — powinieneś zobaczyć GRUB, a potem ekran logowania SDDM z KDE Plasma.

## Alternatywne sposoby uruchomienia

```bash
# Tylko konfiguracja (generuje plik .conf, nic nie instaluje)
./install.sh --configure

# Instalacja z gotowego configa (bez wizarda)
./install.sh --config moj-config.conf --install

# Wznów po awarii (skanuje dyski w poszukiwaniu checkpointów)
./install.sh --resume

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

### Wznowienie po awarii (`--resume`)

Jeśli instalacja została przerwana (OOM kill, zawieszenie, utrata SSH, przerwa w prądzie), możesz wznowić jedną komendą:

```bash
./install.sh --resume
```

`--resume` automatycznie:
1. Skanuje wszystkie partycje (ext4/btrfs/xfs) w poszukiwaniu danych z poprzedniej instalacji
2. Odzyskuje checkpointy (informacje o ukończonych fazach) i plik konfiguracji
3. Pomija już ukończone fazy i kontynuuje od miejsca przerwania

Co przetrwało na dysku docelowym:
- **Checkpointy** — pliki w `/tmp/gentoo-installer-checkpoints/` na partycji docelowej
- **Config** — `/tmp/gentoo-installer.conf` na partycji docelowej (zapisywany po fazie partycjonowania)

Jeśli config nie zostanie znaleziony (np. awaria nastąpiła przed partycjonowaniem), `--resume` poprosi o ponowne przejście wizarda konfiguracyjnego — ale ukończone fazy instalacji nadal zostaną pominięte.

Ręczna alternatywa (jeśli `--resume` nie zadziała):

```bash
# 1. Zamontuj dysk docelowy
mount /dev/sdX2 /mnt/gentoo

# 2. Skopiuj checkpointy
cp -a /mnt/gentoo/tmp/gentoo-installer-checkpoints/* /tmp/gentoo-installer-checkpoints/

# 3. Skopiuj config (jeśli istnieje)
cp /mnt/gentoo/tmp/gentoo-installer.conf /tmp/gentoo-installer.conf

# 4. Odmontuj i uruchom normalnie
umount /mnt/gentoo
./install.sh
```

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
passwd root

# 2. Ustaw datę (Live ISO może mieć przestarzały zegar — SSL nie zadziała)
date -s "2026-02-25 09:00:00"   # wstaw aktualną datę

# 3. Uruchom sshd
#    Gentoo LiveGUI (OpenRC):
rc-service sshd start

#    Jeśli live ISO ma systemd:
systemctl start sshd

# 4. Sprawdź IP
ip -4 addr show | grep inet
```

#### Zdalna instalacja z innego komputera

```bash
# Połącz się (wyłączamy klucze SSH, bo Live ISO ich nie ma — łączymy hasłem)
ssh -o PubkeyAuthentication=no root@<IP-live-ISO>

# Sklonuj repo i uruchom installer
git clone https://github.com/szoniu/gentoo.git
cd gentoo
./install.sh
```

Installer działa normalnie przez SSH — dialog TUI renderuje się w terminalu SSH.

> **"Connection refused"?** Sprawdź czy `sshd` działa na Live ISO: `rc-service sshd status`.
>
> **"Encrypted private OpenSSH key detected"?** Twój klient SSH próbuje użyć zaszyfrowanego klucza. Użyj flagi `-o PubkeyAuthentication=no` jak wyżej, żeby wymusić hasło.
>
> **Nie możesz się połączyć mimo poprawnego IP?** Upewnij się, że oba komputery są w **tej samej sieci**. Sieci gościnne (Guest WiFi) są zazwyczaj izolowane od firmowego LAN-u. Podłącz oba urządzenia do tej samej sieci.
>
> **"WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED"?** Po restarcie Live ISO klucze SSH hosta się zmieniają. Usuń stary klucz i połącz się ponownie:
> ```bash
> ssh-keygen -R <IP-live-ISO>
> ssh -o PubkeyAuthentication=no root@<IP-live-ISO>
> ```

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

#### Przed instalacją

- **`git clone` — SSL certificate not yet valid** — zegar systemowy jest przestarzały. Ustaw datę: `date -s "2026-02-25 09:00:00"` (wstaw aktualną).
- **`git clone` — Permission denied (publickey)** — użyj HTTPS: `git clone https://github.com/szoniu/gentoo.git`, nie SSH (`git@github.com:...`).
- **`nmcli` nie łączy z WiFi** — użyj single quotes zamiast double quotes: `nmcli device wifi connect 'MojaSiec' password 'MojeHaslo'`. Double quotes mogą łamać się na znakach specjalnych w SSID/haśle.
- **Preflight: "Network connectivity required"** — installer pinguje `gentoo.org` i `google.com`. Jeśli sieć działa ale DNS nie, dodaj ręcznie: `echo "nameserver 8.8.8.8" >> /etc/resolv.conf`. Installer próbuje to naprawić automatycznie, ale na świeżym Live ISO DNS może nie być skonfigurowany.

#### W trakcie instalacji

- **`emerge` — "Temporary failure in name resolution"** — DNS przestał działać. Na innym TTY (`Ctrl+Alt+F2`) wpisz: `echo "nameserver 8.8.8.8" >> /etc/resolv.conf`, wróć na TTY1 i wybierz `r` (retry).
- **`chronyd -q` — "No suitable source for synchronisation"** — zegar nie zsynchronizował się z NTP. Nie krytyczne jeśli data jest w miarę poprawna. Wybierz **Continue**.
- **Installer zawisł, nic się nie dzieje** — sprawdź na TTY2 (`Ctrl+Alt+F2`) czy `cc1`/`gcc`/`make` działają w `top`. Jeśli tak — kompilacja trwa, po prostu czekaj. Gentoo kompiluje WSZYSTKO ze źródeł. Kernel: 20-60 min. KDE Plasma: 1-4h.
- **Przerwa w prądzie / reboot** — uruchom installer ponownie, zapyta czy wznowić od ostatniego checkpointu. Fazy takie jak kompilacja kernela czy @world nie będą powtarzane.
- **Menu "retry / shell / continue / abort"** — installer napotkał błąd. `r` = spróbuj ponownie, `s` = otwórz shell i napraw ręcznie (potem `exit`), `c` = pomiń ten krok, `a` = przerwij instalację.

#### Ogólne

- **Log** — pełny log instalacji: `/tmp/gentoo-installer.log` (przed chroot) i `/mnt/gentoo/tmp/gentoo-installer.log` (w chroot)
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
  --resume          Wznów po awarii (skanuje dyski)

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
bash tests/test_resume.sh     # Resume from disk scanning + recovery
bash tests/test_multiboot.sh   # Multi-boot OS detection + serialization
```

## Struktura projektu

```
install.sh              — Główny entry point
configure.sh            — Wrapper: tylko wizard TUI
gentoo.conf.example     — Przykładowa konfiguracja z komentarzami

lib/                    — Moduły biblioteczne (sourcowane, nie uruchamiane)
tui/                    — Ekrany TUI (każdy = funkcja, return 0/1/2)
data/                   — Bazy danych (CPU march, GPU, mirrory, USE flags, motyw TUI)
presets/                — Gotowe presety
hooks/                  — Hooki (*.sh.example)
tests/                  — Testy
TODO.md                 — Planowane ulepszenia
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
