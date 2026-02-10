#!/usr/bin/env bash
# tests/test_disk.sh — Test disk operations in dry-run mode
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export _GENTOO_INSTALLER=1
export LIB_DIR="${SCRIPT_DIR}/lib"
export DATA_DIR="${SCRIPT_DIR}/data"
export LOG_FILE="/tmp/gentoo-test-disk.log"
export DRY_RUN=1
export NON_INTERACTIVE=1
: > "${LOG_FILE}"

source "${LIB_DIR}/constants.sh"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/utils.sh"
source "${LIB_DIR}/dialog.sh"
source "${LIB_DIR}/config.sh"
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

echo "=== Test: Disk Plan Generation (auto, ext4) ==="

TARGET_DISK="/dev/sda"
FILESYSTEM="ext4"
SWAP_TYPE="zram"
PARTITION_SCHEME="auto"

disk_plan_auto

assert_eq "Plan has actions" "true" "$([[ ${#DISK_ACTIONS[@]} -gt 0 ]] && echo true || echo false)"
assert_eq "ESP partition set" "/dev/sda1" "${ESP_PARTITION}"
assert_eq "Root partition set" "/dev/sda2" "${ROOT_PARTITION}"

# Verify plan contains expected operations
plan_text=""
for action in "${DISK_ACTIONS[@]}"; do
    plan_text+="${action%%|||*} "
done
assert_contains "Plan has GPT" "GPT" "${plan_text}"
assert_contains "Plan has ESP" "ESP" "${plan_text}"
assert_contains "Plan has ext4" "ext4" "${plan_text}"

echo ""
echo "=== Test: Disk Plan Generation (auto, btrfs, swap partition) ==="

disk_plan_reset
FILESYSTEM="btrfs"
SWAP_TYPE="partition"
SWAP_SIZE_MIB="4096"

disk_plan_auto

assert_eq "ESP partition" "/dev/sda1" "${ESP_PARTITION}"
assert_eq "Swap partition set" "/dev/sda2" "${SWAP_PARTITION:-}"
assert_eq "Root partition" "/dev/sda3" "${ROOT_PARTITION}"

echo ""
echo "=== Test: NVMe partition naming ==="

disk_plan_reset
TARGET_DISK="/dev/nvme0n1"
FILESYSTEM="ext4"
SWAP_TYPE="none"

disk_plan_auto

assert_eq "NVMe ESP" "/dev/nvme0n1p1" "${ESP_PARTITION}"
assert_eq "NVMe root" "/dev/nvme0n1p2" "${ROOT_PARTITION}"

echo ""
echo "=== Test: Dry-run execution ==="

# Should succeed without actually doing anything
disk_execute_plan
assert_eq "Dry-run succeeds" "0" "$?"

# Cleanup
rm -f "${LOG_FILE}"

echo ""
echo "=== Results ==="
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"

[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
