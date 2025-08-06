#!/usr/bin/env bash
set -e

OVPN_VER=2.6.14
PATCH_URL="https://github.com/luzrain/openvpn-xorpatch/releases/download/v${OVPN_VER}/openvpn-${OVPN_VER}.tar.gz"

for dir in padavan-ng/trunk/user/openvpn \
           padavan-ng/trunk/user/openvpn-openssl
do
    mf="$dir/Makefile"         || continue
    [[ -f $mf ]] || continue

    echo ">> patching $mf"
    # 1. подменяем архив и имя каталога
    sed -i "s|^SRC_NAME=.*|SRC_NAME=openvpn-${OVPN_VER}|" "$mf"
    sed -i "s|^SRC_URL=.*|SRC_URL=${PATCH_URL}|"          "$mf"

    # 2. добавляем --enable-xor-patch (оставляем остальные опции автора)
    sed -i '/--enable-small/ s|$| \\\
\t\t--enable-xor-patch|' "$mf"
done

# 3. оригинальный патч больше не нужен
rm -f padavan-ng/trunk/user/openvpn*/openvpn-orig.patch || true
