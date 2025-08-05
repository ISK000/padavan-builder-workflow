#!/usr/bin/env bash
set -e                      # останавливаемся при любой ошибке

PATCH_DIR="${GITHUB_WORKSPACE}/patches"   # туда мы загрузили diff’ы

# Переходим в исходники OpenVPN внутри Padavan
cd padavan-ng/trunk/user/openvpn

# Применяем все diff'ы по порядку
for p in "${PATCH_DIR}"/0*-tunnelblick-openvpn_xorpatch-*.diff; do
    echo ">>> Патчим $(basename "$p")"
    patch -p1 -t < "$p"
done
