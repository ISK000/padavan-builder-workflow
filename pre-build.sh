#!/usr/bin/env bash
############################################################
# MILLENIUM Group — Padavan-NG pre-build v16.2
#
# v16.2:
# - fixed duplicate fl-vpn-start launches
# - removed nohup (not present on router)
# - real SystemCmd via AJAX /apply.cgi
# - lock files for restart/start
# - config in /etc/storage/udp2raw.conf
# - watchdog aware of active startup
############################################################
set -euo pipefail

TRUNK="padavan-ng/trunk"
UDP2RAW_DIR="$TRUNK/user/udp2raw-tunnel"
WWW="$TRUNK/user/www/n56u_ribbon_fixed"
ROMFS_STORAGE="$TRUNK/romfs/etc/storage"
ROMFS_SBIN="$TRUNK/romfs/sbin"

echo "============================================"
echo "  MILLENIUM Group VPN — pre-build v16.2"
echo "  FIX: lock files + real AJAX SystemCmd"
echo "============================================"

############################################################
# 1. OpenVPN 2.6.14 + XOR patch
############################################################
echo ">>> [1] OpenVPN XOR patch"
OVPN_VER=2.6.14
RELEASE_URL="https://github.com/luzrain/openvpn-xorpatch/releases/download/v${OVPN_VER}/openvpn-${OVPN_VER}.tar.gz"

for dir in "$TRUNK/user/openvpn" "$TRUNK/user/openvpn-openssl"; do
  mf="${dir}/Makefile"
  [[ -f "$mf" ]] || continue
  echo "  refresh: ${dir}"
  rm -rf "${dir}/openvpn-${OVPN_VER}" "${dir}/openvpn-${OVPN_VER}.tar."* 2>/dev/null || true
  curl -L --retry 5 -o "${dir}/openvpn-${OVPN_VER}.tar.gz" "${RELEASE_URL}"
  sed -i "s|^SRC_NAME=.*|SRC_NAME=openvpn-${OVPN_VER}|" "$mf"
  sed -i "s|^SRC_URL=.*|SRC_URL=${RELEASE_URL}|" "$mf"
  grep -q -- '--enable-xor-patch' "$mf" || \
    sed -i 's/--enable-small/--enable-small \\\n\t--enable-xor-patch/' "$mf"
  sed -i 's|true # autoreconf disabled.*|autoreconf -fi |' "$mf"
  sed -i '/openvpn-orig\.patch/s|^[^\t#]|#&|' "$mf"
  echo "  OK: XOR patch enabled in ${dir}"
done

############################################################
# 2. WebUI branding
############################################################
echo ">>> [2] WebUI branding"
CUSTOM_MODEL="MILLENIUM Group VPN (private build)"
CUSTOM_FOOTER="(c) 2025 MILLENIUM Group. Powered by Padavan-NG"
find "$TRUNK" -name '*.dict' -print0 | while IFS= read -r -d '' F; do
  sed -i "s/ZVMODELVZ/${CUSTOM_MODEL//\//\\/}/g" "$F"
  sed -i "s/ZVCOPYRVZ/${CUSTOM_FOOTER//\//\\/}/g" "$F"
done
echo "  OK"

############################################################
# 3. udp2raw binary
############################################################
echo ">>> [3] udp2raw binary"
mkdir -p "$UDP2RAW_DIR/files"
curl -sL -o /tmp/udp2raw_binaries.tar.gz \
  https://github.com/wangyu-/udp2raw/releases/download/20230206.0/udp2raw_binaries.tar.gz
cd /tmp
tar xzf udp2raw_binaries.tar.gz
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
START_LOCK="/var/run/fl-vpn-start.pid"
RESTART_LOCK="/var/run/restart_udp2raw.pid"

cfg_load() {
    UDP2RAW_ENABLE=0
    UDP2RAW_SERVERS=""
    UDP2RAW_LOGLEVEL=0

    if [ -f "$CFG" ]; then
        . "$CFG"
    fi

    [ -n "${UDP2RAW_ENABLE:-}" ] || UDP2RAW_ENABLE=0
    [ -n "${UDP2RAW_SERVERS:-}" ] || UDP2RAW_SERVERS=""
    [ -n "${UDP2RAW_LOGLEVEL:-}" ] || UDP2RAW_LOGLEVEL=0
}

nvram_sync() {
    nvram set udp2raw_enable="${UDP2RAW_ENABLE:-0}"
    nvram set udp2raw_servers="${UDP2RAW_SERVERS:-}"
    nvram set udp2raw_loglevel="${UDP2RAW_LOGLEVEL:-0}"
    nvram commit
}

lock_is_running() {
    PIDFILE="$1"
    [ -f "$PIDFILE" ] || return 1
    PID="$(cat "$PIDFILE" 2>/dev/null)"
    [ -n "$PID" ] || return 1
    kill -0 "$PID" 2>/dev/null
}

lock_take() {
    PIDFILE="$1"
    echo $$ > "$PIDFILE"
}

lock_release() {
    PIDFILE="$1"
    rm -f "$PIDFILE"
}
CMEOF
chmod +x "$UDP2RAW_DIR/files/udp2raw-common"

cat > "$UDP2RAW_DIR/files/udp2raw-save" << 'SAVEOF'
#!/bin/sh
CFG="/etc/storage/udp2raw.conf"
POSTWAN="/etc/storage/post_wan_script.sh"
TMP="/tmp/udp2raw.conf.tmp"

EN="${1:-0}"
SRVS="${2:-}"
LOGLEVEL="${3:-0}"

safe() {
    printf '%s' "$1" | sed 's/[\\`"$]/\\&/g'
}

EN_SAFE="$(safe "$EN")"
SRVS_SAFE="$(safe "$SRVS")"
LOGLEVEL_SAFE="$(safe "$LOGLEVEL")"

mkdir -p /etc/storage

cat > "$TMP" <<EOF
#!/bin/sh
UDP2RAW_ENABLE="$EN_SAFE"
UDP2RAW_SERVERS="$SRVS_SAFE"
UDP2RAW_LOGLEVEL="$LOGLEVEL_SAFE"
EOF

chmod 600 "$TMP"
mv "$TMP" "$CFG"

nvram set udp2raw_enable="$EN"
nvram set udp2raw_servers="$SRVS"
nvram set udp2raw_loglevel="$LOGLEVEL"
nvram set udp2raw_status="DISCONNECTED"
nvram set udp2raw_active=""
nvram commit

touch "$POSTWAN"
if ! grep -q "### UDP2RAW AUTO START ###" "$POSTWAN" 2>/dev/null; then
cat >> "$POSTWAN" <<'EOF'

### UDP2RAW AUTO START ###
if [ -f /etc/storage/udp2raw.conf ]; then
    . /etc/storage/udp2raw.conf
    /usr/bin/fl-vpn-watchdog start >/dev/null 2>&1 || true
    if [ "${UDP2RAW_ENABLE:-0}" = "1" ]; then
        /sbin/restart_udp2raw >/dev/null 2>&1 &
    fi
fi
### UDP2RAW AUTO END ###
EOF
chmod +x "$POSTWAN"
fi

/sbin/mtd_storage.sh save >/dev/null 2>&1 || true
/sbin/restart_udp2raw >/dev/null 2>&1 &

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

do_start_once() {
    cfg_load

    [ -f /tmp/udp2raw_srv ] && . /tmp/udp2raw_srv || { echo "No server config"; return 1; }
    [ -n "$SRV" ] || { echo "SRV empty"; return 1; }
    [ -n "$PRT" ] || PRT=4096
    [ -n "$KEY" ] || KEY=changeme

    killall udp2raw 2>/dev/null || true
    sleep 2

    iptables -D OUTPUT -p tcp --dport "$PRT" --tcp-flags RST RST -j DROP 2>/dev/null || true
    iptables -I OUTPUT 1 -p tcp --dport "$PRT" --tcp-flags RST RST -j DROP

    /usr/bin/udp2raw -c \
        -l "127.0.0.1:3333" \
        -r "${SRV}:${PRT}" \
        -k "$KEY" \
        --raw-mode faketcp \
        --cipher-mode xor \
        --auth-mode simple \
        -a --log-level "${UDP2RAW_LOGLEVEL:-0}" > "$LOGFILE" 2>&1 &

    echo $! > "$PIDFILE"
    sleep 3

    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "OK PID=$(cat "$PIDFILE")"
        return 0
    fi

    echo "FAIL"
    return 1
}

do_start() {
    do_start_once && return 0
    sleep 3
    do_start_once && return 0
    return 1
}

do_stop() {
    if [ -f /tmp/udp2raw_srv ]; then
        . /tmp/udp2raw_srv
        iptables -D OUTPUT -p tcp --dport "${PRT:-4096}" --tcp-flags RST RST -j DROP 2>/dev/null || true
    fi
    [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null || true
    rm -f "$PIDFILE"
    killall udp2raw 2>/dev/null || true
    echo "Stopped"
}

case "${1:-}" in
    start)   do_start ;;
    stop)    do_stop ;;
    restart) do_stop; sleep 2; do_start ;;
    status)
        if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
            echo "RUNNING PID=$(cat "$PIDFILE")"
        else
            echo "STOPPED"
        fi
        ;;
    *) echo "Usage: udp2raw-ctl {start|stop|restart|status}" ;;
esac
CTLEOF
chmod +x "$UDP2RAW_DIR/files/udp2raw-ctl"

cat > "$UDP2RAW_DIR/files/fl-vpn-start" << 'VPNEOF'
#!/bin/sh
. /usr/bin/udp2raw-common

LOG="/tmp/fl-vpn.log"

if lock_is_running "$START_LOCK"; then
    echo "fl-vpn-start already running"
    exit 0
fi

lock_take "$START_LOCK"
trap 'lock_release "$START_LOCK"' EXIT INT TERM

exec >> "$LOG" 2>&1
echo "=== fl-vpn-start $(date) ==="

cfg_load
nvram_sync

SERVERS="$UDP2RAW_SERVERS"
[ -n "$SERVERS" ] || {
    echo "No servers in config"
    nvram set udp2raw_status="NO CONFIG"
    nvram set udp2raw_active=""
    nvram commit
    exit 1
}

echo "$SERVERS" | tr '%' '\n' > /tmp/vpn_srvlist
/usr/bin/fl-vpn-stop 2>/dev/null || true
sleep 1

nvram set udp2raw_status="CONNECTING..."
nvram set udp2raw_active=""
nvram commit

resolve_host() {
    H="$1"
    echo "$H" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' && { echo "$H"; return; }

    IP=$(nslookup "$H" 2>/dev/null | awk '/^Address/{if(NR>2)print $NF}' | head -1)
    echo "$IP" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' && { echo "$IP"; return; }

    IP=$(ping -c1 -W3 "$H" 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    [ -n "$IP" ] && echo "$IP"
}

OK=0
IDX=0
while IFS='' read -r line; do
    [ -n "$line" ] || continue
    echo "$line" | grep -q "^#" && continue

    S=$(echo "$line" | cut -d: -f1)
    P=$(echo "$line" | cut -d: -f2)
    K=$(echo "$line" | cut -d: -f3-)

    [ -n "$S" ] || continue
    [ -n "$P" ] || P=4096
    [ -n "$K" ] || K=changeme

    echo ">>> [$IDX] $S:$P"

    SIP=$(resolve_host "$S")
    if [ -z "$SIP" ]; then
        echo "  DNS fail: $S"
        IDX=$((IDX+1))
        continue
    fi

    [ "$SIP" = "$S" ] || echo "  resolved: $S -> $SIP"

    printf "SRV=%s\nPRT=%s\nKEY=%s\n" "$SIP" "$P" "$K" > /tmp/udp2raw_srv

    /usr/bin/udp2raw-ctl start
    if [ $? -ne 0 ]; then
        echo "  udp2raw start failed"
        IDX=$((IDX+1))
        continue
    fi

    WG=$(ip route | awk '/^default/{print $3; exit}')
    WI=$(ip route | awk '/^default/{print $5; exit}')
    if [ -n "$WG" ] && [ -n "$WI" ]; then
        ip route del "$SIP/32" 2>/dev/null || true
        ip route add "$SIP/32" via "$WG" dev "$WI" 2>/dev/null || true
    fi

    echo "  TUNNEL UP -> $S ($SIP):$P"
    nvram set udp2raw_status="CONNECTED"
    nvram set udp2raw_active="$S:$P"
    nvram commit
    echo "=== DONE $(date) ==="
    OK=1
    break
done < /tmp/vpn_srvlist

if [ "$OK" != "1" ]; then
    nvram set udp2raw_status="ALL FAILED"
    nvram set udp2raw_active=""
    nvram commit
    echo "FATAL: all servers failed"
    exit 1
fi
VPNEOF
chmod +x "$UDP2RAW_DIR/files/fl-vpn-start"

cat > "$UDP2RAW_DIR/files/fl-vpn-stop" << 'STOPEOF'
#!/bin/sh
if [ -f /tmp/udp2raw_srv ]; then
    . /tmp/udp2raw_srv
    ip route del "$SRV/32" 2>/dev/null || true
fi
/usr/bin/udp2raw-ctl stop 2>/dev/null || true
nvram set udp2raw_status="DISCONNECTED"
nvram set udp2raw_active=""
nvram commit
STOPEOF
chmod +x "$UDP2RAW_DIR/files/fl-vpn-stop"

cat > "$UDP2RAW_DIR/files/fl-vpn-switch" << 'SWEOF'
#!/bin/sh
/usr/bin/fl-vpn-stop
sleep 1
/usr/bin/fl-vpn-start &
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
        nvram_sync

        if [ "$UDP2RAW_ENABLE" != "1" ]; then
            pidof udp2raw >/dev/null 2>&1 && {
                /usr/bin/fl-vpn-stop
                echo "$(date '+%H:%M:%S') disabled -> stopped" >> "$LOG"
            }
            sleep 10
            continue
        fi

        if lock_is_running "$START_LOCK"; then
            sleep 5
            continue
        fi

        if ! pidof udp2raw >/dev/null 2>&1; then
            echo "$(date '+%H:%M:%S') udp2raw dead -> restart" >> "$LOG"
            /usr/bin/fl-vpn-start >> "$LOG" 2>&1
            sleep 10
            continue
        fi

        if ! pidof openvpn >/dev/null 2>&1; then
            echo "$(date '+%H:%M:%S') openvpn dead -> keep tunnel alive" >> "$LOG"
        fi

        sleep 20
    done
}

case "${1:-}" in
    start)
        if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
            echo "watchdog already running"
            exit 0
        fi
        loop &
        echo $! > "$PIDFILE"
        echo "watchdog started PID=$(cat "$PIDFILE")"
        ;;
    stop)
        [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null || true
        rm -f "$PIDFILE"
        echo "watchdog stopped"
        ;;
    restart)
        [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null || true
        rm -f "$PIDFILE"
        loop &
        echo $! > "$PIDFILE"
        echo "watchdog restarted PID=$(cat "$PIDFILE")"
        ;;
    status)
        if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
            echo "watchdog running PID=$(cat "$PIDFILE")"
        else
            echo "watchdog stopped"
        fi
        ;;
    *)
        echo "Usage: fl-vpn-watchdog {start|stop|restart|status}"
        ;;
esac
WDEOF
chmod +x "$UDP2RAW_DIR/files/fl-vpn-watchdog"

cat > "$UDP2RAW_DIR/files/fl-vpn-status" << 'STEOF'
#!/bin/sh
. /usr/bin/udp2raw-common
cfg_load
echo "=== MILLENIUM VPN ==="
printf "Enable(cfg):  %s\n" "$UDP2RAW_ENABLE"
printf "Servers(cfg): %s\n" "$UDP2RAW_SERVERS"
printf "Loglevel:     %s\n" "$UDP2RAW_LOGLEVEL"
printf "Status:       %s\n" "$(nvram get udp2raw_status 2>/dev/null || echo '?')"
printf "Server:       %s\n" "$(nvram get udp2raw_active 2>/dev/null || echo '-')"
printf "udp2raw:      %s\n" "$(pidof udp2raw >/dev/null && echo "ON ($(pidof udp2raw))" || echo OFF)"
printf "openvpn:      %s\n" "$(pidof openvpn >/dev/null && echo "ON ($(pidof openvpn))" || echo OFF)"
printf "watchdog:     %s\n" "$(/usr/bin/fl-vpn-watchdog status)"
[ -f /tmp/udp2raw.log ] && echo "--- last udp2raw ---" && tail -20 /tmp/udp2raw.log
STEOF
chmod +x "$UDP2RAW_DIR/files/fl-vpn-status"

echo "  Scripts OK"

############################################################
# 5. restart_udp2raw helper
############################################################
echo ">>> [5] restart_udp2raw helper"
mkdir -p "$ROMFS_SBIN"

cat > "$ROMFS_SBIN/restart_udp2raw" << 'RSTEOF'
#!/bin/sh
. /usr/bin/udp2raw-common

LOG="/tmp/udp2raw_restart.log"

if lock_is_running "$RESTART_LOCK"; then
    exit 0
fi

lock_take "$RESTART_LOCK"
trap 'lock_release "$RESTART_LOCK"' EXIT INT TERM

exec >> "$LOG" 2>&1
echo "=== restart_udp2raw $(date) ==="

cfg_load
nvram_sync

echo "  EN=$UDP2RAW_ENABLE SRVS=$UDP2RAW_SERVERS LOGLEVEL=$UDP2RAW_LOGLEVEL"

if [ "$UDP2RAW_ENABLE" = "1" ]; then
    echo "  -> fl-vpn-start"
    /usr/bin/fl-vpn-start &
else
    echo "  -> fl-vpn-stop"
    /usr/bin/fl-vpn-stop
fi

/usr/bin/fl-vpn-watchdog restart >/dev/null 2>&1 || /usr/bin/fl-vpn-watchdog start >/dev/null 2>&1
RSTEOF
chmod +x "$ROMFS_SBIN/restart_udp2raw"
cp "$ROMFS_SBIN/restart_udp2raw" "$UDP2RAW_DIR/files/restart_udp2raw"
chmod +x "$UDP2RAW_DIR/files/restart_udp2raw"
echo "  Created restart_udp2raw"

############################################################
# 6. default storage files
############################################################
echo ">>> [6] default storage files"
mkdir -p "$ROMFS_STORAGE"

cat > "$ROMFS_STORAGE/udp2raw.conf" << 'CFGEOF'
#!/bin/sh
UDP2RAW_ENABLE="0"
UDP2RAW_SERVERS=""
UDP2RAW_LOGLEVEL="0"
CFGEOF
chmod +x "$ROMFS_STORAGE/udp2raw.conf"
echo "  Created udp2raw.conf"

############################################################
# 7. custom-extras
############################################################
echo ">>> [7] custom-extras"
CUSTOM_DIR="$TRUNK/user/custom-extras"
[ -d "$CUSTOM_DIR" ] && mkdir -p "$CUSTOM_DIR/files/etc/storage/wireguard"
echo "  OK"

############################################################
# 8. Patch user/Makefile
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
# 9. Makefile for udp2raw-tunnel
############################################################
cat > "$UDP2RAW_DIR/Makefile" << 'MKEOF'
all:
	@echo "[udp2raw-tunnel] pre-compiled binary"
	@[ -f files/udp2raw ] && ls -la files/udp2raw || echo "WARNING: binary missing"

romfs:
	@echo "[udp2raw-tunnel] installing to romfs..."
	$(ROMFSINST) -p +x files/udp2raw           /usr/bin/udp2raw
	$(ROMFSINST) -p +x files/udp2raw-common    /usr/bin/udp2raw-common
	$(ROMFSINST) -p +x files/udp2raw-save      /usr/bin/udp2raw-save
	$(ROMFSINST) -p +x files/u2s               /usr/bin/u2s
	$(ROMFSINST) -p +x files/udp2raw-ctl       /usr/bin/udp2raw-ctl
	$(ROMFSINST) -p +x files/fl-vpn-start      /usr/bin/fl-vpn-start
	$(ROMFSINST) -p +x files/fl-vpn-stop       /usr/bin/fl-vpn-stop
	$(ROMFSINST) -p +x files/fl-vpn-switch     /usr/bin/fl-vpn-switch
	$(ROMFSINST) -p +x files/fl-vpn-watchdog   /usr/bin/fl-vpn-watchdog
	$(ROMFSINST) -p +x files/fl-vpn-status     /usr/bin/fl-vpn-status
	$(ROMFSINST) -p +x files/restart_udp2raw   /sbin/restart_udp2raw
	@echo "[udp2raw-tunnel] DONE"

clean:
	@echo "[udp2raw-tunnel] clean"
MKEOF

############################################################
# 10. WebUI ASP
############################################################
echo ">>> [9] WebUI ASP"

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
.help-text  { color: #888; font-size: 11px; margin-top: 3px; }
.status-box { background: #f5f5f5; border-radius: 6px; padding: 12px 16px; margin: 10px; }
</style>
<script>var $j = jQuery.noConflict();</script>
<script>
<% login_state_hook(); %>
var m_status = '<% nvram_get_x("", "udp2raw_status"); %>';
var m_active = '<% nvram_get_x("", "udp2raw_active"); %>';

function initial(){
    show_banner(0);
    show_menu(7,-1,0);
    show_footer();
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
            m_active = p[1].trim();
            update_status();
        }
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

    if (s == 'CONNECTED'){
        el.innerHTML = '<span class="label label-success" style="font-size:14px;padding:5px 12px;">&#x25CF; Туннель активен</span>';
        info.innerHTML = m_active ? 'Сервер: <b>' + m_active + '</b>' : '';
    } else if (s == 'CONNECTING...'){
        el.innerHTML = '<span class="label label-warning" style="font-size:14px;padding:5px 12px;">&#x25CF; Подключение...</span>';
        info.innerHTML = '<i>Запуск туннеля...</i>';
    } else {
        el.innerHTML = '<span class="label label-important" style="font-size:14px;padding:5px 12px;">&#x25CB; Туннель выкл.</span>';
        info.innerHTML = (s && s != 'DISCONNECTED') ? '<span style="color:#c00">' + s + '</span>' : '';
    }
}

function syncToggle(){
    var val = document.getElementById('udp2raw_enable_val').value || '0';
    var sel = document.getElementById('udp2raw_enable_sel');
    if (sel){
        sel.value = val;
        change_enabled();
    }
}

function onEnableChange(){
    change_enabled();
}

function change_enabled(){
    var sel = document.getElementById('udp2raw_enable_sel');
    showhide_div('cfg_main', sel && sel.value === '1');
}

function load_servers(){
    var fld = document.getElementById('udp2raw_servers_stored');
    if (fld){
        document.getElementById('srv_text').value = fld.value.replace(/%/g, '\n');
    }
}

function syncLogLevel(){
    var val = document.getElementById('udp2raw_loglevel_val').value || '0';
    var sel = document.getElementById('udp2raw_loglevel_sel');
    if (!sel) return;
    for (var i = 0; i < sel.options.length; i++){
        if (sel.options[i].value === val){
            sel.selectedIndex = i;
            break;
        }
    }
}

function shellEscape(s){
    return "'" + String(s).replace(/'/g, "'\\''") + "'";
}

function applyRule(){
    var sv = document.getElementById('srv_text').value;
    sv = sv.replace(/\r\n/g, '\n').replace(/\n+/g, '\n').replace(/^\n|\n$/g, '');

    var en = document.getElementById('udp2raw_enable_sel').value;
    var ll = document.getElementById('udp2raw_loglevel_sel').value;
    var compact = sv.replace(/\n/g, '%');

    var cmd = "/usr/bin/u2s "
        + shellEscape(en) + " "
        + shellEscape(compact) + " "
        + shellEscape(ll);

    var btn = document.getElementById('save_btn');
    var msg = document.getElementById('apply_msg');

    if (btn){
        btn.value = 'Сохранение...';
        btn.disabled = true;
    }
    if (msg) msg.innerHTML = 'Выполнение команды...';

    m_status = 'CONNECTING...';
    m_active = '';
    update_status();

    $j.post('/apply.cgi', {
        current_page: 'Advanced_udp2raw.asp',
        next_page: 'Advanced_udp2raw.asp',
        action_mode: ' SystemCmd ',
        action_script: '',
        SystemCmd: cmd
    }, function(resp){
        document.getElementById('udp2raw_enable_val').value = en;
        document.getElementById('udp2raw_servers_stored').value = compact;
        document.getElementById('udp2raw_loglevel_val').value = ll;
        if (msg) msg.innerHTML = 'Команда отправлена. Обновление статуса...';
        setTimeout(poll_status, 1000);
        setTimeout(poll_status, 3000);
        setTimeout(poll_status, 6000);
    }).fail(function(){
        if (msg) msg.innerHTML = 'Ошибка отправки команды';
        m_status = 'DISCONNECTED';
        m_active = '';
        update_status();
    }).always(function(){
        if (btn){
            btn.value = 'Сохранить и применить';
            btn.disabled = false;
        }
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

<input type="hidden" id="udp2raw_enable_val" value="<% nvram_get_x("", "udp2raw_enable"); %>">
<input type="hidden" id="udp2raw_servers_stored" value="<% nvram_get_x("", "udp2raw_servers"); %>">
<input type="hidden" id="udp2raw_loglevel_val" value="<% nvram_get_x("", "udp2raw_loglevel"); %>">

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
          DPI видит обычный TCP.<br><br>
          <b>Важно:</b> эта версия использует штатный Padavan SystemCmd через AJAX /apply.cgi.<br>
          Добавлена защита от двойного запуска и bind error.<br><br>
          <b>VPN клиент:</b> <a href="/vpncli.asp">Настройки</a>
          &rarr; Удалённый сервер: <b>127.0.0.1</b>, порт: <b>3333</b>, транспорт: <b>UDP</b>
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
echo "  Created Advanced_udp2raw.asp v16.2"

############################################################
# 11. state.js menu
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
# 12. nvram defaults
############################################################
echo ">>> [11] nvram defaults"
patch_nvram_defaults() {
    local FILE="$1" LABEL="$2"
    [ -f "$FILE" ] || return

    grep -q "udp2raw_enable" "$FILE" && {
        echo "  Already patched ($LABEL)"
        return
    }

    for TERM in '{ 0, 0 }' '{0, 0}'; do
        if grep -q "$TERM" "$FILE"; then
            LINE=$(grep -n "$TERM" "$FILE" | tail -1 | cut -d: -f1)
            sed -i "${LINE}i\\
\t{ \"udp2raw_enable\",   \"0\" },\\
\t{ \"udp2raw_servers\",  \"\" },\\
\t{ \"udp2raw_status\",   \"\" },\\
\t{ \"udp2raw_active\",   \"\" },\\
\t{ \"udp2raw_loglevel\", \"0\" }," "$FILE"
            echo "  Patched ($LABEL)"
            return
        fi
    done

    echo "  WARN: terminator not found ($LABEL)"
}
patch_nvram_defaults "$TRUNK/user/shared/defaults.c" "shared/defaults.c"

############################################################
# 13. vpnc_cus3 defaults
############################################################
echo ">>> [12] MTU defaults (vpnc_cus3)"
for F in "$TRUNK/user/shared/defaults.c"; do
    [ -f "$F" ] || continue
    grep -q "vpnc_cus3" "$F" && { echo "  vpnc_cus3 already in $F"; continue; }

    for TERM in '{ 0, 0 }' '{0, 0}'; do
        if grep -q "$TERM" "$F"; then
            LINE=$(grep -n "$TERM" "$F" | tail -1 | cut -d: -f1)
            sed -i "${LINE}i\\
\t{ \"vpnc_cus3\", \"tun-mtu 1300\\\\nmssfix 1260\" }," "$F"
            echo "  Added vpnc_cus3 to $F"
            break
        fi
    done
done

############################################################
# 14. rc.c helper registration
############################################################
echo ">>> [13] ★ rc.c — add restart_udp2raw handler"

RC_FILE="$TRUNK/user/rc/rc.c"

if grep -q 'strcmp(entry->d_name, "restart_udp2raw")' "$RC_FILE"; then
    echo "  Already patched"
else
    python3 - <<PY
import sys

rc_file = "$RC_FILE"

with open(rc_file) as f:
    lines = f.readlines()

zapret_start = None
for i, line in enumerate(lines):
    if 'APP_ZAPRET' in line and '#if' in line:
        zapret_start = i
        break

if zapret_start is None:
    print("  ERROR: APP_ZAPRET block not found")
    sys.exit(1)

endif_line = None
for i in range(zapret_start + 1, min(zapret_start + 20, len(lines))):
    if lines[i].strip() == '#endif':
        endif_line = i
        break

if endif_line is None:
    print("  ERROR: #endif not found after APP_ZAPRET")
    sys.exit(1)

print(f"  APP_ZAPRET at line {zapret_start+1}, #endif at line {endif_line+1}")

new_block = [
    '\t\telse if (strcmp(entry->d_name, "restart_udp2raw") == 0)\n',
    '\t\t{\n',
    '\t\t\tsystem("/sbin/restart_udp2raw");\n',
    '\t\t}\n',
]

for idx, nl in enumerate(new_block):
    lines.insert(endif_line + 1 + idx, nl)

with open(rc_file, 'w') as f:
    f.writelines(lines)

with open(rc_file) as f:
    content = f.read()

if 'restart_udp2raw' not in content:
    print("  VERIFY FAILED")
    sys.exit(1)

for i, line in enumerate(content.splitlines()):
    if 'restart_udp2raw' in line:
        start = max(0, i - 3)
        end = min(len(content.splitlines()), i + 6)
        for j in range(start, end):
            print(f"  {j+1}: {content.splitlines()[j]}")
        break

print("  VERIFY OK")
PY
fi

############################################################
# Final diagnostics
############################################################
echo
echo "============================================"
echo "  MILLENIUM Group VPN — build ready v16.2"
echo
echo "  MODE:"
echo "  - real AJAX SystemCmd"
echo "  - no nohup dependency"
echo "  - startup locks enabled"
echo "============================================"

echo
echo "=== DIAGNOSTICS ==="
echo "--- Files ---"
ls -la "$UDP2RAW_DIR/files/" 2>/dev/null
echo "--- rc.c patch ---"
grep -n "restart_udp2raw" "$TRUNK"/user/rc/*.c 2>/dev/null || echo "NOT FOUND in rc/*.c"
echo "--- ASP ---"
grep -n "SystemCmd\|u2s\|CONNECTING" "$WWW/Advanced_udp2raw.asp" 2>/dev/null || true
echo "=== END ==="
