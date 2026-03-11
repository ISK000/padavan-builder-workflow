#!/usr/bin/env bash
############################################################
# MILLENIUM Group — Padavan-NG pre-build v17.0
#
# Основано на v16.2. Исправлены 3 бага:
# БАГ 1: Race condition → START_LOCK берётся ДО fork
# БАГ 2: Ложный CONNECTED → проверяем PID после sleep 2
# БАГ 3: Двойной restart → убран из udp2raw-save
############################################################
set -euo pipefail

TRUNK="padavan-ng/trunk"
UDP2RAW_DIR="$TRUNK/user/udp2raw-tunnel"
WWW="$TRUNK/user/www/n56u_ribbon_fixed"
ROMFS_STORAGE="$TRUNK/romfs/etc/storage"
ROMFS_SBIN="$TRUNK/romfs/sbin"

echo "============================================"
echo "  MILLENIUM Group VPN — pre-build v17.0"
echo "  FIX: lock before fork + real status check"
echo "============================================"

############################################################
# 1. OpenVPN XOR patch
############################################################
echo ">>> [1] OpenVPN XOR patch"
OVPN_VER=2.6.14
RELEASE_URL="https://github.com/luzrain/openvpn-xorpatch/releases/download/v${OVPN_VER}/openvpn-${OVPN_VER}.tar.gz"
for dir in "$TRUNK/user/openvpn" "$TRUNK/user/openvpn-openssl"; do
  mf="${dir}/Makefile"; [[ -f "$mf" ]] || continue
  rm -rf "${dir}/openvpn-${OVPN_VER}" "${dir}/openvpn-${OVPN_VER}.tar."* 2>/dev/null || true
  curl -L --retry 5 -o "${dir}/openvpn-${OVPN_VER}.tar.gz" "${RELEASE_URL}"
  sed -i "s|^SRC_NAME=.*|SRC_NAME=openvpn-${OVPN_VER}|" "$mf"
  sed -i "s|^SRC_URL=.*|SRC_URL=${RELEASE_URL}|" "$mf"
  grep -q -- '--enable-xor-patch' "$mf" || sed -i 's/--enable-small/--enable-small \\\n\t--enable-xor-patch/' "$mf"
  sed -i 's|true # autoreconf disabled.*|autoreconf -fi |' "$mf"
  sed -i '/openvpn-orig\.patch/s|^[^\t#]|#&|' "$mf"
  echo "  OK: ${dir}"
done

############################################################
# 2. WebUI branding
############################################################
echo ">>> [2] WebUI branding"
find "$TRUNK" -name '*.dict' -print0 | while IFS= read -r -d '' F; do
  sed -i "s/ZVMODELVZ/MILLENIUM Group VPN (private build)/g" "$F"
  sed -i "s/ZVCOPYRVZ/(c) 2025 MILLENIUM Group. Powered by Padavan-NG/g" "$F"
done
echo "  OK"

############################################################
# 3. udp2raw binary
############################################################
echo ">>> [3] udp2raw binary"
mkdir -p "$UDP2RAW_DIR/files"
curl -sL -o /tmp/udp2raw_binaries.tar.gz \
  https://github.com/wangyu-/udp2raw/releases/download/20230206.0/udp2raw_binaries.tar.gz
cd /tmp && tar xzf udp2raw_binaries.tar.gz
cp udp2raw_mips24kc_le "$OLDPWD/$UDP2RAW_DIR/files/udp2raw"
chmod +x "$OLDPWD/$UDP2RAW_DIR/files/udp2raw"
cd "$OLDPWD"
echo "  OK: $(ls -lh "$UDP2RAW_DIR/files/udp2raw" | awk '{print $5}')"

############################################################
# 4. Scripts
############################################################
echo ">>> [4] Scripts"

cat > "$UDP2RAW_DIR/files/udp2raw-common" << 'CMEOF'
#!/bin/sh
CFG="/etc/storage/udp2raw.conf"
START_LOCK="/var/run/fl-vpn-start.lock"
RESTART_LOCK="/var/run/restart_udp2raw.lock"
cfg_load() {
    UDP2RAW_ENABLE=0; UDP2RAW_SERVERS=""; UDP2RAW_LOGLEVEL=0
    [ -f "$CFG" ] && . "$CFG"
    [ -n "${UDP2RAW_ENABLE:-}"   ] || UDP2RAW_ENABLE=0
    [ -n "${UDP2RAW_SERVERS:-}"  ] || UDP2RAW_SERVERS=""
    [ -n "${UDP2RAW_LOGLEVEL:-}" ] || UDP2RAW_LOGLEVEL=0
}
nvram_sync() {
    nvram set udp2raw_enable="${UDP2RAW_ENABLE:-0}"
    nvram set udp2raw_servers="${UDP2RAW_SERVERS:-}"
    nvram set udp2raw_loglevel="${UDP2RAW_LOGLEVEL:-0}"
    nvram commit
}
lock_is_running() {
    [ -f "$1" ] || return 1
    PID="$(cat "$1" 2>/dev/null)"
    [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null
}
lock_take()    { echo $$ > "$1"; }
lock_release() { rm -f "$1"; }
CMEOF
chmod +x "$UDP2RAW_DIR/files/udp2raw-common"

# ─── udp2raw-save — v17.0: НЕ вызывает restart в конце ───
cat > "$UDP2RAW_DIR/files/udp2raw-save" << 'SAVEOF'
#!/bin/sh
CFG="/etc/storage/udp2raw.conf"
POSTWAN="/etc/storage/post_wan_script.sh"
TMP="/tmp/udp2raw.conf.tmp"
EN="${1:-0}"; SRVS="${2:-}"; LOGLEVEL="${3:-0}"
safe() { printf '%s' "$1" | sed 's/[\\`"$]/\\&/g'; }
mkdir -p /etc/storage
cat > "$TMP" << EOF
#!/bin/sh
UDP2RAW_ENABLE="$(safe "$EN")"
UDP2RAW_SERVERS="$(safe "$SRVS")"
UDP2RAW_LOGLEVEL="$(safe "$LOGLEVEL")"
EOF
chmod 600 "$TMP"; mv "$TMP" "$CFG"
nvram set udp2raw_enable="$EN"
nvram set udp2raw_servers="$SRVS"
nvram set udp2raw_loglevel="$LOGLEVEL"
nvram set udp2raw_status="DISCONNECTED"
nvram set udp2raw_active=""
nvram commit
touch "$POSTWAN"
if ! grep -q "### UDP2RAW AUTO START ###" "$POSTWAN" 2>/dev/null; then
cat >> "$POSTWAN" << 'HOOK'

### UDP2RAW AUTO START ###
if [ -f /etc/storage/udp2raw.conf ]; then
    . /etc/storage/udp2raw.conf
    /usr/bin/fl-vpn-watchdog start >/dev/null 2>&1 || true
    [ "${UDP2RAW_ENABLE:-0}" = "1" ] && /sbin/restart_udp2raw >/dev/null 2>&1 &
fi
### UDP2RAW AUTO END ###
HOOK
chmod +x "$POSTWAN"
fi
/sbin/mtd_storage.sh save >/dev/null 2>&1 || true
# v17.0 FIX: НЕ вызываем restart_udp2raw — AJAX сделает это отдельным запросом
echo "OK"
SAVEOF
chmod +x "$UDP2RAW_DIR/files/udp2raw-save"

cat > "$UDP2RAW_DIR/files/u2s" << 'U2SEOF'
#!/bin/sh
exec /usr/bin/udp2raw-save "$@"
U2SEOF
chmod +x "$UDP2RAW_DIR/files/u2s"

cat > "$UDP2RAW_DIR/files/udp2raw-ctl" << 'CTLEOF'
#!/bin/sh
. /usr/bin/udp2raw-common
PIDFILE="/var/run/udp2raw.pid"
LOGFILE="/tmp/udp2raw.log"
do_start() {
    cfg_load
    [ -f /tmp/udp2raw_srv ] && . /tmp/udp2raw_srv || { echo "No server config"; return 1; }
    [ -n "$SRV" ] || { echo "SRV empty"; return 1; }
    [ -n "$PRT" ] || PRT=4096; [ -n "$KEY" ] || KEY=changeme
    killall udp2raw 2>/dev/null || true; sleep 1
    iptables -D OUTPUT -p tcp --dport "$PRT" --tcp-flags RST RST -j DROP 2>/dev/null || true
    iptables -I OUTPUT 1 -p tcp --dport "$PRT" --tcp-flags RST RST -j DROP
    /usr/bin/udp2raw -c \
        -l "127.0.0.1:3333" -r "${SRV}:${PRT}" -k "$KEY" \
        --raw-mode faketcp --cipher-mode xor --auth-mode simple \
        -a --log-level "${UDP2RAW_LOGLEVEL:-0}" > "$LOGFILE" 2>&1 &
    echo $! > "$PIDFILE"; sleep 2
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "OK PID=$(cat "$PIDFILE")"; return 0
    fi
    echo "FAIL"; cat "$LOGFILE" 2>/dev/null | tail -3; return 1
}
do_stop() {
    [ -f /tmp/udp2raw_srv ] && { . /tmp/udp2raw_srv
        iptables -D OUTPUT -p tcp --dport "${PRT:-4096}" --tcp-flags RST RST -j DROP 2>/dev/null || true; }
    [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null || true
    rm -f "$PIDFILE"; killall udp2raw 2>/dev/null || true; echo "Stopped"
}
case "${1:-}" in
    start)   do_start ;;
    stop)    do_stop ;;
    restart) do_stop; sleep 1; do_start ;;
    status)
        [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null \
            && echo "RUNNING PID=$(cat "$PIDFILE")" || echo "STOPPED" ;;
    *) echo "Usage: udp2raw-ctl {start|stop|restart|status}" ;;
esac
CTLEOF
chmod +x "$UDP2RAW_DIR/files/udp2raw-ctl"

# ─── fl-vpn-start — v17.0: lock СРАЗУ + проверка PID ───
cat > "$UDP2RAW_DIR/files/fl-vpn-start" << 'VPNEOF'
#!/bin/sh
. /usr/bin/udp2raw-common
LOG="/tmp/fl-vpn.log"
if lock_is_running "$START_LOCK"; then
    echo "fl-vpn-start already running"; exit 0
fi
# v17.0 FIX: берём lock СРАЗУ до любой работы
lock_take "$START_LOCK"
trap 'lock_release "$START_LOCK"' EXIT INT TERM
exec >> "$LOG" 2>&1
echo "=== fl-vpn-start $(date) ==="
cfg_load; nvram_sync
SERVERS="$UDP2RAW_SERVERS"
[ -n "$SERVERS" ] || {
    echo "No servers"; nvram set udp2raw_status="NO CONFIG"
    nvram set udp2raw_active=""; nvram commit; exit 1; }
echo "$SERVERS" | tr '%' '\n' > /tmp/vpn_srvlist
/usr/bin/fl-vpn-stop 2>/dev/null || true; sleep 1
nvram set udp2raw_status="CONNECTING..."; nvram set udp2raw_active=""; nvram commit
resolve_host() {
    H="$1"
    echo "$H" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' && { echo "$H"; return; }
    IP=$(nslookup "$H" 2>/dev/null | awk '/^Address/{if(NR>2)print $NF}' | head -1)
    echo "$IP" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' && { echo "$IP"; return; }
    IP=$(ping -c1 -W3 "$H" 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    [ -n "$IP" ] && echo "$IP"
}
OK=0; IDX=0
while IFS='' read -r line; do
    [ -n "$line" ] || continue; echo "$line" | grep -q "^#" && continue
    S=$(echo "$line" | cut -d: -f1); P=$(echo "$line" | cut -d: -f2); K=$(echo "$line" | cut -d: -f3-)
    [ -n "$S" ] || continue; [ -n "$P" ] || P=4096; [ -n "$K" ] || K=changeme
    echo ">>> [$IDX] $S:$P"
    SIP=$(resolve_host "$S")
    [ -n "$SIP" ] || { echo "  DNS fail: $S"; IDX=$((IDX+1)); continue; }
    [ "$SIP" = "$S" ] || echo "  resolved: $S -> $SIP"
    printf "SRV=%s\nPRT=%s\nKEY=%s\n" "$SIP" "$P" "$K" > /tmp/udp2raw_srv
    /usr/bin/udp2raw-ctl start || { echo "  start failed"; IDX=$((IDX+1)); continue; }
    # v17.0 FIX: проверяем PID реально жив (bind error = падает через ~1с)
    UPID=$(cat /var/run/udp2raw.pid 2>/dev/null)
    if [ -z "$UPID" ] || ! kill -0 "$UPID" 2>/dev/null; then
        echo "  udp2raw died — bind error?"; cat /tmp/udp2raw.log 2>/dev/null | tail -3
        IDX=$((IDX+1)); continue
    fi
    WG=$(ip route | awk '/^default/{print $3; exit}')
    WI=$(ip route | awk '/^default/{print $5; exit}')
    [ -n "$WG" ] && [ -n "$WI" ] && {
        ip route del "$SIP/32" 2>/dev/null || true
        ip route add "$SIP/32" via "$WG" dev "$WI" 2>/dev/null || true; }
    echo "  TUNNEL UP -> $S ($SIP):$P"
    nvram set udp2raw_status="CONNECTED"; nvram set udp2raw_active="$S:$P"; nvram commit
    echo "=== DONE $(date) ==="; OK=1; break
done < /tmp/vpn_srvlist
[ "$OK" = "1" ] || {
    nvram set udp2raw_status="ALL FAILED"; nvram set udp2raw_active=""; nvram commit
    echo "FATAL: all servers failed"; exit 1; }
VPNEOF
chmod +x "$UDP2RAW_DIR/files/fl-vpn-start"

cat > "$UDP2RAW_DIR/files/fl-vpn-stop" << 'STOPEOF'
#!/bin/sh
[ -f /tmp/udp2raw_srv ] && { . /tmp/udp2raw_srv; ip route del "$SRV/32" 2>/dev/null || true; }
/usr/bin/udp2raw-ctl stop 2>/dev/null || true
nvram set udp2raw_status="DISCONNECTED"; nvram set udp2raw_active=""; nvram commit
STOPEOF
chmod +x "$UDP2RAW_DIR/files/fl-vpn-stop"

cat > "$UDP2RAW_DIR/files/fl-vpn-switch" << 'SWEOF'
#!/bin/sh
/usr/bin/fl-vpn-stop; sleep 1; /usr/bin/fl-vpn-start &
SWEOF
chmod +x "$UDP2RAW_DIR/files/fl-vpn-switch"

cat > "$UDP2RAW_DIR/files/fl-vpn-watchdog" << 'WDEOF'
#!/bin/sh
. /usr/bin/udp2raw-common
PIDFILE="/var/run/fl-vpn-watchdog.pid"
LOG="/tmp/fl-vpn-wd.log"
loop() {
    while true; do
        cfg_load
        if [ "$UDP2RAW_ENABLE" != "1" ]; then
            pidof udp2raw >/dev/null 2>&1 && {
                /usr/bin/fl-vpn-stop
                echo "$(date '+%H:%M:%S') disabled -> stopped" >> "$LOG"; }
            sleep 10; continue
        fi
        # Не трогаем пока идёт запуск
        if lock_is_running "$START_LOCK"; then sleep 5; continue; fi
        if ! pidof udp2raw >/dev/null 2>&1; then
            echo "$(date '+%H:%M:%S') udp2raw dead -> restart" >> "$LOG"
            /usr/bin/fl-vpn-start >> "$LOG" 2>&1
            sleep 15; continue
        fi
        sleep 20
    done
}
case "${1:-}" in
    start)
        lock_is_running "$PIDFILE" && { echo "watchdog already running"; exit 0; }
        loop &; echo $! > "$PIDFILE"; echo "watchdog started PID=$(cat "$PIDFILE")" ;;
    stop)
        [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null || true
        rm -f "$PIDFILE"; echo "watchdog stopped" ;;
    restart)
        [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null || true
        rm -f "$PIDFILE"; loop &; echo $! > "$PIDFILE"
        echo "watchdog restarted PID=$(cat "$PIDFILE")" ;;
    status)
        lock_is_running "$PIDFILE" \
            && echo "watchdog running PID=$(cat "$PIDFILE")" \
            || echo "watchdog stopped" ;;
    *) echo "Usage: fl-vpn-watchdog {start|stop|restart|status}" ;;
esac
WDEOF
chmod +x "$UDP2RAW_DIR/files/fl-vpn-watchdog"

cat > "$UDP2RAW_DIR/files/fl-vpn-status" << 'STEOF'
#!/bin/sh
. /usr/bin/udp2raw-common; cfg_load
echo "=== MILLENIUM VPN ==="
printf "Enable:   %s\n" "$UDP2RAW_ENABLE"
printf "Servers:  %s\n" "$UDP2RAW_SERVERS"
printf "Status:   %s\n" "$(nvram get udp2raw_status 2>/dev/null)"
printf "Active:   %s\n" "$(nvram get udp2raw_active 2>/dev/null)"
printf "udp2raw:  %s\n" "$(pidof udp2raw >/dev/null 2>&1 && echo "ON($(pidof udp2raw))" || echo OFF)"
printf "openvpn:  %s\n" "$(pidof openvpn >/dev/null 2>&1 && echo ON || echo OFF)"
printf "watchdog: %s\n" "$(/usr/bin/fl-vpn-watchdog status)"
printf "start_lk: %s\n" "$(lock_is_running "$START_LOCK" && echo LOCKED || echo free)"
[ -f /tmp/udp2raw.log ] && echo "--- udp2raw ---" && tail -20 /tmp/udp2raw.log
STEOF
chmod +x "$UDP2RAW_DIR/files/fl-vpn-status"
echo "  Scripts OK"

############################################################
# 5. restart_udp2raw — v17.0: START_LOCK ДО fork
############################################################
echo ">>> [5] restart_udp2raw"
mkdir -p "$ROMFS_SBIN"

cat > "$ROMFS_SBIN/restart_udp2raw" << 'RSTEOF'
#!/bin/sh
. /usr/bin/udp2raw-common
LOG="/tmp/udp2raw_restart.log"
if lock_is_running "$RESTART_LOCK"; then exit 0; fi
lock_take "$RESTART_LOCK"
trap 'lock_release "$RESTART_LOCK"' EXIT INT TERM
exec >> "$LOG" 2>&1
echo "=== restart_udp2raw $(date) ==="
cfg_load; nvram_sync
echo "  EN=$UDP2RAW_ENABLE"
if [ "$UDP2RAW_ENABLE" = "1" ]; then
    echo "  -> fl-vpn-start"
    # v17.0 FIX: берём START_LOCK ДО fork
    # watchdog стартует через ~6мс после fork — без этого lock'а
    # он видит нет-lock+нет-udp2raw и запускает второй fl-vpn-start
    # = двойной udp2raw = socket bind error
    lock_take "$START_LOCK"
    /usr/bin/fl-vpn-start &
    # Ждём пока fl-vpn-start возьмёт свой lock
    sleep 1
    # Освобождаем наш lock — fl-vpn-start уже держит свой
    lock_release "$START_LOCK"
else
    echo "  -> fl-vpn-stop"
    /usr/bin/fl-vpn-stop
fi
# Запускаем watchdog с паузой — fl-vpn-start уже держит START_LOCK
sleep 2
/usr/bin/fl-vpn-watchdog restart >/dev/null 2>&1 || \
    /usr/bin/fl-vpn-watchdog start  >/dev/null 2>&1 || true
RSTEOF
chmod +x "$ROMFS_SBIN/restart_udp2raw"
cp "$ROMFS_SBIN/restart_udp2raw" "$UDP2RAW_DIR/files/restart_udp2raw"
chmod +x "$UDP2RAW_DIR/files/restart_udp2raw"
echo "  Created restart_udp2raw"

############################################################
# 6. default storage
############################################################
echo ">>> [6] default storage"
mkdir -p "$ROMFS_STORAGE"
cat > "$ROMFS_STORAGE/udp2raw.conf" << 'CFGEOF'
#!/bin/sh
UDP2RAW_ENABLE="0"
UDP2RAW_SERVERS=""
UDP2RAW_LOGLEVEL="0"
CFGEOF
chmod +x "$ROMFS_STORAGE/udp2raw.conf"

############################################################
# 7. custom-extras
############################################################
echo ">>> [7] custom-extras"
CUSTOM_DIR="$TRUNK/user/custom-extras"
[ -d "$CUSTOM_DIR" ] && mkdir -p "$CUSTOM_DIR/files/etc/storage/wireguard"
echo "  OK"

############################################################
# 8. user/Makefile
############################################################
echo ">>> [8] user/Makefile"
UMAKEFILE="$TRUNK/user/Makefile"
if ! grep -q "udp2raw-tunnel" "$UMAKEFILE"; then
    sed -i 's/for i in $(dir_y) ;/for i in $(dir_y) udp2raw-tunnel custom-extras ;/g' "$UMAKEFILE"
    sed -i 's/for i in `ls -d \*` ;/for i in `ls -d *` udp2raw-tunnel custom-extras ;/g' "$UMAKEFILE"
    echo "  PATCHED"
else
    echo "  ALREADY PATCHED"
fi

############################################################
# 9. Makefile udp2raw-tunnel
############################################################
cat > "$UDP2RAW_DIR/Makefile" << 'MKEOF'
all:
	@echo "[udp2raw-tunnel] pre-compiled"
romfs:
	@echo "[udp2raw-tunnel] installing..."
	$(ROMFSINST) -p +x files/udp2raw          /usr/bin/udp2raw
	$(ROMFSINST) -p +x files/udp2raw-common   /usr/bin/udp2raw-common
	$(ROMFSINST) -p +x files/udp2raw-save     /usr/bin/udp2raw-save
	$(ROMFSINST) -p +x files/u2s              /usr/bin/u2s
	$(ROMFSINST) -p +x files/udp2raw-ctl      /usr/bin/udp2raw-ctl
	$(ROMFSINST) -p +x files/fl-vpn-start     /usr/bin/fl-vpn-start
	$(ROMFSINST) -p +x files/fl-vpn-stop      /usr/bin/fl-vpn-stop
	$(ROMFSINST) -p +x files/fl-vpn-switch    /usr/bin/fl-vpn-switch
	$(ROMFSINST) -p +x files/fl-vpn-watchdog  /usr/bin/fl-vpn-watchdog
	$(ROMFSINST) -p +x files/fl-vpn-status    /usr/bin/fl-vpn-status
	$(ROMFSINST) -p +x files/restart_udp2raw  /sbin/restart_udp2raw
	@echo "[udp2raw-tunnel] DONE"
clean:
	@echo "[udp2raw-tunnel] clean"
MKEOF

############################################################
# 10. WebUI
############################################################
echo ">>> [9] WebUI"
cat > "$WWW/millenium_status.asp" << 'EOF'
<% nvram_get_x("", "udp2raw_status"); %>|<% nvram_get_x("", "udp2raw_active"); %>
EOF

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
.help-text  { color:#888; font-size:11px; margin-top:3px; }
.status-box { background:#f5f5f5; border-radius:6px; padding:12px 16px; margin:10px; }
</style>
<script>var $j = jQuery.noConflict();</script>
<script>
<% login_state_hook(); %>
var m_status = '<% nvram_get_x("", "udp2raw_status"); %>';
var m_active  = '<% nvram_get_x("", "udp2raw_active"); %>';

function initial(){
    show_banner(0); show_menu(7,-1,0); show_footer();
    load_body(); load_servers(); syncToggle(); syncLogLevel(); update_status();
    var ld = document.getElementById('Loading');
    if (ld) ld.style.display = 'none';
    inject_menu();
    setInterval(poll_status, 5000);
}

function poll_status(){
    $j.get('/millenium_status.asp?t='+Date.now(), function(d){
        var p = d.split('|');
        if (p.length >= 2){ m_status=p[0].trim(); m_active=p[1].trim(); update_status(); }
    });
}

function inject_menu(){
    var sub = document.getElementById('subMenu');
    if (!sub || sub.innerHTML.indexOf('Advanced_udp2raw') >= 0) return;
    var groups = sub.getElementsByClassName('accordion-group');
    if (groups.length > 0){
        var d = document.createElement('div');
        d.className = 'accordion-group';
        d.innerHTML = '<div class="accordion-heading"><a class="accordion-toggle" style="padding:5px 15px;" href="/Advanced_udp2raw.asp"><b>MILLENIUM VPN</b></a></div>';
        groups[groups.length-1].parentNode.appendChild(d);
    }
}

function update_status(){
    var s = m_status || 'DISCONNECTED';
    var el = document.getElementById('vpn_status');
    var info = document.getElementById('vpn_info');
    if (!el) return;
    if (s === 'CONNECTED'){
        el.innerHTML = '<span class="label label-success" style="font-size:14px;padding:5px 12px;">&#x25CF; Туннель активен</span>';
        info.innerHTML = m_active ? 'Сервер: <b>'+m_active+'</b>' : '';
    } else if (s === 'CONNECTING...'){
        el.innerHTML = '<span class="label label-warning" style="font-size:14px;padding:5px 12px;">&#x25CF; Подключение...</span>';
        info.innerHTML = '<i>Запуск туннеля...</i>';
    } else {
        el.innerHTML = '<span class="label label-important" style="font-size:14px;padding:5px 12px;">&#x25CB; Туннель выкл.</span>';
        info.innerHTML = (s && s !== 'DISCONNECTED') ? '<span style="color:#c00">'+s+'</span>' : '';
    }
}

function syncToggle(){
    var val = document.getElementById('udp2raw_enable_val').value || '0';
    var sel = document.getElementById('udp2raw_enable_sel');
    if (sel){ sel.value = val; change_enabled(); }
}
function onEnableChange(){ change_enabled(); }
function change_enabled(){
    var sel = document.getElementById('udp2raw_enable_sel');
    showhide_div('cfg_main', sel && sel.value === '1');
}
function load_servers(){
    var fld = document.getElementById('udp2raw_servers_stored');
    if (fld) document.getElementById('srv_text').value = fld.value.replace(/%/g,'\n');
}
function syncLogLevel(){
    var val = document.getElementById('udp2raw_loglevel_val').value || '0';
    var sel = document.getElementById('udp2raw_loglevel_sel');
    if (!sel) return;
    for (var i=0; i<sel.options.length; i++){
        if (sel.options[i].value === val){ sel.selectedIndex=i; break; }
    }
}
function shellEscape(s){ return "'"+String(s).replace(/'/g,"'\\''")+"'"; }

function applyRule(){
    var sv = document.getElementById('srv_text').value;
    sv = sv.replace(/\r\n/g,'\n').replace(/\n+/g,'\n').replace(/^\n|\n$/g,'');
    var en = document.getElementById('udp2raw_enable_sel').value;
    var ll = document.getElementById('udp2raw_loglevel_sel').value;
    var compact = sv.replace(/\n/g,'%');

    var btn = document.getElementById('save_btn');
    var msg = document.getElementById('apply_msg');
    if (btn){ btn.value='Сохранение...'; btn.disabled=true; }
    if (msg) msg.innerHTML = 'Сохранение конфига...';
    m_status='CONNECTING...'; m_active=''; update_status();

    // v17.0: шаг 1 — сохранить конфиг (без restart)
    $j.post('/apply.cgi', {
        current_page:'Advanced_udp2raw.asp', next_page:'Advanced_udp2raw.asp',
        action_mode:' SystemCmd ', action_script:'',
        SystemCmd: '/usr/bin/u2s '+shellEscape(en)+' '+shellEscape(compact)+' '+shellEscape(ll)
    }).always(function(){
        if (msg) msg.innerHTML = 'Запуск туннеля...';
        // шаг 2 — отдельный запуск restart (через 300мс)
        setTimeout(function(){
            $j.post('/apply.cgi', {
                current_page:'Advanced_udp2raw.asp', next_page:'Advanced_udp2raw.asp',
                action_mode:' SystemCmd ', action_script:'',
                SystemCmd: '/sbin/restart_udp2raw'
            }).always(function(){
                document.getElementById('udp2raw_enable_val').value = en;
                document.getElementById('udp2raw_servers_stored').value = compact;
                document.getElementById('udp2raw_loglevel_val').value = ll;
                if (msg) msg.innerHTML = 'Выполнено. Ожидание статуса...';
                setTimeout(poll_status, 2000);
                setTimeout(poll_status, 5000);
                setTimeout(poll_status, 10000);
                if (btn){ btn.value='Сохранить и применить'; btn.disabled=false; }
            });
        }, 300);
    });
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
<input type="hidden" id="udp2raw_enable_val"     value="<% nvram_get_x("", "udp2raw_enable"); %>">
<input type="hidden" id="udp2raw_servers_stored"  value="<% nvram_get_x("", "udp2raw_servers"); %>">
<input type="hidden" id="udp2raw_loglevel_val"    value="<% nvram_get_x("", "udp2raw_loglevel"); %>">
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
          <b>Как работает:</b> OpenVPN &rarr; 127.0.0.1:3333 &rarr; udp2raw (faketcp) &rarr; сервер<br>
          DPI видит обычный TCP. Туннель стартует автоматически при WAN-up.<br>
          <b>VPN клиент:</b> <a href="/vpncli.asp">Настройки</a>
          &rarr; Сервер: <b>127.0.0.1</b>, порт: <b>3333</b>, транспорт: <b>UDP</b>
        </div>
        <div class="status-box">
          <span id="vpn_status"></span>
          <span id="vpn_info" style="color:#555;margin-left:10px;"></span>
        </div>
        <table class="table">
          <tr>
            <th width="50%" style="border-top:0 none;">Включить udp2raw туннель</th>
            <td style="border-top:0 none;">
              <select id="udp2raw_enable_sel" class="span3" onchange="onEnableChange();">
                <option value="0">OFF</option>
                <option value="1">ON</option>
              </select>
            </td>
          </tr>
        </table>
        <div id="cfg_main" style="display:none;">
        <table class="table">
          <tr><th colspan="2" style="background:#E3E3E3;">Список серверов</th></tr>
          <tr>
            <td colspan="2">
              <textarea id="srv_text" rows="6" wrap="off" spellcheck="false" class="span12"
                style="font-family:'Courier New';font-size:12px;"
                placeholder="89.39.70.159:4096:millenium2026&#10;server2.example.com:4096:millenium2026"></textarea>
              <div class="help-text">Формат: ХОСТ:ПОРТ:ПАРОЛЬ, один на строку. Автоматический failover.</div>
            </td>
          </tr>
          <tr>
            <th width="50%">Подробное логирование</th>
            <td>
              <select id="udp2raw_loglevel_sel" class="span4">
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
              <input type="button" id="save_btn" class="btn btn-primary" style="width:219px"
                onclick="applyRule();" value="Сохранить и применить">
              <div id="apply_msg" class="help-text" style="text-align:center;margin-top:8px;">
                Статус обновляется каждые 5 сек.
              </div>
            </td>
          </tr>
        </table>
      </div>
    </div>
  </div>
</div></div>
<div id="footer"></div>
</div>
</body>
</html>
ASPEOF
echo "  Created Advanced_udp2raw.asp v17.0"

############################################################
# 11. state.js
############################################################
echo ">>> [10] state.js menu"
STATEJS="$WWW/state.js"
if [ -f "$STATEJS" ] && ! grep -q "Advanced_udp2raw" "$STATEJS"; then
    ML2_LINE=$(grep -n 'menuL2_link.*new Array' "$STATEJS" | head -1 | cut -d: -f1)
    [ -n "$ML2_LINE" ] && sed -i "${ML2_LINE}a\\
menuL2_title.push(\"MILLENIUM VPN\");\\
menuL2_link.push(\"Advanced_udp2raw.asp\");" "$STATEJS" && echo "  OK"
else
    [ -f "$STATEJS" ] && echo "  ALREADY PATCHED" || echo "  WARN: state.js not found"
fi

############################################################
# 12. nvram defaults
############################################################
echo ">>> [11] nvram defaults"
patch_nvram_defaults() {
    local FILE="$1" LABEL="$2"
    [ -f "$FILE" ] || return
    grep -q "udp2raw_enable" "$FILE" && { echo "  Already ($LABEL)"; return; }
    for TERM in '{ 0, 0 }' '{0, 0}'; do
        grep -q "$TERM" "$FILE" || continue
        LINE=$(grep -n "$TERM" "$FILE" | tail -1 | cut -d: -f1)
        sed -i "${LINE}i\\
\t{ \"udp2raw_enable\",   \"0\" },\\
\t{ \"udp2raw_servers\",  \"\" },\\
\t{ \"udp2raw_status\",   \"\" },\\
\t{ \"udp2raw_active\",   \"\" },\\
\t{ \"udp2raw_loglevel\", \"0\" }," "$FILE"
        echo "  Patched ($LABEL)"; return
    done
    echo "  WARN: terminator not found ($LABEL)"
}
patch_nvram_defaults "$TRUNK/user/shared/defaults.c" "shared/defaults.c"

############################################################
# 13. MTU
############################################################
echo ">>> [12] MTU defaults"
F="$TRUNK/user/shared/defaults.c"
if [ -f "$F" ] && ! grep -q "vpnc_cus3" "$F"; then
    for TERM in '{ 0, 0 }' '{0, 0}'; do
        grep -q "$TERM" "$F" || continue
        LINE=$(grep -n "$TERM" "$F" | tail -1 | cut -d: -f1)
        sed -i "${LINE}i\\\t{ \"vpnc_cus3\", \"tun-mtu 1300\\\\nmssfix 1260\" }," "$F"
        echo "  Added vpnc_cus3"; break
    done
fi

############################################################
# 14. rc.c
############################################################
echo ">>> [13] rc.c — restart_udp2raw handler"
RC_FILE="$TRUNK/user/rc/rc.c"
if grep -q 'restart_udp2raw' "$RC_FILE" 2>/dev/null; then
    echo "  Already patched"
elif [ -f "$RC_FILE" ]; then
    cat > /tmp/patch_rc.py << 'RCPY'
import sys
rc_file = sys.argv[1]
with open(rc_file) as f:
    lines = f.readlines()
zapret_start = None
for i, line in enumerate(lines):
    if 'APP_ZAPRET' in line and '#if' in line:
        zapret_start = i; break
if zapret_start is None:
    print("  ERROR: APP_ZAPRET not found"); sys.exit(1)
endif_line = None
for i in range(zapret_start+1, min(zapret_start+20, len(lines))):
    if lines[i].strip() == '#endif':
        endif_line = i; break
if endif_line is None:
    print("  ERROR: #endif not found"); sys.exit(1)
new_block = [
    '\t\telse if (strcmp(entry->d_name, "restart_udp2raw") == 0)\n',
    '\t\t{\n',
    '\t\t\tsystem("/sbin/restart_udp2raw");\n',
    '\t\t}\n',
]
for idx, nl in enumerate(new_block):
    lines.insert(endif_line+1+idx, nl)
with open(rc_file, 'w') as f:
    f.writelines(lines)
if 'restart_udp2raw' in open(rc_file).read():
    print("  VERIFY OK")
else:
    print("  VERIFY FAILED"); sys.exit(1)
RCPY
    python3 /tmp/patch_rc.py "$RC_FILE"
else
    echo "  WARN: rc.c not found"
fi

echo ""
echo "============================================"
echo "  MILLENIUM Group VPN — build ready v17.0"
echo "  1. START_LOCK берётся ДО fork (нет двойного запуска)"
echo "  2. PID проверяется после sleep 2 (нет ложного CONNECTED)"
echo "  3. restart убран из udp2raw-save (нет дублирования)"
echo "  4. AJAX: 2 раздельных запроса save + restart"
echo "============================================"
echo ""
echo "=== DIAGNOSTICS ==="
ls -la "$UDP2RAW_DIR/files/" 2>/dev/null
grep -n "restart_udp2raw" "$TRUNK"/user/rc/*.c 2>/dev/null || echo "rc.c: check manually"
ls "$WWW/Advanced_udp2raw.asp" "$WWW/millenium_status.asp" 2>/dev/null && echo "ASP OK"
echo "=== END ==="
