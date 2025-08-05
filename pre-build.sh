#!/usr/bin/env bash
set -e

PATCH_DIR="${GITHUB_WORKSPACE}/patches"

# !!! Переходим прямо в исходники OpenVPN
cd padavan-ng/trunk/user/openvpn/openvpn-2.6.13

for p in "${PATCH_DIR}"/0*-tunnelblick-openvpn_xorpatch-*.diff; do
    echo ">>> Патчим $(basename "$p")"
    # -p1   – срезаем "openvpn-2.6.x.old/"
    # -t    – падаем, если хунк не применился
    patch -p1 -t < "$p"
done
