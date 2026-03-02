#!/usr/bin/env bash
# tests/test_surface.sh — Test Surface detection, config vars, kernel types, inference
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Setup mock environment
export _GENTOO_INSTALLER=1
export LIB_DIR="${SCRIPT_DIR}/lib"
export DATA_DIR="${SCRIPT_DIR}/data"
export LOG_FILE="/tmp/gentoo-test-surface.log"
export DRY_RUN=1
export NON_INTERACTIVE=1
: > "${LOG_FILE}"

source "${LIB_DIR}/constants.sh"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/config.sh"
source "${LIB_DIR}/utils.sh"

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

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "${haystack}" == *"${needle}"* ]]; then
        echo "  PASS: ${desc}"
        (( PASS++ )) || true
    else
        echo "  FAIL: ${desc} — '${needle}' not found in output"
        (( FAIL++ )) || true
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "${haystack}" != *"${needle}"* ]]; then
        echo "  PASS: ${desc}"
        (( PASS++ )) || true
    else
        echo "  FAIL: ${desc} — '${needle}' should NOT be in output"
        (( FAIL++ )) || true
    fi
}

# Helper: set all required vars to valid defaults
set_valid_config() {
    export INIT_SYSTEM="systemd"
    export TARGET_DISK="/dev/sda"
    export PARTITION_SCHEME="auto"
    export FILESYSTEM="ext4"
    export SWAP_TYPE="zram"
    export HOSTNAME="gentoo"
    export TIMEZONE="Europe/Warsaw"
    export LOCALE="pl_PL.UTF-8"
    export KEYMAP="pl"
    export KERNEL_TYPE="dist-kernel"
    export GPU_VENDOR="intel"
    export USERNAME="user"
    export ROOT_PASSWORD_HASH='$6$rounds=500000$salt$hash'
    export USER_PASSWORD_HASH='$6$rounds=500000$salt$hash'
}

clear_config() {
    unset INIT_SYSTEM TARGET_DISK PARTITION_SCHEME FILESYSTEM SWAP_TYPE \
          HOSTNAME TIMEZONE LOCALE KEYMAP KERNEL_TYPE GPU_VENDOR USERNAME \
          ROOT_PASSWORD_HASH USER_PASSWORD_HASH ESP_PARTITION ROOT_PARTITION \
          ESP_REUSE SWAP_SIZE_MIB HYBRID_GPU SURFACE_DETECTED SURFACE_MODEL \
          ENABLE_IPTSD ENABLE_SURFACE_CONTROL ENABLE_SECUREBOOT 2>/dev/null || true
}

# ============================
echo "=== Test: Surface CONFIG_VARS in constants ==="
found_surface=0
found_model=0
found_iptsd=0
found_sc=0
found_sb=0
for var in "${CONFIG_VARS[@]}"; do
    case "${var}" in
        SURFACE_DETECTED) found_surface=1 ;;
        SURFACE_MODEL) found_model=1 ;;
        ENABLE_IPTSD) found_iptsd=1 ;;
        ENABLE_SURFACE_CONTROL) found_sc=1 ;;
        ENABLE_SECUREBOOT) found_sb=1 ;;
    esac
done
assert_eq "SURFACE_DETECTED in CONFIG_VARS" "1" "${found_surface}"
assert_eq "SURFACE_MODEL in CONFIG_VARS" "1" "${found_model}"
assert_eq "ENABLE_IPTSD in CONFIG_VARS" "1" "${found_iptsd}"
assert_eq "ENABLE_SURFACE_CONTROL in CONFIG_VARS" "1" "${found_sc}"
assert_eq "ENABLE_SECUREBOOT in CONFIG_VARS" "1" "${found_sb}"

# ============================
echo ""
echo "=== Test: secureboot checkpoint in CHECKPOINTS ==="
found_sb_cp=0
sb_after_bootloader=0
prev=""
for cp in "${CHECKPOINTS[@]}"; do
    [[ "${cp}" == "secureboot" ]] && found_sb_cp=1
    [[ "${prev}" == "bootloader" && "${cp}" == "secureboot" ]] && sb_after_bootloader=1
    prev="${cp}"
done
assert_eq "secureboot in CHECKPOINTS" "1" "${found_sb_cp}"
assert_eq "secureboot after bootloader" "1" "${sb_after_bootloader}"

# ============================
echo ""
echo "=== Test: KERNEL_TYPE validation — surface-kernel ==="
clear_config
set_valid_config
export KERNEL_TYPE="surface-kernel"

rc=0
output=$(validate_config) || rc=$?
assert_eq "surface-kernel is valid" "0" "${rc}"

# ============================
echo ""
echo "=== Test: KERNEL_TYPE validation — surface-genkernel ==="
clear_config
set_valid_config
export KERNEL_TYPE="surface-genkernel"

rc=0
output=$(validate_config) || rc=$?
assert_eq "surface-genkernel is valid" "0" "${rc}"

# ============================
echo ""
echo "=== Test: KERNEL_TYPE validation — invalid value still fails ==="
clear_config
set_valid_config
export KERNEL_TYPE="custom-kernel"

rc=0
output=$(validate_config) || rc=$?
assert_eq "custom-kernel is invalid" "1" "${rc}"
assert_contains "Output mentions KERNEL_TYPE" "KERNEL_TYPE" "${output}"

# ============================
echo ""
echo "=== Test: Config save/load round-trip with Surface vars ==="
clear_config
set_valid_config
export SURFACE_DETECTED=1
export SURFACE_MODEL="Surface Pro 4"
export ENABLE_IPTSD="yes"
export ENABLE_SURFACE_CONTROL="yes"
export ENABLE_SECUREBOOT="yes"

tmpconf=$(mktemp /tmp/gentoo-test-surface-conf.XXXXXX)
config_save "${tmpconf}"

# Clear and reload
clear_config
config_load "${tmpconf}"

assert_eq "SURFACE_DETECTED round-trip" "1" "${SURFACE_DETECTED}"
assert_eq "SURFACE_MODEL round-trip" "Surface Pro 4" "${SURFACE_MODEL}"
assert_eq "ENABLE_IPTSD round-trip" "yes" "${ENABLE_IPTSD}"
assert_eq "ENABLE_SURFACE_CONTROL round-trip" "yes" "${ENABLE_SURFACE_CONTROL}"
assert_eq "ENABLE_SECUREBOOT round-trip" "yes" "${ENABLE_SECUREBOOT}"

rm -f "${tmpconf}"

# ============================
echo ""
echo "=== Test: Inference — surface-kernel from overlay ==="
INFER_DIR=$(mktemp -d /tmp/gentoo-test-surface-infer.XXXXXX)
_RESUME_TEST_DIR="${INFER_DIR}"

# Setup fake partition
partname="sda2"
fakemnt="${INFER_DIR}/mnt/${partname}"
mkdir -p "${fakemnt}/etc/portage/repos.conf"
mkdir -p "${fakemnt}/etc/portage/package.accept_keywords"
mkdir -p "${fakemnt}/etc/portage"
mkdir -p "${fakemnt}/etc/systemd"

# linux-surface overlay present
echo "[linux-surface]" > "${fakemnt}/etc/portage/repos.conf/linux-surface.conf"
# surface-sources keyword
echo "sys-kernel/surface-sources ~amd64" > "${fakemnt}/etc/portage/package.accept_keywords/surface-kernel"
# iptsd keyword
echo "dev-libs/iptsd ~amd64" > "${fakemnt}/etc/portage/package.accept_keywords/surface-tools"

# Minimal make.conf for inference
cat > "${fakemnt}/etc/portage/make.conf" << 'EOF'
COMMON_FLAGS="-march=skylake -O2 -pipe"
USE="systemd -consolekit"
VIDEO_CARDS="intel"
EOF

# hostname, timezone, locale for sufficient config
echo "surface-box" > "${fakemnt}/etc/hostname"
echo "Europe/Warsaw" > "${fakemnt}/etc/timezone"
echo "pl_PL.UTF-8 UTF-8" > "${fakemnt}/etc/locale.gen"

# fstab
mkdir -p "${fakemnt}/etc"
cat > "${fakemnt}/etc/fstab" << 'EOF'
/dev/sda2  /     ext4  defaults  0 1
/dev/sda1  /efi  vfat  defaults  0 2
EOF

# UUID map
_INFER_UUID_MAP="${INFER_DIR}/uuid_map"
echo "" > "${_INFER_UUID_MAP}"

# Run inference
clear_config
rc=0
infer_config_from_partition "/dev/sda2" "ext4" || rc=$?

assert_eq "Inference returns 0 (sufficient)" "0" "${rc}"
assert_eq "KERNEL_TYPE inferred as surface-kernel" "surface-kernel" "${KERNEL_TYPE:-}"
assert_eq "SURFACE_DETECTED inferred" "1" "${SURFACE_DETECTED:-0}"
assert_eq "ENABLE_IPTSD inferred" "yes" "${ENABLE_IPTSD:-no}"
assert_eq "INIT_SYSTEM inferred as systemd" "systemd" "${INIT_SYSTEM:-}"
assert_eq "HOSTNAME inferred" "surface-box" "${HOSTNAME:-}"

# ============================
echo ""
echo "=== Test: Inference — surface-genkernel marker ==="
# Replace surface-sources with the marker
echo "# surface-genkernel" > "${fakemnt}/etc/portage/package.accept_keywords/surface-kernel"
rm -f "${fakemnt}/etc/portage/repos.conf/linux-surface.conf"

clear_config
rc=0
infer_config_from_partition "/dev/sda2" "ext4" || rc=$?

assert_eq "surface-genkernel marker inferred" "surface-genkernel" "${KERNEL_TYPE:-}"

# Cleanup
rm -rf "${INFER_DIR}"
unset _RESUME_TEST_DIR _INFER_UUID_MAP

# ============================
echo ""
echo "=== Test: Standard kernel types still validate ==="
clear_config
set_valid_config
export KERNEL_TYPE="dist-kernel"
rc=0
output=$(validate_config) || rc=$?
assert_eq "dist-kernel still valid" "0" "${rc}"

clear_config
set_valid_config
export KERNEL_TYPE="genkernel"
rc=0
output=$(validate_config) || rc=$?
assert_eq "genkernel still valid" "0" "${rc}"

# Cleanup
rm -f "${LOG_FILE}"

echo ""
echo "=== Results ==="
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"

[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
