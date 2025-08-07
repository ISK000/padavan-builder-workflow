#!/usr/bin/env bash
set -e

OVPN_VER=2.6.14
TAG_URL="https://github.com/luzrain/openvpn-xorpatch/archive/refs/tags/v${OVPN_VER}.tar.gz"

for dir in padavan-ng/trunk/user/openvpn \
           padavan-ng/trunk/user/openvpn-openssl; do
    mf="$dir/Makefile" || continue
    [[ -f $mf ]] || continue
    echo ">>> patching $mf"

    # 1. подставляем патчёный архив
    sed -i "s|^SRC_NAME=.*|SRC_NAME=openvpn-${OVPN_VER}|" "$mf"
    sed -i "s|^SRC_URL=.*|SRC_URL=${TAG_URL}|"            "$mf"

    # 2. гарантируем наличие флага
    grep -q -- '--enable-xor-patch' "$mf" || \
      sed -i 's|--enable-small|--enable-small \\\n\t--enable-xor-patch|' "$mf"

    # 3. возвращаем autoreconf
    sed -i 's|^.*true # autoreconf disabled.*$|autoreconf -fi |' "$mf"

    # 4. отключаем старый openvpn-orig.patch
    sed -i '/openvpn-orig\.patch/s|^[^#]|#&|' "$mf"
done


# -----------------------------------------------------------------------------
# Готовим tar-ball под ожидания Padavan’а
# -----------------------------------------------------------------------------
DL_DIR="padavan-ng/trunk/dl"
mkdir -p "$DL_DIR"
pushd "$DL_DIR" >/dev/null

rm -f openvpn-${OVPN_VER}.tar.* tmp.tar.gz 2>/dev/null || true

curl -L -o tmp.tar.gz "${TAG_URL}"
tar -xf tmp.tar.gz
mv openvpn-xorpatch-${OVPN_VER} openvpn-${OVPN_VER}
tar -czf openvpn-${OVPN_VER}.tar.gz openvpn-${OVPN_VER}
rm -rf openvpn-${OVPN_VER} tmp.tar.gz

popd >/dev/null
