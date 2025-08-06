#!/usr/bin/env bash
set -e

OVPN_VER=2.6.14
PATCH_URL="https://github.com/luzrain/openvpn-xorpatch/releases/download/v${OVPN_VER}/openvpn-${OVPN_VER}.tar.gz"

# 1. Переписываем URL у обеих сборок (openssl / uclibc)
for dir in padavan-ng/trunk/user/openvpn \
           padavan-ng/trunk/user/openvpn-openssl; do
    mf="${dir}/Makefile"        || continue
    [ -f "$mf" ] || continue
    echo ">> Патчим $mf"
    sed -i "s|^SRC_URL=.*|SRC_URL=${PATCH_URL}|" "$mf"
done

# 2. Удаляем старый архив, чтобы точно скачался новый
rm -f padavan-ng/trunk/dl/openvpn-${OVPN_VER}.tar.* || true

# 3. (необязательно) убираем строку, которая тащит openvpn-orig.patch,
#    если она вдруг осталась раскомментированной
sed -i '/openvpn-orig\.patch/s/^/#/' \
  padavan-ng/trunk/user/openvpn*/Makefile || true
