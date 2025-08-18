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

# ----------------------------------------------------------------------
# custom-extras: кладём CLI-инструменты в образ (без правок GUI)
# ----------------------------------------------------------------------
ROOT=padavan-ng/trunk
PKG="$ROOT/user/custom-extras"

mkdir -p "$PKG/files/usr/bin" "$PKG/files/etc/storage/wireguard"

# Makefile пакета
cat > "$PKG/Makefile" <<'MAKEEOF'
ifndef ROOTDIR
ROOTDIR=../..
endif
include $(ROOTDIR)/tools/build-rules.mk

all:
	@echo "custom-extras: nothing to build"

romfs:
	@echo "[custom-extras] install -> ROMFS"
	$(ROMFSINST) -p +x ./files/usr/bin/awg-client /usr/bin/awg-client
	$(ROMFSINST) -p +x ./files/usr/bin/obfs4-run /usr/bin/obfs4-run
	$(ROMFSINST) -p +x ./files/etc/storage/wireguard/client.sh /etc/storage/wireguard/client.sh
	$(ROMFSINST) ./files/etc/storage/wireguard/wg0.conf.example /etc/storage/wireguard/wg0.conf.example

clean:
	@true
MAKEEOF

# awg-client (обёртка на твой клиент)
cat > "$PKG/files/usr/bin/awg-client" <<'SH'
#!/bin/sh
set -e
SCRIPT="/etc/storage/wireguard/client.sh"
[ -x "$SCRIPT" ] || { echo "Missing $SCRIPT"; exit 1; }
exec "$SCRIPT" "$@"
SH
chmod +x "$PKG/files/usr/bin/awg-client"

# obfs4-run (удобный раннер obfs4proxy)
cat > "$PKG/files/usr/bin/obfs4-run" <<'SH'
#!/bin/sh
# Пример: obfs4-run --state /etc/storage/obfs4 --log /tmp/obfs4.log --bind 0.0.0.0:443 ...
set -e
OBFS="/usr/sbin/obfs4proxy"
[ -x "$OBFS" ] || { echo "obfs4proxy not found"; exit 1; }
exec "$OBFS" "$@"
SH
chmod +x "$PKG/files/usr/bin/obfs4-run"

# ТВОЙ client.sh (как у тебя выше; сейчас — версия под обычный WireGuard)
cat > "$PKG/files/etc/storage/wireguard/client.sh" <<'SH'
# <<< вставь сюда свой client.sh (из сообщения) без изменений >>>
SH
chmod +x "$PKG/files/etc/storage/wireguard/client.sh"

# Шаблон wg0.conf
cat > "$PKG/files/etc/storage/wireguard/wg0.conf.example" <<'EOF'
# Example WireGuard config
# [Interface]
# Address = 10.7.0.2/32
# PrivateKey = <CLIENT_PRIVATE_KEY>
# DNS = 1.1.1.1
#
# [Peer]
# PublicKey = <SERVER_PUBLIC_KEY>
# AllowedIPs = 0.0.0.0/0
# Endpoint = <server_ip_or_host>:<port>
# PersistentKeepalive = 25
EOF

# Подключаем пакет в общий список, если ещё не подключен
U_MF="$ROOT/user/Makefile"
grep -q 'custom-extras' "$U_MF" || echo 'DIRS-y += custom-extras' >> "$U_MF"

echo '>>> custom-extras ready (client.sh, awg-client, obfs4-run, wg0.conf.example)'

