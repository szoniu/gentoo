#!/usr/bin/env bash
# Uruchamia wszystkie testy i zbiera wyniki plików oraz asercji.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Mapa plik:narzędzie dla testów wymagających rozszerzeń GNU.
GNU_REQUIREMENTS=("tests/test_infer_config.sh:sed" "tests/test_resume.sh:stat")

include_shellcheck=true
for option in "$@"; do
    case "${option}" in
        --no-shellcheck) include_shellcheck=false ;;
        *) echo "Nieznana opcja: ${option}" >&2; exit 2 ;;
    esac
done

cd "${SCRIPT_DIR}"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TEMP_DIR}"' EXIT
mkdir -p "${TEMP_DIR}/bin"
for tool in sed stat; do
    if ! "${tool}" --version 2>/dev/null | grep -q GNU; then
        if command -v "g${tool}" >/dev/null 2>&1; then
            ln -s "$(command -v "g${tool}")" "${TEMP_DIR}/bin/${tool}"
        fi
    fi
done
export PATH="${TEMP_DIR}/bin:${PATH}"

gnu_sed=false
gnu_stat=false
if sed --version 2>/dev/null | grep -q GNU; then gnu_sed=true; fi
if stat --version 2>/dev/null | grep -q GNU; then gnu_stat=true; fi

files=(tests/test_*.sh)
if ${include_shellcheck}; then files+=(tests/shellcheck.sh); fi
passed=0
failed=0
skipped=0
assertions_passed=0
assertions_failed=0

for file in "${files[@]}"; do
    reason=""
    for requirement in "${GNU_REQUIREMENTS[@]}"; do
        if [[ ${requirement%:*} == "${file}" ]]; then
            tool="${requirement##*:}"
            if [[ ${tool} == sed && ${gnu_sed} == false ]] ||
               [[ ${tool} == stat && ${gnu_stat} == false ]]; then
                reason="wymaga GNU ${tool}"
            fi
        fi
    done
    if [[ ${file} == tests/shellcheck.sh ]] && ! command -v shellcheck >/dev/null 2>&1; then
        reason="brak shellcheck"
    fi
    if [[ -n ${reason} ]]; then
        printf '%s: SKIP (%s) [0 s]\n' "${file}" "${reason}"
        (( skipped++ )) || true
        continue
    fi

    log="${TEMP_DIR}/$(basename "${file}").log"
    start=${SECONDS}
    code=0
    bash "${file}" >"${log}" 2>&1 || code=$?
    elapsed=$((SECONDS - start))
    counts=""
    while read -r label count; do
        [[ ${count} =~ ^[0-9]+$ ]] || continue
        counts+=" ${label} ${count}"
        if [[ ${label} == Passed: ]]; then
            assertions_passed=$((assertions_passed + count))
        else
            assertions_failed=$((assertions_failed + count))
        fi
    done < <(awk '/^[[:space:]]*(Passed|Failed):/ {print $1, $2}' "${log}")

    if [[ ${code} -ne 0 ]]; then
        status=FAIL
        (( failed++ )) || true
    elif grep -q '^SKIP:' "${log}" && ! grep -q '^[[:space:]]*Passed:' "${log}"; then
        status=SKIP
        (( skipped++ )) || true
    else
        status=PASS
        (( passed++ )) || true
    fi
    printf '%s: %s [%s s]%s\n' "${file}" "${status}" "${elapsed}" "${counts}"
    if [[ ${status} == FAIL ]]; then
        tail -n 20 "${log}" | sed 's/^/    /'
    elif [[ ${status} == SKIP ]]; then
        grep '^SKIP:' "${log}" | sed 's/^/    /'
    fi
done

echo ""
echo "=== Results ==="
echo "Pliki: PASS=${passed} FAIL=${failed} SKIP=${skipped}"
echo "Asercje: Passed: ${assertions_passed} Failed: ${assertions_failed}"
if [[ ${failed} -gt 0 ]]; then exit 1; fi
exit 0
