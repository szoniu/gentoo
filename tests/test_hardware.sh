#!/usr/bin/env bash
# tests/test_hardware.sh — Test hardware detection with mock data
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export _GENTOO_INSTALLER=1
export LIB_DIR="${SCRIPT_DIR}/lib"
export DATA_DIR="${SCRIPT_DIR}/data"
export LOG_FILE="/tmp/gentoo-test-hardware.log"
: > "${LOG_FILE}"

source "${LIB_DIR}/constants.sh"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/utils.sh"
source "${DATA_DIR}/cpu_march_database.sh"
source "${DATA_DIR}/gpu_database.sh"

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

echo "=== Test: CPU March Database ==="

# Test known CPU entries
assert_eq "AMD Zen 3 Vermeer" "znver3" "${CPU_MARCH_MAP["AuthenticAMD:25:33:33"]:-unknown}"
assert_eq "AMD Zen 4 Genoa" "znver4" "${CPU_MARCH_MAP["AuthenticAMD:25:97:97"]:-unknown}"
assert_eq "Intel Alder Lake" "alderlake" "${CPU_MARCH_MAP["GenuineIntel:6:151:151"]:-unknown}"
assert_eq "Intel Skylake" "skylake" "${CPU_MARCH_MAP["GenuineIntel:6:78:78"]:-unknown}"

# Intel Core Ultra / Core Series 3 era. These four are the ones a wrong guess
# actually hurts, because their model numbers are not ordered by generation.
assert_eq "Intel Arrow Lake-H (0xC5)" "arrowlake" "${CPU_MARCH_MAP["GenuineIntel:6:197:197"]:-unknown}"
assert_eq "Intel Panther Lake-L (0xCC)" "pantherlake" "${CPU_MARCH_MAP["GenuineIntel:6:204:204"]:-unknown}"
assert_eq "Intel Panther Lake-R (0xE5)" "pantherlake" "${CPU_MARCH_MAP["GenuineIntel:6:229:229"]:-unknown}"
assert_eq "Intel Wildcat Lake-L (0xD5, Framework 12)" "pantherlake" "${CPU_MARCH_MAP["GenuineIntel:6:213:213"]:-unknown}"
# Arrow Lake-U is Meteor Lake silicon. Naming it arrowlake would let GCC emit
# AVX-IFMA / AVX-VNNI-INT8 / CMPCCXADD that this CPU does not implement.
assert_eq "Intel Arrow Lake-U (0xB5) is NOT arrowlake" "meteorlake" "${CPU_MARCH_MAP["GenuineIntel:6:181:181"]:-unknown}"

echo ""
echo "=== Test: CPU March Fallback Ladder (unknown models) ==="

assert_eq "Wildcat Lake resolves via table" "pantherlake" "$(lookup_cpu_march GenuineIntel 6 213)"
# 0xB5=181 sits BELOW Raptor Lake's 0xBA=186 — proof the ladder is not a
# simple "bigger model = newer CPU" rule.
assert_eq "Ladder: model 182 -> meteorlake" "meteorlake" "$(lookup_cpu_march GenuineIntel 6 182)"
assert_eq "Ladder: model 187 -> raptorlake" "raptorlake" "$(lookup_cpu_march GenuineIntel 6 187)"
assert_eq "Ladder: model 200 -> arrowlake" "arrowlake" "$(lookup_cpu_march GenuineIntel 6 200)"
assert_eq "Ladder: model 210 -> pantherlake" "pantherlake" "$(lookup_cpu_march GenuineIntel 6 210)"
# Beyond everything we can name, stop guessing and let GCC read CPUID.
assert_eq "Ladder: unknown future Intel -> native" "native" "$(lookup_cpu_march GenuineIntel 6 250)"
assert_eq "Ladder: unknown future AMD -> native" "native" "$(lookup_cpu_march AuthenticAMD 27 1)"
assert_eq "Ladder: known AMD family 25 -> znver3" "znver3" "$(lookup_cpu_march AuthenticAMD 25 200)"
assert_eq "Unknown vendor -> x86-64" "x86-64" "$(lookup_cpu_march SomethingElse 6 1)"

echo ""
echo "=== Test: NVIDIA GPU Generation Detection ==="

assert_eq "Turing device" "turing" "$(nvidia_generation "1e82")"
assert_eq "Ampere device" "ampere" "$(nvidia_generation "2204")"
assert_eq "Ada device" "ada" "$(nvidia_generation "2704")"
# AD102 = RTX 4090. The old 0x2700 threshold called it Ampere (Forgejo #3).
assert_eq "Ada AD102 / RTX 4090 (2684)" "ada" "$(nvidia_generation "2684")"
assert_eq "Ampere GA107 (25a0) still ampere" "ampere" "$(nvidia_generation "25a0")"
assert_eq "Blackwell device" "blackwell" "$(nvidia_generation "2904")"
assert_eq "Pre-Turing device" "pre-turing" "$(nvidia_generation "1b80")"

echo ""
echo "=== Test: NVIDIA Open Kernel Support ==="

nvidia_supports_open_kernel "2704" && result="yes" || result="no"
assert_eq "Ada supports open kernel" "yes" "${result}"

nvidia_supports_open_kernel "1b80" && result="yes" || result="no"
assert_eq "Pascal doesn't support open kernel" "no" "${result}"

nvidia_prefers_open_kernel "2704" && result="yes" || result="no"
assert_eq "Ada prefers open kernel" "yes" "${result}"

nvidia_prefers_open_kernel "1e82" && result="yes" || result="no"
assert_eq "Turing doesn't prefer open kernel" "no" "${result}"

echo ""
echo "=== Test: GPU Recommendation ==="

rec=$(get_gpu_recommendation "10de" "2704")
assert_eq "NVIDIA recommendation" "nvidia-drivers|nvidia|yes" "${rec}"

rec=$(get_gpu_recommendation "1002" "7340")
assert_eq "AMD recommendation" "amdgpu|amdgpu radeonsi|no" "${rec}"

rec=$(get_gpu_recommendation "8086" "9a49")
assert_eq "Intel recommendation" "intel-media-driver|intel|no" "${rec}"

# Cleanup
rm -f "${LOG_FILE}"

echo ""
echo "=== Results ==="
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"

[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
