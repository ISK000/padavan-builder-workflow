#!/bin/bash
set -e

echo "=== Запуск pre-build.sh ==="

# Путь до исходников OpenVPN (папка берётся из trunk)
OPENVPN_DIR="trunk/user/openvpn/openvpn-2.5.x"

# Применяем XOR-патч
if [ -f "patches/openvpn_xor.patch" ]; then
    echo "Применяю XOR-патч..."
    patch -d "$OPENVPN_DIR" -p1 < patches/openvpn_xor.patch || {
        echo "Ошибка: не удалось применить XOR-патч!"
        exit 1
    }
else
    echo "Внимание: patches/openvpn_xor.patch не найден!"
fi

# Проверка AmneziaWG
if grep -q "CONFIG_FIRMWARE_INCLUDE_AMNEZIAWG=y" build.config; then
    echo "AmneziaWG включен в build.config"
else
    echo "AmneziaWG не включен — добавляю!"
    echo "CONFIG_FIRMWARE_INCLUDE_AMNEZIAWG=y" >> build.config
fi

echo "=== pre-build.sh завершён успешно ==="
