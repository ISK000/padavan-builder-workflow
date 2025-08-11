#!/usr/bin/env bash
set -e

# ----------------------------------------------------------------------
# XOR-patch OpenVPN (оставил без изменений)
# ----------------------------------------------------------------------
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

# ----------------------------------------------------------------------
# Кастомизация WebUI (оставил как у тебя)
# ----------------------------------------------------------------------
CUSTOM_MODEL="FastLink  (private build)"
CUSTOM_FOOTER="© 2025 FastLink Team.  Powered by Padavan-NG"

sed -i '
  s/^Web_Title=.*/Web_Title=ZVMODELVZ Wireless Router/;
' padavan-ng/trunk/romfs/www/*.dict 2>/dev/null || true

find padavan-ng/trunk -name '*.dict' -print0 | while IFS= read -r -d '' F; do
  sed -i "s/ZVMODELVZ/${CUSTOM_MODEL//\//\\/}/g" "$F"
  sed -i "s/ZVCOPYRVZ/${CUSTOM_FOOTER//\//\\/}/g" "$F"
done

# ===================== WAN = eth2, LAN = eth3+Wi-Fi ===================

# 1) IFNAME_WAN на уровне платформы
RBH="padavan-ng/trunk/user/shared/ralink_boards.h"
if [ -f "$RBH" ]; then
  sed -i 's/^\([[:space:]]*#define[[:space:]]\+IFNAME_WAN[[:space:]]*\).*/\1"eth2"/' "$RBH"
  echo ">>> ralink_boards.h — IFNAME_WAN=\"eth2\""
fi

# 2) defaults.c: WAN=eth2 (DHCP), LAN-мост без eth2
DEF="padavan-ng/trunk/user/shared/defaults.c"
if [ -f "$DEF" ]; then
  sed -i 's/{ *"wan_ifname", *IFNAME_WAN *}/{ "wan_ifname", "eth2" }/' "$DEF"
  sed -i 's/{ *"wan0_ifname", *IFNAME_WAN *}/{ "wan0_ifname", "eth2" }/' "$DEF"
  sed -i 's/{ *"wan_proto", *"dhcp" *}/{ "wan_proto", "dhcp" }/' "$DEF"
  sed -i 's/{ *"wan0_proto", *"dhcp" *}/{ "wan0_proto", "dhcp" }/' "$DEF"
  sed -i 's/{ *"lan_ifnames", *".*" *}/{ "lan_ifnames", "eth3 ra0 rai0" }/' "$DEF"
  echo ">>> defaults.c — WAN=eth2, lan_ifnames=eth3 ra0 rai0"
fi

# 3) добавим сервис wan-linkd и автозапуск через ваш Makefile+autostart.sh
ROOTS="padavan-ng"   # тут лежат autostart.sh и Makefile в этом форке
AS="$ROOTS/autostart.sh"
MF="$ROOTS/Makefile"
WD="$ROOTS/wan-linkd.sh"

# 3.1 сам скрипт: bringup + синхронизация ether_link_wan по carrier
cat > "$WD" <<'EOF'
#!/bin/sh
WANIF="$(nvram get wan_ifname 2>/dev/null)"; [ -z "$WANIF" ] && WANIF=eth2

# выкинуть WAN из моста, поднять интерфейс и DHCP-клиент
brctl delif br0 "$WANIF" 2>/dev/null
ifconfig "$WANIF" up
killall udhcpc 2>/dev/null
udhcpc -i "$WANIF" -b -t 5 -T 3 -s /usr/share/udhcpc/default.script

# маленький вотчер линка для UI
(
  while sleep 2; do
    C=0; [ -r "/sys/class/net/$WANIF/carrier" ] && C="$(cat /sys/class/net/$WANIF/carrier)"
    if [ "x$C" = "x1" ]; then
      nvram set ether_link_wan=1; nvram set ether_flow_wan=1
    else
      nvram set ether_link_wan=0; nvram set ether_flow_wan=0
    fi
    nvram commit
  done
) &
exit 0
EOF
chmod +x "$WD"
echo ">>> создали wan-linkd.sh"

# 3.2 установим его в образ (/usr/bin/wan-linkd)
if grep -q 'wan-linkd' "$MF"; then
  echo ">>> Makefile уже устанавливает wan-linkd"
else
  # добавим одну строку ROMFSINST
  sed -i 's#^\(\s*$(ROMFSINST) /sbin/mtd_storage.sh.*\)$#\1\n\t$(ROMFSINST) -p +x '"$WD"' /usr/bin/wan-linkd#' "$MF"
  echo ">>> Makefile — добавлена установка /usr/bin/wan-linkd"
fi

# 3.3 автозапуск в конце autostart.sh (один раз)
if ! grep -q 'wan-linkd' "$AS"; then
  printf '\n# start WAN link daemon\n/usr/bin/wan-linkd &\n' >> "$AS"
  echo ">>> autostart.sh — добавлен запуск wan-linkd"
else
  echo ">>> autostart.sh — запуск wan-linkd уже есть"
fi

echo ">>> prebuild.sh finished OK"
