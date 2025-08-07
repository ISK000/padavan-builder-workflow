#!/usr/bin/env bash
set -e

OVPN_VER=2.6.14
SRC_URL="https://github.com/OpenVPN/openvpn/archive/refs/tags/v${OVPN_VER}.tar.gz"
PATCH_URL="https://raw.githubusercontent.com/luzrain/openvpn-xorpatch/master/patches/openvpn-${OVPN_VER}.patch"

for dir in padavan-ng/trunk/user/openvpn \
           padavan-ng/trunk/user/openvpn-openssl; do
    mf="$dir/Makefile" || continue
    [[ -f $mf ]] || continue

    echo "### правим $mf"

    # 1. ставим правильный архив и имя каталога
    sed -i \
        -e "s|^SRC_NAME=.*|SRC_NAME=openvpn-${OVPN_VER}|" \
        -e "s|^SRC_URL=.*|SRC_URL=${SRC_URL}|"           \
        "$mf"

    # 2. выкачиваем xor-patch рядом с Makefile (один раз на сборку)
    curl -sSL -o "$dir/openvpn-xor.patch" "${PATCH_URL}"

    # 3. раскомментируем строку патча и меняем её на новый файл
    sed -i \
        -e '/openvpn-orig\.patch/{
                s|#\s*||; s|openvpn-orig\.patch|openvpn-xor.patch|
            }' "$mf"
done

# 4. старые исходники – удалить, чтобы кэш не мешал
rm -f padavan-ng/trunk/dl/openvpn-${OVPN_VER}.tar.* 2>/dev/null || true
