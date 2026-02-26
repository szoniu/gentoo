#!/usr/bin/env bash
# dialog.sh — Dialog/whiptail wrapper, navigation stack, wizard runner
source "${LIB_DIR}/protection.sh"

# --- Gum bundled backend ---

# Extract gum binary from bundled tarball in data/gum.tar.gz
_extract_bundled_gum() {
    # Already extracted and working?
    if [[ -x "${GUM_CACHE_DIR}/gum" ]]; then
        return 0
    fi

    local tarball="${DATA_DIR}/gum.tar.gz"
    if [[ ! -f "${tarball}" ]]; then
        return 1
    fi

    mkdir -p "${GUM_CACHE_DIR}"
    if ! tar xzf "${tarball}" -C "${GUM_CACHE_DIR}" \
        "gum_${GUM_VERSION}_Linux_x86_64/gum" 2>/dev/null; then
        return 1
    fi

    # Move binary from subdirectory to cache root
    mv "${GUM_CACHE_DIR}/gum_${GUM_VERSION}_Linux_x86_64/gum" \
       "${GUM_CACHE_DIR}/gum" 2>/dev/null || true
    rmdir "${GUM_CACHE_DIR}/gum_${GUM_VERSION}_Linux_x86_64" 2>/dev/null || true
    chmod +x "${GUM_CACHE_DIR}/gum"

    # Verify it runs
    if ! "${GUM_CACHE_DIR}/gum" --version &>/dev/null; then
        rm -f "${GUM_CACHE_DIR}/gum"
        return 1
    fi
    return 0
}

# Try to enable gum backend. Returns 0 if gum is available, 1 otherwise.
_try_gum_backend() {
    # Opt-out via env
    if [[ "${GUM_BACKEND:-}" == "0" ]]; then
        return 1
    fi

    # System gum?
    if command -v gum &>/dev/null; then
        GUM_CMD="$(command -v gum)"
        return 0
    fi

    # Cached from previous extraction?
    if [[ -x "${GUM_CACHE_DIR}/gum" ]]; then
        GUM_CMD="${GUM_CACHE_DIR}/gum"
        export PATH="${GUM_CACHE_DIR}:${PATH}"
        return 0
    fi

    # Extract from bundled tarball
    if _extract_bundled_gum; then
        GUM_CMD="${GUM_CACHE_DIR}/gum"
        export PATH="${GUM_CACHE_DIR}:${PATH}"
        return 0
    fi

    return 1
}

# Set gum theme env vars to match existing dialogrc dark theme
_setup_gum_theme() {
    # Accent: cyan (6), text: white (7), bg: default terminal
    export GUM_CHOOSE_CURSOR_FOREGROUND="6"
    export GUM_CHOOSE_HEADER_FOREGROUND="6"
    export GUM_CHOOSE_SELECTED_FOREGROUND="0"
    export GUM_CHOOSE_SELECTED_BACKGROUND="6"
    export GUM_CHOOSE_UNSELECTED_FOREGROUND="7"
    export GUM_CONFIRM_SELECTED_FOREGROUND="0"
    export GUM_CONFIRM_SELECTED_BACKGROUND="6"
    export GUM_CONFIRM_UNSELECTED_FOREGROUND="7"
    export GUM_INPUT_CURSOR_FOREGROUND="6"
    export GUM_INPUT_PROMPT_FOREGROUND="6"
    export GUM_INPUT_WIDTH="60"
}

# Detect dialog backend
_detect_dialog_backend() {
    if _try_gum_backend; then
        DIALOG_CMD="gum"
    elif command -v dialog &>/dev/null; then
        DIALOG_CMD="dialog"
    elif command -v whiptail &>/dev/null; then
        DIALOG_CMD="whiptail"
    else
        die "Neither gum, dialog, nor whiptail found. Install one of them."
    fi
    export DIALOG_CMD
}

# Dialog dimensions
readonly DIALOG_HEIGHT=22
readonly DIALOG_WIDTH=76
readonly DIALOG_LIST_HEIGHT=14

# Initialize dialog backend
init_dialog() {
    _detect_dialog_backend
    einfo "Using dialog backend: ${DIALOG_CMD}"

    case "${DIALOG_CMD}" in
        gum)
            _setup_gum_theme
            ;;
        dialog)
            local rc_file="${DATA_DIR}/dialogrc"
            if [[ -f "${rc_file}" ]]; then
                export DIALOGRC="${rc_file}"
            fi
            ;;
    esac
}

# --- Gum helpers ---

# Backtitle bar at top of screen — matches dialog's backtitle
_gum_backtitle() {
    gum style --foreground 6 --bold --width "${DIALOG_WIDTH}" \
        "${INSTALLER_NAME} v${INSTALLER_VERSION}"
    echo ""
}

# Styled box with rounded border and cyan header — matches dialogrc theme
_gum_style_box() {
    local title="$1" text="$2"
    local body
    body=$(echo -e "${text}")
    local content
    content=$(printf '%s\n\n%s' "$(gum style --bold --foreground 6 "${title}")" "${body}")
    gum style --border rounded --border-foreground 6 \
        --padding "1 2" --width "${DIALOG_WIDTH}" \
        "${content}"
}

# --- Primitives ---

# dialog_infobox — Display a message without waiting for input (returns immediately)
dialog_infobox() {
    local title="$1" text="$2"
    if [[ "${DIALOG_CMD}" == "gum" ]]; then
        clear 2>/dev/null
        _gum_backtitle
        _gum_style_box "${title}" "${text}"
        return 0
    fi
    "${DIALOG_CMD}" --backtitle "${INSTALLER_NAME} v${INSTALLER_VERSION}" \
        --title "${title}" \
        --infobox "${text}" \
        "${DIALOG_HEIGHT}" "${DIALOG_WIDTH}"
}

# dialog_msgbox — Display a message box
dialog_msgbox() {
    local title="$1" text="$2"
    if [[ "${DIALOG_CMD}" == "gum" ]]; then
        clear 2>/dev/null
        _gum_backtitle
        _gum_style_box "${title}" "${text}"
        echo ""
        gum style --foreground 8 --italic "  Press any key to continue..."
        read -rsn1 </dev/tty
        return 0
    fi
    "${DIALOG_CMD}" --backtitle "${INSTALLER_NAME} v${INSTALLER_VERSION}" \
        --title "${title}" \
        --msgbox "${text}" \
        "${DIALOG_HEIGHT}" "${DIALOG_WIDTH}"
}

# dialog_yesno — Ask yes/no question. Returns 0=yes, 1=no
dialog_yesno() {
    local title="$1" text="$2"
    if [[ "${DIALOG_CMD}" == "gum" ]]; then
        clear 2>/dev/null
        _gum_backtitle
        _gum_style_box "${title}" "${text}"
        echo ""
        gum confirm --affirmative "Yes" --negative "No" </dev/tty
        return $?
    fi
    "${DIALOG_CMD}" --backtitle "${INSTALLER_NAME} v${INSTALLER_VERSION}" \
        --title "${title}" \
        --yesno "${text}" \
        "${DIALOG_HEIGHT}" "${DIALOG_WIDTH}"
}

# dialog_inputbox — Get text input. Prints result to stdout.
dialog_inputbox() {
    local title="$1" text="$2" default="${3:-}"
    local result
    if [[ "${DIALOG_CMD}" == "gum" ]]; then
        clear 2>/dev/null
        _gum_backtitle >/dev/tty
        _gum_style_box "${title}" "${text}" >/dev/tty
        echo "" >/dev/tty
        result=$(gum input --value "${default}" --width 60 \
            --prompt.foreground 6 --cursor.foreground 6 \
            </dev/tty) || return $?
        echo "${result}"
        return 0
    elif [[ "${DIALOG_CMD}" == "dialog" ]]; then
        result=$("${DIALOG_CMD}" --backtitle "${INSTALLER_NAME} v${INSTALLER_VERSION}" \
            --title "${title}" \
            --inputbox "${text}" \
            "${DIALOG_HEIGHT}" "${DIALOG_WIDTH}" "${default}" \
            2>&1 >/dev/tty) || return $?
    else
        result=$("${DIALOG_CMD}" --backtitle "${INSTALLER_NAME} v${INSTALLER_VERSION}" \
            --title "${title}" \
            --inputbox "${text}" \
            "${DIALOG_HEIGHT}" "${DIALOG_WIDTH}" "${default}" \
            3>&1 1>&2 2>&3) || return $?
    fi
    echo "${result}"
}

# dialog_passwordbox — Get password input
dialog_passwordbox() {
    local title="$1" text="$2"
    local result
    if [[ "${DIALOG_CMD}" == "gum" ]]; then
        clear 2>/dev/null
        _gum_backtitle >/dev/tty
        _gum_style_box "${title}" "${text}" >/dev/tty
        echo "" >/dev/tty
        result=$(gum input --password --width 60 \
            --prompt.foreground 6 --cursor.foreground 6 \
            </dev/tty) || return $?
        echo "${result}"
        return 0
    elif [[ "${DIALOG_CMD}" == "dialog" ]]; then
        result=$("${DIALOG_CMD}" --backtitle "${INSTALLER_NAME} v${INSTALLER_VERSION}" \
            --title "${title}" \
            --insecure --passwordbox "${text}" \
            "${DIALOG_HEIGHT}" "${DIALOG_WIDTH}" \
            2>&1 >/dev/tty) || return $?
    else
        result=$("${DIALOG_CMD}" --backtitle "${INSTALLER_NAME} v${INSTALLER_VERSION}" \
            --title "${title}" \
            --passwordbox "${text}" \
            "${DIALOG_HEIGHT}" "${DIALOG_WIDTH}" \
            3>&1 1>&2 2>&3) || return $?
    fi
    echo "${result}"
}

# dialog_menu — Display a menu. Prints selected tag to stdout.
# Usage: dialog_menu "title" "tag1" "desc1" "tag2" "desc2" ...
dialog_menu() {
    local title="$1"
    shift
    local -a items=("$@")
    local result

    if [[ "${DIALOG_CMD}" == "gum" ]]; then
        clear 2>/dev/null
        _gum_backtitle
        # Build "tag | description" lines for gum choose
        local -a gum_items=()
        local i
        for (( i=0; i<${#items[@]}; i+=2 )); do
            gum_items+=("${items[i]} | ${items[i+1]}")
        done
        local header
        header=$(gum style --foreground 6 --bold "  ${title}")
        result=$(printf '%s\n' "${gum_items[@]}" | \
            gum choose --header "${header}" \
                --label-delimiter " | " \
                --height "${DIALOG_LIST_HEIGHT}" \
                --no-show-help \
                --cursor "▸ " \
                --cursor.foreground 6 \
                --selected.foreground 0 --selected.background 6 \
            </dev/tty) || return $?
        echo "${result}"
        return 0
    fi

    if [[ "${DIALOG_CMD}" == "dialog" ]]; then
        result=$("${DIALOG_CMD}" --backtitle "${INSTALLER_NAME} v${INSTALLER_VERSION}" \
            --title "${title}" \
            --menu "Choose an option:" \
            "${DIALOG_HEIGHT}" "${DIALOG_WIDTH}" "${DIALOG_LIST_HEIGHT}" \
            "${items[@]}" \
            2>&1 >/dev/tty) || return $?
    else
        result=$("${DIALOG_CMD}" --backtitle "${INSTALLER_NAME} v${INSTALLER_VERSION}" \
            --title "${title}" \
            --menu "Choose an option:" \
            "${DIALOG_HEIGHT}" "${DIALOG_WIDTH}" "${DIALOG_LIST_HEIGHT}" \
            "${items[@]}" \
            3>&1 1>&2 2>&3) || return $?
    fi
    echo "${result}"
}

# dialog_radiolist — Display a radio list. Prints selected tag to stdout.
# Usage: dialog_radiolist "title" "tag1" "desc1" "on/off" "tag2" "desc2" "on/off" ...
dialog_radiolist() {
    local title="$1"
    shift
    local -a items=("$@")
    local result

    if [[ "${DIALOG_CMD}" == "gum" ]]; then
        clear 2>/dev/null
        _gum_backtitle
        # Build items and find preselected one (on/off is every 3rd element)
        local -a gum_items=()
        local preselected=""
        local i
        for (( i=0; i<${#items[@]}; i+=3 )); do
            local tag="${items[i]}" desc="${items[i+1]}" state="${items[i+2]}"
            gum_items+=("${tag} | ${desc}")
            if [[ "${state}" == "on" ]]; then
                preselected="${tag} | ${desc}"
            fi
        done
        local header
        header=$(gum style --foreground 6 --bold "  ${title}")
        local -a gum_args=(
            --header "${header}"
            --label-delimiter " | "
            --height "${DIALOG_LIST_HEIGHT}"
            --no-show-help
            --cursor "▸ "
            --cursor.foreground 6
            --selected.foreground 0 --selected.background 6
        )
        if [[ -n "${preselected}" ]]; then
            gum_args+=(--selected "${preselected}")
        fi
        result=$(printf '%s\n' "${gum_items[@]}" | \
            gum choose "${gum_args[@]}" </dev/tty) || return $?
        echo "${result}"
        return 0
    fi

    if [[ "${DIALOG_CMD}" == "dialog" ]]; then
        result=$("${DIALOG_CMD}" --backtitle "${INSTALLER_NAME} v${INSTALLER_VERSION}" \
            --title "${title}" \
            --radiolist "Select one:" \
            "${DIALOG_HEIGHT}" "${DIALOG_WIDTH}" "${DIALOG_LIST_HEIGHT}" \
            "${items[@]}" \
            2>&1 >/dev/tty) || return $?
    else
        result=$("${DIALOG_CMD}" --backtitle "${INSTALLER_NAME} v${INSTALLER_VERSION}" \
            --title "${title}" \
            --radiolist "Select one:" \
            "${DIALOG_HEIGHT}" "${DIALOG_WIDTH}" "${DIALOG_LIST_HEIGHT}" \
            "${items[@]}" \
            3>&1 1>&2 2>&3) || return $?
    fi
    echo "${result}"
}

# dialog_checklist — Display a checklist. Prints selected tags to stdout.
# Usage: dialog_checklist "title" "tag1" "desc1" "on/off" ...
dialog_checklist() {
    local title="$1"
    shift
    local -a items=("$@")
    local result

    if [[ "${DIALOG_CMD}" == "gum" ]]; then
        clear 2>/dev/null
        _gum_backtitle
        # Build items and collect preselected (on/off is every 3rd element)
        local -a gum_items=()
        local -a preselected=()
        local i
        for (( i=0; i<${#items[@]}; i+=3 )); do
            local tag="${items[i]}" desc="${items[i+1]}" state="${items[i+2]}"
            gum_items+=("${tag} | ${desc}")
            if [[ "${state}" == "on" ]]; then
                preselected+=("${tag} | ${desc}")
            fi
        done
        local header
        header=$(gum style --foreground 6 --bold "  ${title}")
        local -a gum_args=(
            --no-limit
            --header "${header}"
            --label-delimiter " | "
            --height "${DIALOG_LIST_HEIGHT}"
            --no-show-help
            --cursor "▸ "
            --cursor.foreground 6
            --selected.foreground 0 --selected.background 6
        )
        if [[ ${#preselected[@]} -gt 0 ]]; then
            local sel_joined
            sel_joined=$(printf '%s,' "${preselected[@]}")
            sel_joined="${sel_joined%,}"
            gum_args+=(--selected "${sel_joined}")
        fi
        result=$(printf '%s\n' "${gum_items[@]}" | \
            gum choose "${gum_args[@]}" \
                --output-delimiter " " \
            </dev/tty) || return $?
        echo "${result}"
        return 0
    fi

    if [[ "${DIALOG_CMD}" == "dialog" ]]; then
        result=$("${DIALOG_CMD}" --backtitle "${INSTALLER_NAME} v${INSTALLER_VERSION}" \
            --title "${title}" \
            --checklist "Select items:" \
            "${DIALOG_HEIGHT}" "${DIALOG_WIDTH}" "${DIALOG_LIST_HEIGHT}" \
            "${items[@]}" \
            2>&1 >/dev/tty) || return $?
    else
        result=$("${DIALOG_CMD}" --backtitle "${INSTALLER_NAME} v${INSTALLER_VERSION}" \
            --title "${title}" \
            --checklist "Select items:" \
            "${DIALOG_HEIGHT}" "${DIALOG_WIDTH}" "${DIALOG_LIST_HEIGHT}" \
            "${items[@]}" \
            3>&1 1>&2 2>&3) || return $?
    fi
    echo "${result}"
}

# dialog_gauge — Display a progress gauge
# Usage: dialog_gauge "title" "text" <percentage>
# Reads percentage updates from stdin (echo "50" | dialog_gauge ...)
dialog_gauge() {
    local title="$1" text="$2" percent="${3:-0}"
    if [[ "${DIALOG_CMD}" == "gum" ]]; then
        # Read percentages from stdin, render progress bar in styled box
        local line pct bar_len filled empty bar
        local width=50
        while IFS= read -r line; do
            pct="${line//[!0-9]/}"
            [[ -z "${pct}" ]] && continue
            (( pct > 100 )) && pct=100
            bar_len=$(( width * pct / 100 ))
            filled=$(printf '%*s' "${bar_len}" '' | tr ' ' '█')
            empty=$(printf '%*s' $(( width - bar_len )) '' | tr ' ' '░')
            bar="${filled}${empty} ${pct}%"
            clear 2>/dev/null
            _gum_backtitle
            _gum_style_box "${title}" "${text}\n\n${bar}"
        done
        return 0
    fi
    "${DIALOG_CMD}" --backtitle "${INSTALLER_NAME} v${INSTALLER_VERSION}" \
        --title "${title}" \
        --gauge "${text}" \
        8 "${DIALOG_WIDTH}" "${percent}"
}

# dialog_textbox — Display a text file in a scrollable box
dialog_textbox() {
    local title="$1" file="$2"
    if [[ "${DIALOG_CMD}" == "gum" ]]; then
        clear 2>/dev/null
        _gum_backtitle
        gum style --foreground 6 --bold "  ${title}"
        echo ""
        gum pager < "${file}" </dev/tty
        return 0
    fi
    "${DIALOG_CMD}" --backtitle "${INSTALLER_NAME} v${INSTALLER_VERSION}" \
        --title "${title}" \
        --textbox "${file}" \
        "${DIALOG_HEIGHT}" "${DIALOG_WIDTH}"
}

# dialog_prgbox — Run a command and show output in a box
dialog_prgbox() {
    local title="$1"
    shift
    local cmd
    cmd=$(printf '%q ' "$@")
    if [[ "${DIALOG_CMD}" == "gum" ]]; then
        # Run command, capture output, show in pager (like whiptail fallback)
        local output
        output=$("$@" 2>&1) || true
        clear 2>/dev/null
        _gum_backtitle
        gum style --foreground 6 --bold "  ${title}"
        echo ""
        echo "${output}" | gum pager </dev/tty
        return 0
    elif [[ "${DIALOG_CMD}" == "dialog" ]]; then
        "${DIALOG_CMD}" --backtitle "${INSTALLER_NAME} v${INSTALLER_VERSION}" \
            --title "${title}" \
            --prgbox "${cmd}" \
            "${DIALOG_HEIGHT}" "${DIALOG_WIDTH}"
    else
        # whiptail doesn't have prgbox, fall back to msgbox
        local output
        output=$("$@" 2>&1) || true
        dialog_msgbox "${title}" "${output}"
    fi
}

# --- Wizard navigation ---

# Navigation stack for wizard
declare -a _WIZARD_SCREENS=()
_WIZARD_INDEX=0

# register_wizard_screens — Set the ordered list of screen functions
register_wizard_screens() {
    _WIZARD_SCREENS=("$@")
    _WIZARD_INDEX=0
}

# run_wizard — Execute the wizard, handling back/next/abort navigation
run_wizard() {
    local total=${#_WIZARD_SCREENS[@]}

    if [[ ${total} -eq 0 ]]; then
        die "No wizard screens registered"
    fi

    while (( _WIZARD_INDEX < total )); do
        local screen_func="${_WIZARD_SCREENS[${_WIZARD_INDEX}]}"

        elog "Running wizard screen ${_WIZARD_INDEX}/${total}: ${screen_func}"

        # Clear terminal to prevent flicker between screens
        clear 2>/dev/null

        local rc=0
        "${screen_func}" || rc=$?

        case ${rc} in
            "${TUI_NEXT}"|0)
                (( _WIZARD_INDEX++ )) || true
                ;;
            "${TUI_BACK}"|1)
                if (( _WIZARD_INDEX > 0 )); then
                    (( _WIZARD_INDEX-- )) || true
                else
                    ewarn "Already at first screen"
                fi
                ;;
            "${TUI_ABORT}"|2)
                if dialog_yesno "Abort Installation" \
                    "Are you sure you want to abort the installation?"; then
                    die "Installation aborted by user"
                fi
                ;;
            *)
                eerror "Unknown return code ${rc} from ${screen_func}"
                ;;
        esac
    done

    einfo "Wizard completed"
}

# dialog_nav_menu — Menu with Back/Abort options built-in
# Returns selection via stdout, handles Cancel=back
dialog_nav_menu() {
    local title="$1"
    shift

    local result
    result=$(dialog_menu "${title}" "$@") || {
        # Cancel pressed — treat as back
        return "${TUI_BACK}"
    }
    echo "${result}"
    return "${TUI_NEXT}"
}
