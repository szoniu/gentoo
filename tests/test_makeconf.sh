#!/usr/bin/env bash
# tests/test_makeconf.sh — Test make.conf generation
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export _GENTOO_INSTALLER=1
export LIB_DIR="${SCRIPT_DIR}/lib"
export DATA_DIR="${SCRIPT_DIR}/data"
export LOG_FILE="/tmp/gentoo-test-makeconf.log"
export DRY_RUN=1
export MOUNTPOINT="/tmp/gentoo-test-mount-$$"
: > "${LOG_FILE}"

source "${LIB_DIR}/constants.sh"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/utils.sh"
source "${LIB_DIR}/config.sh"
source "${DATA_DIR}/use_flags_desktop.sh"
source "${LIB_DIR}/portage.sh"

PASS=0
FAIL=0

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "${haystack}" == *"${needle}"* ]]; then
        echo "  PASS: ${desc}"
        (( PASS++ )) || true
    else
        echo "  FAIL: ${desc} — '${needle}' not found"
        (( FAIL++ )) || true
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "${haystack}" != *"${needle}"* ]]; then
        echo "  PASS: ${desc}"
        (( PASS++ )) || true
    else
        echo "  FAIL: ${desc} — '${needle}' should not be present"
        (( FAIL++ )) || true
    fi
}

echo "=== Test: make.conf generation (systemd + NVIDIA) ==="

CPU_MARCH="znver4"
CPU_FLAGS="aes avx avx2 avx512f"
INIT_SYSTEM="systemd"
GPU_VENDOR="nvidia"
VIDEO_CARDS="nvidia"
MIRROR_URL="https://distfiles.gentoo.org"
LOCALE="en_US.UTF-8"

output=$(_write_make_conf)

assert_contains "Has march" "-march=znver4" "${output}"
assert_contains "Has CPU_FLAGS" "aes avx avx2 avx512f" "${output}"
assert_contains "Has VIDEO_CARDS nvidia" 'VIDEO_CARDS="nvidia"' "${output}"
assert_contains "Has systemd USE" "systemd" "${output}"
assert_not_contains "Has no -systemd" "-systemd" "${output}"
assert_contains "Has GRUB_PLATFORMS" "efi-64" "${output}"
assert_contains "Has parallel-fetch" "parallel-fetch" "${output}"
assert_contains "Has mirror" "distfiles.gentoo.org" "${output}"

echo ""
echo "=== Test: make.conf generation (OpenRC + AMD) ==="

INIT_SYSTEM="openrc"
GPU_VENDOR="amd"
VIDEO_CARDS="amdgpu radeonsi"
CPU_MARCH="x86-64"
CPU_FLAGS=""

output=$(_write_make_conf)

assert_contains "Has march x86-64" "-march=x86-64" "${output}"
assert_contains "Has -systemd USE" "-systemd" "${output}"
assert_contains "Has elogind" "elogind" "${output}"
assert_contains "Has VIDEO_CARDS amdgpu" "amdgpu" "${output}"

echo ""
echo "=== Test: USE flags ==="

use_systemd=$(get_use_flags "systemd" "nvidia")
assert_contains "systemd USE has systemd" "systemd" "${use_systemd}"
assert_contains "systemd USE has nvenc" "nvenc" "${use_systemd}"
assert_contains "systemd USE has plasma" "plasma" "${use_systemd}"

use_openrc=$(get_use_flags "openrc" "amd")
assert_contains "openrc USE has elogind" "elogind" "${use_openrc}"
assert_contains "openrc USE has vaapi" "vaapi" "${use_openrc}"
assert_contains "openrc USE has -systemd" "-systemd" "${use_openrc}"

# Cleanup
rm -f "${LOG_FILE}"

echo ""
echo "=== Results ==="
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"

[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
