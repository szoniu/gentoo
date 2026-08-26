# Framework Laptop 12 (Core Series 3) — notatki instalacyjne

> Dotyczy **odświeżenia z sierpnia 2026** — Framework Laptop 12 z procesorami
> Intel **Core Series 3** („Wildcat Lake"). To nie jest ten sam sprzęt co
> pierwszy Laptop 12 z 13. generacji Core i3/i5 (Raptor Lake-U) — inna
> platforma, inny sterownik GPU, inny wymóg wersji kernela.

## Kiedy czytać ten plik

Gdy instalujesz na Framework Laptop 12 z Core 3 / Core 5 / Core 7 (modele
304 / 320 / 350). Przeczytaj **przed** wypaleniem pendrive'a — kluczowa
decyzja (wersja kernela na live ISO) zapada zanim installer w ogóle wystartuje.

## Twarde fakty sprzętowe

| Element | Co siedzi w środku | Konsekwencja dla instalacji |
|---|---|---|
| CPU | Wildcat Lake, 6 rdzeni (2× Cougar Cove P + 4× Darkmont LP-E), Intel 18A | CPUID **family 6, model 0xD5 (213)** |
| `-march` | `pantherlake` | GCC mapuje `wildcatlake` na `PROCESSOR_PANTHERLAKE` z identyczną maską `PTA_PANTHERLAKE`; nazwa `wildcatlake` wymaga GCC 16, `pantherlake` działa już od GCC 14 |
| iGPU | Xe3, 1–2 rdzenie Xe | **`xe`, nie `i915`** — patrz niżej |
| Wi-Fi | Intel **BE213** (Wi-Fi 7 R2), wymienny moduł M.2 | `iwlwifi` + `iwlmld` (nie sam `iwlmvm`) |
| EC | kontroler w protokole ChromeOS EC | `cros_ec_lpc`, nie vendorowe WMI |
| Thunderbolt | TB4 na **dwóch tylnych** slotach kart rozszerzeń; przednie to USB 3.2 Gen 2 | ma znaczenie, gdy bootujesz z zewnętrznego nośnika |
| Ekran | 12,2" dotykowy, konwertowalny, obsługa rysika | chassis_type 31/32 → `detect_convertible` |
| Fingerprint | w przycisku zasilania (standard w Core 5/7, opcja w Core 3) | `fprintd` |
| Klawiatura | podświetlana, firmware ZMK (open source) | brak sterownika po stronie kernela |
| RAM | DDR5 SO-DIMM, do 64 GB, do 6400 MT/s | wymienna — realnie zdejmuje problem OOM-a przy Qt6/KDE |
| Dysk | M.2 **2230** NVMe, do 2 TB | jeden slot, brak eMMC |

Framework sprzedaje warianty z preinstalowaną Fedorą 44 KDE i sam podaje
wymaganie: **kernel 7.1 lub nowszy**.

## Największa pułapka: wersja kernela na live ISO

To jest punkt, w którym instalacja psuje się najwcześniej i najmniej czytelnie.
Wsparcie display dla Wildcat Lake weszło do kernela dopiero w 6.17, a Framework
podaje 7.1 jako próg pełnej funkcjonalności. Gentoo Minimal Install ISO bywa
starsze.

**Zanim wypalisz pendrive — sprawdź datę i wersję kernela ISO.** Po
zabootowaniu:

```bash
uname -r
```

Jeśli live ISO ma kernel starszy niż 6.17, spodziewaj się kombinacji: brak
obrazu poza efifb, brak Wi-Fi (BE213 nierozpoznane), niedziałający touchpad.
Wtedy pobierz **najnowsze** Gentoo Minimal ISO albo zainstaluj przez SSH z
ISO innej dystrybucji z nowym kernelem — installer nie wymaga, żeby live ISO
było gentoowskie.

Osobna, **niezależna** sprawa: kernel, który wyląduje na dysku. Tu jest OK —
`_set_kernel_keyword` dopisuje `~amd64` dla wybranego typu kernela, więc:

| typ | co się zainstaluje | uwaga |
|---|---|---|
| `dist-kernel` | `sys-kernel/gentoo-kernel-bin` 7.1.x | stabilne w Gentoo to nadal 6.18.x — bez tego keyworda dostałbyś kernel bez Wildcat Lake |
| `genkernel` | `sys-kernel/gentoo-sources` 7.1.x / 7.2.x | j.w. |

## Rekomendowana konfiguracja instalatora

| Ekran | Wybór | Dlaczego |
|---|---|---|
| Kernel | **`dist-kernel`** | patrz niżej |
| Init | systemd | krótsza ścieżka do działającego fingerprinta i time-syncu; OpenRC też przejdzie |
| Filesystem | btrfs | wymienny dysk + snapshoty; ext4 jeśli wolisz prostotę |
| Swap | zram | 16–64 GB DDR5, swap na dysku niepotrzebny |
| Desktop | plasma / gnome | Framework sam wysyła Fedorę z KDE |
| Secure Boot | włącz, jeśli zostawiasz SB w UEFI | Framework wysyła z włączonym |

### Dlaczego dist-kernel, a nie genkernel — na starcie

`genkernel` w tym instalatorze robi `localmodconfig`, czyli przycina konfigurację
do modułów **załadowanych na live ISO**. Na świeżej platformie to jest dokładnie
najgorszy moment: jeśli ISO nie zna Wildcat Lake, to nie załadowało ani `xe`,
ani `iwlwifi` pod BE213 — a więc nie ma czego zachować. Tablica wymuszeń w
`_patch_kernel_config` to nadrabia (i po poprawkach opisanych niżej nadrabia
poprawnie), ale zakładanie się z nią na nieznanym sprzęcie nie ma sensu, skoro
`gentoo-kernel-bin` daje gotowy, przetestowany 7.1.x w kilka minut.

Na genkernel przejdź **po** pierwszym udanym boocie — wtedy `localmodconfig`
seeduje się z *działającego* systemu, gdzie wszystkie właściwe moduły są już
załadowane. Ścieżkę ma wizard z dotfiles: `_gentoo_switch_to_genkernel()`
(zostawia dist-kernel jako wpis fallback w GRUB-ie, nic nie kasuje).

## Co instalator robi automatycznie (nie powtarzaj ręcznie)

- `-march=pantherlake` z jawnego wpisu w `data/cpu_march_database.sh`
  (model 213), plus walidacja `portage_validate_march` w chroocie, która
  sprawdza, że toolchain naprawdę tę nazwę zna, zanim ruszy `@world`
- `CONFIG_DRM_XE=m` + `CONFIG_DRM_XE_DISPLAY=y` + `CONFIG_X86_PLATFORM_DEVICES=y`
  (ścieżka genkernel)
- `CONFIG_PINCTRL_INTEL_PLATFORM=m` — GPIO/pinctrl dla Panther/Wildcat Lake
- `CONFIG_CROS_EC` + `CONFIG_CROS_EC_LPC` — kontroler EC (bateria, USB-PD)
- `CONFIG_IWLWIFI` + `CONFIG_IWLMVM` + `CONFIG_IWLMLD` — Wi-Fi 7
- wykrycie Wi-Fi po **klasie PCI** (`8086::0280`), nie po nazwie z `pci.ids` —
  odporne na przestarzałą bazę na live ISO
- `sys-firmware/intel-microcode`, `sys-firmware/sof-firmware`, `linux-firmware`
- `fprintd` + `libfprint` (gdy czytnik wykryty), na OpenRC dodatkowo helper
  `fprintd-pam-setup` do uruchomienia po pierwszym boocie
- moduły dla konwertowalnych: `HID_SENSOR_*`, `INTEL_ISH_HID`, `INTEL_VBTN`,
  `INTEL_HID`, `HID_MULTITOUCH`

## Checklista post-deploy (po pierwszym boocie)

### 1. GPU — czy związał się `xe`

```bash
lspci -k -d ::0300
```

Chcesz zobaczyć `Kernel driver in use: xe`. Jeśli widzisz `i915` albo nic:

```bash
dmesg | grep -iE 'xe |i915|drm'
```

Brak jakiegokolwiek sterownika = działasz na efifb (obraz jest, ale bez
akceleracji, bez sterowania jasnością). Na dist-kernelu nie powinno się
zdarzyć; na genkernelu sprawdź, czy `CONFIG_DRM_XE=m` przetrwało
`olddefconfig` — installer wypisuje wtedy ostrzeżenie
„Dropped by olddefconfig".

### 2. Wi-Fi

```bash
ip link                       # interfejs wl* istnieje?
dmesg | grep -i iwlwifi       # firmware BE213 się wczytał?
```

Brak firmware'u → `sys-kernel/linux-firmware` musi być świeży.

### 3. Kontroler EC (bateria, ładowanie)

```bash
ls /dev/cros_ec               # urządzenie istnieje?
cat /sys/class/power_supply/BAT*/capacity
```

`cros_ec_lpc` wiąże się przez DMI `sys_vendor=Framework` +
`product_family=Laptop` — reguła catch-all w upstreamie obejmuje Laptop 12.

### 4. Dotyk, rysik, obrót ekranu

```bash
libinput list-devices | grep -iE 'touch|pen|stylus'
monitor-sensor                # z iio-sensor-proxy — obrót ekranu
```

### 5. Fingerprint

Na systemd działa od razu (`fprintd-enroll`). Na OpenRC:

```bash
sudo fprintd-pam-setup
```

### 6. Thunderbolt

Pamiętaj, że TB4 jest tylko na **tylnych** dwóch slotach — dok podłączony z
przodu zadziała jak zwykły USB 3.2 i będzie to wyglądało na usterkę doka.

## Do zweryfikowania na żywym sprzęcie

Nie mam tego laptopa — poniższe wynika z lektury upstreamu i dokumentacji
producenta, nie z uruchomienia:

- czy `PINCTRL_INTEL_PLATFORM` faktycznie obsługuje Wildcat Lake. Help tego
  symbolu wymienia Lunar Lake, Nova Lake i Panther Lake; Wildcat Lake to ta
  sama rodzina IP i sterownik jest enumerowany przez ACPI, więc powinien —
  ale to wniosek, nie pomiar. Jeśli touchpad nie generuje przerwań, to jest
  pierwsze miejsce do sprawdzenia (`ls /sys/bus/acpi/devices/INTC*`)
- dokładne PCI ID modułu BE213 (w `iwlwifi` dopasowuje się po typie RF, nie po
  ID) — dlatego gate przestawiony na klasę PCI zamiast listy ID
- vendor czytnika linii papilarnych (zakładam Goodix/Synaptics — obie rodziny
  są w `detect_fingerprint`)
- czy `suspend` (s2idle) wraca poprawnie
