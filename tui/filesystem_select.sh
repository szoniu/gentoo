#!/usr/bin/env bash
# tui/filesystem_select.sh — Filesystem selection: ext4 / btrfs / XFS
source "${LIB_DIR}/protection.sh"

screen_filesystem_select() {
    local current="${FILESYSTEM:-ext4}"
    local on_ext4="off" on_btrfs="off" on_xfs="off"
    case "${current}" in
        ext4)  on_ext4="on" ;;
        btrfs) on_btrfs="on" ;;
        xfs)   on_xfs="on" ;;
    esac

    local choice
    choice=$(dialog_radiolist "Root Filesystem" \
        "ext4"  "ext4 — stable, proven, recommended for beginners" "${on_ext4}" \
        "btrfs" "btrfs — snapshots, subvolumes, compression" "${on_btrfs}" \
        "xfs"   "XFS — high performance, good for large files" "${on_xfs}") \
        || return "${TUI_BACK}"

    if [[ -z "${choice}" ]]; then
        return "${TUI_BACK}"
    fi

    FILESYSTEM="${choice}"
    export FILESYSTEM

    # Btrfs subvolumes configuration
    if [[ "${FILESYSTEM}" == "btrfs" ]]; then
        BTRFS_SUBVOLUMES="@:/:@home:/home:@var-log:/var/log:@snapshots:/.snapshots"

        dialog_yesno "Btrfs Subvolumes" \
            "The following btrfs subvolumes will be created:\n\n\
  @           -> /\n\
  @home       -> /home\n\
  @var-log    -> /var/log\n\
  @snapshots  -> /.snapshots\n\n\
Use these defaults?" || {
            local custom
            custom=$(dialog_inputbox "Custom Subvolumes" \
                "Enter subvolumes (format: name:mountpoint pairs, colon-separated):\n\
Example: @:/:@home:/home:@var-log:/var/log" \
                "${BTRFS_SUBVOLUMES}") || return "${TUI_BACK}"
            BTRFS_SUBVOLUMES="${custom}"
        }

        export BTRFS_SUBVOLUMES
    else
        BTRFS_SUBVOLUMES=""
        export BTRFS_SUBVOLUMES
    fi

    einfo "Filesystem: ${FILESYSTEM}"
    return "${TUI_NEXT}"
}
