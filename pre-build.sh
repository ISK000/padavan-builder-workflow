#!/usr/bin/env bash
set -e

OVPN_VER=2.6.14
PATCH_URL="https://github.com/luzrain/openvpn-xorpatch/releases/download/v${OVPN_VER}/openvpn-${OVPN_VER}.tar.gz"

for dir in padavan-ng/trunk/user/openvpn \
           padavan-ng/trunk/user/openvpn-openssl; do
    mf="$dir/Makefile"
    [[ -f $mf ]] || continue
    echo ">> patching $mf"

    # 1. архив и каталог
    sed -i "s|^SRC_NAME=.*|SRC_NAME=openvpn-${OVPN_VER}|" "$mf"
    sed -i "s|^SRC_URL=.*|SRC_URL=${PATCH_URL}|"          "$mf"

    # 2. удаляем ВСЕ старые вставки xor-patch и лишние обратные слэши
    sed -i '/--enable-xor-patch/d' "$mf"
    sed -i '/^[[:space:]]*\\[[:space:]]*$/d' "$mf"

    # 3. перезаписываем строку с --enable-small одной корректной версией
    sed -i 's|--enable-small[[:space:]]*\\|--enable-small --enable-xor-patch \\|' "$mf"

    # 4. комментируем возможный openvpn-orig.patch
    sed -i '/openvpn-orig\.patch/ s|^[[:space:]]*|# &|' "$mf"
done

# 5. гарантируем повторную загрузку архива
rm -f padavan-ng/trunk/dl/openvpn-${OVPN_VER}.tar.* || true
