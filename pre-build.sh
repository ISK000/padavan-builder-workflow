#!/usr/bin/env bash
set -e
OVPN_VER=2.6.14
PATCHED_URL="https://github.com/luzrain/openvpn-xorpatch/releases/download/v${OVPN_VER}/openvpn-${OVPN_VER}.tar.gz"

for DIR in padavan-ng/trunk/user/openvpn \
           padavan-ng/trunk/user/openvpn_ssl ; do
    echo ">> Подменяем OpenVPN в $DIR"
    curl -L -o "$DIR/openvpn-${OVPN_VER}.tar.gz" "$PATCHED_URL"
done
