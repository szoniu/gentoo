#!/usr/bin/env bash
# tests/test_hybrid_gpu.sh — Test hybrid GPU detection, recommendation, and CONFIG_VARS
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export _GENTOO_INSTALLER=1
export LIB_DIR="${SCRIPT_DIR}/lib"
export DATA_DIR="${SCRIPT_DIR}/data"
export LOG_FILE="/tmp/gentoo-test-hybrid-gpu.log"
: > "${LOG_FILE}"

source "${LIB_DIR}/constants.sh"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/utils.sh"
source "${DATA_DIR}/gpu_database.sh"

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
        echo "  FAIL: ${desc} — '${haystack}' does not contain '${needle}'"
        (( FAIL++ )) || true
    fi
}

# ================================================================
echo "=== Test: get_hybrid_gpu_recommendation ==="

result=$(get_hybrid_gpu_recommendation "intel" "nvidia")
assert_eq "Intel + NVIDIA" "intel nvidia" "${result}"

result=$(get_hybrid_gpu_recommendation "amd" "nvidia")
assert_eq "AMD + NVIDIA" "amdgpu radeonsi nvidia" "${result}"

result=$(get_hybrid_gpu_recommendation "intel" "amd")
assert_eq "Intel + AMD" "intel amdgpu radeonsi" "${result}"

result=$(get_hybrid_gpu_recommendation "amd" "amd")
assert_eq "AMD + AMD" "amdgpu radeonsi" "${result}"

result=$(get_hybrid_gpu_recommendation "unknown" "unknown")
assert_eq "Unknown + Unknown fallback" "fbdev" "${result}"

# ================================================================
echo ""
echo "=== Test: Hybrid CONFIG_VARS present in CONFIG_VARS[] ==="

found_hybrid=0
found_igpu_vendor=0
found_igpu_name=0
found_dgpu_vendor=0
found_dgpu_name=0
found_rog=0
found_asusctl=0

for var in "${CONFIG_VARS[@]}"; do
    case "${var}" in
        HYBRID_GPU)         found_hybrid=1 ;;
        IGPU_VENDOR)        found_igpu_vendor=1 ;;
        IGPU_DEVICE_NAME)   found_igpu_name=1 ;;
        DGPU_VENDOR)        found_dgpu_vendor=1 ;;
        DGPU_DEVICE_NAME)   found_dgpu_name=1 ;;
        ASUS_ROG_DETECTED)  found_rog=1 ;;
        ENABLE_ASUSCTL)     found_asusctl=1 ;;
    esac
done

assert_eq "HYBRID_GPU in CONFIG_VARS" "1" "${found_hybrid}"
assert_eq "IGPU_VENDOR in CONFIG_VARS" "1" "${found_igpu_vendor}"
assert_eq "IGPU_DEVICE_NAME in CONFIG_VARS" "1" "${found_igpu_name}"
assert_eq "DGPU_VENDOR in CONFIG_VARS" "1" "${found_dgpu_vendor}"
assert_eq "DGPU_DEVICE_NAME in CONFIG_VARS" "1" "${found_dgpu_name}"
assert_eq "ASUS_ROG_DETECTED in CONFIG_VARS" "1" "${found_rog}"
assert_eq "ENABLE_ASUSCTL in CONFIG_VARS" "1" "${found_asusctl}"

# ================================================================
echo ""
echo "=== Test: NVIDIA recommendation unchanged for Ada ==="

rec=$(get_gpu_recommendation "10de" "2704")
assert_eq "NVIDIA Ada recommendation" "nvidia-drivers|nvidia|yes" "${rec}"

# ================================================================
echo ""
echo "=== Test: Hybrid inference from VIDEO_CARDS (make.conf parser) ==="

# Simulate _infer_from_make_conf with hybrid VIDEO_CARDS
export DRY_RUN=1 NON_INTERACTIVE=1
TEST_TMPDIR="$(mktemp -d)"
export CHECKPOINT_DIR="${TEST_TMPDIR}/checkpoints"
export CHECKPOINT_DIR_SUFFIX="/tmp/gentoo-installer-checkpoints"
export CONFIG_FILE="${TEST_TMPDIR}/gentoo-installer.conf"
export MOUNTPOINT="${TEST_TMPDIR}/mnt"

source "${LIB_DIR}/config.sh"

# Helper: clear all config vars
clear_config_vars() {
    local var
    for var in "${CONFIG_VARS[@]}"; do
        unset "${var}" 2>/dev/null || true
    done
}

# Test Intel + NVIDIA hybrid inference
clear_config_vars
export _RESUME_TEST_DIR="$(mktemp -d)"
export _INFER_UUID_MAP="${_RESUME_TEST_DIR}/uuid_map"

local_root="${_RESUME_TEST_DIR}/mnt/sda2"
mkdir -p "${local_root}/etc/portage"

cat > "${_RESUME_TEST_DIR}/uuid_map" <<'MAP'
aaaa-1111 /dev/sda1
bbbb-2222 /dev/sda2
MAP

cat > "${local_root}/etc/fstab" <<'FSTAB'
UUID=bbbb-2222  /          ext4  defaults  0 1
UUID=aaaa-1111  /boot/efi  vfat  defaults  0 2
FSTAB

cat > "${local_root}/etc/portage/make.conf" <<'MAKECONF'
COMMON_FLAGS="-march=alderlake -O2 -pipe"
USE="X wayland systemd"
VIDEO_CARDS="intel nvidia"
MAKECONF

rc=0
infer_config_from_partition "/dev/sda2" "ext4" || rc=$?

assert_eq "Hybrid inference return code" "0" "${rc}"
assert_eq "HYBRID_GPU inferred" "yes" "${HYBRID_GPU:-}"
assert_eq "IGPU_VENDOR inferred" "intel" "${IGPU_VENDOR:-}"
assert_eq "DGPU_VENDOR inferred" "nvidia" "${DGPU_VENDOR:-}"
assert_eq "GPU_VENDOR inferred (dGPU)" "nvidia" "${GPU_VENDOR:-}"

rm -rf "${_RESUME_TEST_DIR}"

# Test AMD + NVIDIA hybrid inference
clear_config_vars
export _RESUME_TEST_DIR="$(mktemp -d)"
export _INFER_UUID_MAP="${_RESUME_TEST_DIR}/uuid_map"

local_root="${_RESUME_TEST_DIR}/mnt/sda2"
mkdir -p "${local_root}/etc/portage"

cat > "${_RESUME_TEST_DIR}/uuid_map" <<'MAP'
aaaa-1111 /dev/sda1
bbbb-2222 /dev/sda2
MAP

cat > "${local_root}/etc/fstab" <<'FSTAB'
UUID=bbbb-2222  /          ext4  defaults  0 1
UUID=aaaa-1111  /boot/efi  vfat  defaults  0 2
FSTAB

cat > "${local_root}/etc/portage/make.conf" <<'MAKECONF'
USE="X wayland systemd"
VIDEO_CARDS="amdgpu radeonsi nvidia"
MAKECONF

rc=0
infer_config_from_partition "/dev/sda2" "ext4" || rc=$?

assert_eq "AMD+NVIDIA hybrid return code" "0" "${rc}"
assert_eq "HYBRID_GPU amd+nvidia" "yes" "${HYBRID_GPU:-}"
assert_eq "IGPU_VENDOR amd+nvidia" "amd" "${IGPU_VENDOR:-}"
assert_eq "DGPU_VENDOR amd+nvidia" "nvidia" "${DGPU_VENDOR:-}"

rm -rf "${_RESUME_TEST_DIR}"

# Test single vendor — NOT hybrid
clear_config_vars
export _RESUME_TEST_DIR="$(mktemp -d)"
export _INFER_UUID_MAP="${_RESUME_TEST_DIR}/uuid_map"

local_root="${_RESUME_TEST_DIR}/mnt/sda2"
mkdir -p "${local_root}/etc/portage"

cat > "${_RESUME_TEST_DIR}/uuid_map" <<'MAP'
aaaa-1111 /dev/sda1
bbbb-2222 /dev/sda2
MAP

cat > "${local_root}/etc/fstab" <<'FSTAB'
UUID=bbbb-2222  /          ext4  defaults  0 1
UUID=aaaa-1111  /boot/efi  vfat  defaults  0 2
FSTAB

cat > "${local_root}/etc/portage/make.conf" <<'MAKECONF'
USE="X wayland systemd"
VIDEO_CARDS="nvidia"
MAKECONF

rc=0
infer_config_from_partition "/dev/sda2" "ext4" || rc=$?

assert_eq "Single nvidia return code" "0" "${rc}"
assert_eq "HYBRID_GPU single nvidia" "no" "${HYBRID_GPU:-}"
assert_eq "GPU_VENDOR single nvidia" "nvidia" "${GPU_VENDOR:-}"

rm -rf "${_RESUME_TEST_DIR}"

# ================================================================
echo ""
echo "=== Test: ROG overlay inference ==="

clear_config_vars
export _RESUME_TEST_DIR="$(mktemp -d)"
export _INFER_UUID_MAP="${_RESUME_TEST_DIR}/uuid_map"

local_root="${_RESUME_TEST_DIR}/mnt/sda2"
mkdir -p "${local_root}/etc/portage/repos.conf"

cat > "${_RESUME_TEST_DIR}/uuid_map" <<'MAP'
aaaa-1111 /dev/sda1
bbbb-2222 /dev/sda2
MAP

cat > "${local_root}/etc/fstab" <<'FSTAB'
UUID=bbbb-2222  /          ext4  defaults  0 1
UUID=aaaa-1111  /boot/efi  vfat  defaults  0 2
FSTAB

cat > "${local_root}/etc/portage/make.conf" <<'MAKECONF'
USE="X wayland systemd"
MAKECONF

cat > "${local_root}/etc/portage/repos.conf/zgentoo.conf" <<'ZGENTOO'
[zgentoo]
location = /var/db/repos/zgentoo
sync-type = git
sync-uri = https://github.com/gentoo-mirror/zgentoo.git
ZGENTOO

rc=0
infer_config_from_partition "/dev/sda2" "ext4" || rc=$?

assert_eq "ROG overlay return code" "0" "${rc}"
assert_eq "ENABLE_ASUSCTL inferred from zgentoo" "yes" "${ENABLE_ASUSCTL:-}"

rm -rf "${_RESUME_TEST_DIR}"

# Cleanup
unset _RESUME_TEST_DIR _INFER_UUID_MAP
rm -rf "${TEST_TMPDIR}"
rm -f "${LOG_FILE}"

echo ""
echo "=== Results ==="
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"

[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
