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
# 3) udp2raw-tunnel — кросс-компиляция для mipsel (MT7621)
# ======================================================================
echo ">>> Setting up udp2raw-tunnel package"

ROOT=padavan-ng/trunk
UDP2RAW_PKG="$ROOT/user/udp2raw-tunnel"
UDP2RAW_VER="20230206.0"

mkdir -p "$UDP2RAW_PKG"

# --- Скачиваем исходники сейчас (в pre-build), чтобы не зависеть от сети при make ---
echo ">>> Downloading udp2raw source v${UDP2RAW_VER}"
curl -L --retry 5 -o "$UDP2RAW_PKG/udp2raw-src.tar.gz" \
  "https://github.com/wangyu-/udp2raw/archive/refs/tags/${UDP2RAW_VER}.tar.gz"
cd "$UDP2RAW_PKG"
tar xzf udp2raw-src.tar.gz
mv "udp2raw-${UDP2RAW_VER}" src
rm -f udp2raw-src.tar.gz
cd - >/dev/null

# --- Makefile пакета: использует native udp2raw makefile с кросс-компилятором ---
# CROSS_COMPILE задаётся системой сборки padavan (mipsel-linux-uclibc-)
# udp2raw поддерживает: make cross (dynamic), make cross2/cross3 (static)
cat > "$UDP2RAW_PKG/Makefile" << 'MAKEEOF'
ifndef ROOTDIR
ROOTDIR=../..
endif
include $(ROOTDIR)/tools/build-rules.mk

SRC_DIR = src

all:
	@echo "[udp2raw] Cross-compiling with cc_cross=$(CROSS_COMPILE)g++"
	# Подставляем кросс-компилятор padavan в makefile udp2raw
	cd $(SRC_DIR) && sed -i 's|^cc_cross=.*|cc_cross=$(CROSS_COMPILE)g++|' makefile
	# cross2 = статическая линковка (нужно для embedded)
	# Если cross2 не сработает — пробуем cross3, потом cross
	cd $(SRC_DIR) && ( make cross2 OPT="-Os -s" || make cross3 OPT="-Os -s" || make cross OPT="-Os -s" )
	# Результат: src/udp2raw_cross
	@ls -la $(SRC_DIR)/udp2raw_cross
	@echo "[udp2raw] Build OK"

romfs:
	$(ROMFSINST) -p +x $(SRC_DIR)/udp2raw_cross /usr/bin/udp2raw
	$(ROMFSINST) -p +x ./files/udp2raw-ctl /usr/bin/udp2raw-ctl

clean:
	-cd $(SRC_DIR) && make clean 2>/dev/null
	rm -f $(SRC_DIR)/udp2raw_cross
MAKEEOF

# --- Управляющий скрипт для роутера ---
mkdir -p "$UDP2RAW_PKG/files"

cat > "$UDP2RAW_PKG/files/udp2raw-ctl" << 'CTLEOF'
#!/bin/sh
#
# udp2raw-ctl — управление udp2raw туннелем на Padavan
#
# Использование:
#   udp2raw-ctl start          — запустить туннель
#   udp2raw-ctl stop           — остановить
#   udp2raw-ctl restart        — перезапустить
#   udp2raw-ctl status         — показать статус
#
# Конфигурация: /etc/storage/udp2raw.conf
#   SERVER=89.39.70.30
#   PORT=4096
#   PASSWORD=millenium2026
#   LOCAL_PORT=1194
#   RAW_MODE=faketcp
#

CONF="/etc/storage/udp2raw.conf"
PID_FILE="/var/run/udp2raw.pid"
LOG_FILE="/tmp/udp2raw.log"
BIN="/usr/bin/udp2raw"

# Умолчания
SERVER="89.39.70.30"
PORT="4096"
PASSWORD="millenium2026"
LOCAL_PORT="1194"
RAW_MODE="faketcp"

# Загружаем конфиг если есть
[ -f "$CONF" ] && . "$CONF"

get_pid() {
    if [ -f "$PID_FILE" ]; then
        local p=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
            echo "$p"
            return 0
        fi
    fi
    # Ищем по процессу
    local p=$(pidof udp2raw 2>/dev/null)
    [ -n "$p" ] && echo "$p" && return 0
    return 1
}

do_start() {
    if pid=$(get_pid); then
        echo "udp2raw already running (PID $pid)"
        return 0
    fi

    if [ ! -x "$BIN" ]; then
        echo "ERROR: $BIN not found"
        return 1
    fi

    echo "Starting udp2raw: ${SERVER}:${PORT} -> 127.0.0.1:${LOCAL_PORT} (${RAW_MODE})"

    # Запускаем в фоне, маскируем имя процесса
    $BIN -c \
        -l "127.0.0.1:${LOCAL_PORT}" \
        -r "${SERVER}:${PORT}" \
        -k "${PASSWORD}" \
        --raw-mode "${RAW_MODE}" \
        --cipher-mode xor \
        --auth-mode simple \
        -a \
        --fix-gro \
        --retry-on-error \
        --log-level 3 \
        >> "$LOG_FILE" 2>&1 &

    local pid=$!
    echo "$pid" > "$PID_FILE"
    sleep 1

    if kill -0 "$pid" 2>/dev/null; then
        echo "udp2raw started (PID $pid)"
        # Даём время на установку raw socket
        sleep 2
        return 0
    else
        echo "ERROR: udp2raw failed to start. Check $LOG_FILE"
        rm -f "$PID_FILE"
        return 1
    fi
}

do_stop() {
    local pid
    if pid=$(get_pid); then
        echo "Stopping udp2raw (PID $pid)"
        kill "$pid" 2>/dev/null
        sleep 1
        kill -9 "$pid" 2>/dev/null
        rm -f "$PID_FILE"
        echo "udp2raw stopped"
    else
        echo "udp2raw is not running"
    fi
}

do_status() {
    local pid
    if pid=$(get_pid); then
        echo "udp2raw is RUNNING (PID $pid)"
        echo "  Server: ${SERVER}:${PORT}"
        echo "  Local:  127.0.0.1:${LOCAL_PORT}"
        echo "  Mode:   ${RAW_MODE}"
        echo ""
        echo "Last 5 log lines:"
        tail -5 "$LOG_FILE" 2>/dev/null || echo "(no log)"
    else
        echo "udp2raw is STOPPED"
    fi
}

case "$1" in
    start)   do_start ;;
    stop)    do_stop ;;
    restart) do_stop; sleep 1; do_start ;;
    status)  do_status ;;
    *)
        echo "Usage: $0 {start|stop|restart|status}"
        exit 1
    ;;
esac
CTLEOF
chmod +x "$UDP2RAW_PKG/files/udp2raw-ctl"

# --- Регистрируем пакет в системе сборки ---
U_MF="$ROOT/user/Makefile"
grep -q 'udp2raw-tunnel' "$U_MF" || echo 'DIRS-y += udp2raw-tunnel' >> "$U_MF"

echo ">>> udp2raw-tunnel package ready"

# ======================================================================
# 4) custom-extras: обёртки + стартовые скрипты (обновлённая версия)
# ======================================================================
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
	$(ROMFSINST) -p +x ./files/usr/bin/fl-vpn-start /usr/bin/fl-vpn-start
	$(ROMFSINST) ./files/etc/storage/wireguard/wg0.conf.example /etc/storage/wireguard/wg0.conf.example

clean:
	@true
MAKEEOF

# awg-client (обёртка на AmneziaWG клиент)
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
set -e
OBFS="/usr/sbin/obfs4proxy"
[ -x "$OBFS" ] || { echo "obfs4proxy not found"; exit 1; }
exec "$OBFS" "$@"
SH
chmod +x "$PKG/files/usr/bin/obfs4-run"

# =====================================================================
# fl-vpn-start — Главный стартовый скрипт
# Запускает udp2raw, потом OpenVPN через туннель
# Добавляется в /etc/storage/started_script.sh на роутере
# =====================================================================
cat > "$PKG/files/usr/bin/fl-vpn-start" << 'VPNSH'
#!/bin/sh
#
# fl-vpn-start — запуск VPN-стека: udp2raw -> OpenVPN
#
# Вызов: fl-vpn-start [start|stop|restart|status]
#
# Этот скрипт:
#   1) Запускает udp2raw (FakeTCP туннель к серверу)
#   2) Ждёт готовности
#   3) Перезапускает OpenVPN (который подключается к 127.0.0.1)
#
# Для автозапуска добавить в /etc/storage/started_script.sh:
#   sleep 10 && fl-vpn-start start &
#

LOG="/tmp/fl-vpn.log"
log() { echo "$(date '+%H:%M:%S') $*" >> "$LOG"; echo "$*"; }

start_all() {
    log "=== FastLink VPN start ==="

    # 1) Запускаем udp2raw
    log "Starting udp2raw tunnel..."
    udp2raw-ctl start
    if [ $? -ne 0 ]; then
        log "ERROR: udp2raw failed, aborting"
        return 1
    fi

    # 2) Ждём 3 сек для стабилизации raw socket
    sleep 3

    # 3) Перезапускаем OpenVPN клиент через Padavan
    # OpenVPN конфиг должен быть: remote 127.0.0.1 1194 udp
    log "Restarting OpenVPN client..."
    if [ -f /etc/init.d/openvpn ]; then
        /etc/init.d/openvpn restart
    else
        # Padavan использует nvram для управления
        killall openvpn 2>/dev/null
        sleep 2
        /usr/sbin/openvpn --config /etc/storage/openvpn/client.conf \
            --daemon --log-append /tmp/openvpn.log
    fi

    sleep 5
    log "VPN stack started. Checking..."

    # 4) Проверяем
    if pidof udp2raw >/dev/null && pidof openvpn >/dev/null; then
        local tun_ip=$(ip addr show tun0 2>/dev/null | grep 'inet ' | awk '{print $2}')
        log "OK: udp2raw + OpenVPN running. TUN IP: ${tun_ip:-pending...}"
    else
        log "WARNING: something may not be running"
        log "  udp2raw: $(pidof udp2raw 2>/dev/null || echo 'NOT RUNNING')"
        log "  openvpn: $(pidof openvpn 2>/dev/null || echo 'NOT RUNNING')"
    fi
}

stop_all() {
    log "=== FastLink VPN stop ==="
    killall openvpn 2>/dev/null
    udp2raw-ctl stop
    log "All stopped"
}

status_all() {
    echo "=== FastLink VPN Status ==="
    echo ""
    udp2raw-ctl status
    echo ""
    echo "--- OpenVPN ---"
    local ovpn_pid=$(pidof openvpn 2>/dev/null)
    if [ -n "$ovpn_pid" ]; then
        echo "OpenVPN is RUNNING (PID $ovpn_pid)"
        local tun_ip=$(ip addr show tun0 2>/dev/null | grep 'inet ' | awk '{print $2}')
        echo "  TUN IP: ${tun_ip:-no tun0}"
    else
        echo "OpenVPN is STOPPED"
    fi
    echo ""
    echo "--- Last log entries ---"
    tail -10 "$LOG" 2>/dev/null || echo "(no log)"
}

case "${1:-start}" in
    start)   start_all ;;
    stop)    stop_all ;;
    restart) stop_all; sleep 2; start_all ;;
    status)  status_all ;;
    *)       echo "Usage: $0 {start|stop|restart|status}" ;;
esac
VPNSH
chmod +x "$PKG/files/usr/bin/fl-vpn-start"

# Шаблон wg0.conf
cat > "$PKG/files/etc/storage/wireguard/wg0.conf.example" <<'EOF'
# Example WireGuard / AmneziaWG config
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

# Регистрируем custom-extras
grep -q 'custom-extras' "$U_MF" || echo 'DIRS-y += custom-extras' >> "$U_MF"

echo '>>> custom-extras ready (fl-vpn-start, awg-client, obfs4-run, udp2raw-ctl)'

# ======================================================================
# 5) WebUI - stranitsa udp2raw v Padavan
# ======================================================================
echo ">>> Setting up udp2raw WebUI page"

WWW_DIR="$ROOT/user/httpd/www"
mkdir -p "$WWW_DIR"

# --- 5.1) ASP stranitsa ---
cat > "$WWW_DIR/Advanced_udp2raw.asp" << 'ASPEOF'
<!DOCTYPE html>
<html>
<head>
<title>udp2raw Tunnel</title>
<meta http-equiv="Content-Type" content="text/html; charset=utf-8">
<meta http-equiv="Pragma" content="no-cache">
<meta http-equiv="Expires" content="-1">
<link rel="shortcut icon" href="images/favicon.ico">
<link rel="icon" href="images/favicon.png">
<link rel="stylesheet" type="text/css" href="/bootstrap/css/bootstrap.min.css">
<link rel="stylesheet" type="text/css" href="/bootstrap/css/main.css">
<link rel="stylesheet" type="text/css" href="/bootstrap/css/engage.itoggle.css">
<script type="text/javascript" src="/jquery.js"></script>
<script type="text/javascript" src="/bootstrap/js/bootstrap.min.js"></script>
<script type="text/javascript" src="/bootstrap/js/engage.itoggle.min.js"></script>
<script type="text/javascript" src="/state.js"></script>
<script type="text/javascript" src="/general.js"></script>
<script type="text/javascript" src="/itoggle.js"></script>
<script type="text/javascript" src="/popup.js"></script>
<script>
var $j = jQuery.noConflict();
<% login_state_hook(); %>
function initial(){
    show_banner(2);
    show_menu(5,11,0);
    show_footer();
    fill_status();
    change_udp2raw_enabled();
}
function change_udp2raw_enabled(){
    var en = document.form.udp2raw_enable[0].checked;
    showhide_div('tbl_udp2raw_config', en);
}
function fill_status(){
    $j('#udp2raw_status_area').text('Checking...');
    $j.get('/console_response.asp', function(data){
        $j('#udp2raw_status_area').text('Use SSH for status: udp2raw-ctl status');
    });
}
function applyRule(){
    showLoading();
    document.form.action_mode.value = " Apply ";
    document.form.current_page.value = "Advanced_udp2raw.asp";
    document.form.submit();
}
</script>
</head>
<body onload="initial();" onunload="return unload_body();">
<div class="wrapper">
    <div class="container-fluid" style="padding-right: 0px">
        <div class="row-fluid">
            <div class="span3"><center><div id="logo"></div></center></div>
            <div class="span9"><div id="TopBanner"></div></div>
        </div>
    </div>
    <div id="Loading" class="popup_bg"></div>
    <iframe name="hidden_frame" id="hidden_frame" src="" width="0" height="0" frameborder="0"></iframe>
    <form method="post" name="form" id="form" action="/start_apply.htm" target="hidden_frame">
    <input type="hidden" name="current_page" value="Advanced_udp2raw.asp">
    <input type="hidden" name="next_page" value="">
    <input type="hidden" name="next_host" value="">
    <input type="hidden" name="sid_list" value="">
    <input type="hidden" name="group_id" value="">
    <input type="hidden" name="action_mode" value="">
    <input type="hidden" name="action_script" value="">
    <div class="container-fluid">
        <div class="row-fluid">
            <div class="span3">
                <div class="well sidebar-nav side_nav" style="padding: 0px;">
                    <ul id="mainMenu" class="clearfix"></ul>
                    <ul class="clearfix"><li><div id="subMenu" class="accordion"></div></li></ul>
                </div>
            </div>
            <div class="span9">
                <div class="row-fluid">
                    <div class="span12">
                        <div class="box well grad_colour_dark_blue">
                            <h2 class="box_head round_top">udp2raw - FakeTCP Tunnel</h2>
                            <div class="round_bottom">
                                <div class="row-fluid">
                                    <div id="tabMenu" class="submenuBlock"></div>
                                    <table width="100%" cellpadding="4" cellspacing="0" class="table">
                                        <tr>
                                            <th width="50%">Enable udp2raw tunnel:</th>
                                            <td>
                                                <div class="main_itoggle">
                                                    <div id="udp2raw_enable_on_of">
                                                        <input type="checkbox" id="udp2raw_enable_fake"
                                                            <% nvram_match_x("", "udp2raw_enable", "1", "value=1 checked"); %>
                                                            <% nvram_match_x("", "udp2raw_enable", "0", "value=0"); %>>
                                                    </div>
                                                </div>
                                                <div style="position: absolute; margin-left: -10000px;">
                                                    <input type="radio" name="udp2raw_enable" id="udp2raw_enable_1" class="input" value="1" onclick="change_udp2raw_enabled();"
                                                        <% nvram_match_x("", "udp2raw_enable", "1", "checked"); %>>Yes
                                                    <input type="radio" name="udp2raw_enable" id="udp2raw_enable_0" class="input" value="0" onclick="change_udp2raw_enabled();"
                                                        <% nvram_match_x("", "udp2raw_enable", "0", "checked"); %>>No
                                                </div>
                                            </td>
                                        </tr>
                                    </table>
                                    <div id="tbl_udp2raw_config">
                                        <table width="100%" cellpadding="4" cellspacing="0" class="table">
                                            <tr><th colspan="2" style="background-color: #E3E3E3;">Connection Settings</th></tr>
                                            <tr>
                                                <th width="50%">Remote server (IP or domain):</th>
                                                <td><input type="text" name="udp2raw_server" class="input" maxlength="128" size="32" value="<% nvram_get_x("", "udp2raw_server"); %>"></td>
                                            </tr>
                                            <tr>
                                                <th>Server port:</th>
                                                <td><input type="text" name="udp2raw_port" class="input" maxlength="5" size="5" value="<% nvram_get_x("", "udp2raw_port"); %>" onkeypress="return is_number(this,event);"> [ 1..65535 ]</td>
                                            </tr>
                                            <tr>
                                                <th>Password:</th>
                                                <td>
                                                    <input type="password" name="udp2raw_password" id="udp2raw_password" class="input" maxlength="64" size="32" value="<% nvram_get_x("", "udp2raw_password"); %>">
                                                    <button style="margin-left:-5px;" class="btn" type="button" onclick="passwordShowHide('udp2raw_password')"><i class="icon-eye-close"></i></button>
                                                </td>
                                            </tr>
                                            <tr>
                                                <th>Local port (for OpenVPN):</th>
                                                <td><input type="text" name="udp2raw_local_port" class="input" maxlength="5" size="5" value="<% nvram_get_x("", "udp2raw_local_port"); %>" onkeypress="return is_number(this,event);"> [ 1..65535 ]</td>
                                            </tr>
                                            <tr>
                                                <th>Obfuscation mode:</th>
                                                <td>
                                                    <select name="udp2raw_raw_mode" class="input">
                                                        <option value="faketcp" <% nvram_match_x("", "udp2raw_raw_mode", "faketcp", "selected"); %>>FakeTCP (recommended)</option>
                                                        <option value="udp" <% nvram_match_x("", "udp2raw_raw_mode", "udp", "selected"); %>>UDP</option>
                                                        <option value="icmp" <% nvram_match_x("", "udp2raw_raw_mode", "icmp", "selected"); %>>ICMP</option>
                                                    </select>
                                                </td>
                                            </tr>
                                            <tr><th colspan="2" style="background-color: #E3E3E3;">Status / Management</th></tr>
                                            <tr>
                                                <td colspan="2" style="padding: 8px;">
                                                    <div style="background:#1a1a2e; color:#0f0; padding:10px; border-radius:5px; font-size:12px;">
                                                        After clicking Apply, settings are saved to nvram.<br>
                                                        Use SSH to manage: <b>udp2raw-ctl start|stop|restart|status</b><br>
                                                        Auto-start: add to Scripts > Run After Router Started:<br>
                                                        <code>sleep 15 && fl-vpn-start start &</code>
                                                    </div>
                                                </td>
                                            </tr>
                                        </table>
                                    </div>
                                    <table width="100%" cellpadding="4" cellspacing="0" class="table">
                                        <tr>
                                            <td style="border-top: 0 none; text-align:center;">
                                                <input type="button" id="applyButton" class="btn btn-primary" style="width: 219px" onclick="applyRule();" value="Apply">
                                            </td>
                                        </tr>
                                    </table>
                                </div>
                            </div>
                        </div>
                    </div>
                </div>
            </div>
        </div>
    </div>
    </form>
    <div id="footer"></div>
</div>
</body>
</html>
ASPEOF

echo "  Created Advanced_udp2raw.asp"

# --- 5.2) Menu item in sidebar ---
STATE_JS="$WWW_DIR/state.js"
if [ -f "$STATE_JS" ]; then
    if grep -q 'Advanced_nfqws' "$STATE_JS"; then
        sed -i '/Advanced_nfqws/,/;/{
            /;/a\
// udp2raw tunnel page\
if(found_app_udp2raw()) { menuL3_link[menuL3_link.length]="Advanced_udp2raw.asp"; menuL3_title[menuL3_title.length]="udp2raw Tunnel"; }
        }' "$STATE_JS" 2>/dev/null || true
    fi
    # Also add found_app_udp2raw function (always returns true since we build it in)
    if ! grep -q 'found_app_udp2raw' "$STATE_JS"; then
        echo 'function found_app_udp2raw(){return true;}' >> "$STATE_JS"
    fi
    echo "  Menu: patched state.js"
else
    echo "  WARNING: state.js not found. Access page at http://router/Advanced_udp2raw.asp"
fi

# --- 5.3) nvram defaults ---
DEFAULTS_H=$(find "$ROOT" -path '*/shared/defaults.h' 2>/dev/null | head -1)
if [ -n "$DEFAULTS_H" ] && [ -f "$DEFAULTS_H" ]; then
    if ! grep -q 'udp2raw_enable' "$DEFAULTS_H"; then
        ANCHOR=$(grep -n 'nfqws\|wg_enable\|vpnc_enable' "$DEFAULTS_H" | tail -1 | cut -d: -f1)
        if [ -n "$ANCHOR" ]; then
            sed -i "${ANCHOR}a\\
\t{ \"udp2raw_enable\", \"0\" },\\
\t{ \"udp2raw_server\", \"\" },\\
\t{ \"udp2raw_port\", \"4096\" },\\
\t{ \"udp2raw_password\", \"\" },\\
\t{ \"udp2raw_local_port\", \"1194\" },\\
\t{ \"udp2raw_raw_mode\", \"faketcp\" }," "$DEFAULTS_H"
            echo "  nvram defaults: added to defaults.h (line $ANCHOR)"
        else
            echo "  WARNING: Could not find anchor in defaults.h"
        fi
    fi
else
    echo "  WARNING: defaults.h not found"
fi

echo ">>> udp2raw WebUI ready"
echo ">>> Access at: http://router_ip/Advanced_udp2raw.asp"

# ======================================================================
# 6) Update udp2raw-ctl to read nvram
# ======================================================================
echo ">>> Updating udp2raw-ctl for nvram support"

cat > "$UDP2RAW_PKG/files/udp2raw-ctl" << 'CTLEOF'
#!/bin/sh
# udp2raw-ctl - manage udp2raw tunnel on Padavan
# Reads settings from nvram (WebUI) or /etc/storage/udp2raw.conf

PID_FILE="/var/run/udp2raw.pid"
LOG_FILE="/tmp/udp2raw.log"
BIN="/usr/bin/udp2raw"

# Read from nvram (set via WebUI)
if command -v nvram >/dev/null 2>&1; then
    NV_ENABLE=$(nvram get udp2raw_enable 2>/dev/null)
    NV_SERVER=$(nvram get udp2raw_server 2>/dev/null)
    NV_PORT=$(nvram get udp2raw_port 2>/dev/null)
    NV_PASSWORD=$(nvram get udp2raw_password 2>/dev/null)
    NV_LOCAL_PORT=$(nvram get udp2raw_local_port 2>/dev/null)
    NV_RAW_MODE=$(nvram get udp2raw_raw_mode 2>/dev/null)
fi

# Fallback to config file
CONF="/etc/storage/udp2raw.conf"
[ -f "$CONF" ] && . "$CONF"

# nvram overrides config file
SERVER="${NV_SERVER:-${SERVER:-}}"
PORT="${NV_PORT:-${PORT:-4096}}"
PASSWORD="${NV_PASSWORD:-${PASSWORD:-}}"
LOCAL_PORT="${NV_LOCAL_PORT:-${LOCAL_PORT:-1194}}"
RAW_MODE="${NV_RAW_MODE:-${RAW_MODE:-faketcp}}"

get_pid() {
    if [ -f "$PID_FILE" ]; then
        p=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
            echo "$p"; return 0
        fi
    fi
    p=$(pidof udp2raw 2>/dev/null)
    [ -n "$p" ] && echo "$p" && return 0
    return 1
}

do_start() {
    if [ "$NV_ENABLE" = "0" ] && [ "$1" != "force" ]; then
        echo "udp2raw disabled in WebUI"; return 0
    fi
    if pid=$(get_pid); then
        echo "udp2raw running (PID $pid)"; return 0
    fi
    [ -x "$BIN" ] || { echo "ERROR: $BIN not found"; return 1; }
    [ -n "$SERVER" ] || { echo "ERROR: Server not set"; return 1; }
    [ -n "$PASSWORD" ] || { echo "ERROR: Password not set"; return 1; }
    echo "Starting: ${SERVER}:${PORT} -> 127.0.0.1:${LOCAL_PORT} (${RAW_MODE})"
    $BIN -c -l "127.0.0.1:${LOCAL_PORT}" -r "${SERVER}:${PORT}" \
        -k "${PASSWORD}" --raw-mode "${RAW_MODE}" \
        --cipher-mode xor --auth-mode simple \
        -a --fix-gro --retry-on-error --log-level 3 \
        >> "$LOG_FILE" 2>&1 &
    pid=$!; echo "$pid" > "$PID_FILE"; sleep 2
    if kill -0 "$pid" 2>/dev/null; then
        echo "udp2raw started (PID $pid)"; return 0
    else
        echo "ERROR: failed. Check $LOG_FILE"; rm -f "$PID_FILE"; return 1
    fi
}

do_stop() {
    if pid=$(get_pid); then
        echo "Stopping udp2raw (PID $pid)"
        kill "$pid" 2>/dev/null; sleep 1; kill -9 "$pid" 2>/dev/null
        rm -f "$PID_FILE"; echo "Stopped"
    else
        echo "udp2raw not running"
    fi
}

do_status() {
    echo "=== udp2raw ==="
    if pid=$(get_pid); then echo "RUNNING (PID $pid)"
    else echo "STOPPED"; fi
    echo "Server: ${SERVER:-<not set>}:${PORT}"
    echo "Local:  127.0.0.1:${LOCAL_PORT}"
    echo "Mode:   ${RAW_MODE}"
    echo "WebUI:  $([ "$NV_ENABLE" = "1" ] && echo ON || echo OFF)"
    [ -f "$LOG_FILE" ] && { echo ""; echo "--- Log ---"; tail -5 "$LOG_FILE"; }
}

case "$1" in
    start)   do_start "$2" ;;
    stop)    do_stop ;;
    restart) do_stop; sleep 1; do_start "$2" ;;
    status)  do_status ;;
    *)       echo "Usage: $0 {start|stop|restart|status}"; exit 1 ;;
esac
CTLEOF
chmod +x "$UDP2RAW_PKG/files/udp2raw-ctl"

echo ">>> udp2raw-ctl updated with nvram support"

# ======================================================================
# Summary
# ======================================================================
echo ""
echo "============================================"
echo "  Firmware components:"
echo "  - OpenVPN ${OVPN_VER} + XOR scramble"
echo "  - udp2raw (FakeTCP tunnel) + WebUI"
echo "  - AmneziaWG (kernel module)"
echo "  - WireGuard (kernel module)"
echo "  - NFQWS (DPI bypass)"
echo "  - TOR + OBFS4"
echo "  - fl-vpn-start, udp2raw-ctl"
echo "============================================"
echo ""
