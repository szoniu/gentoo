#!/usr/bin/env bash
# tests/test_checkpoint.sh — Test checkpoint mechanism (set/reached/validate/migrate)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export _GENTOO_INSTALLER=1
export LIB_DIR="${SCRIPT_DIR}/lib"
export DATA_DIR="${SCRIPT_DIR}/data"
export LOG_FILE="/tmp/gentoo-test-checkpoint.log"
export DRY_RUN=1
export NON_INTERACTIVE=1

# Use temp dirs for testing (avoid touching real system)
TEST_TMPDIR="$(mktemp -d)"
export CHECKPOINT_DIR="${TEST_TMPDIR}/checkpoints"
export CHECKPOINT_DIR_SUFFIX="/tmp/gentoo-installer-checkpoints"
export MOUNTPOINT="${TEST_TMPDIR}/mnt"
: > "${LOG_FILE}"

source "${LIB_DIR}/constants.sh"
source "${LIB_DIR}/logging.sh"
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

echo "=== Test: checkpoint_set / checkpoint_reached ==="

checkpoint_set "test_phase"
assert_eq "Checkpoint file created" "true" "$([[ -f "${CHECKPOINT_DIR}/test_phase" ]] && echo true || echo false)"
assert_eq "checkpoint_reached returns true" "true" "$(checkpoint_reached "test_phase" && echo true || echo false)"
assert_eq "Non-existent checkpoint returns false" "false" "$(checkpoint_reached "nonexistent" && echo true || echo false)"

echo ""
echo "=== Test: checkpoint_clear ==="

checkpoint_clear
assert_eq "Checkpoint dir removed" "false" "$([[ -d "${CHECKPOINT_DIR}" ]] && echo true || echo false)"
assert_eq "checkpoint_reached false after clear" "false" "$(checkpoint_reached "test_phase" && echo true || echo false)"

echo ""
echo "=== Test: checkpoint_validate — preflight always re-runs ==="

checkpoint_set "preflight"
assert_eq "preflight validates false (always re-run)" "false" "$(checkpoint_validate "preflight" && echo true || echo false)"

echo ""
echo "=== Test: checkpoint_validate — stage3_extract ==="

# Without gentoo-release file → invalid
assert_eq "stage3_extract invalid without file" "false" "$(checkpoint_validate "stage3_extract" && echo true || echo false)"

# Create fake gentoo-release
mkdir -p "${MOUNTPOINT}/etc"
touch "${MOUNTPOINT}/etc/gentoo-release"
assert_eq "stage3_extract valid with file" "true" "$(checkpoint_validate "stage3_extract" && echo true || echo false)"

echo ""
echo "=== Test: checkpoint_validate — portage_preconfig ==="

assert_eq "portage_preconfig invalid without make.conf" "false" "$(checkpoint_validate "portage_preconfig" && echo true || echo false)"

mkdir -p "${MOUNTPOINT}/etc/portage"
touch "${MOUNTPOINT}/etc/portage/make.conf"
assert_eq "portage_preconfig valid with make.conf" "true" "$(checkpoint_validate "portage_preconfig" && echo true || echo false)"

echo ""
echo "=== Test: checkpoint_validate — unknown checkpoints trusted ==="

assert_eq "Unknown checkpoint trusted" "true" "$(checkpoint_validate "some_unknown_phase" && echo true || echo false)"

echo ""
echo "=== Test: checkpoint_migrate_to_target ==="

# Reset checkpoint dir to /tmp style
CHECKPOINT_DIR="${TEST_TMPDIR}/checkpoints"
mkdir -p "${CHECKPOINT_DIR}"
checkpoint_set "disks"
checkpoint_set "stage3_extract"

local_target="${MOUNTPOINT}${CHECKPOINT_DIR_SUFFIX}"

# Migrate
checkpoint_migrate_to_target

assert_eq "CHECKPOINT_DIR updated" "${local_target}" "${CHECKPOINT_DIR}"
assert_eq "disks checkpoint migrated" "true" "$([[ -f "${local_target}/disks" ]] && echo true || echo false)"
assert_eq "stage3_extract checkpoint migrated" "true" "$([[ -f "${local_target}/stage3_extract" ]] && echo true || echo false)"
assert_eq "Old dir removed" "false" "$([[ -d "${TEST_TMPDIR}/checkpoints" ]] && echo true || echo false)"

echo ""
echo "=== Test: checkpoint_migrate idempotency ==="

# Second call should be a no-op (already on target)
checkpoint_migrate_to_target
assert_eq "Idempotent migrate succeeds" "true" "$(checkpoint_reached "disks" && echo true || echo false)"

# Cleanup
rm -rf "${TEST_TMPDIR}"
rm -f "${LOG_FILE}"

echo ""
echo "=== Results ==="
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"

[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
