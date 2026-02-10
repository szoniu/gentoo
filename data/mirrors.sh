#!/usr/bin/env bash
# mirrors.sh — Gentoo mirror list
source "${LIB_DIR}/protection.sh"

# Mirror list: "url|name|country"
readonly -a GENTOO_MIRRORS=(
    "https://distfiles.gentoo.org|Gentoo CDN (default)|Global"
    "https://gentoo.osuosl.org|OSU Open Source Lab|USA"
    "https://mirrors.rit.edu/gentoo|RIT|USA"
    "https://mirrors.lug.mtu.edu/gentoo|Michigan Tech|USA"
    "https://ftp.fau.de/gentoo|FAU Erlangen|Germany"
    "https://ftp-stud.hs-esslingen.de/pub/Mirrors/gentoo|HS Esslingen|Germany"
    "https://ftp.snt.utwente.nl/pub/os/linux/gentoo|SNT Twente|Netherlands"
    "https://mirror.bytemark.co.uk/gentoo|Bytemark|UK"
    "https://ftp.jaist.ac.jp/pub/Linux/Gentoo|JAIST|Japan"
    "https://ftp.iij.ad.jp/pub/linux/gentoo|IIJ|Japan"
    "https://mirror.aarnet.edu.au/pub/gentoo|AARNet|Australia"
    "https://gentoo.c3sl.ufpr.br|C3SL UFPR|Brazil"
    "https://mirrors.tuna.tsinghua.edu.cn/gentoo|TUNA Tsinghua|China"
    "https://mirrors.ustc.edu.cn/gentoo|USTC|China"
    "https://mirror.yandex.ru/gentoo-distfiles|Yandex|Russia"
    "https://ftp.linux.cz/pub/linux/gentoo|linux.cz|Czech Republic"
    "https://ftp.fi.muni.cz/pub/linux/gentoo|MUNI|Czech Republic"
    "https://mirror.netcologne.de/gentoo|NetCologne|Germany"
    "https://ftp.agdsn.de/gentoo|AGDSN|Germany"
    "https://ftp.halifax.rwth-aachen.de/gentoo|RWTH Aachen|Germany"
)

# get_mirror_list_for_dialog — Format mirrors for dialog menu
# Outputs pairs: "url" "description"
get_mirror_list_for_dialog() {
    local entry
    for entry in "${GENTOO_MIRRORS[@]}"; do
        local url name country
        IFS='|' read -r url name country <<< "${entry}"
        echo "${url}"
        echo "${name} (${country})"
    done
}

# get_default_mirror — Return the default mirror URL
get_default_mirror() {
    echo "https://distfiles.gentoo.org"
}
