# ThinkPad X1 Nano Gen 1 — notatki instalacyjne

> Notatki per-urządzenie, wzorowane na [POCKET4.md](POCKET4.md). Sprzętowe fakty, tryb
> instalacji (SSH), **obowiązkowa checklista post-deploy** i znane ryzyka.
>
> **Status: jeszcze nieprzetestowane na żywym sprzęcie.** Wszystko poniżej to kod napisany
> z rozpoznania (lipiec 2026) — pola „zweryfikowane" wypełniamy dopiero po realnej instalacji.

## Kiedy czytać ten plik

Gdy user napisze **„instalujemy na x1 nano"** (albo cokolwiek o instalacji na tej maszynie):
przeczytaj ten plik w całości, ustaw tryb pracy przez SSH (niżej) i **pilnuj, żeby po
reboocie przejść całą checklistę post-deploy** — instalator kończy się przed nią, więc
łatwo o niej zapomnieć.

## Rola / kierunek

Lekki ultrabook (13", ~907 g). Docelowo Gentoo + systemd. Maszyna jest „nudna" dla Linuksa
(Tiger Lake, Intel wszędzie) — cała trudność siedzi w dwóch peryferiach: **czytniku linii
papilarnych** i **modemie WWAN**.

## Twarde fakty sprzętowe

| Element | Co to jest | Konsekwencja |
|---|---|---|
| CPU | Intel Tiger Lake (i5-1130G7 / i7-1160G7), 4C/8T, ~15 W | `intel-microcode` auto; `-march=tigerlake` |
| GPU | Iris Xe (integrated) | `i915` + `linux-firmware`, `VIDEO_CARDS="intel"` |
| Ekran | 13" 2160×1350 (2K, 16:10) | HiDPI — skalowanie ~150 % (GNOME: fractional scaling) |
| WiFi/BT | Intel AX201 | `IWLWIFI`/`IWLMVM` + firmware; BT przez `BT_HCIBTUSB` |
| Audio | Intel SOF, 4 głośniki + 4 mikrofony | `sof-firmware` (instalator robi to auto dla Intela) |
| Fingerprint | Synaptics Prometheus (`06cb:*`) | `libfprint` + `fprintd` + **PAM** (patrz niżej) |
| WWAN (opcja) | Fibocom L850-GL = **Intel XMM7360, PCIe** (`8086:7360`) | sterownik `iosm` (in-tree od 5.18) + FCC unlock |
| Porty | 2× Thunderbolt 4, brak USB-A, brak RJ45 | `sys-apps/bolt`; **sieć przewodowa tylko przez dongle USB-C** |
| Klawiatura/Fn | ThinkPad ACPI | `THINKPAD_ACPI` (detekcja po DMI `product_family`) |

**Brak RJ45 ma znaczenie dla instalacji:** Live ISO musi wejść na WiFi albo mieć dongle
USB-C→Ethernet. WWAN na Live ISO nie zadziała (FCC lock), więc nie licz na modem jako
źródło sieci podczas instalacji.

## Rekomendowana konfiguracja instalatora

| Zmienna | Wartość | Dlaczego |
|---|---|---|
| `INIT_SYSTEM` | `systemd` | fprintd stoi na aktywacji D-Bus; na OpenRC instalator celowo **nie** ruszy PAM |
| `KERNEL_TYPE` | `dist-kernel` | binarka ma `IOSM`/`UHID` w configu — omija cały temat patchowania kernela |
| `DESKTOP_TYPE` | `gnome` lub `plasma` | GNOME ma gładsze fractional scaling na 2160×1350 |
| `FILESYSTEM` | `btrfs` | snapshoty przed eksperymentami z modemem/kernelem |
| `ENABLE_FINGERPRINT` | `yes` | pojawi się w checkliście tylko gdy wykryty |
| `ENABLE_WWAN` | `yes` | j.w.; bezpiecznie zostawić `yes` nawet bez karty WWAN |

## Instalacja przez SSH

**To jest domyślny tryb pracy na tej maszynie** — instalujemy zdalnie, z drugiego kompa.
Pełna procedura (sshd na Live ISO, tmux, drugi terminal do podglądu) jest w
[README.md → „Zdalna instalacja przez SSH"](../README.md). X1-Nano-specyficzne dodatki:

- **Zawsze w `tmux`** — reguła ogólna, ale tutaj krytyczna: zerwane WiFi = zabity emerge
  w połowie KDE/GNOME. `tmux new -s install`, powrót `tmux attach -t install`.
- **Nie ma zapasowego TTY.** Przy instalacji lokalnej ratunkiem jest `Ctrl+Alt+F2`; przez
  SSH tego nie ma — drugi „TTY" to druga sesja SSH lub drugie okno tmux (`Ctrl+B` `"`).
- **Reboot ucina sesję.** Po pierwszym boocie łączysz się już z zainstalowanym systemem:
  instalator instaluje i włącza `sshd` (`ENABLE_SSH=yes`, `lib/system.sh`), ale logujesz
  się jako **user** (nie root — `PermitRootLogin` zostaje domyślne). Hasło ustawione
  w wizardzie. IP wyszukaj po MAC na routerze albo podłącz ekran raz.
- **Po reboocie od razu leć checklistę niżej** — z SSH to wszystko działa, żaden krok nie
  wymaga fizycznego dostępu poza dotknięciem czytnika przy `fprintd-enroll`.

## Checklista post-deploy (po pierwszym boocie)

Komendy jednoliniowe, do wklejenia po SSH. Odhaczamy po kolei.

### 1. Sanity systemu

```bash
journalctl -b -p err --no-pager | head -40
```
```bash
uname -r && cat /sys/power/mem_sleep
```
> `[s2idle]` bez `deep` = modern standby (Nano może nie mieć S3). Jeśli bateria znika
> w torbie, sprawdź w BIOS „Sleep State: Linux/Windows".

### 2. Fingerprint

```bash
lsusb | grep -i '06cb\|synaptics'
```
```bash
grep pam_fprintd /etc/pam.d/system-auth
```
```bash
fprintd-enroll
```
```bash
fprintd-verify
```
```bash
sudo -k && sudo true
```
> Ostatnia komenda ma poprosić o palec (fallback na hasło zawsze działa — wpis PAM jest
> `sufficient`). Brak wpisu w `system-auth` = `_configure_fprintd_pam()` odpuściło; zajrzyj
> do logu instalatora, backup leży w `/etc/pam.d/system-auth.pre-fprintd`.

### 3. WWAN — najbardziej ryzykowny punkt

```bash
lspci -nnk -d 8086:7360
```
> Musi pokazać `Kernel driver in use: iosm`. Brak sekcji `Kernel driver` = kernel bez
> `CONFIG_IOSM` (patrz „Znane ryzyka").

```bash
ls -l /etc/ModemManager/fcc-unlock.d/ | head
```
```bash
grep -w modemmanager /var/db/pkg/net-misc/networkmanager-*/USE
```
```bash
grep -wE 'mbim|qmi' /var/db/pkg/net-misc/modemmanager-*/USE
```
```bash
systemctl status ModemManager --no-pager
```
```bash
mmcli -L
```
> `mmcli -L` musi wylistować modem. Jeśli listuje, ale nie rejestruje się w sieci —
> to FCC lock: sprawdź `journalctl -u ModemManager | grep -i fcc`.

```bash
nmcli device | grep gsm
```

### 4. Reszta sprzętu

```bash
wpctl status | head -30
```
```bash
boltctl list
```
```bash
nmcli device wifi list | head
```
```bash
cat /sys/class/power_supply/BAT0/charge_control_end_threshold
```
> Ostatnie = `thinkpad_acpi` żyje (progi ładowania). Ustawienie progu: `echo 80 | sudo tee …`.

## Co instalator robi automatycznie (nie powtarzaj ręcznie)

Zaimplementowane w lipcu 2026 właśnie pod tę maszynę:

- **`lib/hardware.sh` `detect_wwan()`** — PCIe `8086:7360`/`8086:7560`, dowolny kontroler
  klasy „cellular", plus modemy USB po vendor ID (Quectel/Fibocom/Telit/Cinterion/Sierra/
  Huawei). Intelowe `8087` **celowo pominięte** — to też każdy Intel Bluetooth.
- **`lib/kernel.sh` `_patch_kernel_config()`** — dla WWAN dorzuca `CONFIG_WWAN=m` +
  `CONFIG_IOSM=m` (ścieżka PCIe) obok dotychczasowych USB (`qmi_wwan`, `cdc_mbim`,
  `option`). Dotyczy tylko genkernel/surface; dist-kernel ma to w binarce.
  `WWAN` jako `=m`, nie `=y`: upstream deklaruje `depends on GNSS || GNSS = n`,
  więc przy `GNSS=m` wariant `=y` jest niedozwolony i `make olddefconfig` skasowałby
  go po cichu **razem z `IOSM`**. `IOSM` ma tylko `depends on PCI` + `select NET_DEVLINK`.
- **`lib/portage.sh` `generate_make_conf()`** — pisze `package.use/wwan`
  (`modemmanager mbim qmi`, `networkmanager modemmanager`) **przed** emerge
  NetworkManagera, bo NM bez `USE=modemmanager` nie pokaże modemu w GUI.
- **`lib/portage.sh` `install_wwan_tools()`** — safety net na `package.use`, rebuild NM
  z `--changed-use` gdy zbudowany bez flagi, `dmidecode` (klucz FCC siedzi w SMBIOS),
  `_enable_fcc_unlock()`.
- **`lib/portage.sh` `_enable_fcc_unlock()`** — symlinkuje **wszystkie** skrypty
  z `/usr/share/ModemManager/fcc-unlock.available.d/` do `/etc/ModemManager/fcc-unlock.d/`.
  Od MM 1.18.4 są domyślnie martwe; MM odpala tylko ten o nazwie zgodnej z `vid:pid`
  znalezionego modemu, więc nadmiarowe symlinki są bezczynne. Blanket zamiast
  celowanego, bo w chroocie nie ma pewności co do `lspci`/`lsusb`.
- **`lib/portage.sh` `install_fingerprint_tools()`** — `USE=pam` dla `fprintd`
  (bez tego nie ma `pam_fprintd.so`) + `_configure_fprintd_pam()`.
- **`lib/portage.sh` `_configure_fprintd_pam()`** — najpierw próbuje USE-flagi
  `sys-auth/pambase fprintd` (jeśli drzewo ją ma), w przeciwnym razie wstawia
  `auth sufficient pam_fprintd.so` przed pierwszą linią `auth … pam_unix.so`
  w `/etc/pam.d/system-auth`, z backupem. `sufficient`, nie `required` — nie da się
  tym zablokować logowania. **Tylko systemd.**

## Znane ryzyka i fallbacki

- **`iosm` może związać modem, ale nie wystawić portu MBIM.** Na części firmware'ów
  L850-GL sterownik in-tree nie wystarcza i potrzebny jest out-of-tree
  [`xmm7360-pci`](https://github.com/xmm7360/xmm7360-pci) (kompilowany ręcznie,
  własne narzędzia w Pythonie). Objaw: `lspci -k` pokazuje `iosm`, ale `mmcli -L` pusto.
  Instalator o tym ostrzega tekstem na końcu `install_wwan_tools()`.
- **FCC unlock bywa niewystarczający.** Część kart wymaga jednorazowej aktywacji pod
  Windows. Alternatywa: [lenovo/lenovo-wwan-unlock](https://github.com/lenovo/lenovo-wwan-unlock).
- **Edycja `/etc/pam.d/system-auth` należy do `sys-auth/pambase`.** Po update'cie pambase
  plik wyjdzie jako konflikt w `etc-update`/`dispatch-conf` — wpis `pam_fprintd` trzeba
  wtedy przeklikać z powrotem. Nie zginie po cichu, ale trzeba na to uważać.
- **Przejście dist-kernel → genkernel po instalacji** (wizardem z `~/dotfiles`,
  `_gentoo_switch_to_genkernel`): wizard ma **własny** `_gentoo_patch_kernel_config()`,
  niezależny od tego instalatora — zob. `~/dotfiles/docs/kernel-build-paths.md`. Jeśli
  nie ma tam `CONFIG_IOSM`, po przesiadce modem zniknie. Sprawdź przed migracją.

## Do zweryfikowania na żywym sprzęcie

- [ ] `detect_fingerprint()` faktycznie łapie Prometheusa (czy `lsusb` pokazuje `06cb:`)
- [ ] `_configure_fprintd_pam()` — którą ścieżką poszło (pambase USE vs edycja system-auth)
- [ ] `iosm` vs `xmm7360-pci` — czy in-tree wystarcza na tej rewizji L850-GL
- [ ] Czy `mem_sleep` ma `deep`, czy tylko `s2idle`
- [ ] Skalowanie 2160×1350 — 150 % czy 125 % w praktyce
