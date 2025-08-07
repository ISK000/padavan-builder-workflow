#!/usr/bin/env bash
set -e

OVPN_VER=2.6.14
SRC_URL="https://github.com/luzrain/openvpn-xorpatch/releases/download/\
v${OVPN_VER}/openvpn-${OVPN_VER}.tar.gz"

for dir in padavan-ng/trunk/user/openvpn \
           padavan-ng/trunk/user/openvpn-openssl; do
    mf="$dir/Makefile"         || continue
    [[ -f $mf ]] || continue
    echo ">> patching $mf"

    # берём уже-пропатчённые исходники
    sed -i "s|^SRC_NAME=.*|SRC_NAME=openvpn-${OVPN_VER}|" "$mf"
    sed -i "s|^SRC_URL=.*|SRC_URL=${SRC_URL}|"          "$mf"

    # флага --enable-xor-patch в таком tarball нет → удалить, если был
    sed -i '/--enable-xor-patch/d' "$mf"

    # гасим openvpn-orig.patch, чтобы он не лез
    sed -i '/openvpn-orig\.patch/s|^[^#]|#&|' "$mf"
done

# стираем старый архив, если успел скачаться
rm -f padavan-ng/trunk/dl/openvpn-${OVPN_VER}.tar.* 2>/dev/null || true
