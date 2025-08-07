#!/usr/bin/env bash
set -e

# Версия OpenVPN
OVPN_VER=2.6.14
# ‼️ Берём не «чистый» архив, а архив тега openvpn-xorpatch
TAG_URL="https://github.com/luzrain/openvpn-xorpatch/archive/refs/tags/v${OVPN_VER}.tar.gz"

# Папки с Makefile’ами Padavan’а, в которых правится исходник OpenVPN
for dir in padavan-ng/trunk/user/openvpn \
           padavan-ng/trunk/user/openvpn-openssl; do

    mf="$dir/Makefile"       || continue
    [[ -f $mf ]] || continue
    echo ">>> patching $mf"

    # 1. Заменяем источник на наш архив тега
    sed -i "s|^SRC_NAME=.*|SRC_NAME=openvpn-${OVPN_VER}|" "$mf"
    sed -i "s|^SRC_URL=.*|SRC_URL=${TAG_URL}|"            "$mf"

    # 2. Удаляем флаг --enable-xor-patch (в патченых исходниках он НЕ нужен,
    #     более того, configure на него ругается)
    sed -i '/--enable-xor-patch/d' "$mf"

    # 3. Возвращаем autoreconf (нужен, потому что configure придётся пересобрать)
    sed -i 's|^.*true # autoreconf disabled.*$|autoreconf -fi |' "$mf"

    # 4. Игнорируем старый openvpn-orig.patch
    sed -i '/openvpn-orig\.patch/s|^[^#]|#&|' "$mf"
done

# -----------------------------------------------------------------------------
# 5. Формируем «правильный» tar-ball, который ожидает Padavan
#    (в архиве тега папка называется openvpn-xorpatch-<ver>,
#     Padavan ждёт openvpn-<ver>)
# -----------------------------------------------------------------------------
pushd padavan-ng/trunk/dl >/dev/null

# чистим кеш, если вдруг был прежний файл
rm -f openvpn-${OVPN_VER}.tar.* tmp.tar.gz 2>/dev/null || true

# качаем архив тега
curl -L -o tmp.tar.gz "${TAG_URL}"

# распаковываем, переименовываем директорию и упаковываем обратно
tar -xf tmp.tar.gz
mv openvpn-xorpatch-${OVPN_VER} openvpn-${OVPN_VER}
tar -czf openvpn-${OVPN_VER}.tar.gz openvpn-${OVPN_VER}

# уборка
rm -rf openvpn-${OVPN_VER} tmp.tar.gz
popd
