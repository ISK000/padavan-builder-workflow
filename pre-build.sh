#!/usr/bin/env bash
set -e

# ======================================================================
# 1) OpenVPN с XOR-патчем (как было)
# ======================================================================
OVPN_VER=2.6.14
RELEASE_URL="https://github.com/luzrain/openvpn-xorpatch/releases/download/v${OVPN_VER}/openvpn-${OVPN_VER}.tar.gz"

OPENVPN_DIRS=(
  "padavan-ng/trunk/user/openvpn"
  "padavan-ng/trunk/user/openvpn-openssl"
)

for dir in "${OPENVPN_DIRS[@]}"; do
  mf="${dir}/Makefile" || continue
  [[ -f $mf ]] || continue
  echo ">>> refresh ${dir}"

  rm -rf "${dir}/openvpn-${OVPN_VER}" "${dir}/openvpn-${OVPN_VER}.tar."* 2>/dev/null || true
  curl -L --retry 5 -o "${dir}/openvpn-${OVPN_VER}.tar.gz" "${RELEASE_URL}"

  sed -i "s|^SRC_NAME=.*|SRC_NAME=openvpn-${OVPN_VER}|" "${mf}"
  sed -i "s|^SRC_URL=.*|SRC_URL=${RELEASE_URL}|"      "${mf}"
  grep -q -- '--enable-xor-patch' "${mf}" || \
    sed -i 's/--enable-small/--enable-small \\\n\t--enable-xor-patch/' "${mf}"
  sed -i 's|true # autoreconf disabled.*|autoreconf -fi |' "${mf}"
  sed -i '/openvpn-orig\.patch/s|^[^\t#]|#&|' "${mf}"
done

# ======================================================================
# 2) Кастомизация WebUI (как было)
# ======================================================================
CUSTOM_MODEL="FastLink  (private build)"
CUSTOM_FOOTER="© 2025 FastLink Team.  Powered by Padavan-NG"

sed -i '
  s/^Web_Title=.*/Web_Title=ZVMODELVZ Wireless Router/;
' padavan-ng/trunk/romfs/www/*.dict 2>/dev/null || true

find padavan-ng/trunk -name '*.dict' -print0 | while IFS= read -r -d '' F; do
  sed -i "s/ZVMODELVZ/${CUSTOM_MODEL//\//\\/}/g" "$F"
  sed -i "s/ZVCOPYRVZ/${CUSTOM_FOOTER//\//\\/}/g" "$F"
done

# ======================================================================
# 3) AmneziaWG (ядро + клиент WireGuard/Amnezia) через /etc/storage
#    - кладём awg-client и client.sh
#    - пример конфига wg0.conf.example
#    - автоподгрузка модуля и автозапуск клиента по WAN up/down
# ======================================================================
ROOT=padavan-ng/trunk

# Папки в образе
mkdir -p "$ROOT/romfs/usr/bin"
mkdir -p "$ROOT/romfs/etc/storage/wireguard"
mkdir -p "$ROOT/romfs/etc/storage"

# 3.1 Обёртка для запуска клиента
cat > "$ROOT/romfs/usr/bin/awg-client" <<'EOF'
#!/bin/sh
# Простая обёртка — весь функционал в /etc/storage/wireguard/client.sh
set -e
SCRIPT="/etc/storage/wireguard/client.sh"
[ -x "$SCRIPT" ] || { echo "Missing $SCRIPT"; exit 1; }
exec "$SCRIPT" "$@"
EOF
chmod +x "$ROOT/romfs/usr/bin/awg-client"

# 3.2 Реальный client.sh — тянем из репозитория (можно заменить URL на свой форк)
curl -L --retry 5 \
  -o "$ROOT/romfs/etc/storage/wireguard/client.sh" \
  "https://raw.githubusercontent.com/shvchk/padavan-wireguard-client/main/client.sh"
chmod +x "$ROOT/romfs/etc/storage/wireguard/client.sh"

# 3.3 Пример конфига
cat > "$ROOT/romfs/etc/storage/wireguard/wg0.conf.example" <<'EOF'
# Пример WireGuard/AmneziaWG конфига. Переименуйте в wg0.conf и заполните ключи.

# [Interface]
# Address = 10.7.0.2/32
# PrivateKey = <CLIENT_PRIVATE_KEY>
# DNS = 1.1.1.1

# [Peer]
# PublicKey = <SERVER_PUBLIC_KEY>
# PresharedKey = <OPTIONAL>
# AllowedIPs = 0.0.0.0/0
# Endpoint = <server_ip_or_host>:<port>
# PersistentKeepalive = 25

# Положите ваш реальный файл как /etc/storage/wireguard/wg0.conf
EOF

# 3.4 Автоподгрузка ядра amneziawg при старте роутера:
STARTED="$ROOT/romfs/etc/storage/started_script.sh"
touch "$STARTED"
if ! grep -q '### AmneziaWG autoload (begin)' "$STARTED"; then
  cat >> "$STARTED" <<'EOF'

### AmneziaWG autoload (begin)
# Сначала пытаемся insmod по конкретному пути (надёжнее), потом modprobe
insmod /lib/modules/$(uname -r)/kernel/net/amneziawg/amneziawg.ko 2>/dev/null || modprobe amneziawg 2>/dev/null || :
### AmneziaWG autoload (end)
EOF
fi

# 3.5 Автостарт клиента по событию WAN up/down
POST_WAN="$ROOT/romfs/etc/storage/post_wan_script.sh"
touch "$POST_WAN"
if ! grep -q '### AmneziaWG client autostart (begin)' "$POST_WAN"; then
  cat >> "$POST_WAN" <<'EOF'

### AmneziaWG client autostart (begin)
case "$1" in
  up)
    # Если есть /etc/storage/wireguard/*.conf — стартуем
    if [ -x /usr/bin/awg-client ] && ls /etc/storage/wireguard/*.conf >/dev/null 2>&1; then
      /usr/bin/awg-client start
    fi
    ;;
  down)
    [ -x /usr/bin/awg-client ] && /usr/bin/awg-client stop
    ;;
esac
### AmneziaWG client autostart (end)
EOF
fi

echo ">>> prebuild.sh finished OK"
