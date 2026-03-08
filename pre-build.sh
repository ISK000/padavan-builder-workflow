#!/usr/bin/env bash
############################################################
# MILLENIUM Group — Padavan-NG pre-build v10.0
#
# ROOT CAUSE HISTORY:
#  v5-v6: variables.c не патчился (break в цикле). httpd
#         игнорировал udp2raw_* переменные — toggle сбрасывался.
#  v7:    variables.c патчился НЕПРАВИЛЬНЫМ форматом:
#         вставлялся { "name", "val" } (defaults.c формат),
#         а variables.c ожидает { "name", int_flags } или
#         { "ServiceId", "name", int_flags } — разные структуры.
#         Кроме того, v7 НИКОГДА НЕ СОБИРАЛСЯ (CI гонял v6).
#
# ИСПРАВЛЕНО В v8.0:
#
#  1. restart_udp2raw получает enable+servers КАК АРГУМЕНТЫ
#     через action_script поле формы. Скрипт сам сохраняет
#     значения в nvram. variables.c whitelist БОЛЬШЕ НЕ БЛОКИРУЕТ.
#     (Belt+suspenders: variables.c тоже патчится правильно)
#
#  2. Разделитель серверов '>' заменён на '%' — '>' в строке
#     серверов интерпретировался shell как редирект при вызове
#     через action_script.
#
#  3. variables.c патчится с АВТО-ДЕТЕКТОМ формата (2-field или
#     3-field) по существующим записям в файле.
#
#  4. CSS toggle (без itoggle) — сохранён из v7.0.
############################################################
set -euo pipefail

TRUNK="padavan-ng/trunk"
UDP2RAW_DIR="$TRUNK/user/udp2raw-tunnel"
WWW="$TRUNK/user/www/n56u_ribbon_fixed"
ROMFS_STORAGE="$TRUNK/romfs/etc/storage"
ROMFS_SBIN="$TRUNK/romfs/sbin"

echo "============================================"
echo "  MILLENIUM Group VPN — pre-build v10.0"
echo "  FIX: action_script без аргументов, httpd сохраняет nvram"
echo "============================================"

############################################################
# 1. OpenVPN 2.6.14 + XOR patch (scramble obfuscate)
############################################################
echo ">>> [1] OpenVPN XOR patch"
OVPN_VER=2.6.14
RELEASE_URL="https://github.com/luzrain/openvpn-xorpatch/releases/download/v${OVPN_VER}/openvpn-${OVPN_VER}.tar.gz"

for dir in "$TRUNK/user/openvpn" "$TRUNK/user/openvpn-openssl"; do
  mf="${dir}/Makefile"
  [[ -f $mf ]] || continue
  echo "  refresh: ${dir}"
  rm -rf "${dir}/openvpn-${OVPN_VER}" "${dir}/openvpn-${OVPN_VER}.tar."* 2>/dev/null || true
  curl -L --retry 5 -o "${dir}/openvpn-${OVPN_VER}.tar.gz" "${RELEASE_URL}"
  sed -i "s|^SRC_NAME=.*|SRC_NAME=openvpn-${OVPN_VER}|" "${mf}"
  sed -i "s|^SRC_URL=.*|SRC_URL=${RELEASE_URL}|" "${mf}"
  grep -q -- '--enable-xor-patch' "${mf}" || \
    sed -i 's/--enable-small/--enable-small \\\n\t--enable-xor-patch/' "${mf}"
  sed -i 's|true # autoreconf disabled.*|autoreconf -fi |' "${mf}"
  sed -i '/openvpn-orig\.patch/s|^[^\t#]|#&|' "${mf}"
  echo "  OK: XOR patch enabled in ${dir}"
done

############################################################
# 2. WebUI branding
############################################################
echo ">>> [2] WebUI branding"
CUSTOM_MODEL="MILLENIUM Group VPN (private build)"
CUSTOM_FOOTER="(c) 2025 MILLENIUM Group.  Powered by Padavan-NG"
find "$TRUNK" -name '*.dict' -print0 | while IFS= read -r -d '' F; do
  sed -i "s/ZVMODELVZ/${CUSTOM_MODEL//\//\\/}/g" "$F"
  sed -i "s/ZVCOPYRVZ/${CUSTOM_FOOTER//\//\\/}/g" "$F"
done
echo "  OK"

############################################################
# 3. udp2raw binary (mipsel для MT7621 / R3Gv2)
############################################################
echo ">>> [3] udp2raw binary"
mkdir -p "$UDP2RAW_DIR/files"
curl -sL -o /tmp/udp2raw_binaries.tar.gz \
  https://github.com/wangyu-/udp2raw/releases/download/20230206.0/udp2raw_binaries.tar.gz
cd /tmp && tar xzf udp2raw_binaries.tar.gz
cp udp2raw_mips24kc_le "$OLDPWD/$UDP2RAW_DIR/files/udp2raw"
chmod +x "$OLDPWD/$UDP2RAW_DIR/files/udp2raw"
cd "$OLDPWD"
echo "  OK: $(ls -lh $UDP2RAW_DIR/files/udp2raw | awk '{print $5}')"

############################################################
# 4. udp2raw-ctl
############################################################
echo ">>> [4] Scripts"
cat > "$UDP2RAW_DIR/files/udp2raw-ctl" << 'CTLEOF'
#!/bin/sh
PIDFILE="/var/run/udp2raw.pid"
LOGFILE="/tmp/udp2raw.log"

do_start() {
    [ -f /tmp/udp2raw_srv ] && . /tmp/udp2raw_srv || { echo "No server config"; return 1; }
    [ -z "$SRV" ] && { echo "SRV empty"; return 1; }

    killall udp2raw 2>/dev/null; sleep 1

    # dedup + INSERT в позицию 1 (не APPEND в конец)
    iptables -D OUTPUT -p tcp --dport "$PRT" --tcp-flags RST RST -j DROP 2>/dev/null
    iptables -I OUTPUT 1 -p tcp --dport "$PRT" --tcp-flags RST RST -j DROP

    LOGLVL=$(nvram get udp2raw_loglevel 2>/dev/null)
    [ -z "$LOGLVL" ] && LOGLVL=0
    /usr/bin/udp2raw -c \
        -l "127.0.0.1:3333" \
        -r "${SRV}:${PRT}" \
        -k "$KEY" \
        --raw-mode faketcp \
        --cipher-mode xor \
        --auth-mode simple \
        -a --log-level "$LOGLVL" > "$LOGFILE" 2>&1 &
    echo $! > "$PIDFILE"
    sleep 2
    kill -0 "$(cat $PIDFILE)" 2>/dev/null && echo "OK PID=$(cat $PIDFILE)" || { echo "FAIL"; return 1; }
}

do_stop() {
    [ -f /tmp/udp2raw_srv ] && {
        . /tmp/udp2raw_srv
        iptables -D OUTPUT -p tcp --dport "${PRT:-4096}" --tcp-flags RST RST -j DROP 2>/dev/null
    }
    [ -f "$PIDFILE" ] && kill "$(cat $PIDFILE)" 2>/dev/null
    rm -f "$PIDFILE"
    killall udp2raw 2>/dev/null
    echo "Stopped"
}

case "${1:-}" in
    start)   do_start ;;
    stop)    do_stop ;;
    restart) do_stop; sleep 2; do_start ;;
    status)
        if [ -f "$PIDFILE" ] && kill -0 "$(cat $PIDFILE)" 2>/dev/null; then
            echo "RUNNING PID=$(cat $PIDFILE)"
        else
            echo "STOPPED"
        fi ;;
    *) echo "Usage: udp2raw-ctl {start|stop|restart|status}" ;;
esac
CTLEOF
chmod +x "$UDP2RAW_DIR/files/udp2raw-ctl"

############################################################
# 5. fl-vpn-start
############################################################
cat > "$UDP2RAW_DIR/files/fl-vpn-start" << 'VPNEOF'
#!/bin/sh
LOG="/tmp/fl-vpn.log"
exec >> "$LOG" 2>&1
echo "=== fl-vpn-start $(date) ==="

SERVERS=$(nvram get udp2raw_servers 2>/dev/null)
[ -z "$SERVERS" ] && { echo "No servers in nvram"; nvram set udp2raw_status="NO CONFIG"; exit 1; }

fl-vpn-stop 2>/dev/null; sleep 1
nvram set udp2raw_status="CONNECTING..."

SKIP=$(cat /tmp/vpn_skip 2>/dev/null || echo "-1")
OK=0
# Разделитель % (не >, т.к. > интерпретируется shell как редирект)
echo "$SERVERS" | tr '%' '\n' > /tmp/vpn_srvlist

resolve_host() {
    local H="$1"
    echo "$H" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' && { echo "$H"; return; }
    local IP
    IP=$(nslookup "$H" 2>/dev/null | awk '/^Address/{if(NR>2)print $NF}' | head -1)
    echo "$IP" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' && { echo "$IP"; return; }
    IP=$(ping -c1 -W3 "$H" 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    [ -n "$IP" ] && echo "$IP"
}

IDX=0
while IFS='' read -r line; do
    [ -z "$line" ] && continue
    echo "$line" | grep -q "^#" && continue
    S=$(echo "$line" | cut -d: -f1)
    P=$(echo "$line" | cut -d: -f2)
    K=$(echo "$line" | cut -d: -f3-)
    [ -z "$S" ] && continue
    [ -z "$P" ] && P=4096
    [ -z "$K" ] && K=changeme

    if [ "$IDX" -le "$SKIP" ] && [ "$SKIP" -ge 0 ]; then
        IDX=$((IDX+1)); continue
    fi

    echo ">>> [$IDX] $S:$P"
    SIP=$(resolve_host "$S")
    if [ -z "$SIP" ]; then
        echo "  DNS fail: $S"; IDX=$((IDX+1)); continue
    fi
    [ "$SIP" != "$S" ] && echo "  resolved: $S -> $SIP"
    ping -c2 -W4 "$SIP" >/dev/null 2>&1 || { echo "  unreachable: $SIP"; IDX=$((IDX+1)); continue; }

    printf "SRV=%s\nPRT=%s\nKEY=%s\n" "$SIP" "$P" "$K" > /tmp/udp2raw_srv
    udp2raw-ctl start
    if [ $? -ne 0 ]; then
        echo "  udp2raw start failed"; IDX=$((IDX+1)); continue
    fi

    WG=$(ip route | grep default | awk '{print $3}' | head -1)
    WI=$(ip route | grep default | awk '{print $5}' | head -1)
    [ -n "$WG" ] && {
        ip route del "$SIP/32" 2>/dev/null
        ip route add "$SIP/32" via "$WG" dev "$WI"
    }

    echo "  TUNNEL UP -> $S ($SIP):$P"
    echo "$IDX" > /tmp/vpn_idx
    nvram set udp2raw_status="CONNECTED"
    nvram set udp2raw_active="$S:$P"
    echo "=== DONE $(date) ==="
    OK=1; break
done < /tmp/vpn_srvlist

if [ "$OK" != "1" ] && [ "$SKIP" -ge 0 ]; then
    echo "Retry from 0"; echo "-1" > /tmp/vpn_skip; exec fl-vpn-start
fi
[ "$OK" != "1" ] && { nvram set udp2raw_status="ALL FAILED"; echo "FATAL: all servers failed"; exit 1; }
VPNEOF
chmod +x "$UDP2RAW_DIR/files/fl-vpn-start"

############################################################
# 6. fl-vpn-stop
############################################################
cat > "$UDP2RAW_DIR/files/fl-vpn-stop" << 'STOPEOF'
#!/bin/sh
[ -f /tmp/udp2raw_srv ] && { . /tmp/udp2raw_srv; ip route del "$SRV/32" 2>/dev/null; }
udp2raw-ctl stop 2>/dev/null
nvram set udp2raw_status="DISCONNECTED"
nvram set udp2raw_active=""
STOPEOF
chmod +x "$UDP2RAW_DIR/files/fl-vpn-stop"

############################################################
# 7. fl-vpn-switch
############################################################
cat > "$UDP2RAW_DIR/files/fl-vpn-switch" << 'SWEOF'
#!/bin/sh
C=$(cat /tmp/vpn_idx 2>/dev/null || echo 0)
echo "$C" > /tmp/vpn_skip
fl-vpn-stop; sleep 1
fl-vpn-start &
SWEOF
chmod +x "$UDP2RAW_DIR/files/fl-vpn-switch"

############################################################
# 8. fl-vpn-watchdog
############################################################
cat > "$UDP2RAW_DIR/files/fl-vpn-watchdog" << 'WDEOF'
#!/bin/sh
LOG="/tmp/fl-vpn-wd.log"
[ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 20000 ] && \
    tail -30 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"

cru l 2>/dev/null | grep -q "fl_vpn_wd" || {
    cru a fl_vpn_wd "*/1 * * * * /usr/bin/fl-vpn-watchdog"
    echo "$(date '+%H:%M') cron installed" >> "$LOG"
}

EN=$(nvram get udp2raw_enable 2>/dev/null)

if [ "$EN" != "1" ]; then
    pidof udp2raw >/dev/null 2>&1 && {
        fl-vpn-stop
        echo "$(date '+%H:%M') disabled -> stopped" >> "$LOG"
    }
    exit 0
fi

if ! pidof udp2raw >/dev/null 2>&1; then
    echo "$(date '+%H:%M') udp2raw dead -> restart" >> "$LOG"
    fl-vpn-start >> "$LOG" 2>&1 &
    exit 0
fi

# Если udp2raw жив, но OpenVPN не запущен — перезапускаем туннель
if ! pidof openvpn >/dev/null 2>&1; then
    echo "$(date '+%H:%M') openvpn dead (udp2raw alive) -> restart" >> "$LOG"
    fl-vpn-start >> "$LOG" 2>&1 &
    exit 0
fi

for t in tun0 tun1 tun2; do
    ip link show "$t" 2>/dev/null | grep -q UP || continue
    GW=$(ip route show dev "$t" 2>/dev/null | awk '/via/{print $3}' | head -1)
    [ -z "$GW" ] && GW="10.8.0.1"
    ping -c2 -W5 -I "$t" "$GW" >/dev/null 2>&1 || {
        echo "$(date '+%H:%M') VPN dead via $t -> switch" >> "$LOG"
        fl-vpn-switch >> "$LOG" 2>&1 &
    }
    break
done
WDEOF
chmod +x "$UDP2RAW_DIR/files/fl-vpn-watchdog"

############################################################
# 9. fl-vpn-status
############################################################
cat > "$UDP2RAW_DIR/files/fl-vpn-status" << 'STEOF'
#!/bin/sh
echo "=== MILLENIUM VPN ==="
printf "Enable:  %s\n" "$(nvram get udp2raw_enable 2>/dev/null || echo 0)"
printf "Status:  %s\n" "$(nvram get udp2raw_status 2>/dev/null || echo '?')"
printf "Server:  %s\n" "$(nvram get udp2raw_active 2>/dev/null || echo '-')"
printf "udp2raw: %s\n" "$(pidof udp2raw >/dev/null && echo "ON ($(pidof udp2raw))" || echo OFF)"
printf "openvpn: %s\n" "$(pidof openvpn >/dev/null && echo "ON ($(pidof openvpn))" || echo OFF)"
[ -f /tmp/udp2raw.log ] && echo "--- last udp2raw ---" && tail -5 /tmp/udp2raw.log
STEOF
chmod +x "$UDP2RAW_DIR/files/fl-vpn-status"

echo "  Scripts OK"

############################################################
# 10. restart_udp2raw — action_script hook для Padavan WebUI
############################################################
echo ">>> [5] restart_udp2raw (action_script hook)"
mkdir -p "$ROMFS_SBIN"

cat > "$ROMFS_SBIN/restart_udp2raw" << 'RSTEOF'
#!/bin/sh
# Вызывается Padavan httpd как action_script после submit формы.
# АРГУМЕНТЫ (передаются через action_script поле формы):
#   $1 = enable  (0 или 1)
#   $2 = servers (HOST:PORT:KEY разделённые %)
#
# v8.0 FIX: скрипт СОХРАНЯЕТ значения в nvram сам — не зависит
# от variables.c whitelist. Также читает nvram как fallback.

LOG="/tmp/udp2raw_restart.log"
exec >> "$LOG" 2>&1
echo "=== restart_udp2raw $(date) args=$* ==="

# Принять аргументы от action_script или читать из nvram
if [ $# -ge 1 ] && [ -n "$1" ]; then
    EN="$1"
else
    EN=$(nvram get udp2raw_enable 2>/dev/null || echo 0)
fi

if [ $# -ge 2 ] && [ -n "$2" ]; then
    SRVS="$2"
else
    SRVS=$(nvram get udp2raw_servers 2>/dev/null || echo "")
fi

[ -z "$EN" ]   && EN=0
[ -z "$SRVS" ] && SRVS=""

echo "  EN=$EN SRVS=$SRVS"

# Сохранить в nvram (belt-and-suspenders)
nvram set udp2raw_enable="$EN"   2>/dev/null
nvram set udp2raw_servers="$SRVS" 2>/dev/null
nvram commit 2>/dev/null

if [ "$EN" = "1" ]; then
    echo "  -> fl-vpn-start"
    /usr/bin/fl-vpn-start &
else
    echo "  -> fl-vpn-stop"
    /usr/bin/fl-vpn-stop
fi
RSTEOF
chmod +x "$ROMFS_SBIN/restart_udp2raw"
# Также копируем в files/ для установки через Makefile ROMFSINST
cp "$ROMFS_SBIN/restart_udp2raw" "$UDP2RAW_DIR/files/restart_udp2raw"
chmod +x "$UDP2RAW_DIR/files/restart_udp2raw"
echo "  Created $ROMFS_SBIN/restart_udp2raw + files/restart_udp2raw"

############################################################
# 11. WAN hook вшитый в romfs
############################################################
echo ">>> [6] WAN hook → romfs"
mkdir -p "$ROMFS_STORAGE"

WAN_HOOK="$ROMFS_STORAGE/started_wan_hook.sh"
if [ -f "$WAN_HOOK" ]; then
    if ! grep -q "fl-vpn-watchdog" "$WAN_HOOK"; then
        cat >> "$WAN_HOOK" << 'HOOKEOF'

# MILLENIUM VPN v8.0 — udp2raw autostart
sleep 3
PRT=$(nvram get udp2raw_servers 2>/dev/null | cut -d'%' -f1 | cut -d: -f2)
if [ -n "$PRT" ] && echo "$PRT" | grep -qE '^[0-9]+$'; then
    iptables -D OUTPUT -p tcp --dport "$PRT" --tcp-flags RST RST -j DROP 2>/dev/null
    iptables -I OUTPUT 1 -p tcp --dport "$PRT" --tcp-flags RST RST -j DROP
fi
EN=$(nvram get udp2raw_enable 2>/dev/null)
if [ "$EN" = "1" ]; then
    sleep 2 && /usr/bin/fl-vpn-start &
else
    sleep 2 && /usr/bin/fl-vpn-watchdog &
fi
HOOKEOF
        echo "  Appended to existing $WAN_HOOK"
    else
        echo "  Already patched: $WAN_HOOK"
    fi
else
    cat > "$WAN_HOOK" << 'HOOKEOF'
#!/bin/sh
# MILLENIUM VPN v8.0 — udp2raw autostart
# Запускается автоматически при поднятии WAN.
sleep 3
PRT=$(nvram get udp2raw_servers 2>/dev/null | cut -d'%' -f1 | cut -d: -f2)
if [ -n "$PRT" ] && echo "$PRT" | grep -qE '^[0-9]+$'; then
    iptables -D OUTPUT -p tcp --dport "$PRT" --tcp-flags RST RST -j DROP 2>/dev/null
    iptables -I OUTPUT 1 -p tcp --dport "$PRT" --tcp-flags RST RST -j DROP
fi
# Если включён — запускаем напрямую, не ждём cron watchdog
EN=$(nvram get udp2raw_enable 2>/dev/null)
if [ "$EN" = "1" ]; then
    sleep 2 && /usr/bin/fl-vpn-start &
else
    sleep 2 && /usr/bin/fl-vpn-watchdog &
fi
HOOKEOF
    echo "  Created $WAN_HOOK"
fi
chmod +x "$WAN_HOOK"

############################################################
# 12. custom-extras
############################################################
echo ">>> [7] custom-extras"
CUSTOM_DIR="$TRUNK/user/custom-extras"
if [ -d "$CUSTOM_DIR" ]; then
    mkdir -p "$CUSTOM_DIR/files/etc/storage/wireguard"
fi
echo "  OK"

############################################################
# 13. Patch user/Makefile
############################################################
echo ">>> [8] user/Makefile patch"
UMAKEFILE="$TRUNK/user/Makefile"
if ! grep -q "udp2raw-tunnel" "$UMAKEFILE"; then
    sed -i 's/for i in $(dir_y) ;/for i in $(dir_y) udp2raw-tunnel custom-extras ;/g' "$UMAKEFILE"
    sed -i 's/for i in `ls -d \*` ;/for i in `ls -d *` udp2raw-tunnel custom-extras ;/g' "$UMAKEFILE"
    echo "  PATCHED"
else
    echo "  ALREADY PATCHED"
fi

############################################################
# 14. Makefile для udp2raw-tunnel
############################################################
cat > "$UDP2RAW_DIR/Makefile" << 'MKEOF'
all:
	@echo "[udp2raw-tunnel] pre-compiled binary"
	@[ -f files/udp2raw ] && ls -la files/udp2raw || echo "WARNING: binary missing"

romfs:
	@echo "[udp2raw-tunnel] installing to romfs..."
	$(ROMFSINST) -p +x files/udp2raw          /usr/bin/udp2raw
	$(ROMFSINST) -p +x files/udp2raw-ctl      /usr/bin/udp2raw-ctl
	$(ROMFSINST) -p +x files/fl-vpn-start     /usr/bin/fl-vpn-start
	$(ROMFSINST) -p +x files/fl-vpn-stop      /usr/bin/fl-vpn-stop
	$(ROMFSINST) -p +x files/fl-vpn-switch    /usr/bin/fl-vpn-switch
	$(ROMFSINST) -p +x files/fl-vpn-watchdog  /usr/bin/fl-vpn-watchdog
	$(ROMFSINST) -p +x files/fl-vpn-status       /usr/bin/fl-vpn-status
	$(ROMFSINST) -p +x files/restart_udp2raw     /sbin/restart_udp2raw
	@echo "[udp2raw-tunnel] DONE"

clean:
	@echo "[udp2raw-tunnel] clean"
MKEOF

############################################################
# 15. AJAX статус endpoint
############################################################
echo ">>> [9] WebUI"
cat > "$WWW/millenium_status.asp" << 'EOF'
<% nvram_get_x("", "udp2raw_status"); %>|<% nvram_get_x("", "udp2raw_active"); %>
EOF

############################################################
# 16. ASP страница MILLENIUM VPN v7.0
#
# КЛЮЧЕВЫЕ ИЗМЕНЕНИЯ v7.0:
#
# A) CSS TOGGLE вместо itoggle:
#    Причина: itoggle не гарантирует синхронизацию radio button
#    при submit формы (особенно в версиях Padavan 3.4.x).
#    Новый toggle — чистый CSS checkbox + hidden input
#    "udp2raw_enable" который ВСЕГДА правильно устанавливается
#    через onEnableChange(). Нет зависимости от библиотек.
#
# B) HIDDEN INPUT вместо radio buttons:
#    <input type="hidden" name="udp2raw_enable" id="udp2raw_enable_val">
#    Значение устанавливается JS при клике на toggle.
#    Гарантированно попадает в POST при submit формы.
############################################################
cat > "$WWW/Advanced_udp2raw.asp" << 'ASPEOF'
<!DOCTYPE html>
<html>
<head>
<title>MILLENIUM VPN</title>
<meta http-equiv="Content-Type" content="text/html; charset=utf-8">
<meta http-equiv="Pragma" content="no-cache">
<meta http-equiv="Expires" content="-1">
<link rel="shortcut icon" href="images/favicon.ico">
<link rel="icon" href="images/favicon.png">
<link rel="stylesheet" type="text/css" href="/bootstrap/css/bootstrap.min.css">
<link rel="stylesheet" type="text/css" href="/bootstrap/css/main.css">
<script type="text/javascript" src="/jquery.js"></script>
<script type="text/javascript" src="/bootstrap/js/bootstrap.min.js"></script>
<script type="text/javascript" src="/state.js"></script>
<script type="text/javascript" src="/general.js"></script>
<script type="text/javascript" src="/popup.js"></script>
<style>
/* ── CSS Toggle (без зависимости от itoggle) ── */
.mil-switch {
    position: relative;
    display: inline-block;
    width: 60px;
    height: 30px;
    vertical-align: middle;
    cursor: pointer;
}
.mil-switch input { opacity: 0; width: 0; height: 0; position: absolute; }
.mil-slider {
    position: absolute;
    top: 0; left: 0; right: 0; bottom: 0;
    background: #ccc;
    border-radius: 30px;
    transition: .3s;
}
.mil-slider:before {
    position: absolute;
    content: "";
    height: 22px; width: 22px;
    left: 4px; top: 4px;
    background: #fff;
    border-radius: 50%;
    transition: .3s;
    box-shadow: 0 1px 3px rgba(0,0,0,.3);
}
.mil-switch input:checked + .mil-slider { background: #5cb85c; }
.mil-switch input:checked + .mil-slider:before { transform: translateX(30px); }
.mil-toggle-label {
    display: inline-block;
    margin-left: 10px;
    font-size: 14px;
    font-weight: bold;
    vertical-align: middle;
    min-width: 36px;
}
/* ── Остальные стили ── */
.help-text  { color: #888; font-size: 11px; margin-top: 3px; }
.status-box { background: #f5f5f5; border-radius: 6px; padding: 12px 16px; margin: 10px; }
</style>
<script>
var $j = jQuery.noConflict();
</script>
<script>
<% login_state_hook(); %>
var m_status = '<% nvram_get_x("", "udp2raw_status"); %>';
var m_active  = '<% nvram_get_x("", "udp2raw_active"); %>';

function initial(){
    show_banner(0); show_menu(7,-1,0); show_footer();
    load_body();
    load_servers();
    syncToggle();
    syncLogLevel();
    update_status();
    var ld = document.getElementById('Loading');
    if (ld) ld.style.display = 'none';
    inject_menu();
    setInterval(poll_status, 5000);
}

function poll_status(){
    $j.get('/millenium_status.asp?t=' + Date.now(), function(d){
        var p = d.split('|');
        if (p.length >= 2){
            m_status = p[0].trim();
            m_active  = p[1].trim();
            update_status();
        }
    });
}

function inject_menu(){
    var sub = document.getElementById('subMenu');
    if (!sub) return;
    if (sub.innerHTML.indexOf('Advanced_udp2raw') >= 0) return;
    var groups = sub.getElementsByClassName('accordion-group');
    if (groups.length > 0){
        var d = document.createElement('div');
        d.className = 'accordion-group';
        d.innerHTML = '<div class="accordion-heading"><a class="accordion-toggle"'
            + ' style="padding:5px 15px;" href="/Advanced_udp2raw.asp">'
            + '<b>MILLENIUM VPN</b></a></div>';
        groups[groups.length-1].parentNode.appendChild(d);
    }
}

function update_status(){
    var s    = m_status || 'DISCONNECTED';
    var el   = document.getElementById('vpn_status');
    var info = document.getElementById('vpn_info');
    if (!el) return;
    if (s == 'CONNECTED'){
        el.innerHTML = '<span class="label label-success"'
            + ' style="font-size:14px;padding:5px 12px;">&#x25CF; Туннель активен</span>';
        info.innerHTML = m_active ? 'Сервер: <b>' + m_active + '</b>' : '';
    } else if (s == 'CONNECTING...'){
        el.innerHTML = '<span class="label label-warning"'
            + ' style="font-size:14px;padding:5px 12px;">&#x25CF; Подключение...</span>';
        info.innerHTML = '<i>Перебор серверов...</i>';
    } else {
        el.innerHTML = '<span class="label label-important"'
            + ' style="font-size:14px;padding:5px 12px;">&#x25CB; Туннель выкл.</span>';
        info.innerHTML = (s && s != 'DISCONNECTED')
            ? '<span style="color:#c00">' + s + '</span>' : '';
    }
}

/* ─────────────────────────────────────────────
   CSS TOGGLE — FIX v7.0
   hidden input "udp2raw_enable" — единственный
   источник правды для формы. Никаких radio buttons,
   никакого itoggle.
   ───────────────────────────────────────────── */
function syncToggle(){
    var val = document.getElementById('udp2raw_enable_val').value;
    var cb  = document.getElementById('enable_cb');
    cb.checked = (val === '1');
    refreshToggleLabel(cb.checked);
    change_enabled();
}

function onEnableChange(cb){
    document.getElementById('udp2raw_enable_val').value = cb.checked ? '1' : '0';
    refreshToggleLabel(cb.checked);
    change_enabled();
}

function refreshToggleLabel(checked){
    var lbl = document.getElementById('toggle_lbl');
    if (!lbl) return;
    lbl.innerHTML = checked
        ? '<span style="color:#3c763d;font-weight:bold">ON</span>'
        : '<span style="color:#999">OFF</span>';
}

function change_enabled(){
    var enabled = document.getElementById('enable_cb').checked;
    showhide_div('cfg_main', enabled);
}

function load_servers(){
    var fld = document.getElementById('udp2raw_servers_stored');
    if (!fld) return;
    document.getElementById('srv_text').value = fld.value.replace(/%/g, '\n');
}

function syncLogLevel(){
    var val = document.getElementById('udp2raw_loglevel_val').value || '0';
    var sel = document.getElementById('udp2raw_loglevel_sel');
    if (!sel) return;
    for (var i = 0; i < sel.options.length; i++){
        if (sel.options[i].value === val){ sel.selectedIndex = i; break; }
    }
}

function applyRule(){
    var sv = document.getElementById('srv_text').value;
    sv = sv.replace(/\r\n/g, '\n').replace(/\n+/g, '\n').replace(/^\n|\n$/g, '');
    var srvPct = sv.replace(/\n/g, '%');
    document.form.udp2raw_servers.value = srvPct;
    document.form.action_mode.value  = ' Apply ';
    document.form.current_page.value = 'Advanced_udp2raw.asp';
    document.form.next_page.value    = 'Advanced_udp2raw.asp';
    // v10.0 FIX: action_script = "restart_udp2raw" БЕЗ АРГУМЕНТОВ.
    // httpd Padavan принимает только имя скрипта без пробелов/аргументов.
    // Строка с аргументами ("restart_udp2raw 1 server...") молча игнорируется httpd.
    // httpd сам сохраняет POST-поля в nvram через variables.c whitelist.
    // restart_udp2raw читает enable и servers из nvram (fallback уже реализован).
    document.form.action_script.value = 'restart_udp2raw';

    // FIX (сохранён из v8): ПЕРЕЗАГРУЖАЕМ СТРАНИЦУ после submit.
    // Форма уходит в hidden_frame — без этого основное окно не обновляется.
    var btn = document.getElementById('save_btn');
    if (btn) { btn.value = 'Сохранение...'; btn.disabled = true; }
    document.form.submit();
    setTimeout(function(){ window.location.href = 'Advanced_udp2raw.asp'; }, 3500);
}

function done_validating(action){}
</script>
</head>
<body onload="initial();" onunload="unload_body();">
<div class="wrapper">
<div class="container-fluid" style="padding-right:0px">
  <div class="row-fluid">
    <div class="span3"><center><div id="logo"></div></center></div>
    <div class="span9"><div id="TopBanner"></div></div>
  </div>
</div>
<br>
<div id="Loading" class="popup_bg"></div>
<iframe name="hidden_frame" id="hidden_frame" src="" width="0" height="0"
    frameborder="0" style="position:absolute;"></iframe>

<form method="post" name="form" id="ruleForm"
    action="/start_apply.htm" target="hidden_frame">
<input type="hidden" name="current_page"  value="Advanced_udp2raw.asp">
<input type="hidden" name="next_page"     value="Advanced_udp2raw.asp">
<input type="hidden" name="next_host"     value="">
<input type="hidden" name="sid_list"      value="LANHostConfig;">
<input type="hidden" name="group_id"      value="">
<input type="hidden" name="action_mode"   value="">
<input type="hidden" name="action_script" value="restart_udp2raw">
<input type="hidden" name="flag"          value="">

<!-- FIX v7.0: HIDDEN INPUT вместо radio buttons.
     Значение устанавливается JS через onEnableChange().
     Гарантированно попадает в POST при любом submit. -->
<input type="hidden" name="udp2raw_enable" id="udp2raw_enable_val"
    value="<% nvram_get_x("", "udp2raw_enable"); %>">

<!-- Серверы: пустой hidden для submit, _stored только для чтения -->
<input type="hidden" name="udp2raw_servers" id="udp2raw_servers_submit" value="">
<!-- Алиас для load_servers() -->
<input type="hidden" id="udp2raw_servers_stored"
    value="<% nvram_get_x("", "udp2raw_servers"); %>">
<input type="hidden" name="udp2raw_loglevel" id="udp2raw_loglevel_val"
    value="<% nvram_get_x("", "udp2raw_loglevel"); %>">

<div class="container-fluid"><div class="row-fluid">
  <div class="span3">
    <div class="well sidebar-nav side_nav" style="padding:0px;">
      <ul id="mainMenu" class="clearfix"></ul>
      <ul class="clearfix"><li><div id="subMenu" class="accordion"></div></li></ul>
    </div>
  </div>
  <div class="span9">
    <div class="box well grad_colour_dark_blue">
      <div id="tabMenu"></div>
      <h2 class="box_head round_top">MILLENIUM VPN &mdash; udp2raw FakeTCP</h2>
      <div class="round_bottom">

        <div class="alert alert-info" style="margin:10px;">
          <b>Как работает:</b> OpenVPN → 127.0.0.1:3333 → udp2raw (faketcp) → сервер<br>
          DPI видит обычный TCP. Туннель стартует автоматически при поднятии WAN.<br>
          <b>VPN клиент:</b> <a href="/vpncli.asp">Настройки</a>
          → Удалённый сервер: <b>127.0.0.1</b>, порт: <b>3333</b>, транспорт: <b>UDP</b>
        </div>

        <div class="status-box">
          <span id="vpn_status"></span>
          <span id="vpn_info" style="color:#555;margin-left:10px;"></span>
        </div>

        <table class="table">
          <tr>
            <th width="50%" style="border-top:0 none;">Включить udp2raw туннель</th>
            <td style="border-top:0 none;">
              <!-- CSS TOGGLE v7.0: нет зависимости от itoggle/engage.itoggle -->
              <label class="mil-switch">
                <input type="checkbox" id="enable_cb"
                    onchange="onEnableChange(this)">
                <span class="mil-slider"></span>
              </label>
              <span id="toggle_lbl" class="mil-toggle-label"></span>
            </td>
          </tr>
        </table>

        <div id="cfg_main" style="display:none;">
        <table class="table">
          <tr><th colspan="2" style="background:#E3E3E3;">Список серверов</th></tr>
          <tr>
            <td colspan="2">
              <textarea id="srv_text" rows="6" wrap="off" spellcheck="false"
                class="span12"
                style="font-family:'Courier New';font-size:12px;"
                placeholder="89.39.70.30:4096:millenium2026&#10;server2.example.com:4096:millenium2026&#10;185.x.x.x:4096:millenium2026"></textarea>
              <div class="help-text">
                Формат: ХОСТ:ПОРТ:ПАРОЛЬ — домены или IP, один на строку.<br>
                При недоступности первого — автоматически переключается на следующий.<br>
                Пароль — это ключ udp2raw (-k), не пароль OpenVPN.
              </div>
            </td>
          </tr>
          <tr>
            <th width="50%">Подробное логирование работы сервиса</th>
            <td>
              <select id="udp2raw_loglevel_sel" class="span4"
                  onchange="document.getElementById('udp2raw_loglevel_val').value=this.value;">
                <option value="0">Отключено</option>
                <option value="3">Включено (уровень 3)</option>
                <option value="5">Максимальное (уровень 5)</option>
              </select>
              <div class="help-text">Логи в /tmp/udp2raw.log</div>
            </td>
          </tr>
        </table>
        </div>

        <table class="table">
          <tr>
            <td style="border:0 none;text-align:center;">
              <input type="button" class="btn btn-primary" style="width:219px"
                onclick="applyRule();" value="Сохранить и применить">
              <div class="help-text" style="text-align:center;margin-top:8px;">
                Toggle ON/OFF + Сохранить = VPN запустится/остановится немедленно.<br>
                Статус обновляется каждые 5 сек.
              </div>
            </td>
          </tr>
        </table>

      </div>
    </div>
  </div>
</div></div>
</form>
<div id="footer"></div>
</div>
</body>
</html>
ASPEOF
echo "  Created Advanced_udp2raw.asp v8.0"

############################################################
# 17. Patch state.js
############################################################
echo ">>> [10] state.js menu"
STATEJS="$WWW/state.js"
if [ -f "$STATEJS" ] && ! grep -q "Advanced_udp2raw" "$STATEJS"; then
    ML2_LINE=$(grep -n 'menuL2_link.*new Array' "$STATEJS" | head -1 | cut -d: -f1)
    if [ -n "$ML2_LINE" ]; then
        sed -i "${ML2_LINE}a\\
menuL2_title.push(\"MILLENIUM VPN\");\\
menuL2_link.push(\"Advanced_udp2raw.asp\");" "$STATEJS"
        echo "  OK: menu added"
    else
        echo "  WARN: menuL2_link pattern not found"
    fi
else
    [ -f "$STATEJS" ] && echo "  ALREADY PATCHED" || echo "  WARN: state.js not found"
fi

############################################################
############################################################
# 18. nvram defaults (defaults.c)
############################################################
echo ">>> [11] nvram defaults"

patch_nvram_defaults() {
    local FILE="$1"
    local LABEL="$2"
    [ -f "$FILE" ] || return
    if grep -q "udp2raw_enable" "$FILE"; then
        echo "  Already patched ($LABEL): $FILE"
        return
    fi
    for TERM in '{ 0, 0 }' '{0, 0}'; do
        if grep -q "$TERM" "$FILE"; then
            LINE=$(grep -n "$TERM" "$FILE" | tail -1 | cut -d: -f1)
            sed -i "${LINE}i\\
\t{ \"udp2raw_enable\",   \"0\" },\\
\t{ \"udp2raw_servers\",  \"\" },\\
\t{ \"udp2raw_status\",   \"\" },\\
\t{ \"udp2raw_active\",   \"\" },\\
\t{ \"udp2raw_loglevel\", \"0\" }," "$FILE"
            echo "  Patched ($LABEL): $FILE"
            return
        fi
    done
    echo "  WARN: terminator not found in $FILE"
}

patch_nvram_defaults "$TRUNK/user/shared/defaults.c" "shared/defaults.c"

############################################################
# 12. variables.c — НЕ ПАТЧИМ (v8.0 финальное решение)
#
# variables.c содержит НЕСКОЛЬКО разных массивов (variables[], events_desc[] и др.)
# Автопатч вставлял в НЕПРАВИЛЬНЫЙ массив (events_desc) — build failure.
# variables.c НЕ НУЖЕН: restart_udp2raw получает args напрямую и сам
# вызывает nvram set. Whitelist httpd не участвует в нашем flow.
############################################################
############################################################
# 12. variables.c — httpd whitelist
#
# КРИТИЧНО для WebUI: Padavan httpd сохраняет POST-поля в nvram
# ТОЛЬКО если они есть в variables.c. Без этого udp2raw_enable
# никогда не сохраняется → toggle всегда сбрасывается в OFF.
#
# ИСПРАВЛЕНИЕ v8.1: Python с поиском КОНКРЕТНОГО массива
# struct variable variables[] через отслеживание глубины скобок.
# НЕ трогает events_desc[] или другие массивы в том же файле.
############################################################
echo ">>> [12] variables.c — struct-aware Python patch"

HTTPD_VARS="$TRUNK/user/httpd/variables.c"

if [ ! -f "$HTTPD_VARS" ]; then
    echo "  WARN: variables.c not found, skip"
else
python3 - "$HTTPD_VARS" << 'PYEOF'
import re, sys

FILE = sys.argv[1]
NEW_VARS = ["udp2raw_enable", "udp2raw_servers", "udp2raw_status", "udp2raw_active", "udp2raw_loglevel"]
NEW_DEFS = {"udp2raw_enable": "0", "udp2raw_servers": "", "udp2raw_status": "", "udp2raw_active": "", "udp2raw_loglevel": "0"}

with open(FILE, 'r') as f:
    content = f.read()

if 'udp2raw_enable' in content:
    print("  Already patched:", FILE)
    sys.exit(0)

print("  Patching:", FILE)

# 1. Find struct variable variables[] = { SPECIFICALLY
m = re.search(r'struct\s+variable\s+\w+\s*\[\s*\]\s*=\s*\{', content)
if not m:
    print("  ERROR: 'struct variable ... [] = {' not found")
    print("  Trying fallback: 'variables[] ='")
    m = re.search(r'\bvariables\s*\[\s*\]\s*=\s*\{', content)
    if not m:
        print("  ERROR: no variables array found")
        sys.exit(1)

arr_open = m.end() - 1  # position of opening {
print(f"  Array declaration: {repr(content[m.start():m.end()])}")
print(f"  Opening brace at offset {arr_open}")

# 2. Track brace depth to find EXACT closing brace of THIS array
# This way we NEVER cross into events_desc[] or any other array
depth = 0
arr_close = None
for i in range(arr_open, len(content)):
    c = content[i]
    if c == '{':
        depth += 1
    elif c == '}':
        depth -= 1
        if depth == 0:
            arr_close = i
            break

if arr_close is None:
    print("  ERROR: matching closing brace not found")
    sys.exit(1)

print(f"  Array: offset {arr_open} to {arr_close} ({arr_close - arr_open} chars)")

# 3. Detect entry format from entries INSIDE this array ONLY
arr_body = content[arr_open+1:arr_close]
ENTRY_RE = re.compile(r'^([\t ]+)\{([ \t]*"[^"]*"[^}]*)\}', re.MULTILINE)
entries = ENTRY_RE.findall(arr_body)

if not entries:
    print("  ERROR: no string-keyed entries found inside variables[] array")
    print("  Array body (first 200):", repr(arr_body[:200]))
    sys.exit(1)

sample_indent = entries[0][0]
sample_body   = entries[0][1].strip()

def split_fields(s):
    fields, cur, in_q = [], '', False
    for c in s:
        if c == '"': in_q = not in_q
        if c == ',' and not in_q:
            fields.append(cur.strip()); cur = ''
        else:
            cur += c
    if cur.strip(): fields.append(cur.strip())
    return fields

sample_fields = split_fields(sample_body)
n_fields = len(sample_fields)
print(f"  Sample: {repr(sample_body[:60])} -> {n_fields} fields")

# Build extra suffix matching existing format
extra_fields = sample_fields[2:] if n_fields > 2 else []
safe_extras = [
    f if re.match(r'^(0|-?[0-9]+|NULL|FALSE|TRUE|[A-Z_][A-Z0-9_]*)$', f) else '0'
    for f in extra_fields
]
extra_str_sample = (', ' + ', '.join(safe_extras)) if safe_extras else ''
print(f"  Sample extra suffix: {repr(extra_str_sample)}")

# v10.0 FIX: restart_needed_bits.
# FALSE/0 = httpd не вызывает action_script. Нужно ненулевое значение.
extra_str = extra_str_sample.replace('FALSE', '1')
if extra_str == extra_str_sample and ', 0' in extra_str:
    import re as _re2
    extra_str = _re2.sub(r',\s*0(\s*[,}])', lambda m: ', 1' + m.group(1), extra_str, count=1)
print(f"  Our restart suffix (restart=1): {repr(extra_str)}")

def make_entry(varname, default):
    return f'{sample_indent}{{"{varname}", "{default}"{extra_str}}},'

new_block = '\n'.join(make_entry(v, NEW_DEFS[v]) for v in NEW_VARS) + '\n'
print(f"  New entries:\n{new_block}")

# 4. Insert just before arr_close, ensuring trailing comma on last existing entry
before = content[:arr_close].rstrip('\n\r')
if before and not before.endswith(','):
    before += ','
    print("  Added trailing comma to last existing entry")

new_content = before + '\n' + new_block + content[arr_close:]

with open(FILE, 'w') as f:
    f.write(new_content)

print("  SUCCESS: variables.c patched (inside struct variable[] only)")
PYEOF

echo "  --- Verify ---"
grep -n "udp2raw" "$HTTPD_VARS" && echo "  VERIFY OK" || echo "  VERIFY FAILED!"
fi

echo ">>> [13] MTU defaults (vpnc_cus3)"
for F in "$TRUNK/user/shared/defaults.c" "$TRUNK/user/httpd/variables.c"; do
    [ -f "$F" ] || continue
    if grep -q "vpnc_cus3.*tun-mtu" "$F"; then
        echo "  vpnc_cus3 already in: $F"; continue
    fi
    for TERM in '{ 0, 0 }' '{0, 0}'; do
        if grep -q "$TERM" "$F"; then
            LINE=$(grep -n "$TERM" "$F" | tail -1 | cut -d: -f1)
            sed -i "${LINE}i\\
\t{ \"vpnc_cus3\", \"tun-mtu 1300\\\\nmssfix 1260\" }," "$F"
            echo "  Added vpnc_cus3 to: $F"
            break
        fi
    done
done

############################################################
echo ""
echo "============================================"
echo "  MILLENIUM Group VPN — build ready v8.0"
echo ""
echo "  ИСПРАВЛЕНИЕ v10.0:"
echo "  action_script = 'restart_udp2raw' БЕЗ АРГУМЕНТОВ."
echo "  httpd Padavan ИГНОРИРОВАЛ скрипт если в строке были пробелы."
echo "  Теперь httpd сохраняет udp2raw_enable + udp2raw_servers"
echo "  в nvram через variables.c whitelist, затем вызывает скрипт."
echo "  restart_udp2raw читает enable+servers из nvram."
echo "============================================"

echo ""
echo "=== DIAGNOSTICS ==="
echo "--- Files ---"
ls -la "$UDP2RAW_DIR/files/" 2>/dev/null
echo "--- restart_udp2raw ---"
cat "$ROMFS_SBIN/restart_udp2raw" 2>/dev/null || echo "NOT FOUND"
echo "--- WAN hook ---"
cat "$ROMFS_STORAGE/started_wan_hook.sh" 2>/dev/null || echo "NOT FOUND"
echo "--- nvram vars in variables.c ---"
grep "udp2raw_enable\|udp2raw_servers\|vpnc_cus3" \
    "$TRUNK/user/httpd/variables.c" 2>/dev/null || echo "NOT FOUND"
ls "$WWW/Advanced_udp2raw.asp" "$WWW/millenium_status.asp" 2>/dev/null && echo "ASP OK"
echo "=== END ==="
