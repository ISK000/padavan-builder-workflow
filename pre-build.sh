#!/usr/bin/env bash
set -e

OVPN_VER=2.6.14
SRC_URL="https://github.com/luzrain/openvpn-xorpatch/releases/download/\
v${OVPN_VER}/openvpn-${OVPN_VER}.tar.gz"

for dir in padavan-ng/trunk/user/openvpn \
           padavan-ng/trunk/user/openvpn-openssl; do
    mf="$dir/Makefile"       || continue
    [[ -f $mf ]] || continue
    echo ">>> patching $mf"

    # 1) берём уже-пропатчённый архив
    sed -i "s|^SRC_NAME=.*|SRC_NAME=openvpn-${OVPN_VER}|" "$mf"
    sed -i "s|^SRC_URL=.*|SRC_URL=${SRC_URL}|"            "$mf"

    # 2) включаем xor-patch при конфигурации (если строки ещё нет)
    if ! grep -q -- '--enable-xor-patch' "$mf"; then
        sed -i 's|--enable-small|--enable-small \\\n\t--enable-xor-patch|' "$mf"
    fi

    # 3) возвращаем autoreconf, если его закомментировали
    sed -i 's|^.*true # autoreconf disabled.*$|autoreconf -fi |' "$mf"

    # 4) не трогаем openvpn-orig.patch
    sed -i '/openvpn-orig\.patch/s|^[^#]|#&|' "$mf"
done

# Удаляем старый дистфайл, если он уже лежит в dl/
rm -f padavan-ng/trunk/dl/openvpn-${OVPN_VER}.tar.* 2>/dev/null || true
