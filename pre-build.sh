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

# ================== 3) WAN=eth2, LAN=eth3+Wi-Fi ==================
# 3.1 defaults.c: жёстко ставим значения по умолчанию
DEF="padavan-ng/trunk/user/shared/defaults.c"
if [[ -f "$DEF" ]]; then
  sed -i 's/{[[:space:]]*"wan_ifname",[[:space:]]*IFNAME_WAN[[:space:]]*}/{ "wan_ifname", "eth2" }/' "$DEF"
  sed -i 's/{[[:space:]]*"wan_proto",[[:space:]]*"dhcp"[[:space:]]*}/{ "wan_proto", "dhcp" }/' "$DEF"
  sed -i 's/{[[:space:]]*"lan_ifnames",[[:space:]]*".*"[[:space:]]*}/{ "lan_ifnames", "eth3 ra0 rai0" }/' "$DEF"
  echo ">>> defaults.c — WAN=eth2, LAN=eth3 ra0 rai0"
fi

# 3.2 Для всех мест, где используется IFNAME_WAN — зададим его через CFLAGS
BMK="padavan-ng/trunk/configs/boards/XIAOMI/MI-R3Gv2/board.mk"
if [[ -f "$BMK" ]] && ! grep -q 'IFNAME_WAN' "$BMK"; then
  echo 'CFLAGS += -DIFNAME_WAN=\"eth2\"' >> "$BMK"
  echo ">>> board.mk — добавлен CFLAGS для IFNAME_WAN=\"eth2\""
fi

# ================== 4) Утилита wan-linkd + автозапуск ==================
SCR_DIR="padavan-ng/trunk/user/scripts"
WD="${SCR_DIR}/wan-linkd.sh"
cat > "$WD" <<'EOF'
#!/bin/sh
WANIF="$(nvram get wan_ifname 2>/dev/null)"; [ -z "$WANIF" ] && WANIF=eth2

# убрать WAN из моста и поднять интерфейс
brctl delif br0 "$WANIF" 2>/dev/null
ifconfig "$WANIF" up

# запустить DHCP-клиент (фон)
killall udhcpc 2>/dev/null
udhcpc -i "$WANIF" -b -t 5 -T 3 -s /usr/share/udhcpc/default.script

# следим за линком и прокидываем статус в NVRAM для WebUI
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
echo ">>> создали user/scripts/wan-linkd.sh"

# 4.1 Пропишем установку файла в образ
SMF="${SCR_DIR}/Makefile"
if ! grep -q '/usr/bin/wan-linkd' "$SMF"; then
  # вставим сразу после строки с autostart.sh
  awk '
    {print}
    /autostart\.sh/ && !p {print "\t$(ROMFSINST) -p +x $(THISDIR)/wan-linkd.sh /usr/bin/wan-linkd"; p=1}
  ' "$SMF" > "${SMF}.new" && mv "${SMF}.new" "$SMF"
  echo ">>> Makefile — добавлена установка /usr/bin/wan-linkd"
fi

# 4.2 Добавим запуск в конец autostart.sh + одноразовую починку NVRAM
AS="${SCR_DIR}/autostart.sh"
if ! grep -q 'wan-linkd' "$AS"; then
  cat >> "$AS" <<'EOF'

# --- one-shot fix NVRAM for proper WAN/LAN if needed ---
WANIF="$(nvram get wan_ifname 2>/dev/null)"
if [ "x$WANIF" != "xeth2" ]; then
  nvram set wan_ifname="eth2"
  nvram set wan_proto="dhcp"
  nvram set lan_ifnames="eth3 ra0 rai0"
  nvram commit
fi

# start WAN link daemon
/usr/bin/wan-linkd &
EOF
  echo ">>> autostart.sh — добавлен запуск wan-linkd и фиксер NVRAM"
fi

echo ">>> pre-build.sh finished OK"

echo ">>> prebuild.sh finished OK"
