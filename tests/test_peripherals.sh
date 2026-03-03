#!/usr/bin/env bash
# tests/test_peripherals.sh — Test peripheral detection, config vars, install functions, inference
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Setup mock environment
export _GENTOO_INSTALLER=1
export LIB_DIR="${SCRIPT_DIR}/lib"
export DATA_DIR="${SCRIPT_DIR}/data"
export LOG_FILE="/tmp/gentoo-test-peripherals.log"
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
          ESP_REUSE SWAP_SIZE_MIB HYBRID_GPU BLUETOOTH_DETECTED \
          FINGERPRINT_DETECTED ENABLE_FINGERPRINT THUNDERBOLT_DETECTED \
          ENABLE_THUNDERBOLT SENSORS_DETECTED ENABLE_SENSORS WEBCAM_DETECTED \
          WWAN_DETECTED ENABLE_WWAN \
          2>/dev/null || true
}

# ============================
echo "=== Test: Peripheral CONFIG_VARS in constants ==="
found_bt=0; found_fp=0; found_efp=0; found_tb=0; found_etb=0
found_sens=0; found_esens=0; found_wc=0; found_wwan=0; found_ewwan=0
for var in "${CONFIG_VARS[@]}"; do
    case "${var}" in
        BLUETOOTH_DETECTED) found_bt=1 ;;
        FINGERPRINT_DETECTED) found_fp=1 ;;
        ENABLE_FINGERPRINT) found_efp=1 ;;
        THUNDERBOLT_DETECTED) found_tb=1 ;;
        ENABLE_THUNDERBOLT) found_etb=1 ;;
        SENSORS_DETECTED) found_sens=1 ;;
        ENABLE_SENSORS) found_esens=1 ;;
        WEBCAM_DETECTED) found_wc=1 ;;
        WWAN_DETECTED) found_wwan=1 ;;
        ENABLE_WWAN) found_ewwan=1 ;;
    esac
done
assert_eq "BLUETOOTH_DETECTED in CONFIG_VARS" "1" "${found_bt}"
assert_eq "FINGERPRINT_DETECTED in CONFIG_VARS" "1" "${found_fp}"
assert_eq "ENABLE_FINGERPRINT in CONFIG_VARS" "1" "${found_efp}"
assert_eq "THUNDERBOLT_DETECTED in CONFIG_VARS" "1" "${found_tb}"
assert_eq "ENABLE_THUNDERBOLT in CONFIG_VARS" "1" "${found_etb}"
assert_eq "SENSORS_DETECTED in CONFIG_VARS" "1" "${found_sens}"
assert_eq "ENABLE_SENSORS in CONFIG_VARS" "1" "${found_esens}"
assert_eq "WEBCAM_DETECTED in CONFIG_VARS" "1" "${found_wc}"
assert_eq "WWAN_DETECTED in CONFIG_VARS" "1" "${found_wwan}"
assert_eq "ENABLE_WWAN in CONFIG_VARS" "1" "${found_ewwan}"

# ============================
echo ""
echo "=== Test: Config save/load round-trip with peripheral vars ==="
clear_config
set_valid_config
export BLUETOOTH_DETECTED=1
export FINGERPRINT_DETECTED=1
export ENABLE_FINGERPRINT="yes"
export THUNDERBOLT_DETECTED=1
export ENABLE_THUNDERBOLT="yes"
export SENSORS_DETECTED=1
export ENABLE_SENSORS="yes"
export WEBCAM_DETECTED=1
export WWAN_DETECTED=1
export ENABLE_WWAN="yes"

tmpconf=$(mktemp /tmp/gentoo-test-periph-conf.XXXXXX)
config_save "${tmpconf}"

# Clear and reload
clear_config
config_load "${tmpconf}"

assert_eq "BLUETOOTH_DETECTED round-trip" "1" "${BLUETOOTH_DETECTED}"
assert_eq "FINGERPRINT_DETECTED round-trip" "1" "${FINGERPRINT_DETECTED}"
assert_eq "ENABLE_FINGERPRINT round-trip" "yes" "${ENABLE_FINGERPRINT}"
assert_eq "THUNDERBOLT_DETECTED round-trip" "1" "${THUNDERBOLT_DETECTED}"
assert_eq "ENABLE_THUNDERBOLT round-trip" "yes" "${ENABLE_THUNDERBOLT}"
assert_eq "SENSORS_DETECTED round-trip" "1" "${SENSORS_DETECTED}"
assert_eq "ENABLE_SENSORS round-trip" "yes" "${ENABLE_SENSORS}"
assert_eq "WEBCAM_DETECTED round-trip" "1" "${WEBCAM_DETECTED}"
assert_eq "WWAN_DETECTED round-trip" "1" "${WWAN_DETECTED}"
assert_eq "ENABLE_WWAN round-trip" "yes" "${ENABLE_WWAN}"

rm -f "${tmpconf}"

# ============================
echo ""
echo "=== Test: Validation passes with ENABLE_* peripheral vars set ==="
clear_config
set_valid_config
export ENABLE_FINGERPRINT="yes"
export ENABLE_THUNDERBOLT="yes"
export ENABLE_SENSORS="yes"

rc=0
output=$(validate_config) || rc=$?
assert_eq "Validation passes with peripherals" "0" "${rc}"

# ============================
echo ""
echo "=== Test: Inference — fprintd → ENABLE_FINGERPRINT ==="
INFER_DIR=$(mktemp -d /tmp/gentoo-test-periph-infer.XXXXXX)
_RESUME_TEST_DIR="${INFER_DIR}"

# Setup fake partition with fprintd installed
partname="sda2"
fakemnt="${INFER_DIR}/mnt/${partname}"
mkdir -p "${fakemnt}/etc/portage"
mkdir -p "${fakemnt}/etc/systemd"
mkdir -p "${fakemnt}/var/db/pkg/sys-auth/fprintd-1.94.2"

# Minimal make.conf
cat > "${fakemnt}/etc/portage/make.conf" << 'EOF'
COMMON_FLAGS="-march=skylake -O2 -pipe"
USE="systemd -consolekit"
VIDEO_CARDS="intel"
EOF

echo "gentoo" > "${fakemnt}/etc/hostname"
echo "Europe/Warsaw" > "${fakemnt}/etc/timezone"
echo "en_US.UTF-8 UTF-8" > "${fakemnt}/etc/locale.gen"

cat > "${fakemnt}/etc/fstab" << 'EOF'
/dev/sda2  /     ext4  defaults  0 1
/dev/sda1  /efi  vfat  defaults  0 2
EOF

_INFER_UUID_MAP="${INFER_DIR}/uuid_map"
echo "" > "${_INFER_UUID_MAP}"

clear_config
rc=0
infer_config_from_partition "/dev/sda2" "ext4" || rc=$?

assert_eq "Inference returns 0" "0" "${rc}"
assert_eq "ENABLE_FINGERPRINT inferred" "yes" "${ENABLE_FINGERPRINT:-no}"
assert_eq "FINGERPRINT_DETECTED inferred" "1" "${FINGERPRINT_DETECTED:-0}"

# ============================
echo ""
echo "=== Test: Inference — bolt → ENABLE_THUNDERBOLT ==="
# Add bolt package
mkdir -p "${fakemnt}/var/db/pkg/sys-apps/bolt-0.9.5"

clear_config
rc=0
infer_config_from_partition "/dev/sda2" "ext4" || rc=$?

assert_eq "ENABLE_THUNDERBOLT inferred" "yes" "${ENABLE_THUNDERBOLT:-no}"
assert_eq "THUNDERBOLT_DETECTED inferred" "1" "${THUNDERBOLT_DETECTED:-0}"

# ============================
echo ""
echo "=== Test: Inference — iio-sensor-proxy → ENABLE_SENSORS ==="
# Add iio-sensor-proxy package
mkdir -p "${fakemnt}/var/db/pkg/sys-apps/iio-sensor-proxy-3.5"

clear_config
rc=0
infer_config_from_partition "/dev/sda2" "ext4" || rc=$?

assert_eq "ENABLE_SENSORS inferred" "yes" "${ENABLE_SENSORS:-no}"
assert_eq "SENSORS_DETECTED inferred" "1" "${SENSORS_DETECTED:-0}"

# ============================
echo ""
echo "=== Test: Inference — modemmanager → ENABLE_WWAN ==="
# Add modemmanager package
mkdir -p "${fakemnt}/var/db/pkg/net-misc/modemmanager-1.22.0"

clear_config
rc=0
infer_config_from_partition "/dev/sda2" "ext4" || rc=$?

assert_eq "ENABLE_WWAN inferred" "yes" "${ENABLE_WWAN:-no}"
assert_eq "WWAN_DETECTED inferred" "1" "${WWAN_DETECTED:-0}"

# ============================
echo ""
echo "=== Test: Inference — empty system → no peripherals ==="
# Create a clean partition without peripheral packages
partname2="sdb2"
fakemnt2="${INFER_DIR}/mnt/${partname2}"
mkdir -p "${fakemnt2}/etc/portage"
mkdir -p "${fakemnt2}/etc/systemd"
mkdir -p "${fakemnt2}/var/db/pkg"

cat > "${fakemnt2}/etc/portage/make.conf" << 'EOF'
COMMON_FLAGS="-march=skylake -O2 -pipe"
USE="systemd -consolekit"
VIDEO_CARDS="intel"
EOF

echo "clean-box" > "${fakemnt2}/etc/hostname"
echo "Europe/Warsaw" > "${fakemnt2}/etc/timezone"
echo "en_US.UTF-8 UTF-8" > "${fakemnt2}/etc/locale.gen"

cat > "${fakemnt2}/etc/fstab" << 'EOF'
/dev/sdb2  /     ext4  defaults  0 1
/dev/sdb1  /efi  vfat  defaults  0 2
EOF

clear_config
rc=0
infer_config_from_partition "/dev/sdb2" "ext4" || rc=$?

assert_eq "Empty system: ENABLE_FINGERPRINT absent" "no" "${ENABLE_FINGERPRINT:-no}"
assert_eq "Empty system: ENABLE_THUNDERBOLT absent" "no" "${ENABLE_THUNDERBOLT:-no}"
assert_eq "Empty system: ENABLE_SENSORS absent" "no" "${ENABLE_SENSORS:-no}"
assert_eq "Empty system: ENABLE_WWAN absent" "no" "${ENABLE_WWAN:-no}"
assert_eq "Empty system: FINGERPRINT_DETECTED absent" "0" "${FINGERPRINT_DETECTED:-0}"
assert_eq "Empty system: THUNDERBOLT_DETECTED absent" "0" "${THUNDERBOLT_DETECTED:-0}"
assert_eq "Empty system: SENSORS_DETECTED absent" "0" "${SENSORS_DETECTED:-0}"
assert_eq "Empty system: WWAN_DETECTED absent" "0" "${WWAN_DETECTED:-0}"

# Cleanup
rm -rf "${INFER_DIR}"
unset _RESUME_TEST_DIR _INFER_UUID_MAP

# Cleanup
rm -f "${LOG_FILE}"

echo ""
echo "=== Results ==="
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"

[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
