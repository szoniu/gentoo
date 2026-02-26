#!/usr/bin/env bash
# tui/gpu_config.sh — GPU driver configuration
source "${LIB_DIR}/protection.sh"

screen_gpu_config() {
    local vendor="${GPU_VENDOR:-unknown}"
    local device="${GPU_DEVICE_NAME:-Unknown GPU}"

    local info_text=""

    if [[ "${HYBRID_GPU:-no}" == "yes" ]]; then
        info_text+="Hybrid GPU detected:\n"
        info_text+="  iGPU: ${IGPU_DEVICE_NAME:-unknown} (${IGPU_VENDOR:-unknown})\n"
        info_text+="  dGPU: ${DGPU_DEVICE_NAME:-unknown} (${DGPU_VENDOR:-unknown})\n\n"
        info_text+="PRIME render offload: use 'prime-run' for dGPU\n"
        info_text+="VIDEO_CARDS: ${VIDEO_CARDS:-auto}\n"
        if [[ "${GPU_USE_NVIDIA_OPEN:-no}" == "yes" ]]; then
            info_text+="NVIDIA open kernel module: supported (Turing+)\n"
        fi
    else
        info_text+="Detected GPU: ${device}\n"
        info_text+="Vendor: ${vendor}\n\n"

        case "${vendor}" in
            nvidia)
                info_text+="Recommended: x11-drivers/nvidia-drivers\n"
                info_text+="VIDEO_CARDS: nvidia\n"
                if [[ "${GPU_USE_NVIDIA_OPEN:-no}" == "yes" ]]; then
                    info_text+="NVIDIA open kernel module: supported (Turing+)\n"
                fi
                ;;
            amd)
                info_text+="Recommended: AMDGPU (built into kernel)\n"
                info_text+="VIDEO_CARDS: amdgpu radeonsi\n"
                ;;
            intel)
                info_text+="Recommended: Intel media driver\n"
                info_text+="VIDEO_CARDS: intel\n"
                ;;
            *)
                info_text+="No specific GPU driver detected.\n"
                info_text+="Using generic framebuffer.\n"
                ;;
        esac
    fi

    # Let user confirm or override
    local auto_label="Use recommended driver"
    if [[ "${HYBRID_GPU:-no}" == "yes" ]]; then
        auto_label="Use hybrid PRIME (${IGPU_VENDOR:-?} + ${DGPU_VENDOR:-?})"
    else
        auto_label="Use recommended driver (${GPU_DRIVER:-auto})"
    fi

    local choice
    choice=$(dialog_menu "GPU Driver" \
        "auto"    "${auto_label}" \
        "nvidia"  "NVIDIA proprietary drivers" \
        "amdgpu"  "AMD open source (amdgpu)" \
        "intel"   "Intel open source" \
        "none"    "No GPU driver (framebuffer only)") \
        || return "${TUI_BACK}"

    case "${choice}" in
        auto)
            # Keep detected values — including hybrid if detected
            ;;
        nvidia)
            GPU_VENDOR="nvidia"
            GPU_DRIVER="nvidia-drivers"
            if [[ "${HYBRID_GPU:-no}" != "yes" ]]; then
                VIDEO_CARDS="nvidia"
            fi

            # Ask about open kernel module
            if [[ "${GPU_USE_NVIDIA_OPEN:-no}" == "yes" ]]; then
                dialog_yesno "NVIDIA Open Kernel" \
                    "Your GPU supports the open-source NVIDIA kernel module.\n\n\
This is recommended for Turing (RTX 20xx) and newer GPUs.\n\n\
Use the open kernel module?" \
                    && GPU_USE_NVIDIA_OPEN="yes" \
                    || GPU_USE_NVIDIA_OPEN="no"
            fi
            ;;
        amdgpu)
            GPU_VENDOR="amd"
            GPU_DRIVER="amdgpu"
            VIDEO_CARDS="amdgpu radeonsi"
            GPU_USE_NVIDIA_OPEN="no"
            HYBRID_GPU="no"
            IGPU_VENDOR="" ; IGPU_DEVICE_NAME=""
            DGPU_VENDOR="" ; DGPU_DEVICE_NAME=""
            ;;
        intel)
            GPU_VENDOR="intel"
            GPU_DRIVER="intel-media-driver"
            VIDEO_CARDS="intel"
            GPU_USE_NVIDIA_OPEN="no"
            HYBRID_GPU="no"
            IGPU_VENDOR="" ; IGPU_DEVICE_NAME=""
            DGPU_VENDOR="" ; DGPU_DEVICE_NAME=""
            ;;
        none)
            GPU_VENDOR="none"
            GPU_DRIVER="none"
            VIDEO_CARDS="fbdev"
            GPU_USE_NVIDIA_OPEN="no"
            HYBRID_GPU="no"
            IGPU_VENDOR="" ; IGPU_DEVICE_NAME=""
            DGPU_VENDOR="" ; DGPU_DEVICE_NAME=""
            ;;
    esac

    export GPU_VENDOR GPU_DRIVER VIDEO_CARDS GPU_USE_NVIDIA_OPEN
    export HYBRID_GPU IGPU_VENDOR IGPU_DEVICE_NAME DGPU_VENDOR DGPU_DEVICE_NAME

    einfo "GPU driver: ${GPU_DRIVER}, VIDEO_CARDS=${VIDEO_CARDS}"
    [[ "${HYBRID_GPU}" == "yes" ]] && einfo "Hybrid GPU: ${IGPU_VENDOR} + ${DGPU_VENDOR} (PRIME)"
    return "${TUI_NEXT}"
}
