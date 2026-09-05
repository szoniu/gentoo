#!/usr/bin/env bash
# tests/test_local_scope.sh — Catch references to a `local` variable from OUTSIDE
# the function that declares it.
#
# Why this exists: `kernel_install()` referenced ${cpuinfo}, a variable declared
# `local` in `_patch_kernel_config()`. Bash scoping is dynamic, but the call goes
# the other way (kernel_install -> _patch_kernel_config), so the name was unbound
# and `set -u` killed the entire kernel phase — the installer finished with no
# kernel and no bootloader. shellcheck cannot see this: SC2154 is file-scoped, so
# an assignment anywhere in the file counts as "assigned".
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# lib/protection.sh guards every module against direct execution
export _GENTOO_INSTALLER=1
export LIB_DIR="${SCRIPT_DIR}/lib"

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

echo "=== Test: local variable scope leaks ==="

# _scope_violations <file> — print "line:var" for every reference to a name that
# is only ever declared `local`, made outside any function declaring it.
#
# Deliberately conservative — a name is checked only when ALL of these hold:
#   - it is declared `local` at least once in the file,
#   - it is never assigned at top level, never `export`ed, never `declare -g`,
#   - it is not a known config variable (CONFIG_VARS, set by the TUI).
# Anything else is skipped rather than reported, so this test stays free of the
# false positives that would make people ignore it.
_scope_violations() {
    local file="$1"
    awk '
        # collect_refs — harvest ${var} AND $var references from one line
        function collect_refs(s,   v) {
            while (match(s, /\$\{?[a-zA-Z_][a-zA-Z0-9_]*/)) {
                v = substr(s, RSTART + 1, RLENGTH - 1)
                sub(/^\{/, "", v)
                refline[++nref] = NR; refvar[nref] = v; reffn[nref] = cur
                s = substr(s, RSTART + RLENGTH)
            }
        }

        # --- embedded scripts: bash -c '"'"'...'"'"' spanning several lines
        # Their body is a separate program with its own scope, and it sits at
        # column 0, so without this it looked like top-level code referencing
        # undeclared names. Recognised narrowly (a bash -c line with an odd
        # number of quotes) so that an apostrophe in a comment cannot open a
        # region by accident.
        sq != 0 {
            n = gsub(/'"'"'/, "&")
            if (n % 2 == 1) sq = 0
            next
        }
        /bash -c '"'"'/ {
            n = gsub(/'"'"'/, "&")
            if (n % 2 == 1) { sq = 1; next }
        }

        # --- heredocs
        # A quoted delimiter (<<'"'"'EOF'"'"') means the body is inert text — skip it whole.
        # An UNQUOTED delimiter (<<EOF) is expanded by bash at runtime, so an
        # out-of-scope local in there dies under set -u exactly like real code:
        # skip the structural parsing (a "}" in the body must not close the
        # function) but still harvest the references.
        heredoc != "" {
            if ($0 ~ "^[[:space:]]*" heredoc "[[:space:]]*$") { heredoc = ""; next }
            if (!hd_quoted) collect_refs($0)
            next
        }
        match($0, /<<-?[[:space:]]*['"'"'"]?[A-Za-z_][A-Za-z0-9_]*/) {
            tag = substr($0, RSTART, RLENGTH)
            hd_quoted = (tag ~ /['"'"'"]/)
            sub(/^<<-?[[:space:]]*/, "", tag); gsub(/['"'"'"]/, "", tag)
            heredoc = tag
            # the opening line itself is still code — fall through
        }

        # --- function boundaries: "name() {" at column 0, closed by "}" at column 0
        # Known limitation: a one-line definition (name() { ...; }) has its body
        # skipped with the header. The only ones in the tree are the four log
        # wrappers in data/fprintd-pam-setup.sh, which use $* — processing the
        # rest of the line would instead leave `cur` open past the closing brace
        # and risk attributing top-level code to that function, so the trade is
        # deliberate: no false positives beats covering four trivial one-liners.
        /^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{/ {
            fname = $0; sub(/\(\).*/, "", fname)
            cur = fname; next
        }
        /^\}/ { cur = ""; next }

        # --- declarations
        {
            line = $0
            # local declarations (may declare several names: local a b c=1)
            if (match(line, /^[[:space:]]*local[[:space:]]+/)) {
                rest = substr(line, RSTART + RLENGTH)
                n = split(rest, toks, /[[:space:]]+/)
                for (i = 1; i <= n; i++) {
                    v = toks[i]
                    if (v ~ /^-/) continue           # local -a / -n flags
                    sub(/=.*$/, "", v)
                    if (v !~ /^[a-zA-Z_][a-zA-Z0-9_]*$/) continue
                    islocal[v] = 1
                    lo[v] = lo[v] " " cur            # a name may be local in several functions
                }
            }
            # names bound by read/for behave like locals of the enclosing scope.
            # Must match indented and IFS-prefixed forms — the repo writes
            # "    read -r a b c" and "IFS=: read -r x y", never at column 0.
            if (match(line, /(^|[[:space:]]|[|;&])read[[:space:]]+/)) {
                rest = line; sub(/^.*[^a-zA-Z0-9_]read[[:space:]]+|^read[[:space:]]+/, "", rest)
                sub(/<<.*$/, "", rest); sub(/[<>].*$/, "", rest); sub(/;.*$/, "", rest)
                n = split(rest, toks, /[[:space:]]+/)
                for (i = 1; i <= n; i++) {
                    v = toks[i]
                    if (v ~ /^-/ || v ~ /^[$"'"'"']/) continue
                    if (v !~ /^[a-zA-Z_][a-zA-Z0-9_]*$/) continue
                    islocal[v] = 1; lo[v] = lo[v] " " cur
                }
            }
            if (match(line, /^[[:space:]]*for[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]+in/)) {
                v = line; sub(/^[[:space:]]*for[[:space:]]+/, "", v); sub(/[[:space:]]+in.*$/, "", v)
                if (v ~ /^[a-zA-Z_][a-zA-Z0-9_]*$/) { islocal[v] = 1; lo[v] = lo[v] " " cur }
            }
            # anything that makes the name global: top-level assign, : "${V:=}", export, declare -g
            if (cur == "" && match(line, /^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*=/)) {
                v = line; sub(/=.*$/, "", v); gsub(/[[:space:]]/, "", v)
                isglobal[v] = 1
            }
            if (cur == "" && match(line, /\$\{[a-zA-Z_][a-zA-Z0-9_]*:?=/)) {
                v = substr(line, RSTART + 2, RLENGTH - 2); sub(/:?=$/, "", v)
                isglobal[v] = 1
            }
            if (line ~ /^[[:space:]]*(export|readonly)[[:space:]]/ || line ~ /declare[[:space:]]+-[a-zA-Z]*g/) {
                n = split(line, toks, /[[:space:]]+/)
                for (i = 1; i <= n; i++) { v = toks[i]; sub(/=.*$/, "", v)
                    if (v ~ /^[a-zA-Z_][a-zA-Z0-9_]*$/) isglobal[v] = 1 }
            }
        }

        # --- every reference, with its enclosing function
        { collect_refs($0) }

        END {
            for (i = 1; i <= nref; i++) {
                v = refvar[i]
                if (!islocal[v] || isglobal[v]) continue
                ok = 0
                n = split(lo[v], owners, /[[:space:]]+/)
                for (j = 1; j <= n; j++) if (owners[j] != "" && owners[j] == reffn[i]) ok = 1
                if (!ok) print refline[i] ":" v
            }
        }
    ' "${file}" | sort -u
}

# CONFIG_VARS are set by the TUI and exported at runtime — never a scope leak.
source "${SCRIPT_DIR}/lib/constants.sh" 2>/dev/null || true
_is_config_var() {
    local needle="$1" v
    for v in "${CONFIG_VARS[@]:-}"; do [[ "${v}" == "${needle}" ]] && return 0; done
    return 1
}

violations=""
count=0
for f in "${SCRIPT_DIR}"/lib/*.sh "${SCRIPT_DIR}"/tui/*.sh "${SCRIPT_DIR}"/data/*.sh "${SCRIPT_DIR}/install.sh"; do
    while IFS= read -r hit; do
        [[ -z "${hit}" ]] && continue
        var="${hit#*:}"
        _is_config_var "${var}" && continue
        violations+="  ${f#"${SCRIPT_DIR}/"}:${hit}"$'\n'
        (( count++ )) || true
    done < <(_scope_violations "${f}")
done

[[ -n "${violations}" ]] && printf '%s' "${violations}"
assert_eq "no local-variable scope leaks" "0" "${count}"

# Regression guard for the exact bug: kernel_install must declare its own cpuinfo
kernel_install_declares=0
awk '/^kernel_install\(\)/ {inf=1} inf && /^[[:space:]]*local cpuinfo=/ {print "yes"; exit} inf && /^\}/ {exit}' \
    "${SCRIPT_DIR}/lib/kernel.sh" | grep -q yes && kernel_install_declares=1
assert_eq "kernel_install() declares its own cpuinfo" "1" "${kernel_install_declares}"

echo ""
echo "=== Results ==="
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"

[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
