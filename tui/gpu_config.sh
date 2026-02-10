#!/usr/bin/env bash
# tui/gpu_config.sh — GPU driver configuration
source "${LIB_DIR}/protection.sh"

screen_gpu_config() {
    local vendor="${GPU_VENDOR:-unknown}"
    local device="${GPU_DEVICE_NAME:-Unknown GPU}"

    local info_text=""
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

    # Let user confirm or override
    local choice
    choice=$(dialog_menu "GPU Driver" \
        "auto"    "Use recommended driver (${GPU_DRIVER:-auto})" \
        "nvidia"  "NVIDIA proprietary drivers" \
        "amdgpu"  "AMD open source (amdgpu)" \
        "intel"   "Intel open source" \
        "none"    "No GPU driver (framebuffer only)") \
        || return "${TUI_BACK}"

    case "${choice}" in
        auto)
            # Keep detected values
            ;;
        nvidia)
            GPU_VENDOR="nvidia"
            GPU_DRIVER="nvidia-drivers"
            VIDEO_CARDS="nvidia"

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
            ;;
        intel)
            GPU_VENDOR="intel"
            GPU_DRIVER="intel-media-driver"
            VIDEO_CARDS="intel"
            GPU_USE_NVIDIA_OPEN="no"
            ;;
        none)
            GPU_VENDOR="none"
            GPU_DRIVER="none"
            VIDEO_CARDS="fbdev"
            GPU_USE_NVIDIA_OPEN="no"
            ;;
    esac

    export GPU_VENDOR GPU_DRIVER VIDEO_CARDS GPU_USE_NVIDIA_OPEN

    einfo "GPU driver: ${GPU_DRIVER}, VIDEO_CARDS=${VIDEO_CARDS}"
    return "${TUI_NEXT}"
}
