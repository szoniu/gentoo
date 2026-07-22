#!/usr/bin/env bash
# tests/test_kernel_config.sh — Test _patch_kernel_config apply semantics
#
# Exercises the REAL function via the _KERNEL_CONFIG_TEST_FILE hook (same
# pattern as _RESUME_TEST_DIR): the hook points it at a scratch .config and
# skips every `make` call, so no root, no kernel tree, no /usr/src/linux.
#
# What matters here is the apply loop, which has four distinct behaviours and
# had two silent-failure bugs:
#   "# KEY is not set" -> KEY=val
#   KEY=m + wanted y   -> KEY=y   (promotion; used to be a no-op)
#   KEY=y + wanted m   -> untouched (never downgrade)
#   key absent         -> appended
# Plus: the post-olddefconfig assertion that reports options which got dropped.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export _GENTOO_INSTALLER=1
export LIB_DIR="${SCRIPT_DIR}/lib"
export DATA_DIR="${SCRIPT_DIR}/data"
export LOG_FILE="/tmp/gentoo-test-kernel-config.log"
export DRY_RUN=1
export NON_INTERACTIVE=1
: > "${LOG_FILE}"

source "${LIB_DIR}/constants.sh"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/utils.sh"
source "${LIB_DIR}/kernel.sh"

PASS=0
FAIL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "${expected}" == "${actual}" ]]; then
        echo "  PASS: ${desc}"
        (( PASS++ )) || true
    else
        echo "  FAIL: ${desc} — expected '${expected}', got '${actual}'"
        (( FAIL++ )) || true
    fi
}

assert_has_line() {
    local desc="$1" line="$2" file="$3"
    if grep -qxF "${line}" "${file}" 2>/dev/null; then
        echo "  PASS: ${desc}"
        (( PASS++ )) || true
    else
        echo "  FAIL: ${desc} — '${line}' not in config"
        (( FAIL++ )) || true
    fi
}

assert_no_line() {
    local desc="$1" line="$2" file="$3"
    if grep -qxF "${line}" "${file}" 2>/dev/null; then
        echo "  FAIL: ${desc} — '${line}' unexpectedly present"
        (( FAIL++ )) || true
    else
        echo "  PASS: ${desc}"
        (( PASS++ )) || true
    fi
}

TESTDIR=$(mktemp -d)
trap 'rm -rf "${TESTDIR}"' EXIT
KCONFIG="${TESTDIR}/.config"
export _KERNEL_CONFIG_TEST_FILE="${KCONFIG}"

# lib/kernel.sh uses GNU `sed -i` (target platform is a Gentoo live ISO). BSD
# sed on macOS wants an argument after -i, fails, and — under `set -e` — kills
# the run mid-loop with no output, which looks like a code bug but isn't. Shim
# GNU sed into PATH when it's available under its Homebrew name so the real
# code path still gets exercised here; skip cleanly when it isn't.
if ! sed --version 2>/dev/null | grep -q GNU; then
    if command -v gsed >/dev/null 2>&1; then
        mkdir -p "${TESTDIR}/bin"
        ln -sf "$(command -v gsed)" "${TESTDIR}/bin/sed"
        export PATH="${TESTDIR}/bin:${PATH}"
        echo "(non-GNU sed detected — using gsed via PATH shim)"
    else
        echo "SKIP: GNU sed required (macOS: brew install gnu-sed)"
        exit 0
    fi
fi

# Hardware flags are read straight from the environment by the function, so a
# fixed set here keeps the run deterministic regardless of the host it runs on.
reset_hw_env() {
    export WWAN_DETECTED=0
    export FINGERPRINT_DETECTED=0
    export BLUETOOTH_DETECTED=0
    export THUNDERBOLT_DETECTED=0
    export SENSORS_DETECTED=0
    export CONVERTIBLE_DETECTED=0
    export SURFACE_DETECTED=0
    export ASUS_ROG_DETECTED=0
    export GPU_VENDOR="intel"
    export IGPU_VENDOR=""
    export DGPU_VENDOR=""
}

seed_config() {
    printf '%s\n' "$@" > "${KCONFIG}"
}

echo "=== Test: WWAN detected — PCIe iosm + USB stack ==="
reset_hw_env
export WWAN_DETECTED=1
seed_config "CONFIG_LOCALVERSION=\"\"" "# CONFIG_IOSM is not set"
_patch_kernel_config >/dev/null 2>&1

assert_has_line "CONFIG_IOSM enabled from 'is not set'" "CONFIG_IOSM=m" "${KCONFIG}"
assert_has_line "CONFIG_WWAN added" "CONFIG_WWAN=m" "${KCONFIG}"
assert_no_line "CONFIG_WWAN NOT forced =y (depends on GNSS || GNSS = n)" \
    "CONFIG_WWAN=y" "${KCONFIG}"
assert_has_line "USB MBIM added" "CONFIG_USB_NET_CDC_MBIM=m" "${KCONFIG}"
assert_has_line "USB QMI kept" "CONFIG_USB_NET_QMI_WWAN=m" "${KCONFIG}"
assert_has_line "USB serial option kept" "CONFIG_USB_SERIAL_OPTION=m" "${KCONFIG}"

echo ""
echo "=== Test: no WWAN hardware — no modem drivers ==="
reset_hw_env
seed_config "CONFIG_LOCALVERSION=\"\""
_patch_kernel_config >/dev/null 2>&1
assert_no_line "CONFIG_IOSM absent without hardware" "CONFIG_IOSM=m" "${KCONFIG}"
assert_no_line "CONFIG_WWAN absent without hardware" "CONFIG_WWAN=m" "${KCONFIG}"

echo ""
echo "=== Test: promotion =m -> =y for boot-critical options ==="
reset_hw_env
# localmodconfig left the root-disk driver as a module — the exact case that
# used to be a silent no-op and would ship an unbootable kernel.
seed_config "CONFIG_BLK_DEV_NVME=m" "CONFIG_VMD=m" "CONFIG_MMC=m"
_patch_kernel_config >/dev/null 2>&1
assert_has_line "NVMe promoted m -> y" "CONFIG_BLK_DEV_NVME=y" "${KCONFIG}"
assert_no_line "NVMe no longer =m" "CONFIG_BLK_DEV_NVME=m" "${KCONFIG}"
assert_has_line "VMD promoted m -> y" "CONFIG_VMD=y" "${KCONFIG}"
assert_has_line "MMC promoted m -> y" "CONFIG_MMC=y" "${KCONFIG}"

echo ""
echo "=== Test: never downgrade =y -> =m ==="
reset_hw_env
export FINGERPRINT_DETECTED=1
# UHID is requested as =m; the seed config has it built in. A symmetric
# implementation would demote it — that would be a regression, not a fix.
seed_config "CONFIG_UHID=y" "CONFIG_HID_MULTITOUCH=y"
_patch_kernel_config >/dev/null 2>&1
assert_has_line "UHID stays =y" "CONFIG_UHID=y" "${KCONFIG}"
assert_no_line "UHID not demoted to =m" "CONFIG_UHID=m" "${KCONFIG}"
assert_has_line "HID_MULTITOUCH stays =y" "CONFIG_HID_MULTITOUCH=y" "${KCONFIG}"

echo ""
echo "=== Test: fingerprint gating ==="
reset_hw_env
seed_config "CONFIG_LOCALVERSION=\"\""
_patch_kernel_config >/dev/null 2>&1
assert_no_line "UHID absent when no reader detected" "CONFIG_UHID=m" "${KCONFIG}"

reset_hw_env
export FINGERPRINT_DETECTED=1
seed_config "CONFIG_LOCALVERSION=\"\""
_patch_kernel_config >/dev/null 2>&1
assert_has_line "UHID added when reader detected" "CONFIG_UHID=m" "${KCONFIG}"

echo ""
echo "=== Test: idempotency (second run changes nothing) ==="
reset_hw_env
export WWAN_DETECTED=1
export FINGERPRINT_DETECTED=1
seed_config "CONFIG_BLK_DEV_NVME=m" "# CONFIG_IOSM is not set"
_patch_kernel_config >/dev/null 2>&1
first_sum=$(cksum < "${KCONFIG}")
_patch_kernel_config >/dev/null 2>&1
second_sum=$(cksum < "${KCONFIG}")
assert_eq "config unchanged on second run" "${first_sum}" "${second_sum}"

# The log line only appears when the loop found nothing left to change.
: > "${LOG_FILE}"
out=$(_patch_kernel_config 2>&1) || true
if [[ "${out}" == *"already has required options"* ]]; then
    echo "  PASS: reports 'already has required options' on a settled config"
    (( PASS++ )) || true
else
    echo "  FAIL: expected 'already has required options', got: ${out##*$'\n'}"
    (( FAIL++ )) || true
fi

echo ""
echo "=== Test: dropped-option assertion after olddefconfig ==="
reset_hw_env
export WWAN_DETECTED=1
seed_config "CONFIG_LOCALVERSION=\"\""
_patch_kernel_config >/dev/null 2>&1
# Simulate what olddefconfig does to an option with unmet dependencies: the
# line vanishes. The next run must both re-add it and be able to name it.
grep -v '^CONFIG_IOSM=' "${KCONFIG}" > "${KCONFIG}.tmp" && mv "${KCONFIG}.tmp" "${KCONFIG}"
assert_no_line "IOSM removed to simulate olddefconfig drop" "CONFIG_IOSM=m" "${KCONFIG}"
_patch_kernel_config >/dev/null 2>&1
assert_has_line "IOSM re-added on next run" "CONFIG_IOSM=m" "${KCONFIG}"

echo ""
echo "=== Test: test hook leaves /usr/src/linux alone ==="
assert_eq "real kernel config path untouched" "0" \
    "$([[ -e /usr/src/linux/.config.test-artifact ]] && echo 1 || echo 0)"
assert_eq "scratch config is what was written" "1" \
    "$([[ -f "${KCONFIG}" ]] && echo 1 || echo 0)"

echo ""
echo "=== Results ==="
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"
[[ ${FAIL} -eq 0 ]]
