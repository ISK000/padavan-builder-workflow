#!/bin/bash
set -e

echo "=== Запуск pre-build.sh ==="

# Папка с исходниками padavan-ng
SRC_DIR="padavan-ng/trunk/user/openvpn/openvpn-2.5.x"
PATCH_FILE="patch/openvpn_xor.patch"

if [ -d "$SRC_DIR" ]; then
    echo "Применяю XOR-патч..."
    patch -d "$SRC_DIR" -p1 < "$PATCH_FILE" || {
        echo "Ошибка: не удалось применить XOR-патч!"
        exit 1
    }
    echo "XOR-патч успешно применён."
else
    echo "Ошибка: каталог с исходниками не найден: $SRC_DIR"
    ls -l padavan-ng/trunk/user/openvpn || true
    exit 1
fi
