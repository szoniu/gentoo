#!/usr/bin/env bash
# stage3.sh — Download, GPG verify, SHA512 check, extract stage3 tarball
source "${LIB_DIR}/protection.sh"

# _find_stage3_file — Locate stage3 tarball on mountpoint if STAGE3_FILE not set
# Needed when stage3_download checkpoint was reached but STAGE3_FILE wasn't exported
_find_stage3_file() {
    if [[ -n "${STAGE3_FILE:-}" && -f "${STAGE3_FILE}" ]]; then
        return 0
    fi
    local f
    for f in "${MOUNTPOINT}"/stage3-amd64-*.tar.xz; do
        if [[ -f "${f}" ]]; then
            STAGE3_FILE="${f}"
            STAGE3_FILENAME=$(basename "${f}")
            export STAGE3_FILE STAGE3_FILENAME
            einfo "Found stage3 tarball: ${f}"
            return 0
        fi
    done
    return 1
}

# stage3_get_url — Determine the correct stage3 URL based on init system
stage3_get_url() {
    local init="${INIT_SYSTEM:-systemd}"
    local latest_url

    case "${init}" in
        systemd) latest_url="${STAGE3_LATEST_URL}" ;;
        openrc)  latest_url="${STAGE3_LATEST_OPENRC_URL}" ;;
    esac

    einfo "Fetching stage3 URL from ${latest_url}..."

    local stage3_path
    stage3_path=$(wget -qO- "${latest_url}" 2>/dev/null | \
                  grep -v '^#' | grep -m1 'stage3-amd64' | awk '{print $1}') || \
        die "Failed to fetch stage3 URL"

    echo "${STAGE3_BASE_URL}/${stage3_path}"
}

# stage3_download — Download stage3 tarball + signatures
stage3_download() {
    einfo "Downloading stage3 tarball..."

    if [[ "${DRY_RUN}" == "1" ]]; then
        einfo "[DRY-RUN] Would download stage3"
        return 0
    fi

    local url
    url=$(stage3_get_url)
    local filename
    filename=$(basename "${url}")
    local dest="${MOUNTPOINT}/${filename}"

    # Download tarball
    try "Downloading stage3 tarball" \
        wget -q -O "${dest}" "${url}"

    # Download DIGESTS (GPG clearsigned, contains SHA512 hashes)
    try "Downloading DIGESTS" \
        wget -q -O "${dest}.DIGESTS" "${url}.DIGESTS"

    STAGE3_FILE="${dest}"
    STAGE3_FILENAME="${filename}"
    export STAGE3_FILE STAGE3_FILENAME

    einfo "Stage3 downloaded: ${dest}"
}

# stage3_verify — Verify GPG signature and SHA512 checksum
stage3_verify() {
    einfo "Verifying stage3 integrity..."

    if [[ "${DRY_RUN}" == "1" ]]; then
        einfo "[DRY-RUN] Would verify stage3"
        return 0
    fi

    if ! _find_stage3_file; then
        die "Stage3 tarball not found — cannot verify (was stage3_download skipped?)"
    fi
    local file="${STAGE3_FILE}"

    # Import Gentoo release key
    try "Importing Gentoo GPG key" \
        gpg --keyserver hkps://keys.gentoo.org --recv-keys "${GENTOO_GPG_KEY}"

    # Verify GPG signature (DIGESTS is clearsigned)
    try "Verifying GPG signature" \
        gpg --verify "${file}.DIGESTS"

    # Verify SHA512
    einfo "Checking SHA512 checksum..."
    local expected_hash
    # Extract hash from SHA512 section only (BLAKE2B section comes first in DIGESTS)
    expected_hash=$(awk -v fname="$(basename "${file}")" '
        /^# SHA512/ { in_sha512=1; next }
        /^#/ { in_sha512=0 }
        in_sha512 && $0 ~ fname && !/CONTENTS/ { print $1; exit }
    ' "${file}.DIGESTS")

    if [[ -z "${expected_hash}" ]]; then
        eerror "Could not extract SHA512 hash from DIGESTS file"
        eerror "Refusing to proceed with unverified stage3"
        return 1
    fi

    local actual_hash
    actual_hash=$(sha512sum "${file}" | awk '{print $1}')

    if [[ "${expected_hash}" == "${actual_hash}" ]]; then
        einfo "SHA512 checksum verified"
    else
        eerror "SHA512 mismatch!"
        eerror "Expected: ${expected_hash}"
        eerror "Actual:   ${actual_hash}"
        die "Stage3 integrity check failed"
    fi
}

# stage3_extract — Extract stage3 to mountpoint
stage3_extract() {
    einfo "Extracting stage3 tarball..."

    if [[ "${DRY_RUN}" == "1" ]]; then
        einfo "[DRY-RUN] Would extract stage3 to ${MOUNTPOINT}"
        return 0
    fi

    if ! _find_stage3_file; then
        die "Stage3 tarball not found — cannot extract (was stage3_download skipped?)"
    fi
    local file="${STAGE3_FILE}"

    try "Extracting stage3" \
        tar xpf "${file}" --xattrs-include='*.*' --numeric-owner -C "${MOUNTPOINT}"

    # Cleanup tarball to save space
    rm -f "${file}" "${file}.DIGESTS"

    einfo "Stage3 extracted to ${MOUNTPOINT}"
}
