#!/usr/bin/env bash
# tests/test_multiboot.sh — Test multi-boot OS detection, serialization, and partition logic
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export _GENTOO_INSTALLER=1
export LIB_DIR="${SCRIPT_DIR}/lib"
export DATA_DIR="${SCRIPT_DIR}/data"
export LOG_FILE="/tmp/gentoo-test-multiboot.log"
export DRY_RUN=1
export NON_INTERACTIVE=1
: > "${LOG_FILE}"

source "${LIB_DIR}/constants.sh"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/utils.sh"
source "${LIB_DIR}/dialog.sh"
source "${LIB_DIR}/config.sh"
source "${LIB_DIR}/hardware.sh"
source "${LIB_DIR}/disk.sh"

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
        echo "  FAIL: ${desc} — '${needle}' not found in '${haystack}'"
        (( FAIL++ )) || true
    fi
}

# =============================================================================
echo "=== Test: Serialization round-trip (3 OSes) ==="

declare -gA DETECTED_OSES=()
DETECTED_OSES["/dev/sda2"]="Windows (system)"
DETECTED_OSES["/dev/sda3"]="openSUSE Tumbleweed"
DETECTED_OSES["/dev/sda5"]="Ubuntu 24.04 LTS"
WINDOWS_DETECTED=1
LINUX_DETECTED=1

serialize_detected_oses

assert_contains "Serialized has Windows" "Windows" "${DETECTED_OSES_SERIALIZED}"
assert_contains "Serialized has openSUSE" "openSUSE" "${DETECTED_OSES_SERIALIZED}"
assert_contains "Serialized has Ubuntu" "Ubuntu" "${DETECTED_OSES_SERIALIZED}"

# Now deserialize
local_serialized="${DETECTED_OSES_SERIALIZED}"
unset DETECTED_OSES
WINDOWS_DETECTED=0
LINUX_DETECTED=0
DETECTED_OSES_SERIALIZED="${local_serialized}"

deserialize_detected_oses

assert_eq "Deserialized Windows" "Windows (system)" "${DETECTED_OSES[/dev/sda2]:-}"
assert_eq "Deserialized openSUSE" "openSUSE Tumbleweed" "${DETECTED_OSES[/dev/sda3]:-}"
assert_eq "Deserialized Ubuntu" "Ubuntu 24.04 LTS" "${DETECTED_OSES[/dev/sda5]:-}"
assert_eq "WINDOWS_DETECTED restored" "1" "${WINDOWS_DETECTED}"
assert_eq "LINUX_DETECTED restored" "1" "${LINUX_DETECTED}"

# =============================================================================
echo ""
echo "=== Test: Serialization sanitizes pipe and equals ==="

declare -gA DETECTED_OSES=()
DETECTED_OSES["/dev/sda1"]="OS|with=pipes"
WINDOWS_DETECTED=0
LINUX_DETECTED=1

serialize_detected_oses

# Pipe and equals should be replaced with -
assert_eq "Pipe sanitized" "0" "$(echo "${DETECTED_OSES_SERIALIZED}" | grep -c '|.*|' || true)"
assert_contains "Equals sanitized in name" "OS-with-pipes" "${DETECTED_OSES_SERIALIZED}"

# Round-trip
DETECTED_OSES_SERIALIZED="${DETECTED_OSES_SERIALIZED}"
unset DETECTED_OSES
deserialize_detected_oses
assert_eq "Sanitized round-trip" "OS-with-pipes" "${DETECTED_OSES[/dev/sda1]:-}"

# =============================================================================
echo ""
echo "=== Test: Config save/load round-trip with DETECTED_OSES_SERIALIZED ==="

# Setup config data
declare -gA DETECTED_OSES=()
DETECTED_OSES["/dev/nvme0n1p2"]="Windows (system)"
DETECTED_OSES["/dev/nvme0n1p4"]="openSUSE Tumbleweed"
WINDOWS_DETECTED=1
LINUX_DETECTED=1
serialize_detected_oses

INIT_SYSTEM="systemd"
TARGET_DISK="/dev/nvme0n1"
PARTITION_SCHEME="dual-boot"
FILESYSTEM="ext4"
export INIT_SYSTEM TARGET_DISK PARTITION_SCHEME FILESYSTEM DETECTED_OSES_SERIALIZED WINDOWS_DETECTED LINUX_DETECTED

TMPFILE="/tmp/gentoo-test-multiboot-$$.conf"
config_save "${TMPFILE}"

# Clear and reload
saved_serialized="${DETECTED_OSES_SERIALIZED}"
unset DETECTED_OSES DETECTED_OSES_SERIALIZED WINDOWS_DETECTED LINUX_DETECTED INIT_SYSTEM

config_load "${TMPFILE}"
assert_eq "Config round-trip DETECTED_OSES_SERIALIZED" "${saved_serialized}" "${DETECTED_OSES_SERIALIZED:-}"
assert_eq "Config round-trip WINDOWS_DETECTED" "1" "${WINDOWS_DETECTED:-0}"
assert_eq "Config round-trip LINUX_DETECTED" "1" "${LINUX_DETECTED:-0}"

# Deserialize after config_load
deserialize_detected_oses
assert_eq "Config+deserialize Windows" "Windows (system)" "${DETECTED_OSES[/dev/nvme0n1p2]:-}"
assert_eq "Config+deserialize openSUSE" "openSUSE Tumbleweed" "${DETECTED_OSES[/dev/nvme0n1p4]:-}"

rm -f "${TMPFILE}"

# =============================================================================
echo ""
echo "=== Test: disk_plan_dualboot with pre-selected ROOT_PARTITION ==="

TARGET_DISK="/dev/sda"
FILESYSTEM="ext4"
PARTITION_SCHEME="dual-boot"
ESP_PARTITION="/dev/sda1"
ROOT_PARTITION="/dev/sda3"

disk_plan_dualboot

# Should not have sfdisk --append (we already have ROOT_PARTITION)
plan_has_append=0
for action in "${DISK_ACTIONS[@]}"; do
    [[ "${action}" == *"free space"* ]] && plan_has_append=1
done
assert_eq "No sfdisk --append when ROOT_PARTITION set" "0" "${plan_has_append}"

# Should have format action
plan_text=""
for action in "${DISK_ACTIONS[@]}"; do
    plan_text+="${action%%|||*} "
done
assert_contains "Plan formats root" "ext4" "${plan_text}"
assert_eq "ROOT_PARTITION preserved" "/dev/sda3" "${ROOT_PARTITION}"

# =============================================================================
echo ""
echo "=== Test: Partition prefix logic ==="

# /dev/sda → sda3 (no p separator)
disk_plan_reset
TARGET_DISK="/dev/sda"
FILESYSTEM="ext4"
ESP_PARTITION="/dev/sda1"
unset ROOT_PARTITION

# We can't actually run sfdisk --dump in test, but we test the prefix logic.
# The disk name goes through a variable rather than a literal on both sides of
# the match: with a literal, shellcheck flags the test as a constant expression
# (SC2050) — correctly, since a literal can never vary the way the real input
# does.
_prefix_for() {
    local disk="$1"
    if [[ "${disk}" =~ [0-9]$ ]]; then
        echo "${disk}p"
    else
        echo "${disk}"
    fi
}

assert_eq "sda prefix (no trailing digit)" "/dev/sda" "$(_prefix_for /dev/sda)"
assert_eq "nvme prefix (trailing digit)" "/dev/nvme0n1p" "$(_prefix_for /dev/nvme0n1)"

# =============================================================================
echo ""
echo "=== Test: Deserialization with empty string ==="

unset DETECTED_OSES
DETECTED_OSES_SERIALIZED=""
WINDOWS_DETECTED=0
LINUX_DETECTED=0

deserialize_detected_oses

assert_eq "Empty serialized → no DETECTED_OSES" "0" "${#DETECTED_OSES[@]}"
assert_eq "Empty serialized → WINDOWS_DETECTED=0" "0" "${WINDOWS_DETECTED}"
assert_eq "Empty serialized → LINUX_DETECTED=0" "0" "${LINUX_DETECTED}"

# =============================================================================
echo ""
echo "=== Test: Flags after deserialize (Linux only) ==="

DETECTED_OSES_SERIALIZED="/dev/sda3=Fedora 41"
WINDOWS_DETECTED=0
LINUX_DETECTED=0
unset DETECTED_OSES

deserialize_detected_oses

assert_eq "Linux-only → LINUX_DETECTED=1" "1" "${LINUX_DETECTED}"
assert_eq "Linux-only → WINDOWS_DETECTED=0" "0" "${WINDOWS_DETECTED}"

# Cleanup
rm -f "${LOG_FILE}"

echo ""
echo "=== Test: containers that cannot be probed still count as an OS ==="

# A LUKS or LVM partition is unreadable without a passphrase / activation, so the
# old scanner skipped it entirely: no dual-boot option, no ERASE gate, and the
# summary claimed "no operating systems detected" on a disk holding an encrypted
# Fedora. Stub lsblk so the scanner sees such a disk.
_stub_dir=$(mktemp -d)
cat > "${_stub_dir}/lsblk" <<'STUB_EOF'
#!/usr/bin/env bash
for a in "$@"; do
    case "${a}" in
        PATH,FSTYPE)
            echo "/dev/sda1 vfat"
            echo "/dev/sda2 crypto_LUKS"
            echo "/dev/sda3 LVM2_member"
            echo "/dev/sda4 ext3"
            echo "/dev/sda5 f2fs"
            exit 0 ;;
        NAME,SIZE,TRAN,MODEL)
            printf '%s\n' "sda      7.3T usb  Samsung Portable SSD T7"
            printf '%s\n' "nvme0n1 953G nvme KINGSTON OM8PGP41024N-A0"
            exit 0 ;;
        PKNAME) echo "sda"; exit 0 ;;
    esac
done
exit 0
STUB_EOF
chmod +x "${_stub_dir}/lsblk"
# No pvs/mount stubs: the VG name is optional and the ext3/f2fs probes simply
# fail to mount, which is the realistic case for a foreign disk.
cat > "${_stub_dir}/mount" <<'STUB_EOF'
#!/usr/bin/env bash
exit 1
STUB_EOF
chmod +x "${_stub_dir}/mount"

(
    export PATH="${_stub_dir}:${PATH}"
    declare -ga ESP_PARTITIONS=("/dev/sda1")
    DRY_RUN=0
    detect_installed_oses >/dev/null 2>&1
    printf '%s\n' "LINUX_DETECTED=${LINUX_DETECTED:-unset}"
    printf '%s\n' "LUKS=${DETECTED_OSES[/dev/sda2]:-}"
    printf '%s\n' "LVM=${DETECTED_OSES[/dev/sda3]:-}"
) > "${_stub_dir}/out.txt" 2>&1

assert_contains "encrypted volume marks Linux as present" "LINUX_DETECTED=1" "$(cat "${_stub_dir}/out.txt")"
assert_contains "LUKS partition is named in DETECTED_OSES" "LUKS=Encrypted volume (LUKS)" "$(cat "${_stub_dir}/out.txt")"
assert_contains "LVM physical volume is named in DETECTED_OSES" "LVM=LVM physical volume" "$(cat "${_stub_dir}/out.txt")"

echo ""
echo "=== Test: an EFI bootloader directory alone marks Linux as present ==="

# detect_esp runs BEFORE detect_installed_oses, which resets LINUX_DETECTED —
# so the ESP result has to be folded back in at the end.
# Deliberately a SEPARATE stub with nothing detectable on it: reusing the stub
# above would set LINUX_DETECTED=1 through the LUKS partition and the assertion
# would pass no matter what this code path does.
_stub2_dir=$(mktemp -d)
cat > "${_stub2_dir}/lsblk" <<'STUB_EOF'
#!/usr/bin/env bash
for a in "$@"; do
    case "${a}" in
        PATH,FSTYPE) echo "/dev/sda1 vfat"; exit 0 ;;
    esac
done
exit 0
STUB_EOF
chmod +x "${_stub2_dir}/lsblk"

(
    export PATH="${_stub2_dir}:${PATH}"
    declare -ga ESP_PARTITIONS=("/dev/sda1")
    DRY_RUN=0
    LINUX_EFI_LOADERS="fedora"
    detect_installed_oses >/dev/null 2>&1
    printf '%s\n' "LINUX_DETECTED=${LINUX_DETECTED:-unset}"
) > "${_stub2_dir}/out2.txt" 2>&1
assert_contains "EFI loader directory survives the reset" "LINUX_DETECTED=1" "$(cat "${_stub2_dir}/out2.txt")"

# Control: without the loader directory the same disk yields nothing — proves the
# assertion above measures the fold-back and not some unrelated side effect.
(
    export PATH="${_stub2_dir}:${PATH}"
    declare -ga ESP_PARTITIONS=("/dev/sda1")
    DRY_RUN=0
    LINUX_EFI_LOADERS=""
    detect_installed_oses >/dev/null 2>&1
    printf '%s\n' "LINUX_DETECTED=${LINUX_DETECTED:-unset}"
) > "${_stub2_dir}/out2b.txt" 2>&1
assert_contains "without a loader directory nothing is detected" "LINUX_DETECTED=0" "$(cat "${_stub2_dir}/out2b.txt")"
rm -rf "${_stub2_dir}"

echo ""
echo "=== Test: the installer's own medium is identified and described ==="

cat > "${_stub_dir}/findmnt" <<'STUB_EOF'
#!/usr/bin/env bash
echo "/dev/sda1"
STUB_EOF
chmod +x "${_stub_dir}/findmnt"

(
    export PATH="${_stub_dir}:${PATH}"
    detect_disks >/dev/null 2>&1
    printf '%s\n' "LIVE=${LIVE_MEDIUM_DISK:-unset}"
    printf '%s\n' "ENTRY0=${AVAILABLE_DISKS[0]:-none}"
) > "${_stub_dir}/out3.txt" 2>&1

assert_contains "live medium resolves to the whole disk" "LIVE=/dev/sda" "$(cat "${_stub_dir}/out3.txt")"
# MODEL is the field with spaces, so it must be read last — otherwise the
# transport ends up glued to the model and "usb" is lost.
assert_contains "transport survives a model containing spaces" "|Samsung Portable SSD T7|usb" "$(cat "${_stub_dir}/out3.txt")"

rm -rf "${_stub_dir}"

echo ""
echo "=== Test: wiping the install medium is refused ==="

out=$( ( TARGET_DISK="/dev/sda"; LIVE_MEDIUM_DISK="/dev/sda"; DRY_RUN=0
         cleanup_target_disk ) 2>&1 ) && out="${out} NO_ABORT"
assert_contains "cleanup refuses the install medium" "Refusing to wipe /dev/sda" "${out}"

echo ""
echo "=== Results ==="
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"

[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
