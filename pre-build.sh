#!/usr/bin/env bash
set -e

OVPN_VER=2.6.14
BASE_URL="https://github.com/OpenVPN/openvpn/archive/refs/tags/v${OVPN_VER}.tar.gz"
PATCH_URL="https://raw.githubusercontent.com/luzrain/openvpn-xorpatch/master/patches/openvpn-${OVPN_VER}.patch"

for dir in padavan-ng/trunk/user/openvpn \
           padavan-ng/trunk/user/openvpn-openssl; do
    mf="${dir}/Makefile" || continue
    [[ -f $mf ]] || continue

    sed -i \
        -e "s|^SRC_NAME=.*|SRC_NAME=openvpn-${OVPN_VER}|" \
        -e "s|^SRC_URL=.*|SRC_URL=${BASE_URL}|"          \
        "$mf"

    # === добавляем накатывание патча =========================
    sed -i "/tar -xf/s|$| \\\
\t\t&& wget -qO- ${PATCH_URL} | patch -d \$(SRC_NAME) -p1|" "$mf"

    # подстрахуемся и раскомментируем возможную старую строку
    sed -i '/openvpn-orig\.patch/s|^#||' "$mf"
done

# старые архивы – в корзину
rm -f padavan-ng/trunk/dl/openvpn-${OVPN_VER}.tar.* 2>/dev/null || true
