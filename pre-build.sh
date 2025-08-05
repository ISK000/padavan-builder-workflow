#!/bin/bash
set -e

echo "=== Запуск pre-build.sh ==="

SRC_DIR="padavan-ng/trunk/user/openvpn/openvpn-2.5.x"

if [[ -d "$SRC_DIR" ]]; then
    echo "Применяю XOR-патч в $SRC_DIR ..."
    patch -d "$SRC_DIR" -p1 < patches/openvpn_xor.patch
    echo "XOR-патч успешно применён!"
else
    echo "Ошибка: не найден каталог $SRC_DIR"
    exit 1
fi
