#!/usr/bin/env bash
set -e

# ======================================================================
# 1) OpenVPN + XOR patch
# ======================================================================
OVPN_VER=2.6.14
RELEASE_URL="https://github.com/luzrain/openvpn-xorpatch/releases/download/v${OVPN_VER}/openvpn-${OVPN_VER}.tar.gz"
OPENVPN_DIRS=("padavan-ng/trunk/user/openvpn" "padavan-ng/trunk/user/openvpn-openssl")
for dir in "${OPENVPN_DIRS[@]}"; do
  mf="${dir}/Makefile" || continue
  [[ -f $mf ]] || continue
  echo ">>> refresh ${dir}"
  rm -rf "${dir}/openvpn-${OVPN_VER}" "${dir}/openvpn-${OVPN_VER}.tar."* 2>/dev/null || true
  curl -L --retry 5 -o "${dir}/openvpn-${OVPN_VER}.tar.gz" "${RELEASE_URL}"
  sed -i "s|^SRC_NAME=.*|SRC_NAME=openvpn-${OVPN_VER}|" "${mf}"
  sed -i "s|^SRC_URL=.*|SRC_URL=${RELEASE_URL}|" "${mf}"
  grep -q -- '--enable-xor-patch' "${mf}" || \
    sed -i 's/--enable-small/--enable-small \\\n\t--enable-xor-patch/' "${mf}"
  sed -i 's|true # autoreconf disabled.*|autoreconf -fi |' "${mf}"
  sed -i '/openvpn-orig\.patch/s|^[^\t#]|#&|' "${mf}"
done

# ======================================================================
# 2) WebUI branding
# ======================================================================
CUSTOM_MODEL="FastLink  (private build)"
CUSTOM_FOOTER="(c) 2025 FastLink Team.  Powered by Padavan-NG"
sed -i 's/^Web_Title=.*/Web_Title=ZVMODELVZ Wireless Router/;' padavan-ng/trunk/romfs/www/*.dict 2>/dev/null || true
find padavan-ng/trunk -name '*.dict' -print0 | while IFS= read -r -d '' F; do
  sed -i "s/ZVMODELVZ/${CUSTOM_MODEL//\//\\/}/g" "$F"
  sed -i "s/ZVCOPYRVZ/${CUSTOM_FOOTER//\//\\/}/g" "$F"
done

# ======================================================================
# 3) udp2raw-tunnel package (PRE-COMPILED binary)
# ======================================================================
ROOT=padavan-ng/trunk
UDP2RAW_VER=20230206.0
UDP2RAW_PKG="$ROOT/user/udp2raw-tunnel"
echo ">>> Setting up udp2raw-tunnel"
mkdir -p "$UDP2RAW_PKG/files"

echo ">>> Downloading pre-compiled udp2raw binary"
curl -L --retry 5 -o "$UDP2RAW_PKG/udp2raw_binaries.tar.gz" \
  "https://github.com/wangyu-/udp2raw/releases/download/${UDP2RAW_VER}/udp2raw_binaries.tar.gz"

cd "$UDP2RAW_PKG"
tar xzf udp2raw_binaries.tar.gz 2>/dev/null || true
echo ">>> Archive contents:"
find . -type f ! -name '*.gz' ! -name 'Makefile' | sort

MIPSEL_BIN=$(find . -name 'udp2raw_mips*le*' -o -name '*mipsel*' 2>/dev/null | grep -v '.gz' | head -1)
[ -z "$MIPSEL_BIN" ] && MIPSEL_BIN=$(find . -name '*mips*' -type f ! -name '*.gz' ! -name 'Makefile' 2>/dev/null | head -1)
if [ -n "$MIPSEL_BIN" ]; then
  cp "$MIPSEL_BIN" files/udp2raw; chmod +x files/udp2raw
  echo ">>> Binary: $MIPSEL_BIN ($(wc -c < files/udp2raw) bytes)"
else
  echo ">>> ERROR: mipsel binary not found!"
fi
rm -f udp2raw_binaries.tar.gz
cd - >/dev/null

# --- Makefile WITHOUT build-rules.mk ---
cat > "$UDP2RAW_PKG/Makefile" << 'MAKEEOF'
ifndef ROOTDIR
ROOTDIR = ../..
endif
ROMFSINST = $(ROOTDIR)/tools/romfs-inst.sh
all:
	@echo "[udp2raw-tunnel] pre-compiled binary"
	@[ -f files/udp2raw ] && ls -la files/udp2raw || echo "WARNING: binary missing"
romfs:
	@echo "[udp2raw-tunnel] installing to romfs..."
	$(ROMFSINST) -p +x files/udp2raw /usr/bin/udp2raw
	$(ROMFSINST) -p +x files/udp2raw-ctl /usr/bin/udp2raw-ctl
	$(ROMFSINST) -p +x files/fl-vpn-start /usr/bin/fl-vpn-start
	@echo "[udp2raw-tunnel] DONE"
clean:
	@echo "[udp2raw-tunnel] clean"
MAKEEOF

# --- udp2raw-ctl ---
cat > "$UDP2RAW_PKG/files/udp2raw-ctl" << 'CTLEOF'
#!/bin/sh
PID_FILE="/var/run/udp2raw.pid"; LOG_FILE="/tmp/udp2raw.log"; BIN="/usr/bin/udp2raw"
nv() { nvram get "$1" 2>/dev/null; }
SERVER=$(nv udp2raw_server); PORT=$(nv udp2raw_port)
PASSWORD=$(nv udp2raw_password); LOCAL_PORT=$(nv udp2raw_local_port)
RAW_MODE=$(nv udp2raw_rawmode)
[ -z "$SERVER" ] && [ -f /etc/storage/udp2raw.conf ] && . /etc/storage/udp2raw.conf
: "${SERVER:=}"; : "${PORT:=4096}"; : "${PASSWORD:=}"
: "${LOCAL_PORT:=1194}"; : "${RAW_MODE:=faketcp}"
get_pid() {
    [ -f "$PID_FILE" ] && p=$(cat "$PID_FILE" 2>/dev/null) && [ -n "$p" ] && kill -0 "$p" 2>/dev/null && echo "$p" && return 0
    p=$(pidof udp2raw 2>/dev/null); [ -n "$p" ] && echo "$p" && return 0; return 1
}
do_start() {
    get_pid >/dev/null && echo "Already running (PID $(get_pid))" && return 0
    [ ! -x "$BIN" ] && echo "ERROR: $BIN missing" && return 1
    [ -z "$SERVER" ] && echo "ERROR: server not set" && return 1
    [ -z "$PASSWORD" ] && echo "ERROR: password not set" && return 1
    echo "Starting: ${SERVER}:${PORT} -> 127.0.0.1:${LOCAL_PORT} (${RAW_MODE})"
    $BIN -c -l "127.0.0.1:${LOCAL_PORT}" -r "${SERVER}:${PORT}" -k "${PASSWORD}" \
        --raw-mode "${RAW_MODE}" --cipher-mode xor --auth-mode simple \
        -a --fix-gro --retry-on-error --log-level 3 >> "$LOG_FILE" 2>&1 &
    echo "$!" > "$PID_FILE"; sleep 2
    kill -0 "$(cat $PID_FILE)" 2>/dev/null && echo "OK (PID $(cat $PID_FILE))" || { echo "FAILED"; rm -f "$PID_FILE"; return 1; }
}
do_stop() {
    if pid=$(get_pid); then kill "$pid" 2>/dev/null; sleep 1; kill -9 "$pid" 2>/dev/null; rm -f "$PID_FILE"; echo "Stopped"
    else echo "Not running"; fi
}
case "$1" in
    start) do_start ;; stop) do_stop ;; restart) do_stop; sleep 1; do_start ;;
    status) if pid=$(get_pid); then echo "RUNNING (PID $pid)"; else echo "STOPPED"; fi
        echo "Server: ${SERVER:-<not set>}:${PORT} Local: 127.0.0.1:${LOCAL_PORT} Mode: ${RAW_MODE}"
        [ -f "$LOG_FILE" ] && tail -5 "$LOG_FILE" ;;
    status_json)
        if pid=$(get_pid); then s="running"; else s="stopped"; pid=0; fi
        printf '{"status":"%s","pid":%s,"server":"%s","port":%s,"local_port":%s,"raw_mode":"%s"}\n' \
            "$s" "$pid" "$SERVER" "$PORT" "$LOCAL_PORT" "$RAW_MODE" ;;
    *) echo "Usage: $0 {start|stop|restart|status}" ;;
esac
CTLEOF

# --- fl-vpn-start ---
cat > "$UDP2RAW_PKG/files/fl-vpn-start" << 'FLEOF'
#!/bin/sh
LOG="/tmp/fl-vpn.log"
log() { echo "$(date '+%H:%M:%S') $*" >> "$LOG"; echo "$*"; }
start_all() {
    log "=== FastLink VPN start ==="
    enabled=$(nvram get udp2raw_enable 2>/dev/null)
    if [ "$enabled" != "1" ]; then log "udp2raw disabled"; return 0; fi
    log "Starting udp2raw..."; udp2raw-ctl start
    [ $? -ne 0 ] && log "udp2raw FAILED" && return 1
    sleep 3; log "Restarting OpenVPN..."
    killall openvpn 2>/dev/null; sleep 2
    [ -f /etc/storage/openvpn/client.conf ] && \
        /usr/sbin/openvpn --config /etc/storage/openvpn/client.conf --daemon --log-append /tmp/openvpn.log
    sleep 5
    pidof udp2raw >/dev/null && pidof openvpn >/dev/null && log "OK" || log "WARNING: check"
}
stop_all() { log "=== stop ==="; killall openvpn 2>/dev/null; udp2raw-ctl stop; }
case "${1:-start}" in
    start) start_all ;; stop) stop_all ;; restart) stop_all; sleep 2; start_all ;;
    status) udp2raw-ctl status; pidof openvpn >/dev/null && echo "OpenVPN: RUNNING" || echo "OpenVPN: STOPPED" ;;
esac
FLEOF

chmod +x "$UDP2RAW_PKG/files/"*
echo ">>> udp2raw-tunnel package ready"

# ======================================================================
# 4) custom-extras package
# ======================================================================
CE_PKG="$ROOT/user/custom-extras"
mkdir -p "$CE_PKG/files/usr/bin" "$CE_PKG/files/etc/storage/wireguard"

cat > "$CE_PKG/Makefile" << 'MAKEEOF'
ifndef ROOTDIR
ROOTDIR = ../..
endif
ROMFSINST = $(ROOTDIR)/tools/romfs-inst.sh
all:
	@echo "[custom-extras] nothing to build"
romfs:
	@echo "[custom-extras] installing..."
	$(ROMFSINST) -p +x files/usr/bin/awg-client /usr/bin/awg-client
	$(ROMFSINST) -p +x files/usr/bin/obfs4-run /usr/bin/obfs4-run
	mkdir -p $(ROOTDIR)/romfs/etc/storage/wireguard
	$(ROMFSINST) files/etc/storage/wireguard/wg0.conf.example /etc/storage/wireguard/wg0.conf.example
	@echo "[custom-extras] DONE"
clean:
	@echo "[custom-extras] clean"
MAKEEOF

cat > "$CE_PKG/files/usr/bin/awg-client" << 'AWG'
#!/bin/sh
CONF="/etc/storage/wireguard/awg0.conf"
case "${1:-start}" in
  start) [ ! -f "$CONF" ] && echo "No $CONF" && exit 1
    ip link add dev awg0 type amneziawg 2>/dev/null || true
    awg setconf awg0 "$CONF"; ip link set awg0 up; echo "AmneziaWG up" ;;
  stop) ip link del awg0 2>/dev/null; echo "AmneziaWG down" ;;
  restart) $0 stop; sleep 1; $0 start ;;
  status) ip link show awg0 2>/dev/null && awg show awg0 || echo "not running" ;;
esac
AWG

cat > "$CE_PKG/files/usr/bin/obfs4-run" << 'OBFS'
#!/bin/sh
CONF="/etc/storage/tor/bridges.conf"
[ -f "$CONF" ] && . "$CONF"
: "${BRIDGE:=}"
[ -z "$BRIDGE" ] && echo "Set BRIDGE= in $CONF" && exit 1
echo "Starting obfs4proxy..."
/usr/bin/obfs4proxy -enableLogging -logLevel INFO &
OBFS

cat > "$CE_PKG/files/etc/storage/wireguard/wg0.conf.example" << 'WG0'
[Interface]
PrivateKey = YOUR_PRIVATE_KEY
Address = 10.0.0.2/24
DNS = 1.1.1.1
[Peer]
PublicKey = SERVER_PUBLIC_KEY
Endpoint = server:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
WG0

chmod +x "$CE_PKG/files/usr/bin/"*
echo ">>> custom-extras ready"

# ======================================================================
# 5) PATCH user/Makefile - add to hardcoded build list
# ======================================================================
echo ">>> Patching user/Makefile..."
U_MF="$ROOT/user/Makefile"
if [ -f "$U_MF" ]; then
  if ! grep -q 'udp2raw-tunnel' "$U_MF"; then
    if grep -q 'for i in' "$U_MF"; then
      sed -i '/for i in/s|; do|udp2raw-tunnel custom-extras ; do|' "$U_MF"
      echo "  Patched: added to for-loop"
    else
      echo "  WARNING: for-loop not found"
    fi
  else
    echo "  Already patched"
  fi
  grep -c 'udp2raw-tunnel' "$U_MF" && echo "  VERIFIED" || echo "  NOT FOUND!"
else
  echo "  ERROR: $U_MF missing!"
fi

# ======================================================================
# 6) WebUI ASP page
# ======================================================================
echo ">>> WebUI setup..."
WWW_DIR=""
for d in "$ROOT/user/www/n56u_ribbon_fixed" "$ROOT/user/www" "$ROOT/user/httpd/www"; do
  [ -d "$d" ] && WWW_DIR="$d" && break
done
[ -z "$WWW_DIR" ] && WWW_DIR=$(find "$ROOT" -name 'state.js' -path '*/www/*' -exec dirname {} \; 2>/dev/null | head -1)

if [ -n "$WWW_DIR" ] && [ -d "$WWW_DIR" ]; then
  echo "  www: $WWW_DIR"
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
function initial(){show_banner(2);show_menu(5,8,0);show_footer();change_udp2raw_enabled();}
function change_udp2raw_enabled(){var en=document.form.udp2raw_enable[0].checked;showhide_div('tbl_udp2raw_config',en);}
function applyRule(){showLoading();document.form.action_mode.value=" Apply ";document.form.current_page.value="Advanced_udp2raw.asp";document.form.next_page.value="";document.form.submit();}
</script>
</head>
<body onload="initial();" onunload="return unload_body();">
<div class="wrapper">
<div class="container-fluid" style="padding-right:0px"><div class="row-fluid"><div class="span3"><center><div id="logo"></div></center></div><div class="span9"><div id="TopBanner"></div></div></div></div>
<div id="Loading" class="popup_bg"></div>
<iframe name="hidden_frame" id="hidden_frame" src="" width="0" height="0" frameborder="0"></iframe>
<form method="post" name="form" id="form" action="/start_apply.htm" target="hidden_frame">
<input type="hidden" name="current_page" value="Advanced_udp2raw.asp">
<input type="hidden" name="next_page" value=""><input type="hidden" name="next_host" value="">
<input type="hidden" name="sid_list" value=""><input type="hidden" name="group_id" value="">
<input type="hidden" name="action_mode" value=""><input type="hidden" name="action_script" value="">
<div class="container-fluid"><div class="row-fluid">
<div class="span3"><div class="well sidebar-nav side_nav" style="padding:0px;"><ul id="mainMenu" class="clearfix"></ul><ul class="clearfix"><li><div id="subMenu" class="accordion"></div></li></ul></div></div>
<div class="span9"><div class="row-fluid"><div class="span12"><div class="box well grad_colour_dark_blue">
<h2 class="box_head round_top">udp2raw - FakeTCP Tunnel</h2>
<div class="round_bottom"><div class="row-fluid"><div id="tabMenu" class="submenuBlock"></div>
<table width="100%" cellpadding="4" cellspacing="0" class="table">
<tr><th width="50%">Enable udp2raw:</th><td>
<div class="main_itoggle"><div id="udp2raw_enable_on_of"><input type="checkbox" id="udp2raw_enable_fake" <% nvram_match_x("", "udp2raw_enable", "1", "value=1 checked"); %><% nvram_match_x("", "udp2raw_enable", "0", "value=0"); %>></div></div>
<div style="position:absolute;margin-left:-10000px;">
<input type="radio" name="udp2raw_enable" id="udp2raw_enable_1" class="input" value="1" onclick="change_udp2raw_enabled();" <% nvram_match_x("", "udp2raw_enable", "1", "checked"); %>>Yes
<input type="radio" name="udp2raw_enable" id="udp2raw_enable_0" class="input" value="0" onclick="change_udp2raw_enabled();" <% nvram_match_x("", "udp2raw_enable", "0", "checked"); %>>No
</div></td></tr></table>
<div id="tbl_udp2raw_config"><table width="100%" cellpadding="4" cellspacing="0" class="table">
<tr><th colspan="2" style="background-color:#E3E3E3;">Connection</th></tr>
<tr><th width="50%">Server:</th><td><input type="text" name="udp2raw_server" class="input" maxlength="128" size="32" value="<% nvram_get_x("", "udp2raw_server"); %>"></td></tr>
<tr><th>Port:</th><td><input type="text" name="udp2raw_port" class="input" maxlength="5" size="5" value="<% nvram_get_x("", "udp2raw_port"); %>" onkeypress="return is_number(this,event);"></td></tr>
<tr><th>Password:</th><td><input type="password" name="udp2raw_password" id="udp2raw_password" class="input" maxlength="64" size="32" value="<% nvram_get_x("", "udp2raw_password"); %>"><button style="margin-left:-5px;" class="btn" type="button" onclick="passwordShowHide('udp2raw_password')"><i class="icon-eye-close"></i></button></td></tr>
<tr><th>Local port:</th><td><input type="text" name="udp2raw_local_port" class="input" maxlength="5" size="5" value="<% nvram_get_x("", "udp2raw_local_port"); %>" onkeypress="return is_number(this,event);"></td></tr>
<tr><th>Raw mode:</th><td><select name="udp2raw_rawmode" class="input">
<option value="faketcp" <% nvram_match_x("", "udp2raw_rawmode", "faketcp", "selected"); %>>FakeTCP</option>
<option value="udp" <% nvram_match_x("", "udp2raw_rawmode", "udp", "selected"); %>>UDP</option>
<option value="icmp" <% nvram_match_x("", "udp2raw_rawmode", "icmp", "selected"); %>>ICMP</option>
</select></td></tr>
<tr><th colspan="2" style="background-color:#E3E3E3;">SSH commands</th></tr>
<tr><td colspan="2"><div style="background:#1a1a2e;color:#0f0;padding:10px;border-radius:5px;font-size:12px;">
<b>udp2raw-ctl start|stop|restart|status</b><br>
<b>fl-vpn-start start|stop|status</b><br><br>
Auto-start: Scripts &gt; Run After Router Started:<br>
<code style="color:#ff0;">sleep 15 &amp;&amp; fl-vpn-start start &amp;</code>
</div></td></tr>
</table></div>
<table width="100%" cellpadding="4" cellspacing="0" class="table">
<tr><td style="border-top:0 none;text-align:center;"><input type="button" class="btn btn-primary" style="width:219px" onclick="applyRule();" value="Apply"></td></tr>
</table>
</div></div></div></div></div></div></div></div>
</form><div id="footer"></div></div>
</body></html>
ASPEOF
  echo "  Created Advanced_udp2raw.asp"

  # Patch state.js menu
  STATE_JS=$(find "$WWW_DIR" -name 'state.js' 2>/dev/null | head -1)
  if [ -n "$STATE_JS" ] && [ -f "$STATE_JS" ]; then
    if ! grep -q 'Advanced_udp2raw' "$STATE_JS"; then
      if grep -q 'vpnclient' "$STATE_JS"; then
        sed -i '/vpnclient/a\
menuL2_link[menuL2_link.length]="Advanced_udp2raw.asp"; menuL2_title[menuL2_title.length]="udp2raw";' "$STATE_JS" 2>/dev/null || true
        echo "  Menu patched"
      fi
    fi
  else
    echo "  state.js not found"
  fi
else
  echo "  www dir not found!"
fi

# ======================================================================
# 7) nvram defaults
# ======================================================================
echo ">>> nvram defaults..."
DEFAULTS_H=$(find "$ROOT" -name 'defaults.h' -path '*/shared/*' 2>/dev/null | head -1)
if [ -n "$DEFAULTS_H" ] && [ -f "$DEFAULTS_H" ]; then
  if ! grep -q 'udp2raw_enable' "$DEFAULTS_H"; then
    LAST=$(grep -n '{ "' "$DEFAULTS_H" | tail -1 | cut -d: -f1)
    if [ -n "$LAST" ]; then
      sed -i "${LAST}a\\
\t{ \"udp2raw_enable\", \"0\" },\\
\t{ \"udp2raw_server\", \"\" },\\
\t{ \"udp2raw_port\", \"4096\" },\\
\t{ \"udp2raw_password\", \"\" },\\
\t{ \"udp2raw_local_port\", \"1194\" },\\
\t{ \"udp2raw_rawmode\", \"faketcp\" }," "$DEFAULTS_H"
      echo "  Added after line $LAST"
    fi
  fi
else
  echo "  defaults.h not found"
fi

# ======================================================================
# DIAGNOSTICS
# ======================================================================
echo ""
echo "============================================"
echo "  Firmware components:"
echo "  - OpenVPN ${OVPN_VER} + XOR"
echo "  - udp2raw ${UDP2RAW_VER} (mipsel)"
echo "  - AmneziaWG + WireGuard"
echo "  - NFQWS + TOR + OBFS4"
echo "  - WebUI: Advanced_udp2raw.asp"
echo "============================================"
echo ""
echo "=== DIAGNOSTICS ==="
echo "--- udp2raw files ---"
ls -la "$UDP2RAW_PKG/files/" 2>/dev/null
echo "--- udp2raw Makefile ---"
cat "$UDP2RAW_PKG/Makefile"
echo "--- custom-extras Makefile ---"
cat "$CE_PKG/Makefile"
echo "--- user/Makefile grep ---"
grep 'udp2raw\|custom-extras' "$U_MF" 2>/dev/null || echo "NOT FOUND!"
echo "--- www ---"
ls "$WWW_DIR"/Advanced_udp2raw.asp 2>/dev/null || echo "ASP NOT FOUND!"
echo "=== END ==="
