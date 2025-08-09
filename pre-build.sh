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


# ----------------------------------------------------------------------
# Принудительно WAN = eth2 для Mi 4A Gigabit (CN)
# ----------------------------------------------------------------------
DEF="padavan-ng/trunk/user/shared/defaults.c"
SS="padavan-ng/trunk/user/scripts/started_script.sh"

if [ -f "$DEF" ]; then
    sed -i 's/{ *"wan_ifname", *IFNAME_WAN *}/{ "wan_ifname", "eth2" }/' "$DEF"
    echo ">>> WAN интерфейс по умолчанию изменён на eth2"
else
    echo "!!! defaults.c не найден — проверь путь !!!"
fi

if [ -f "$SS" ]; then
    grep -q 'delif br0 eth2' "$SS" || echo 'brctl delif br0 eth2 2>/dev/null' >> "$SS"
    echo ">>> Скрипт старта дополнен удалением eth2 из LAN моста"
fi

echo ">>> prebuild.sh finished OK"
