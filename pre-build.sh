#!/usr/bin/env bash
set -e

OVPN_VER=2.6.14
PATCH_URL="https://github.com/luzrain/openvpn-xorpatch/releases/download/v${OVPN_VER}/openvpn-${OVPN_VER}.tar.gz"

for DIR in padavan-ng/trunk/user/openvpn padavan-ng/trunk/user/openvpn-openssl; do
    MF="$DIR/Makefile" ; [ -f "$MF" ] || continue
    echo ">> Патчим $MF"
    sed -i \
        -e "s|^[[:space:]]*SRC_NAME=.*|SRC_NAME=openvpn-${OVPN_VER}|" \
        -e "s|^[[:space:]]*SRC_URL=.*|SRC_URL=${PATCH_URL}|"  "$MF"
done

rm -f padavan-ng/trunk/dl/openvpn-${OVPN_VER}.tar.* || true
