#!/usr/bin/env bash
# fprintd-pam-setup — wire pam_fprintd into the auth stack on OpenRC systems
#
# WHY THIS IS A POST-BOOT STEP, NOT PART OF THE INSTALL
# fprintd is D-Bus activated. There is no running D-Bus system bus inside the
# installer's chroot, so at install time it is impossible to verify that
# activation actually works. On systemd the installer configures PAM directly
# (activation there is reliable enough); on OpenRC it installs this script
# instead, so the PAM edit only happens on a system where fprintd has
# demonstrably answered a real D-Bus call.
#
# WHY THE VERIFICATION MATTERS
# pam_fprintd BLOCKS while it waits for the daemon. If activation silently
# fails, every login sits there until the module gives up — on a machine you
# administer over SSH that is a genuinely bad afternoon. Hence: probe first,
# and always write an explicit timeout.
#
# Usage:
#   fprintd-pam-setup            # verify, then configure PAM
#   fprintd-pam-setup --check    # verify only, change nothing
set -euo pipefail

PAM_FILE="/etc/pam.d/system-auth"
# timeout minimum is 10s (values below are clamped by the module), default 30.
# max-tries default is 3; 2 is enough before falling through to the password.
PAM_LINE="auth     sufficient   pam_fprintd.so timeout=10 max-tries=2"

CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

info()  { echo "[*] $*"; }
ok()    { echo "[+] $*"; }
warn()  { echo "[!] $*" >&2; }
fail()  { echo "[x] $*" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || fail "Uruchom jako root (sudo fprintd-pam-setup)"

# --- 1. Czy moduł PAM w ogóle istnieje ---
if ! compgen -G "/lib*/security/pam_fprintd.so" > /dev/null && \
   ! compgen -G "/usr/lib*/security/pam_fprintd.so" > /dev/null; then
    fail "Brak pam_fprintd.so — fprintd zbudowany bez USE=pam?
    Napraw: echo 'sys-auth/fprintd pam' >> /etc/portage/package.use/fprintd
            emerge --changed-use sys-auth/fprintd"
fi
ok "pam_fprintd.so obecny"

# --- 2. Czy magistrala D-Bus działa ---
if ! pgrep -x dbus-daemon > /dev/null 2>&1 && ! pgrep -x dbus-broker > /dev/null 2>&1; then
    fail "Demon D-Bus nie działa — bez niego fprintd się nie aktywuje.
    Napraw: rc-service dbus start && rc-update add dbus default"
fi
ok "D-Bus działa"

# --- 3. Czy fprintd faktycznie odpowiada (właściwy test) ---
# GetDevices wymusza aktywację usługi przez D-Bus i zwraca listę czytników.
# Odpowiedź = demon wstał i widzi sprzęt. `timeout` chroni przed zawieszeniem
# tego skryptu, gdy aktywacja utknie — dokładnie ten scenariusz, przed którym
# ma chronić późniejszy wpis PAM.
info "Sprawdzam aktywację fprintd przez D-Bus (do 20 s)..."
if ! timeout 20 dbus-send --system --print-reply \
        --dest=net.reactivated.Fprint \
        /net/reactivated/Fprint/Manager \
        net.reactivated.Fprint.Manager.GetDevices > /dev/null 2>&1; then
    fail "fprintd NIE odpowiedział na D-Bus — PAM zostaje nietknięty (i dobrze).
    Diagnostyka:
      dbus-send --system --print-reply --dest=net.reactivated.Fprint \\
        /net/reactivated/Fprint/Manager net.reactivated.Fprint.Manager.GetDevices
      ls /usr/share/dbus-1/system-services/net.reactivated.Fprint.service
      lsusb | grep -iE '06cb:|27c6:|147e:|138a:'
    Jeśli plik .service istnieje, a aktywacja nie działa — uruchom demona
    ręcznie (/usr/libexec/fprintd &) i sprawdź, czy 'fprintd-list root' widzi
    czytnik. Bez działającej aktywacji wpis PAM tylko zawiesiłby logowanie."
fi
ok "fprintd odpowiada na D-Bus"

if [[ "${CHECK_ONLY}" -eq 1 ]]; then
    info "--check: nic nie zmieniam. Bez tej flagi skrypt wpisze PAM."
    exit 0
fi

# --- 4. Wpis do PAM (idempotentny) ---
[[ -f "${PAM_FILE}" ]] || fail "Brak ${PAM_FILE}"

if grep -q 'pam_fprintd.so' "${PAM_FILE}"; then
    ok "pam_fprintd już skonfigurowany w ${PAM_FILE} — nic do zrobienia"
    exit 0
fi

anchor=$(grep -n '^auth.*pam_unix.so' "${PAM_FILE}" | head -1 | cut -d: -f1) || true
[[ -n "${anchor}" ]] || fail "Nie znalazłem linii 'auth ... pam_unix.so' w ${PAM_FILE}
    Dopisz ręcznie PRZED nią: ${PAM_LINE}"

cp -a "${PAM_FILE}" "${PAM_FILE}.pre-fprintd"
sed -i "${anchor}i ${PAM_LINE}" "${PAM_FILE}"

if ! grep -q 'pam_fprintd.so' "${PAM_FILE}"; then
    cp -a "${PAM_FILE}.pre-fprintd" "${PAM_FILE}"
    fail "Wpis się nie powiódł — przywrócono kopię zapasową"
fi

ok "Dodano do ${PAM_FILE} (kopia: ${PAM_FILE}.pre-fprintd):"
echo "    ${PAM_LINE}"
echo ""
info "Wpis jest 'sufficient' — nieudany odcisk ZAWSZE spada na hasło."
info "Dalej:"
echo "    fprintd-enroll                  # jako zwykły user, nie root"
echo "    fprintd-verify"
echo "    sudo -k && sudo true            # test na żywym stosie PAM"
echo ""
warn "Zanim się wylogujesz: sprawdź logowanie w DRUGIEJ sesji (SSH/TTY),"
warn "trzymając tę otwartą. Odzyskanie: cp ${PAM_FILE}.pre-fprintd ${PAM_FILE}"
warn "${PAM_FILE} należy do sys-auth/pambase — po jego aktualizacji wpis"
warn "wróci jako konflikt w etc-update/dispatch-conf, trzeba go przeklikać."
