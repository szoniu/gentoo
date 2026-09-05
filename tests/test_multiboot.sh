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
        -P) seen_P=1 ;;
        NAME,SIZE,TRAN,MODEL)
            # Refuse to answer unless -P was actually requested: a stub that
            # emits key="value" no matter what makes the production code's -P
            # flag untestable — removing it would not redden a single assertion.
            [ "${seen_P:-0}" = "1" ] || { echo "stub: -P not requested" >&2; exit 1; }
            # -P output: key="value". Note the SD-reader row — empty TRAN with a
            # non-empty MODEL, the case positional splitting got wrong.
            printf '%s\n' 'NAME="sda" SIZE="7.3T" TRAN="usb" MODEL="Samsung Portable SSD T7"'
            printf '%s\n' 'NAME="nvme0n1" SIZE="953G" TRAN="nvme" MODEL="KINGSTON OM8PGP41024N-A0"'
            printf '%s\n' 'NAME="mmcblk0" SIZE="29.1G" TRAN="" MODEL="SC32G"'
            exit 0 ;;
        TYPE|PKNAME)
            # Exact match on the device argument, like the real tool: a path such
            # as "/dev/sda1[/@]" (findmnt without --nofsroot) is NOT a block
            # device and must fail here, otherwise the test cannot catch a
            # missing --nofsroot.
            dev=""
            for x in "$@"; do case "${x}" in /dev/*) dev="${x}" ;; esac; done
            case "${a}:${dev}" in
                TYPE:/dev/sda1)   echo "part" ;;
                TYPE:/dev/sda)    echo "disk" ;;
                PKNAME:/dev/sda1) echo "sda" ;;
                *) exit 1 ;;
            esac
            exit 0 ;;
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
# Mirrors real findmnt: without --nofsroot the filesystem root is appended for
# btrfs subvolumes and bind mounts, which then makes every lsblk lookup fail
# with "not a block device". The stub must reproduce that, otherwise the test
# cannot tell a correct call from a broken one.
for a in "$@"; do
    [ "${a}" = "--nofsroot" ] && { echo "/dev/sda1"; exit 0; }
done
echo "/dev/sda1[/@]"
STUB_EOF
chmod +x "${_stub_dir}/findmnt"

(
    export PATH="${_stub_dir}:${PATH}"
    detect_disks >/dev/null 2>&1 || true
    printf '%s\n' "LIVE=${LIVE_MEDIUM_DISK:-unset}"
    printf '%s\n' "ENTRY0=${AVAILABLE_DISKS[0]:-none}"
    printf '%s\n' "ENTRY2=${AVAILABLE_DISKS[2]:-none}"
) > "${_stub_dir}/out3.txt" 2>&1

assert_contains "live medium resolves to the whole disk" "LIVE=/dev/sda" "$(cat "${_stub_dir}/out3.txt")"
# MODEL is the field with spaces, so it must be read last — otherwise the
# transport ends up glued to the model and "usb" is lost.
assert_contains "transport survives a model containing spaces" "|Samsung Portable SSD T7|usb" "$(cat "${_stub_dir}/out3.txt")"
# Empty TRAN with a non-empty MODEL: positional splitting put the model into the
# transport field, so the one signal distinguishing a USB stick was garbage.
assert_contains "empty transport does not swallow the model" "mmcblk0|29.1G|SC32G|unknown" "$(cat "${_stub_dir}/out3.txt")"

rm -rf "${_stub_dir}"

echo ""
echo "=== Test: a device-mapper layer does not hide the medium (Ventoy) ==="

# One PKNAME hop is not enough there: /dev/mapper/ventoy -> /dev/sdb1 -> /dev/sdb.
# Stopping at the first hop yields a PARTITION, which never equals any entry in
# AVAILABLE_DISKS, so the stick would be silently unprotected.
_dm_stub=$(mktemp -d)
cat > "${_dm_stub}/findmnt" <<'STUB_EOF'
#!/usr/bin/env bash
for a in "$@"; do
    [ "${a}" = "--nofsroot" ] && { echo "/dev/mapper/ventoy"; exit 0; }
done
echo "/dev/mapper/ventoy"
STUB_EOF
cat > "${_dm_stub}/lsblk" <<'STUB_EOF'
#!/usr/bin/env bash
dev=""
for x in "$@"; do case "${x}" in /dev/*) dev="${x}" ;; esac; done
for a in "$@"; do
    case "${a}" in
        TYPE)
            case "${dev}" in
                /dev/mapper/ventoy) echo "dm" ;; /dev/sdb1) echo "part" ;;
                /dev/sdb) echo "disk" ;; *) exit 1 ;;
            esac; exit 0 ;;
        PKNAME)
            case "${dev}" in
                /dev/mapper/ventoy) echo "sdb1" ;; /dev/sdb1) echo "sdb" ;; *) exit 1 ;;
            esac; exit 0 ;;
    esac
done
exit 0
STUB_EOF
chmod +x "${_dm_stub}/findmnt" "${_dm_stub}/lsblk"

result=$( export PATH="${_dm_stub}:${PATH}"
          unset LIVE_MEDIUM_DISK
          _detect_live_medium >/dev/null 2>&1 || true
          printf '%s' "${LIVE_MEDIUM_DISK:-unset}" )
rm -rf "${_dm_stub}"
assert_eq "climbs through the dm layer to the whole disk" "/dev/sdb" "${result}"

echo ""
echo "=== Test: wiping the install medium is refused ==="

# Device name that cannot exist, plus logging stubs for the two destructive
# tools. cleanup_target_disk unmounts everything matching the target disk in
# /proc/mounts, so calling it with DRY_RUN=0 on a REAL name meant the only thing
# standing between this test and "umount -l /mnt/hdd" was the guard under test.
# A regression in that guard would have made the test itself wipe mounts.
_guard_stub=$(mktemp -d)
for _t in umount swapoff; do
    cat > "${_guard_stub}/${_t}" <<STUB_EOF
#!/usr/bin/env bash
echo "REAL-OP ${_t} \$*" >> "${_guard_stub}/ops.log"
exit 0
STUB_EOF
    chmod +x "${_guard_stub}/${_t}"
done
: > "${_guard_stub}/ops.log"

out=$( ( export PATH="${_guard_stub}:${PATH}"
         TARGET_DISK="/dev/zz-nonexistent-test"; LIVE_MEDIUM_DISK="/dev/zz-nonexistent-test"
         DRY_RUN=0
         cleanup_target_disk ) 2>&1 ) && out="${out} NO_ABORT"
assert_contains "cleanup refuses the install medium" "Refusing to wipe /dev/zz-nonexistent-test" "${out}"
assert_eq "the guard fires BEFORE anything touches the disk" "0" \
    "$(wc -l < "${_guard_stub}/ops.log" | tr -d ' ')"

echo ""
echo "=== Test: OEM directories on the ESP are not another Linux ==="

for d in fedora ubuntu debian opensuse arch systemd-boot refind; do
    if _efi_dir_is_linux_loader "${d}"; then rc=0; else rc=1; fi
    assert_eq "EFI/${d} counts as a Linux" "0" "${rc}"
done
for d in Boot Microsoft gentoo Dell HP Lenovo tools Recovery Firmware BOOTCAMP; do
    if _efi_dir_is_linux_loader "${d}"; then rc=0; else rc=1; fi
    assert_eq "EFI/${d} does NOT count as a Linux" "1" "${rc}"
done

echo ""
echo "=== Test: the live-medium guard works without the wizard ==="

# detect_all_hardware runs only from tui/hw_detect.sh, so --config and --resume
# used to reach cleanup_target_disk with LIVE_MEDIUM_DISK empty — the guard was
# dead code on exactly the paths where the operator cannot re-read the disk list.
_cli_stub=$(mktemp -d)
cat > "${_cli_stub}/findmnt" <<'STUB_EOF'
#!/usr/bin/env bash
echo "/dev/sdb1"
STUB_EOF
cat > "${_cli_stub}/lsblk" <<'STUB_EOF'
#!/usr/bin/env bash
for a in "$@"; do
    case "${a}" in
        TYPE) case "${*}" in *"/dev/sdb1"*) echo "part" ;; *"/dev/sdb"*) echo "disk" ;; esac; exit 0 ;;
        PKNAME) case "${*}" in *"/dev/sdb1"*) echo "sdb" ;; esac; exit 0 ;;
    esac
done
exit 0
STUB_EOF
chmod +x "${_cli_stub}/findmnt" "${_cli_stub}/lsblk"

cp "${_guard_stub}/umount" "${_guard_stub}/swapoff" "${_cli_stub}/" 2>/dev/null || true
: > "${_guard_stub}/ops.log"
out=$( ( export PATH="${_cli_stub}:${_guard_stub}:${PATH}"
         unset LIVE_MEDIUM_DISK
         TARGET_DISK="/dev/sdb"; DRY_RUN=0
         cleanup_target_disk ) 2>&1 ) && out="${out} NO_ABORT"
rm -rf "${_cli_stub}"
assert_contains "guard fires with no wizard run" "Refusing to wipe /dev/sdb" "${out}"
assert_eq "nothing touched the disk on the CLI path either" "0" \
    "$(wc -l < "${_guard_stub}/ops.log" | tr -d ' ')"
rm -rf "${_guard_stub}"

echo ""
echo "=== Test: a full wipe clears the EFI-only Linux flag ==="

# Tests the clearing directly — NEVER via disk_execute_plan, which would run a
# real sfdisk against whatever TARGET_DISK happens to name.
declare -gA DETECTED_OSES=()
DETECTED_OSES_SERIALIZED=""
LINUX_DETECTED=1
LINUX_EFI_LOADERS="fedora"
WINDOWS_DETECTED=0

_disk_clear_pre_wipe_detection >/dev/null 2>&1

assert_eq "flag cleared after auto wipe" "0" "${LINUX_DETECTED}"
assert_eq "EFI loaders cleared after auto wipe" "" "${LINUX_EFI_LOADERS}"

echo ""
echo "=== Test: GRUB verification skips containers os-prober cannot read ==="

# An unopened LUKS/LVM container is recorded so the ERASE gate exists, but
# os-prober cannot look inside it — so it can never appear in grub.cfg. Verifying
# it produced a permanent "OS missing from GRUB" warning at the end of every
# successful install on an encrypted machine.
source "${LIB_DIR}/bootloader.sh" 2>/dev/null || true

_grub_fixture=$(mktemp -d)
cat > "${_grub_fixture}/grub.cfg" <<'GRUB_EOF'
menuentry 'Gentoo GNU/Linux' { linux /vmlinuz root=UUID=1111 }
menuentry 'Windows Boot Manager (on /dev/sda1)' { chainloader /EFI/Microsoft/Boot/bootmgfw.efi }
GRUB_EOF

declare -gA DETECTED_OSES=()
DETECTED_OSES["/dev/sda2"]="Windows (system)"
DETECTED_OSES["/dev/sda3"]="Encrypted volume (LUKS) — contents unknown"
DETECTED_OSES["/dev/sda4"]="LVM physical volume — contents unknown"
ROOT_PARTITION="/dev/sda9"

out=$( _GRUB_CFG_FILE="${_grub_fixture}/grub.cfg" NON_INTERACTIVE=1 \
       _verify_grub_config 2>&1 ) || true
rm -rf "${_grub_fixture}"

# Mentioning the container in a "skipping" line is fine; what must not happen is
# the warning that says GRUB missed an operating system.
assert_eq "no missing-OS warning at all" "0" \
    "$(printf '%s' "${out}" | grep -c 'may not have detected' || true)"
assert_eq "the LUKS container is not listed as missing" "0" \
    "$(printf '%s' "${out}" | grep 'may not have detected' -A5 | grep -c 'sda3' || true)"
assert_contains "the container is explicitly skipped" "Skipping GRUB verification for /dev/sda3" "${out}"
assert_contains "verification still reports success" "verified" "${out}"

echo ""
echo "=== Test: refusing the install medium re-asks instead of going back ==="

# run_wizard decrements the screen index on TUI_BACK, so returning it after
# "Pick a different disk." would drop the operator on the PREVIOUS screen.
_sel_src=$(sed -n '/^screen_disk_select()/,/^}/p' "${SCRIPT_DIR}/tui/disk_select.sh")
assert_eq "the refusal loops back to the disk list" "1" \
    "$(printf '%s' "${_sel_src}" | grep -A12 'Cannot Install Onto the Install Medium' | grep -c 'continue' || true)"
assert_eq "the refusal does not return TUI_BACK" "0" \
    "$(printf '%s' "${_sel_src}" | grep -A12 'Cannot Install Onto the Install Medium' | grep -c 'return "${TUI_BACK}"' || true)"

echo ""
echo "=== Test: detect_esp skips the ESP on the install medium ==="

# Previously untested: the install stick has an ESP too, and its EFI/ directories
# would report a Linux that lives on the medium rather than on the target.
_esp_stub=$(mktemp -d)
cat > "${_esp_stub}/lsblk" <<'STUB_EOF'
#!/usr/bin/env bash
for a in "$@"; do
    case "${a}" in
        PATH,PARTTYPE)
            echo "/dev/sda1 c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
            echo "/dev/sdb1 c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
            exit 0 ;;
    esac
done
exit 0
STUB_EOF
cat > "${_esp_stub}/mount" <<'STUB_EOF'
#!/usr/bin/env bash
exit 1
STUB_EOF
chmod +x "${_esp_stub}/lsblk" "${_esp_stub}/mount"

result=$( export PATH="${_esp_stub}:${PATH}"
          LIVE_MEDIUM_DISK="/dev/sdb"
          detect_esp >/dev/null 2>&1 || true
          printf '%s' "${ESP_PARTITIONS[*]:-none}" )
assert_eq "only the target machine's ESP is kept" "/dev/sda1" "${result}"

result=$( export PATH="${_esp_stub}:${PATH}"
          unset LIVE_MEDIUM_DISK
          detect_esp >/dev/null 2>&1 || true
          printf '%s' "${ESP_PARTITIONS[*]:-none}" )
rm -rf "${_esp_stub}"
assert_eq "without a known medium both ESPs are kept" "/dev/sda1 /dev/sdb1" "${result}"

echo ""
echo "=== Test: loop-mounted media do not kill the installer ==="

# _walk_up_to_disk returns 1 for a loop device with no parent; the caller must
# absorb that. Without "|| dev=''" the failing substitution killed the shell
# under set -e — on the very first hardware-detection screen.
_loop_stub=$(mktemp -d)
cat > "${_loop_stub}/findmnt" <<'STUB_EOF'
#!/usr/bin/env bash
echo "/dev/loop0"
STUB_EOF
cat > "${_loop_stub}/lsblk" <<'STUB_EOF'
#!/usr/bin/env bash
for a in "$@"; do case "${a}" in TYPE) echo "loop"; exit 0 ;; PKNAME) exit 1 ;; esac; done
exit 0
STUB_EOF
chmod +x "${_loop_stub}/findmnt" "${_loop_stub}/lsblk"

# set -e + inherit_errexit INSIDE the substitution: without them a $( ) subshell
# runs with errexit off, so a failing command substitution inside the function
# would not abort — and the test could not tell the fixed code from the broken
# code it is meant to guard. install.sh sets both, so this mirrors production.
_loop_rc=0
set +e
result=$( set -e; shopt -s inherit_errexit
          export PATH="${_loop_stub}:${PATH}"
          unset LIVE_MEDIUM_DISK
          _detect_live_medium >/dev/null 2>&1
          printf 'SURVIVED:%s' "${LIVE_MEDIUM_DISK:-empty}" )
_loop_rc=$?
set -e
[[ ${_loop_rc} -eq 0 ]] || result="DIED(rc=${_loop_rc})"
rm -rf "${_loop_stub}"
assert_eq "an unresolvable medium leaves the installer alive" "SURVIVED:empty" "${result}"

echo ""
echo "=== Results ==="
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"

[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
