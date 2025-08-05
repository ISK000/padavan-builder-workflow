#!/usr/bin/env bash
set -e
OVPN_VER=2.6.13
PATCHED_URL="https://github.com/luzrain/openvpn-xorpatch/releases/download/v${OVPN_VER}/openvpn-${OVPN_VER}.tar.gz"

cd padavan-ng/trunk/user/openvpn
echo ">> Подменяем архив OpenVPN ${OVPN_VER} на версию с XOR"
curl -L -o openvpn-${OVPN_VER}.tar.gz "${PATCHED_URL}"
