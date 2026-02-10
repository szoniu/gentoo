#!/usr/bin/env bash
# tui/desktop_config.sh — KDE Plasma + desktop options
source "${LIB_DIR}/protection.sh"

screen_desktop_config() {
    local info_text=""
    info_text+="The following desktop environment will be installed:\n\n"
    info_text+="  KDE Plasma Desktop (kde-plasma/plasma-meta)\n"
    info_text+="  Display Manager: SDDM\n"
    info_text+="  Audio: PipeWire (with PulseAudio compatibility)\n"
    info_text+="  Networking: NetworkManager\n\n"
    info_text+="Additional KDE applications can be selected below."

    dialog_msgbox "Desktop Environment" "${info_text}" || return "${TUI_ABORT}"

    # Extra desktop packages
    local extras
    extras=$(dialog_checklist "KDE Applications" \
        "konsole"      "Terminal emulator"        "on" \
        "dolphin"      "File manager"             "on" \
        "kate"         "Text editor"              "on" \
        "firefox-bin"  "Firefox web browser"      "on" \
        "gwenview"     "Image viewer"             "on" \
        "okular"       "Document viewer"          "on" \
        "ark"          "Archive manager"          "on" \
        "spectacle"    "Screenshot tool"          "on" \
        "kcalc"        "Calculator"               "off" \
        "kwalletmanager" "Wallet manager"         "off" \
        "elisa"        "Music player"             "off" \
        "vlc"          "VLC media player"         "off" \
        "libreoffice"  "LibreOffice suite"        "off" \
        "thunderbird"  "Thunderbird email client" "off") \
        || return "${TUI_BACK}"

    DESKTOP_EXTRAS="${extras}"
    export DESKTOP_EXTRAS

    einfo "Desktop extras: ${DESKTOP_EXTRAS}"
    return "${TUI_NEXT}"
}
