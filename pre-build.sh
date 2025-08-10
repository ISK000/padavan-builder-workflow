#!/usr/bin/env bash
set -e

# ----------------------------------------------------------------------
# версия + ссылка на готовый архив c XOR-patch
# ----------------------------------------------------------------------
OVPN_VER=2.6.14
RELEASE_URL="https://github.com/luzrain/openvpn-xorpatch/releases/download/v${OVPN_VER}/openvpn-${OVPN_VER}.tar.gz"

# каталоги с пакетами OpenVPN у Padavan-NG
OPENVPN_DIRS=(
  "padavan-ng/trunk/user/openvpn"
  "padavan-ng/trunk/user/openvpn-openssl"
)

for dir in "${OPENVPN_DIRS[@]}"; do
    mf="${dir}/Makefile"          || continue
    [[ -f $mf ]]                  || continue
    echo ">>> refresh ${dir}"

    # 1. подчистка наследия
    rm -rf "${dir}/openvpn-${OVPN_VER}" \
           "${dir}/openvpn-${OVPN_VER}.tar."* 2>/dev/null || true

    # 2. скачиваем свежий архив
    curl -L --retry 5 -o "${dir}/openvpn-${OVPN_VER}.tar.gz" "${RELEASE_URL}"

    # 3. патчим Makefile
    sed -i "s|^SRC_NAME=.*|SRC_NAME=openvpn-${OVPN_VER}|"      "${mf}"
    sed -i "s|^SRC_URL=.*|SRC_URL=${RELEASE_URL}|"             "${mf}"

    grep -q -- '--enable-xor-patch' "${mf}" || \
        sed -i 's/--enable-small/--enable-small \\\n\t--enable-xor-patch/' "${mf}"

    sed -i 's|true # autoreconf disabled.*|autoreconf -fi |'    "${mf}"
    sed -i '/openvpn-orig\.patch/s|^[^\t#]|#&|'                 "${mf}"
done


CUSTOM_MODEL="FastLink  (private build)"
CUSTOM_FOOTER="© 2025 FastLink Team.  Powered by Padavan-NG"

sed -i "
  s/^Web_Title=.*/Web_Title=ZVMODELVZ Wireless Router/;
" padavan-ng/trunk/romfs/www/*.dict   2>/dev/null || true

# заменим placeholder на свои строки
find padavan-ng/trunk -name '*.dict' -print0 | while IFS= read -r -d '' F; do
  sed -i "s/ZVMODELVZ/${CUSTOM_MODEL//\//\\/}/g"   "$F"
  sed -i "s/ZVCOPYRVZ/${CUSTOM_FOOTER//\//\\/}/g"  "$F"
done



# =========================
# 3. WAN = eth2 + карта портов MT7530
# =========================

# Поправляем defaults.c
DEF="padavan-ng/trunk/user/shared/defaults.c"
if [ -f "$DEF" ]; then
    sed -i 's/{ *"wan_ifname", *IFNAME_WAN *}/{ "wan_ifname", "eth2" }/' "$DEF"
    sed -i 's/{ *"wan0_ifname", *IFNAME_WAN *}/{ "wan0_ifname", "eth2" }/' "$DEF"
    sed -i 's/{ *"wan_proto", *"dhcp" *}/{ "wan_proto", "dhcp" }/' "$DEF"
    sed -i 's/{ *"wan0_proto", *"dhcp" *}/{ "wan0_proto", "dhcp" }/' "$DEF"
    sed -i 's/{ *"lan_ifnames", *".*" *}/{ "lan_ifnames", "eth0 ra0 rai0" }/' "$DEF"
    echo ">>> defaults.c обновлён под eth2"
fi

# Поправляем board.h (число LAN-портов)
BH="padavan-ng/trunk/configs/boards/XIAOMI/MI-R3Gv2/board.h"
if [ -f "$BH" ]; then
    sed -i 's/#define BOARD_NUM_ETH_EPHY.*/#define BOARD_NUM_ETH_EPHY 2/' "$BH"
    echo ">>> board.h — число LAN портов = 2"
fi

# Поправляем kernel config (карта портов)
KC="padavan-ng/trunk/configs/boards/XIAOMI/MI-R3Gv2/kernel-3.4.x.config"
if [ -f "$KC" ]; then
    sed -i 's/CONFIG_RAETH_ESW_PORT_WAN=.*/CONFIG_RAETH_ESW_PORT_WAN=0/' "$KC"
    sed -i 's/CONFIG_RAETH_ESW_PORT_LAN1=.*/CONFIG_RAETH_ESW_PORT_LAN1=1/' "$KC"
    sed -i 's/CONFIG_RAETH_ESW_PORT_LAN2=.*/CONFIG_RAETH_ESW_PORT_LAN2=2/' "$KC"
    sed -i 's/CONFIG_RAETH_ESW_PORT_LAN3=.*/CONFIG_RAETH_ESW_PORT_LAN3=3/' "$KC"
    sed -i 's/CONFIG_RAETH_ESW_PORT_LAN4=.*/CONFIG_RAETH_ESW_PORT_LAN4=4/' "$KC"
    echo ">>> kernel-3.4.x.config — карта портов обновлена (WAN=0, LAN=1,2)"
fi

echo ">>> prebuild.sh finished OK"
