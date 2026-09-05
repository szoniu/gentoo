#!/usr/bin/env bash
# tests/test_shrink.sh — Test partition shrink planning and helpers
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export _GENTOO_INSTALLER=1
export LIB_DIR="${SCRIPT_DIR}/lib"
export DATA_DIR="${SCRIPT_DIR}/data"
export LOG_FILE="/tmp/gentoo-test-shrink.log"
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

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "${haystack}" != *"${needle}"* ]]; then
        echo "  PASS: ${desc}"
        (( PASS++ )) || true
    else
        echo "  FAIL: ${desc} — '${needle}' unexpectedly found in '${haystack}'"
        (( FAIL++ )) || true
    fi
}

# Helper: collect all action descriptions
_get_plan_text() {
    local text=""
    local action
    for action in "${DISK_ACTIONS[@]}"; do
        text+="${action%%|||*} | "
    done
    echo "${text}"
}

echo "=== Test: GENTOO_MIN_SIZE_MIB constant ==="

assert_eq "GENTOO_MIN_SIZE_MIB is 20480" "20480" "${GENTOO_MIN_SIZE_MIB}"

echo ""
echo "=== Test: disk_can_shrink_fstype ==="

disk_can_shrink_fstype "ntfs" && rc=0 || rc=$?
assert_eq "ntfs can shrink" "0" "${rc}"

disk_can_shrink_fstype "ext4" && rc=0 || rc=$?
assert_eq "ext4 can shrink" "0" "${rc}"

disk_can_shrink_fstype "btrfs" && rc=0 || rc=$?
assert_eq "btrfs can shrink" "0" "${rc}"

disk_can_shrink_fstype "xfs" && rc=0 || rc=$?
assert_eq "xfs cannot shrink" "1" "${rc}"

disk_can_shrink_fstype "swap" && rc=0 || rc=$?
assert_eq "swap cannot shrink" "1" "${rc}"

disk_can_shrink_fstype "vfat" && rc=0 || rc=$?
assert_eq "vfat cannot shrink" "1" "${rc}"

echo ""
echo "=== Test: disk_get_free_space_mib (DRY_RUN) ==="

_DRY_RUN_FREE_SPACE_MIB=500
result=$(disk_get_free_space_mib "/dev/sda")
assert_eq "Free space returns dry-run value" "500" "${result}"

_DRY_RUN_FREE_SPACE_MIB=0
result=$(disk_get_free_space_mib "/dev/sda")
assert_eq "Free space returns 0 when none" "0" "${result}"

echo ""
echo "=== Test: disk_get_partition_size_mib (DRY_RUN) ==="

_DRY_RUN_PART_SIZE_MIB=102400
result=$(disk_get_partition_size_mib "/dev/sda2")
assert_eq "Partition size returns dry-run value" "102400" "${result}"

echo ""
echo "=== Test: disk_get_partition_used_mib (DRY_RUN) ==="

_DRY_RUN_PART_USED_MIB=51200
result=$(disk_get_partition_used_mib "/dev/sda2" "ntfs")
assert_eq "Partition used returns dry-run value" "51200" "${result}"

echo ""
echo "=== Test: disk_plan_shrink (NTFS) ==="

disk_plan_reset
TARGET_DISK="/dev/sda"
SHRINK_PARTITION="/dev/sda2"
SHRINK_PARTITION_FSTYPE="ntfs"
SHRINK_NEW_SIZE_MIB=80000

disk_plan_shrink

plan_text=$(_get_plan_text)
assert_contains "NTFS plan has NTFS shrink" "Shrink NTFS" "${plan_text}"
assert_contains "NTFS plan has partition table resize" "partition table" "${plan_text}"
assert_contains "NTFS plan has partprobe" "partition table" "${plan_text}"
assert_eq "NTFS plan action count" "3" "${#DISK_ACTIONS[@]}"

echo ""
echo "=== Test: disk_plan_shrink (ext4) ==="

disk_plan_reset
SHRINK_PARTITION="/dev/sda2"
SHRINK_PARTITION_FSTYPE="ext4"
SHRINK_NEW_SIZE_MIB=60000

disk_plan_shrink

plan_text=$(_get_plan_text)
# e2fsck, resize2fs and the read-back check are ONE critical action now: the
# partition table entry must never be truncated after a half-done shrink.
assert_contains "ext4 plan has shrink step" "Shrink ext4" "${plan_text}"
assert_contains "ext4 shrink does e2fsck" "e2fsck" "${DISK_ACTIONS[0]}"
assert_contains "ext4 shrink does resize2fs" "resize2fs" "${DISK_ACTIONS[0]}"
assert_contains "ext4 shrink reads size back" "read-back" "${DISK_ACTIONS[0]}"
assert_contains "ext4 shrink tolerates e2fsck rc<=2" "le 2" "${DISK_ACTIONS[0]}"
assert_contains "ext4 plan has partition table resize" "partition table" "${plan_text}"
assert_eq "ext4 plan action count" "3" "${#DISK_ACTIONS[@]}"

# Both the shrink and the table truncation are non-skippable
assert_eq "ext4 shrink is critical" "1" "${DISK_CRITICAL[0]}"
assert_eq "ext4 table resize is critical" "1" "${DISK_CRITICAL[1]}"
assert_eq "partprobe is not critical" "0" "${DISK_CRITICAL[2]}"

echo ""
echo "=== Test: disk_plan_shrink (btrfs) ==="

disk_plan_reset
SHRINK_PARTITION="/dev/sda3"
SHRINK_PARTITION_FSTYPE="btrfs"
SHRINK_NEW_SIZE_MIB=50000

disk_plan_shrink

plan_text=$(_get_plan_text)
assert_contains "btrfs plan has btrfs shrink" "btrfs" "${plan_text}"
assert_contains "btrfs plan has partition table resize" "partition table" "${plan_text}"
assert_eq "btrfs plan action count" "3" "${#DISK_ACTIONS[@]}"

echo ""
echo "=== Test: disk_plan_dualboot with SHRINK_PARTITION ==="

disk_plan_reset
TARGET_DISK="/dev/sda"
FILESYSTEM="ext4"
PARTITION_SCHEME="dual-boot"
ESP_PARTITION="/dev/sda1"
SHRINK_PARTITION="/dev/sda2"
SHRINK_PARTITION_FSTYPE="ntfs"
SHRINK_NEW_SIZE_MIB=80000
unset ROOT_PARTITION 2>/dev/null || true

disk_plan_dualboot

plan_text=$(_get_plan_text)
assert_contains "Dualboot+shrink has NTFS shrink" "Shrink NTFS" "${plan_text}"
assert_contains "Dualboot+shrink has sfdisk append" "free space" "${plan_text}"
# mkfs is NOT planned here: the partition number sfdisk --append will pick is
# unknowable at plan time (GPT holes), so formatting waits for the resolver.
assert_not_contains "Dualboot+shrink defers root format" "Format root" "${plan_text}"
assert_eq "Dualboot+shrink flags root resolution" "1" "${_DUALBOOT_RESOLVE_ROOT}"

echo ""
echo "=== Test: disk_plan_dualboot without shrink ==="

disk_plan_reset
unset SHRINK_PARTITION 2>/dev/null || true
unset ROOT_PARTITION 2>/dev/null || true

disk_plan_dualboot

plan_text=$(_get_plan_text)
assert_not_contains "No-shrink dualboot has no NTFS shrink" "Shrink NTFS" "${plan_text}"
assert_not_contains "No-shrink dualboot defers root format" "Format root" "${plan_text}"
assert_eq "No-shrink dualboot flags root resolution" "1" "${_DUALBOOT_RESOLVE_ROOT}"

echo ""
echo "=== Test: CONFIG_VARS includes shrink variables ==="

found_shrink_part=0
found_shrink_fstype=0
found_shrink_size=0
for v in "${CONFIG_VARS[@]}"; do
    case "${v}" in
        SHRINK_PARTITION) found_shrink_part=1 ;;
        SHRINK_PARTITION_FSTYPE) found_shrink_fstype=1 ;;
        SHRINK_NEW_SIZE_MIB) found_shrink_size=1 ;;
    esac
done
assert_eq "CONFIG_VARS has SHRINK_PARTITION" "1" "${found_shrink_part}"
assert_eq "CONFIG_VARS has SHRINK_PARTITION_FSTYPE" "1" "${found_shrink_fstype}"
assert_eq "CONFIG_VARS has SHRINK_NEW_SIZE_MIB" "1" "${found_shrink_size}"

echo ""
echo "=== Test: Config round-trip with shrink vars ==="

SHRINK_PARTITION="/dev/sda2"
SHRINK_PARTITION_FSTYPE="ntfs"
SHRINK_NEW_SIZE_MIB="80000"
INIT_SYSTEM="systemd"
TARGET_DISK="/dev/sda"
FILESYSTEM="ext4"
HOSTNAME="testbox"
TIMEZONE="UTC"
LOCALE="en_US.UTF-8"
KERNEL_TYPE="dist-kernel"
GPU_VENDOR="intel"
USERNAME="user"
ROOT_PASSWORD_HASH='$6$test'
USER_PASSWORD_HASH='$6$test'

tmpfile=$(mktemp)
config_save "${tmpfile}"

# Clear and reload
unset SHRINK_PARTITION SHRINK_PARTITION_FSTYPE SHRINK_NEW_SIZE_MIB
config_load "${tmpfile}"

assert_eq "Round-trip SHRINK_PARTITION" "/dev/sda2" "${SHRINK_PARTITION:-}"
assert_eq "Round-trip SHRINK_PARTITION_FSTYPE" "ntfs" "${SHRINK_PARTITION_FSTYPE:-}"
assert_eq "Round-trip SHRINK_NEW_SIZE_MIB" "80000" "${SHRINK_NEW_SIZE_MIB:-}"

rm -f "${tmpfile}"

echo ""
echo "=== Test: validate_config with shrink vars ==="

# Valid shrink config
PARTITION_SCHEME="dual-boot"
ESP_PARTITION="/dev/sda1"
SWAP_TYPE="zram"
DESKTOP_TYPE="plasma"
SHRINK_PARTITION="/dev/sda2"
SHRINK_PARTITION_FSTYPE="ntfs"
SHRINK_NEW_SIZE_MIB="80000"

errors=$(validate_config) && rc=0 || rc=$?
assert_eq "Valid shrink config passes" "0" "${rc}"

# Invalid fstype
SHRINK_PARTITION_FSTYPE="xfs"
errors=$(validate_config) && rc=0 || rc=$?
assert_eq "Invalid shrink fstype fails" "1" "${rc}"
assert_contains "Error mentions fstype" "SHRINK_PARTITION_FSTYPE" "${errors}"

# Missing size
SHRINK_PARTITION_FSTYPE="ntfs"
SHRINK_NEW_SIZE_MIB=""
errors=$(validate_config) && rc=0 || rc=$?
assert_eq "Missing shrink size fails" "1" "${rc}"

# Cleanup
rm -f "${LOG_FILE}"

echo ""
echo "=== Test: root partition on the target disk is formatted directly ==="

disk_plan_reset
TARGET_DISK="/dev/sda"
FILESYSTEM="ext4"
SHRINK_PARTITION=""
ROOT_PARTITION="/dev/sda5"

disk_plan_dualboot

plan_text=$(_get_plan_text)
assert_contains "Existing root partition is formatted" "Format root as ext4" "${plan_text}"
assert_eq "No resolution needed for existing partition" "0" "${_DUALBOOT_RESOLVE_ROOT}"

echo ""
echo "=== Test: cross-disk values are refused ==="

# A wizard re-entry can leave SHRINK_PARTITION/ROOT_PARTITION pointing at the
# PREVIOUS disk. The partition NUMBER is then fed to sfdisk -N on the new disk,
# so this must abort rather than truncate a stranger's partition.
# Assert on the die MESSAGE, not merely on a non-zero exit: a typo in the
# function name would also exit non-zero and leave the test falsely green.
out=$( (
    TARGET_DISK="/dev/sdb"
    SHRINK_PARTITION="/dev/sda2"
    SHRINK_PARTITION_FSTYPE="ntfs"
    SHRINK_NEW_SIZE_MIB=50000
    disk_plan_reset
    disk_plan_shrink
) 2>&1 ) && out="${out} NO_ABORT"
assert_contains "shrink on a foreign disk aborts with a reason" "Refusing to shrink /dev/sda2" "${out}"

out=$( (
    TARGET_DISK="/dev/sdb"
    SHRINK_PARTITION=""
    ROOT_PARTITION="/dev/sda5"
    disk_plan_reset
    disk_plan_dualboot
) 2>&1 ) && out="${out} NO_ABORT"
assert_contains "root partition on a foreign disk aborts with a reason" "Refusing to format /dev/sda5" "${out}"

echo ""
echo "=== Test: disk_get_largest_free_mib (DRY_RUN) ==="

# The decision "does Gentoo fit" must use the biggest single gap, never the sum
_DRY_RUN_LARGEST_FREE_MIB=15000
_DRY_RUN_FREE_SPACE_MIB=25000
result=$(disk_get_largest_free_mib "/dev/sda")
assert_eq "Largest gap is reported, not the total" "15000" "${result}"
result=$(disk_get_free_space_mib "/dev/sda")
assert_eq "Total free space still available separately" "25000" "${result}"

unset _DRY_RUN_LARGEST_FREE_MIB
result=$(disk_get_largest_free_mib "/dev/sda")
assert_eq "Falls back to the total when unset" "25000" "${result}"

echo ""
echo "=== Test: _disk_list_partitions ==="

_DRY_RUN_PARTITIONS="/dev/sda1 /dev/sda2 /dev/sda4"
result=$(_disk_list_partitions "/dev/sda" | tr '\n' ',')
assert_eq "Partition list is enumerated" "/dev/sda1,/dev/sda2,/dev/sda4," "${result}"
unset _DRY_RUN_PARTITIONS

echo ""
echo "=== Test: _disk_resolve_appended_root ==="

# The bug this replaces: "number of partitions + 1" on a GPT with a hole
# (1,2,4) computed 4 — an EXISTING partition — while sfdisk --append actually
# created number 3. Verified on a real GPT image. So identification is by
# DIFFERENCE against a snapshot, and anything ambiguous must abort.
TARGET_DISK="/dev/sda"
_DRY_RUN_PART_SIZE_MIB=51200

_DUALBOOT_PARTS_BEFORE=$'/dev/sda1\n/dev/sda2\n/dev/sda4'
_DRY_RUN_PARTITIONS="/dev/sda1 /dev/sda2 /dev/sda3 /dev/sda4"
ROOT_PARTITION=""
_disk_resolve_appended_root >/dev/null 2>&1
assert_eq "New partition identified by difference, not arithmetic" "/dev/sda3" "${ROOT_PARTITION}"

# Nothing new — sfdisk did not create anything
out=$( ( _DUALBOOT_PARTS_BEFORE=$'/dev/sda1\n/dev/sda2'
  _DRY_RUN_PARTITIONS="/dev/sda1 /dev/sda2"
  _disk_resolve_appended_root ) 2>&1 ) && out="${out} NO_ABORT"
assert_contains "No new partition aborts with a reason" "Expected exactly one new partition" "${out}"

# Two new devices — ambiguous, must not guess
out=$( ( _DUALBOOT_PARTS_BEFORE=$'/dev/sda1'
  _DRY_RUN_PARTITIONS="/dev/sda1 /dev/sda2 /dev/sda3"
  _disk_resolve_appended_root ) 2>&1 ) && out="${out} NO_ABORT"
assert_contains "Ambiguous result aborts with a reason" "Expected exactly one new partition" "${out}"

# Created, but the gap was too small for Gentoo — say so before the build
out=$( ( _DUALBOOT_PARTS_BEFORE=$'/dev/sda1\n/dev/sda2'
  _DRY_RUN_PARTITIONS="/dev/sda1 /dev/sda2 /dev/sda3"
  _DRY_RUN_PART_SIZE_MIB=10240
  _disk_resolve_appended_root ) 2>&1 ) && out="${out} NO_ABORT"
assert_contains "Undersized partition aborts with a reason" "below the" "${out}"

unset _DRY_RUN_PARTITIONS

echo ""
echo "=== Test: TRY_NO_CONTINUE is actually CONSUMED by try() ==="

# Asserting that the flag is SET on the plan proves nothing about try() honouring
# it. Drive the real recovery menu: it needs a terminal, so borrow one from
# script(1) (util-linux, same package as sfdisk).
if command -v script &>/dev/null; then
    _try_probe="$(mktemp -d)/probe.sh"
    cat > "${_try_probe}" <<PROBE_EOF
#!/usr/bin/env bash
set -euo pipefail
export _GENTOO_INSTALLER=1
export LIB_DIR="${SCRIPT_DIR}/lib"
export DATA_DIR="${SCRIPT_DIR}/data"
export LOG_FILE=/tmp/gentoo-test-try-probe.log
export SKIPPED_LOG=/tmp/gentoo-test-try-probe-skipped.log
: > "\${LOG_FILE}"; : > "\${SKIPPED_LOG}"
source "\${LIB_DIR}/constants.sh"
source "\${LIB_DIR}/logging.sh"
source "\${LIB_DIR}/dialog.sh"
source "\${LIB_DIR}/utils.sh"
DIALOG_CMD=__no_such_dialog__       # force the text fallback
DRY_RUN=0 NON_INTERACTIVE=0 TRY_NO_CONTINUE=0 try "probe-open" false && echo "OPEN_RC=0"
# No "|| echo" here: abort goes through die(), which exits the process rather
# than returning — the assertion below looks for that exit instead.
DRY_RUN=0 NON_INTERACTIVE=0 TRY_NO_CONTINUE=1 try "probe-locked" false
echo "LOCKED_REACHED_SUCCESS_PATH"
PROBE_EOF
    _try_out=$(printf 'c\nc\na\n' | timeout 60 script -qec "bash ${_try_probe}" /dev/null 2>&1 || true)
    rm -rf "$(dirname "${_try_probe}")"

    assert_contains "without the flag the menu offers continue" "(c)ontinue" "${_try_out}"
    assert_contains "without the flag a skip returns success" "OPEN_RC=0" "${_try_out}"
    assert_contains "with the flag the menu warns skipping is unsafe" "NOT safe here" "${_try_out}"
    assert_contains "with the flag a skip is refused" "Skipping is not allowed" "${_try_out}"
    assert_eq "with the flag continue is absent from the menu" "0" \
        "$(printf '%s' "${_try_out}" | grep -c 'a)bort   — skipping this step is NOT safe here.*(c)ontinue' || true)"
    assert_contains "with the flag the run ends in abort" "Aborted by user after failure: probe-locked" "${_try_out}"
    assert_eq "with the flag try() never returns success" "0" \
        "$(printf '%s' "${_try_out}" | grep -c 'LOCKED_REACHED_SUCCESS_PATH' || true)"
else
    echo "  SKIP: script(1) unavailable — cannot drive the recovery menu"
fi

# The probe above drives the TEXT fallback (dialog is deliberately unavailable in
# tests). The dialog branch builds its menu from _try_opts, so guard it
# structurally: this fails if anyone hardcodes "continue" back into that call.
_try_src=$(sed -n '/^try()/,/^}/p' "${SCRIPT_DIR}/lib/utils.sh")
assert_eq "dialog menu is built from the guarded _try_opts array" "1" \
    "$(printf '%s' "${_try_src}" | grep -c 'dialog_menu "Command Failed: ${desc}" "${_try_opts\[@\]}"' || true)"
assert_eq "continue is added to _try_opts only when allowed" "1" \
    "$(printf '%s' "${_try_src}" | grep -A1 'TRY_NO_CONTINUE:-0}" != "1"' | grep -c '_try_opts+=("continue"' || true)"

echo ""
echo "=== Test: disk_get_partition_used_mib signals failure ==="

# The contract this PR introduces: unknown must be a non-zero exit, never "0 MiB".
# Both probes below stay away from real block devices.
rc=0
DRY_RUN=0 disk_get_partition_used_mib "/dev/null" "vfat" >/dev/null 2>&1 || rc=$?
assert_eq "unsupported fstype reports unknown" "1" "$([[ ${rc} -ne 0 ]] && echo 1 || echo 0)"

rc=0
DRY_RUN=0 disk_get_partition_used_mib "/dev/null" "ext4" >/dev/null 2>&1 || rc=$?
assert_eq "unreadable ext4 reports unknown" "1" "$([[ ${rc} -ne 0 ]] && echo 1 || echo 0)"

rc=0
DRY_RUN=0 disk_get_partition_used_mib "/dev/null" "ntfs" >/dev/null 2>&1 || rc=$?
assert_eq "unreadable ntfs reports unknown" "1" "$([[ ${rc} -ne 0 ]] && echo 1 || echo 0)"

echo ""
echo "=== Test: disk_get_largest_free_mib against a real GPT image ==="

# sfdisk operates on plain files, so the actual parser can be exercised without
# root or hardware — the DRY_RUN assertions above only cover the stub.
if command -v sfdisk &>/dev/null; then
    _img=$(mktemp -d)/gpt.img
    truncate -s 400M "${_img}"
    sfdisk "${_img}" >/dev/null 2>&1 <<'IMG_EOF'
label: gpt
start=2048, size=20MiB, type=linux, name=a
start=104448, size=20MiB, type=linux, name=b
IMG_EOF
    # Gaps: ~30 MiB between a and b, ~329 MiB after b.
    result=$(DRY_RUN=0 disk_get_largest_free_mib "${_img}")
    total=$(DRY_RUN=0 disk_get_free_space_mib "${_img}")
    rm -rf "$(dirname "${_img}")"

    assert_eq "largest gap is the trailing one, not the sum" "1" \
        "$([[ ${result} -ge 320 && ${result} -le 340 ]] && echo 1 || echo 0)"
    assert_eq "the sum is larger than the largest gap" "1" \
        "$([[ ${total} -gt ${result} ]] && echo 1 || echo 0)"
else
    echo "  SKIP: sfdisk unavailable"
fi

echo ""
echo "=== Results ==="
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"

[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
