#!/usr/bin/env bash
set -e

OVPN_VER=2.6.14
PATCH_URL="https://github.com/luzrain/openvpn-xorpatch/releases/download/v${OVPN_VER}/openvpn-${OVPN_VER}.tar.gz"

for dir in padavan-ng/trunk/user/openvpn \
           padavan-ng/trunk/user/openvpn-openssl; do
    mf="$dir/Makefile"            || continue
    [[ -f $mf ]] || continue

    echo ">> patching $mf"

    # 1. подменяем имя каталога и URL архива
    sed -i "s|^SRC_NAME=.*|SRC_NAME=openvpn-${OVPN_VER}|" "$mf"
    sed -i "s|^SRC_URL=.*|SRC_URL=${PATCH_URL}|"          "$mf"

    # 2. без дублирования добавляем --enable-xor-patch
    grep -q -- '--enable-xor-patch' "$mf" || \
      sed -i '/--enable-small/ s|$| \\\
\t\t--enable-xor-patch|' "$mf"

    # 3. на случай, если строка с openvpn-orig.patch жива — закомментируем
    sed -i '/openvpn-orig\.patch/s|^[^#]|#&|' "$mf"
done

# 4. удаляем старый тар, чтобы стянулся свежий
rm -f padavan-ng/trunk/dl/openvpn-${OVPN_VER}.tar.* || true
