#!/usr/bin/env bash
set -euo pipefail

OVPN_VER=2.6.14
SRC_URL="https://github.com/luzrain/openvpn-xorpatch/releases/download/\
v${OVPN_VER}/openvpn-${OVPN_VER}.tar.gz"

for dir in padavan-ng/trunk/user/openvpn \
           padavan-ng/trunk/user/openvpn-openssl; do

    mf="${dir}/Makefile"
    [[ -f ${mf} ]] || continue
    echo ">> patching ${mf}"

    # 1. правильный архив
    sed -i "s|^SRC_NAME=.*|SRC_NAME=openvpn-${OVPN_VER}|" "${mf}"
    sed -i "s|^SRC_URL=.*|SRC_URL=${SRC_URL}|"           "${mf}"

    # 2. включаем XOR-patch
    if ! grep -q -- "--enable-xor-patch" "${mf}"; then
        # вставляем сразу после --enable-small \
        sed -i 's/\(--enable-small[[:space:]]*\\\)/\1\
\t--enable-xor-patch \\/' "${mf}"
    fi
    # если строка закомментирована - раскомментируем
    sed -i 's/^[[:space:]]*#[[:space:]]*\(--enable-xor-patch\)/\1/' "${mf}"

    # 3. старый patch больше не нужен
    sed -i '/openvpn-orig\.patch/s|^[^#]|#&|' "${mf}"
done

# 4. вычищаем старый кэш, чтобы точно скачался новый tar.gz
rm -f padavan-ng/trunk/dl/openvpn-${OVPN_VER}.tar.* 2>/dev/null || true
