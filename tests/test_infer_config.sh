#!/usr/bin/env bash
# tests/test_infer_config.sh — Test config inference from installed system
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export _GENTOO_INSTALLER=1
export LIB_DIR="${SCRIPT_DIR}/lib"
export DATA_DIR="${SCRIPT_DIR}/data"
export LOG_FILE="/tmp/gentoo-test-infer.log"
export DRY_RUN=1
export NON_INTERACTIVE=1

TEST_TMPDIR="$(mktemp -d)"
export CHECKPOINT_DIR="${TEST_TMPDIR}/checkpoints"
export CHECKPOINT_DIR_SUFFIX="/tmp/gentoo-installer-checkpoints"
export CONFIG_FILE="${TEST_TMPDIR}/gentoo-installer.conf"
export MOUNTPOINT="${TEST_TMPDIR}/mnt"
: > "${LOG_FILE}"

source "${LIB_DIR}/constants.sh"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/utils.sh"
source "${LIB_DIR}/config.sh"

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

# Helper: clear all config vars
clear_config_vars() {
    local var
    for var in "${CONFIG_VARS[@]}"; do
        unset "${var}" 2>/dev/null || true
    done
}

# ================================================================
echo "=== Test 1: Full ext4+systemd installation ==="

clear_config_vars
export _RESUME_TEST_DIR="$(mktemp -d)"
export _INFER_UUID_MAP="${_RESUME_TEST_DIR}/uuid_map"

local_root="${_RESUME_TEST_DIR}/mnt/sda2"
mkdir -p "${local_root}/etc/portage/package.accept_keywords"
mkdir -p "${local_root}/etc/portage/repos.conf"

cat > "${_RESUME_TEST_DIR}/uuid_map" <<'MAP'
aaaa-1111 /dev/sda1
bbbb-2222-cccc-3333 /dev/sda2
dddd-4444-eeee-5555 /dev/sda3
MAP

cat > "${local_root}/etc/fstab" <<'FSTAB'
# /etc/fstab
UUID=bbbb-2222-cccc-3333  /          ext4  defaults  0 1
UUID=aaaa-1111            /boot/efi  vfat  defaults  0 2
UUID=dddd-4444-eeee-5555  none       swap  sw        0 0
FSTAB

cat > "${local_root}/etc/portage/make.conf" <<'MAKECONF'
COMMON_FLAGS="-march=znver3 -O2 -pipe"
CFLAGS="${COMMON_FLAGS}"
CXXFLAGS="${COMMON_FLAGS}"
CPU_FLAGS_X86="aes avx avx2 fma3 mmx mmxext pclmul popcnt rdrand sha sse sse2 sse3 sse4_1 sse4_2 sse4a ssse3"
VIDEO_CARDS="nvidia"
USE="X wayland elogind systemd pulseaudio"
GENTOO_MIRRORS="https://mirror.example.com/gentoo https://mirror2.example.com/gentoo"
MAKECONF

echo "gentoo-test" > "${local_root}/etc/hostname"
echo "Europe/Warsaw" > "${local_root}/etc/timezone"

cat > "${local_root}/etc/locale.gen" <<'LOCALE'
# Supported locales
pl_PL.UTF-8 UTF-8
en_US.UTF-8 UTF-8
LOCALE

echo 'KEYMAP=pl' > "${local_root}/etc/vconsole.conf"
echo 'sys-kernel/gentoo-kernel-bin ~amd64' > "${local_root}/etc/portage/package.accept_keywords/kernel"

rc=0
infer_config_from_partition "/dev/sda2" "ext4" || rc=$?

assert_eq "Return code 0 (sufficient)" "0" "${rc}"
assert_eq "ROOT_PARTITION" "/dev/sda2" "${ROOT_PARTITION:-}"
assert_eq "TARGET_DISK" "/dev/sda" "${TARGET_DISK:-}"
assert_eq "FILESYSTEM" "ext4" "${FILESYSTEM:-}"
assert_eq "ESP_PARTITION" "/dev/sda1" "${ESP_PARTITION:-}"
assert_eq "SWAP_PARTITION" "/dev/sda3" "${SWAP_PARTITION:-}"
assert_eq "SWAP_TYPE" "partition" "${SWAP_TYPE:-}"
assert_eq "INIT_SYSTEM" "systemd" "${INIT_SYSTEM:-}"
assert_eq "GPU_VENDOR" "nvidia" "${GPU_VENDOR:-}"
assert_eq "CPU_MARCH" "znver3" "${CPU_MARCH:-}"
assert_eq "HOSTNAME" "gentoo-test" "${HOSTNAME:-}"
assert_eq "TIMEZONE" "Europe/Warsaw" "${TIMEZONE:-}"
assert_eq "LOCALE" "pl_PL.UTF-8" "${LOCALE:-}"
assert_eq "KEYMAP" "pl" "${KEYMAP:-}"
assert_eq "KERNEL_TYPE" "dist-kernel" "${KERNEL_TYPE:-}"
assert_eq "MIRROR_URL first mirror" "https://mirror.example.com/gentoo" "${MIRROR_URL:-}"
assert_eq "PARTITION_SCHEME" "auto" "${PARTITION_SCHEME:-}"

rm -rf "${_RESUME_TEST_DIR}"

# ================================================================
echo ""
echo "=== Test 2: Btrfs with subvolumes ==="

clear_config_vars
export _RESUME_TEST_DIR="$(mktemp -d)"
export _INFER_UUID_MAP="${_RESUME_TEST_DIR}/uuid_map"

local_root="${_RESUME_TEST_DIR}/mnt/sda2"
mkdir -p "${local_root}/etc/portage"
mkdir -p "${local_root}/etc/systemd"

cat > "${_RESUME_TEST_DIR}/uuid_map" <<'MAP'
aaaa-1111 /dev/sda1
bbbb-2222 /dev/sda2
MAP

cat > "${local_root}/etc/fstab" <<'FSTAB'
UUID=bbbb-2222  /          btrfs  defaults,subvol=@        0 0
UUID=aaaa-1111  /boot/efi  vfat   defaults                 0 2
UUID=bbbb-2222  /home      btrfs  defaults,subvol=@home    0 0
FSTAB

cat > "${local_root}/etc/portage/make.conf" <<'MAKECONF'
COMMON_FLAGS="-march=native -O2 -pipe"
USE="X wayland elogind systemd"
VIDEO_CARDS="amdgpu radeonsi"
MAKECONF

rc=0
infer_config_from_partition "/dev/sda2" "btrfs" || rc=$?

assert_eq "Return code 0 (sufficient)" "0" "${rc}"
assert_eq "FILESYSTEM btrfs" "btrfs" "${FILESYSTEM:-}"
assert_eq "BTRFS_SUBVOLUMES" "yes" "${BTRFS_SUBVOLUMES:-}"
assert_eq "GPU_VENDOR amd" "amd" "${GPU_VENDOR:-}"

rm -rf "${_RESUME_TEST_DIR}"

# ================================================================
echo ""
echo "=== Test 3: OpenRC system ==="

clear_config_vars
export _RESUME_TEST_DIR="$(mktemp -d)"
export _INFER_UUID_MAP="${_RESUME_TEST_DIR}/uuid_map"

local_root="${_RESUME_TEST_DIR}/mnt/sda2"
mkdir -p "${local_root}/etc/portage/package.accept_keywords"
mkdir -p "${local_root}/etc/conf.d"

cat > "${_RESUME_TEST_DIR}/uuid_map" <<'MAP'
aaaa-1111 /dev/sda1
bbbb-2222 /dev/sda2
MAP

cat > "${local_root}/etc/fstab" <<'FSTAB'
UUID=bbbb-2222  /          ext4  defaults  0 1
UUID=aaaa-1111  /boot/efi  vfat  defaults  0 2
FSTAB

cat > "${local_root}/etc/portage/make.conf" <<'MAKECONF'
COMMON_FLAGS="-march=skylake -O2 -pipe"
USE="X wayland elogind -systemd"
VIDEO_CARDS="intel"
MAKECONF

echo 'hostname="gentoo-openrc"' > "${local_root}/etc/conf.d/hostname"
echo 'keymap="us"' > "${local_root}/etc/conf.d/keymaps"

echo 'sys-kernel/gentoo-sources ~amd64' > "${local_root}/etc/portage/package.accept_keywords/kernel"

rc=0
infer_config_from_partition "/dev/sda2" "ext4" || rc=$?

assert_eq "Return code 0 (sufficient)" "0" "${rc}"
assert_eq "INIT_SYSTEM openrc" "openrc" "${INIT_SYSTEM:-}"
assert_eq "HOSTNAME openrc" "gentoo-openrc" "${HOSTNAME:-}"
assert_eq "KEYMAP openrc" "us" "${KEYMAP:-}"
assert_eq "GPU_VENDOR intel" "intel" "${GPU_VENDOR:-}"
assert_eq "KERNEL_TYPE genkernel" "genkernel" "${KERNEL_TYPE:-}"

rm -rf "${_RESUME_TEST_DIR}"

# ================================================================
echo ""
echo "=== Test 4: Dual-boot (ESP on different disk) ==="

clear_config_vars
export _RESUME_TEST_DIR="$(mktemp -d)"
export _INFER_UUID_MAP="${_RESUME_TEST_DIR}/uuid_map"

local_root="${_RESUME_TEST_DIR}/mnt/sdb2"
mkdir -p "${local_root}/etc/portage"
mkdir -p "${local_root}/etc/systemd"

cat > "${_RESUME_TEST_DIR}/uuid_map" <<'MAP'
aaaa-1111 /dev/sda1
bbbb-2222 /dev/sdb2
MAP

cat > "${local_root}/etc/fstab" <<'FSTAB'
UUID=bbbb-2222  /          ext4  defaults  0 1
UUID=aaaa-1111  /boot/efi  vfat  defaults  0 2
FSTAB

cat > "${local_root}/etc/portage/make.conf" <<'MAKECONF'
USE="X wayland systemd"
MAKECONF

rc=0
infer_config_from_partition "/dev/sdb2" "ext4" || rc=$?

assert_eq "Return code 0 (sufficient)" "0" "${rc}"
assert_eq "TARGET_DISK sdb" "/dev/sdb" "${TARGET_DISK:-}"
assert_eq "ESP_PARTITION different disk" "/dev/sda1" "${ESP_PARTITION:-}"
assert_eq "PARTITION_SCHEME dual-boot" "dual-boot" "${PARTITION_SCHEME:-}"
assert_eq "ESP_REUSE" "yes" "${ESP_REUSE:-}"

rm -rf "${_RESUME_TEST_DIR}"

# ================================================================
echo ""
echo "=== Test 5: Missing fstab → insufficient (no ESP) ==="

clear_config_vars
export _RESUME_TEST_DIR="$(mktemp -d)"
unset _INFER_UUID_MAP

local_root="${_RESUME_TEST_DIR}/mnt/sda2"
mkdir -p "${local_root}/etc/portage"

cat > "${local_root}/etc/portage/make.conf" <<'MAKECONF'
USE="X wayland systemd"
MAKECONF

rc=0
infer_config_from_partition "/dev/sda2" "ext4" || rc=$?

assert_eq "Return code 1 (insufficient — no fstab)" "1" "${rc}"
assert_eq "ROOT_PARTITION still set from args" "/dev/sda2" "${ROOT_PARTITION:-}"
assert_eq "ESP_PARTITION empty" "" "${ESP_PARTITION:-}"

rm -rf "${_RESUME_TEST_DIR}"

# ================================================================
echo ""
echo "=== Test 6: NVMe partition → correct TARGET_DISK ==="

clear_config_vars
export _RESUME_TEST_DIR="$(mktemp -d)"
export _INFER_UUID_MAP="${_RESUME_TEST_DIR}/uuid_map"

local_root="${_RESUME_TEST_DIR}/mnt/nvme0n1p2"
mkdir -p "${local_root}/etc/portage"
mkdir -p "${local_root}/etc/systemd"

cat > "${_RESUME_TEST_DIR}/uuid_map" <<'MAP'
aaaa-1111 /dev/nvme0n1p1
bbbb-2222 /dev/nvme0n1p2
MAP

cat > "${local_root}/etc/fstab" <<'FSTAB'
UUID=bbbb-2222  /          ext4  defaults  0 1
UUID=aaaa-1111  /boot/efi  vfat  defaults  0 2
FSTAB

cat > "${local_root}/etc/portage/make.conf" <<'MAKECONF'
USE="X systemd"
MAKECONF

rc=0
infer_config_from_partition "/dev/nvme0n1p2" "ext4" || rc=$?

assert_eq "Return code 0" "0" "${rc}"
assert_eq "TARGET_DISK nvme" "/dev/nvme0n1" "${TARGET_DISK:-}"
assert_eq "ROOT_PARTITION nvme" "/dev/nvme0n1p2" "${ROOT_PARTITION:-}"

rm -rf "${_RESUME_TEST_DIR}"

# ================================================================
echo ""
echo "=== Test 7: GURU + Noctalia detection ==="

clear_config_vars
export _RESUME_TEST_DIR="$(mktemp -d)"
export _INFER_UUID_MAP="${_RESUME_TEST_DIR}/uuid_map"

local_root="${_RESUME_TEST_DIR}/mnt/sda2"
mkdir -p "${local_root}/etc/portage/package.accept_keywords"
mkdir -p "${local_root}/etc/portage/repos.conf"
mkdir -p "${local_root}/etc/systemd"

cat > "${_RESUME_TEST_DIR}/uuid_map" <<'MAP'
aaaa-1111 /dev/sda1
bbbb-2222 /dev/sda2
MAP

cat > "${local_root}/etc/fstab" <<'FSTAB'
UUID=bbbb-2222  /          ext4  defaults  0 1
UUID=aaaa-1111  /boot/efi  vfat  defaults  0 2
FSTAB

cat > "${local_root}/etc/portage/make.conf" <<'MAKECONF'
USE="X systemd"
MAKECONF

# Create GURU repo config
cat > "${local_root}/etc/portage/repos.conf/guru.conf" <<'GURU'
[guru]
location = /var/db/repos/guru
sync-type = git
sync-uri = https://github.com/gentoo-mirror/guru.git
GURU

echo 'gui-apps/noctalia-shell ~amd64' > "${local_root}/etc/portage/package.accept_keywords/noctalia"

rc=0
infer_config_from_partition "/dev/sda2" "ext4" || rc=$?

assert_eq "Return code 0" "0" "${rc}"
assert_eq "ENABLE_GURU" "yes" "${ENABLE_GURU:-}"
assert_eq "ENABLE_NOCTALIA" "yes" "${ENABLE_NOCTALIA:-}"

rm -rf "${_RESUME_TEST_DIR}"

# ================================================================
echo ""
echo "=== Test 8: Init system fallback (no make.conf USE) ==="

clear_config_vars
export _RESUME_TEST_DIR="$(mktemp -d)"
export _INFER_UUID_MAP="${_RESUME_TEST_DIR}/uuid_map"

local_root="${_RESUME_TEST_DIR}/mnt/sda2"
mkdir -p "${local_root}/etc/portage"
mkdir -p "${local_root}/etc/conf.d"

cat > "${_RESUME_TEST_DIR}/uuid_map" <<'MAP'
aaaa-1111 /dev/sda1
bbbb-2222 /dev/sda2
MAP

cat > "${local_root}/etc/fstab" <<'FSTAB'
UUID=bbbb-2222  /          ext4  defaults  0 1
UUID=aaaa-1111  /boot/efi  vfat  defaults  0 2
FSTAB

# make.conf without USE line
cat > "${local_root}/etc/portage/make.conf" <<'MAKECONF'
COMMON_FLAGS="-O2 -pipe"
VIDEO_CARDS="nvidia"
MAKECONF

# OpenRC indicators (no /etc/systemd, has conf.d/hostname)
echo 'hostname="fallback-test"' > "${local_root}/etc/conf.d/hostname"

rc=0
infer_config_from_partition "/dev/sda2" "ext4" || rc=$?

assert_eq "Return code 0" "0" "${rc}"
assert_eq "INIT_SYSTEM fallback openrc" "openrc" "${INIT_SYSTEM:-}"
assert_eq "SWAP_TYPE none (no swap detected)" "none" "${SWAP_TYPE:-}"

rm -rf "${_RESUME_TEST_DIR}"

# ================================================================
echo ""
echo "=== Test 9: _partition_to_disk helper ==="

assert_eq "sda2 → sda" "/dev/sda" "$(_partition_to_disk /dev/sda2)"
assert_eq "nvme0n1p3 → nvme0n1" "/dev/nvme0n1" "$(_partition_to_disk /dev/nvme0n1p3)"
assert_eq "mmcblk0p1 → mmcblk0" "/dev/mmcblk0" "$(_partition_to_disk /dev/mmcblk0p1)"
assert_eq "vda1 → vda" "/dev/vda" "$(_partition_to_disk /dev/vda1)"

# ================================================================
echo ""
echo "=== Test 10: Hybrid GPU inference from VIDEO_CARDS ==="

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

assert_eq "Hybrid return code 0" "0" "${rc}"
assert_eq "HYBRID_GPU from VIDEO_CARDS" "yes" "${HYBRID_GPU:-}"
assert_eq "IGPU_VENDOR from VIDEO_CARDS" "intel" "${IGPU_VENDOR:-}"
assert_eq "DGPU_VENDOR from VIDEO_CARDS" "nvidia" "${DGPU_VENDOR:-}"
assert_eq "GPU_VENDOR = dGPU vendor" "nvidia" "${GPU_VENDOR:-}"

rm -rf "${_RESUME_TEST_DIR}"

unset _RESUME_TEST_DIR _INFER_UUID_MAP

# Cleanup
rm -rf "${TEST_TMPDIR}"
rm -f "${LOG_FILE}"

echo ""
echo "=== Results ==="
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"

[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
