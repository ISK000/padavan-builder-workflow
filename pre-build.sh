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

# ======================================================================
#  WAN = eth2 + корректная карта портов и правка детекта линка
# ======================================================================

# 0) IFNAME_WAN на уровне платформы
RBH="padavan-ng/trunk/user/shared/ralink_boards.h"
if [ -f "$RBH" ]; then
  # аккуратно заменим только если там не eth2
  if ! grep -q '^[[:space:]]*#define[[:space:]]\+IFNAME_WAN[[:space:]]*"eth2"' "$RBH"; then
    sed -i 's/^\([[:space:]]*#define[[:space:]]\+IFNAME_WAN[[:space:]]*\).*/\1"eth2"/' "$RBH"
  fi
  echo ">>> ralink_boards.h — IFNAME_WAN=\"eth2\""
fi

# 1) defaults.c: WAN=eth2, DHCP, LAN-мост без eth2
DEF="padavan-ng/trunk/user/shared/defaults.c"
if [ -f "$DEF" ]; then
  sed -i 's/{ *"wan_ifname", *IFNAME_WAN *}/{ "wan_ifname", "eth2" }/' "$DEF"
  sed -i 's/{ *"wan0_ifname", *IFNAME_WAN *}/{ "wan0_ifname", "eth2" }/' "$DEF"
  sed -i 's/{ *"wan_proto", *"dhcp" *}/{ "wan_proto", "dhcp" }/' "$DEF"
  sed -i 's/{ *"wan0_proto", *"dhcp" *}/{ "wan0_proto", "dhcp" }/' "$DEF"
  # важно: в мост кладём eth3 (LAN), а не eth2
  sed -i 's/{ *"lan_ifnames", *".*" *}/{ "lan_ifnames", "eth3 ra0 rai0" }/' "$DEF"
  echo ">>> defaults.c — WAN=eth2, lan_ifnames=eth3 ra0 rai0"
fi

# 2) board.h: корректное число PHY (для R3Gv2 должно быть 3)
BH="padavan-ng/trunk/configs/boards/XIAOMI/MI-R3Gv2/board.h"
if [ -f "$BH" ]; then
  sed -i 's/^#define[[:space:]]\+BOARD_NUM_ETH_EPHY[[:space:]].*/#define BOARD_NUM_ETH_EPHY\t3/' "$BH"
  echo ">>> board.h — BOARD_NUM_ETH_EPHY=3 (1 WAN + 2 LAN)"
fi

# 3) kernel 3.4 карта портов (WAN=0, LAN=1..)
KC="padavan-ng/trunk/configs/boards/XIAOMI/MI-R3Gv2/kernel-3.4.x.config"
if [ -f "$KC" ]; then
  sed -i 's/^CONFIG_RAETH_ESW_PORT_WAN=.*/CONFIG_RAETH_ESW_PORT_WAN=0/'   "$KC"
  sed -i 's/^CONFIG_RAETH_ESW_PORT_LAN1=.*/CONFIG_RAETH_ESW_PORT_LAN1=1/' "$KC"
  sed -i 's/^CONFIG_RAETH_ESW_PORT_LAN2=.*/CONFIG_RAETH_ESW_PORT_LAN2=2/' "$KC"
  sed -i 's/^CONFIG_RAETH_ESW_PORT_LAN3=.*/CONFIG_RAETH_ESW_PORT_LAN3=3/' "$KC"
  sed -i 's/^CONFIG_RAETH_ESW_PORT_LAN4=.*/CONFIG_RAETH_ESW_PORT_LAN4=4/' "$KC"
  echo ">>> kernel-3.4.x.config — карта портов обновлена (WAN=0, LAN=1,2)"
fi

# 4) Чиним детект “Ethernet Link State” для WebUI
ETHSH="padavan-ng/trunk/user/scripts/ethernet.sh"
if [ -f "$ETHSH" ]; then
  # Вставим (или обновим) блок, который берёт статус прямо из sysfs по реальному wan_ifname
  if ! grep -q '### WAN LINK FIX ###' "$ETHSH"; then
    cat >>"$ETHSH" <<'EOF'

# --- ### WAN LINK FIX ### ---
# На некоторых платах (MT7621/MT7530) штатный код неверно мапит WAN порт.
# Берём линк из /sys/class/net/${WANIF}/carrier и синхронизируем с NVRAM.
wan_link_fix() {
  WANIF="$(nvram get wan_ifname 2>/dev/null)"
  [ -z "$WANIF" ] && WANIF="eth2"
  if [ -r "/sys/class/net/${WANIF}/carrier" ]; then
    C="$(cat /sys/class/net/${WANIF}/carrier 2>/dev/null)"
    if [ "x$C" = "x1" ]; then
      nvram set ether_link_wan=1
      nvram set ether_flow_wan=1
    else
      nvram set ether_link_wan=0
      nvram set ether_flow_wan=0
    fi
    nvram commit
  fi
}

# вызываем фикс в конце обновления линков (функция может называться по-разному;
# безопасно дергаем здесь, т.к. скрипт исполняется периодически)
wan_link_fix
# --- ### /WAN LINK FIX ### ---
EOF
    echo ">>> ethernet.sh — добавлен WAN LINK FIX (sysfs carrier → ether_link_wan)"
  else
    echo ">>> ethernet.sh — WAN LINK FIX уже присутствует"
  fi
fi

echo ">>> prebuild.sh finished OK"
