#!/bin/bash
############################################################
# MILLENIUM Group — Padavan-NG pre-build script v2.0
# udp2raw FakeTCP + OpenVPN tunnel with WebUI
# All fixes from 2026-03-04 debugging session incorporated
#
# Changes from v1:
# - Local port default 3333 (avoids conflict with OpenVPN 1194)
# - MTU 1000 / MSS 900 (udp2raw overhead fix)
# - RST DROP rules in udp2raw-ctl
# - NAT MASQUERADE inserted FIRST (before SNAT)
# - Auto-detect tun interface (tun0/tun1)
# - DNS via VPN (dnsmasq.servers)
# - fl-vpn-stop script added
# - WebUI v2 with Start/Stop VPN buttons
############################################################
set -euo pipefail

TRUNK="padavan-ng/trunk"
WWW="$TRUNK/user/www/n56u_ribbon_fixed"

echo "============================================"
echo "  MILLENIUM Group VPN — pre-build v2.0"
echo "============================================"

############################################################
# 1. OpenVPN — refresh source directory
############################################################
echo ">>> refresh $TRUNK/user/openvpn"

############################################################
# 2. udp2raw-tunnel: pre-compiled binary
############################################################
echo ">>> Setting up udp2raw-tunnel"
UDP2RAW_DIR="$TRUNK/user/udp2raw-tunnel"
mkdir -p "$UDP2RAW_DIR/files"

echo ">>> Downloading pre-compiled udp2raw binary"
curl -sL -o /tmp/udp2raw_binaries.tar.gz \
  https://github.com/wangyu-/udp2raw/releases/download/20230206.0/udp2raw_binaries.tar.gz
echo ">>> Archive contents:"
tar tzf /tmp/udp2raw_binaries.tar.gz
cd /tmp && tar xzf udp2raw_binaries.tar.gz
cp udp2raw_mips24kc_le "$OLDPWD/$UDP2RAW_DIR/files/udp2raw"
chmod +x "$OLDPWD/$UDP2RAW_DIR/files/udp2raw"
cd "$OLDPWD"
echo ">>> Binary: $(ls -la $UDP2RAW_DIR/files/udp2raw)"
echo ">>> udp2raw-tunnel package ready"

############################################################
# 2a. udp2raw-ctl v2 — control script with all fixes
############################################################
cat > "$UDP2RAW_DIR/files/udp2raw-ctl" << 'CTLEOF'
#!/bin/sh
# udp2raw-ctl v2.0 — control script for udp2raw FakeTCP tunnel
# Includes RST DROP fix, proper iptables cleanup
PIDFILE="/var/run/udp2raw.pid"
LOGFILE="/tmp/udp2raw.log"

get_conf() {
    SERVER=$(nvram get udp2raw_server 2>/dev/null)
    PORT=$(nvram get udp2raw_port 2>/dev/null)
    PASSWORD=$(nvram get udp2raw_password 2>/dev/null)
    LOCAL_PORT=$(nvram get udp2raw_local_port 2>/dev/null)
    RAWMODE=$(nvram get udp2raw_rawmode 2>/dev/null)
    [ -z "$PORT" ] && PORT="4096"
    [ -z "$PASSWORD" ] && PASSWORD="millenium2026"
    [ -z "$LOCAL_PORT" ] && LOCAL_PORT="3333"
    [ -z "$RAWMODE" ] && RAWMODE="faketcp"
}

do_start() {
    get_conf
    if [ -z "$SERVER" ] || [ "$SERVER" = "" ]; then
        echo "ERROR: Server not set"
        echo "  nvram set udp2raw_server=\"IP\""
        return 1
    fi

    # Kill old
    [ -f "$PIDFILE" ] && kill $(cat "$PIDFILE") 2>/dev/null
    killall udp2raw 2>/dev/null
    sleep 1

    # RST DROP — prevent kernel from killing FakeTCP sessions
    iptables -C OUTPUT -p tcp --dport "$PORT" --tcp-flags RST RST -j DROP 2>/dev/null || \
        iptables -A OUTPUT -p tcp --dport "$PORT" --tcp-flags RST RST -j DROP

    echo "Starting: ${SERVER}:${PORT} -> 127.0.0.1:${LOCAL_PORT} (${RAWMODE})"

    /usr/bin/udp2raw -c \
        -l "127.0.0.1:${LOCAL_PORT}" \
        -r "${SERVER}:${PORT}" \
        -k "$PASSWORD" \
        --raw-mode "$RAWMODE" \
        --cipher-mode xor \
        --auth-mode simple \
        -a \
        --log-level 3 \
        > "$LOGFILE" 2>&1 &

    PID=$!
    echo "$PID" > "$PIDFILE"
    sleep 1

    if kill -0 "$PID" 2>/dev/null; then
        echo "OK (PID $PID)"
    else
        echo "FAILED"
        tail -5 "$LOGFILE"
        return 1
    fi
}

do_stop() {
    if [ -f "$PIDFILE" ]; then
        kill $(cat "$PIDFILE") 2>/dev/null
        rm -f "$PIDFILE"
    fi
    killall udp2raw 2>/dev/null
    echo "Stopped"
}

do_status() {
    get_conf
    if [ -f "$PIDFILE" ] && kill -0 $(cat "$PIDFILE") 2>/dev/null; then
        echo "RUNNING (PID $(cat $PIDFILE))"
    else
        echo "STOPPED"
    fi
    echo "Server: ${SERVER:-<not set>}:${PORT} Local: 127.0.0.1:${LOCAL_PORT} Mode: ${RAWMODE}"
    [ -f "$LOGFILE" ] && tail -3 "$LOGFILE" 2>/dev/null
}

case "${1:-}" in
    start)   do_start ;;
    stop)    do_stop ;;
    restart) do_stop; sleep 2; do_start ;;
    status)  do_status ;;
    *) echo "Usage: udp2raw-ctl {start|stop|restart|status}"; exit 1 ;;
esac
CTLEOF
chmod +x "$UDP2RAW_DIR/files/udp2raw-ctl"

############################################################
# 2b. fl-vpn-start v2 — full VPN startup
############################################################
cat > "$UDP2RAW_DIR/files/fl-vpn-start" << 'VPNEOF'
#!/bin/sh
# fl-vpn-start v2.0 — Start udp2raw + OpenVPN with network rules
# All fixes: MTU 1000, MSS 900, NAT before SNAT, DNS, auto tun detect
LOG="/tmp/fl-vpn.log"
exec > "$LOG" 2>&1
echo "=== fl-vpn-start $(date) ==="

SERVER=$(nvram get udp2raw_server 2>/dev/null)
LOCAL_PORT=$(nvram get udp2raw_local_port 2>/dev/null || echo "3333")
VPN_MTU=$(nvram get udp2raw_mtu 2>/dev/null || echo "1000")
VPN_MSS=$(nvram get udp2raw_mss 2>/dev/null || echo "900")
OVPN="/etc/storage/openvpn/client-udp2raw.ovpn"

[ -z "$SERVER" ] && { echo "ERROR: no server"; exit 1; }

# Stop everything
killall openvpn 2>/dev/null; sleep 1
udp2raw-ctl stop 2>/dev/null; sleep 2

# Start udp2raw
udp2raw-ctl start || exit 1
sleep 3

# Patch ovpn config with current settings
[ -f "$OVPN" ] && {
    sed -i "s|^remote .*|remote 127.0.0.1 ${LOCAL_PORT}|" "$OVPN"
    sed -i "s|^tun-mtu .*|tun-mtu ${VPN_MTU}|" "$OVPN"
    sed -i "s|^mssfix .*|mssfix ${VPN_MSS}|" "$OVPN"
}

# Start OpenVPN
openvpn --config "$OVPN" --daemon --log /tmp/openvpn.log
sleep 15

# Find tun interface
TUN=""
for t in tun0 tun1 tun2; do
    ip link show "$t" 2>/dev/null | grep -q UP && { TUN="$t"; break; }
done
[ -z "$TUN" ] && { echo "FATAL: no tun"; tail -10 /tmp/openvpn.log; exit 1; }
echo ">>> tun=$TUN"

# LAN subnet
LAN_NET=$(ip -4 addr show br0 2>/dev/null | awk '/inet /{print $2}' | sed 's|/.*||;s|\.[0-9]*$|.0/24|')
[ -z "$LAN_NET" ] && LAN_NET="192.168.30.0/24"

# MSS clamping
iptables -t mangle -F FORWARD 2>/dev/null
iptables -t mangle -A FORWARD -o "$TUN" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$VPN_MSS"
iptables -t mangle -A FORWARD -i "$TUN" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$VPN_MSS"

# NAT — insert FIRST (before firmware SNAT rules!)
iptables -t nat -D POSTROUTING -o "$TUN" -s "$LAN_NET" -j MASQUERADE 2>/dev/null
iptables -t nat -I POSTROUTING 1 -o "$TUN" -s "$LAN_NET" -j MASQUERADE

# DNS
echo "server=94.140.14.14" > /tmp/dnsmasq.servers
echo "server=8.8.8.8" >> /tmp/dnsmasq.servers
killall -HUP dnsmasq 2>/dev/null

echo "=== DONE $(date) ==="
echo "tun=$TUN ip=$(ifconfig $TUN 2>/dev/null | awk '/inet addr/{print $2}' | cut -d: -f2)"
VPNEOF
chmod +x "$UDP2RAW_DIR/files/fl-vpn-start"

############################################################
# 2c. fl-vpn-stop — clean shutdown
############################################################
cat > "$UDP2RAW_DIR/files/fl-vpn-stop" << 'STOPEOF'
#!/bin/sh
echo ">>> Stopping VPN..."
killall openvpn 2>/dev/null; sleep 1
udp2raw-ctl stop 2>/dev/null
iptables -t mangle -F FORWARD 2>/dev/null
for t in tun0 tun1 tun2; do
    iptables -t nat -D POSTROUTING -o "$t" -j MASQUERADE 2>/dev/null
done
echo ">>> Done"
STOPEOF
chmod +x "$UDP2RAW_DIR/files/fl-vpn-stop"

############################################################
# 2d. Makefile
############################################################
cat > "$UDP2RAW_DIR/Makefile" << 'MKEOF'
all:
	@echo "[udp2raw-tunnel] pre-compiled binary"
	@[ -f files/udp2raw ] && ls -la files/udp2raw || echo "WARNING: binary missing"

romfs:
	@echo "[udp2raw-tunnel] installing to romfs..."
	$(ROMFSINST) -p +x files/udp2raw /usr/bin/udp2raw
	$(ROMFSINST) -p +x files/udp2raw-ctl /usr/bin/udp2raw-ctl
	$(ROMFSINST) -p +x files/fl-vpn-start /usr/bin/fl-vpn-start
	$(ROMFSINST) -p +x files/fl-vpn-stop /usr/bin/fl-vpn-stop
	@echo "[udp2raw-tunnel] DONE"

clean:
	@echo "[udp2raw-tunnel] clean"
MKEOF

############################################################
# 3. custom-extras (mkdir fix)
############################################################
echo ">>> custom-extras ready"
CUSTOM_DIR="$TRUNK/user/custom-extras"
if [ -d "$CUSTOM_DIR" ]; then
    mkdir -p "$CUSTOM_DIR/files/etc/storage/wireguard"
    if [ -f "$CUSTOM_DIR/Makefile" ] && ! grep -q "mkdir -p" "$CUSTOM_DIR/Makefile"; then
        sed -i '/ROMFSINST.*wireguard/i\\tmkdir -p $(ROOTDIR)/romfs/etc/storage/wireguard' "$CUSTOM_DIR/Makefile"
    fi
fi

############################################################
# 4. Patch user/Makefile
############################################################
echo ">>> Patching user/Makefile..."
UMAKEFILE="$TRUNK/user/Makefile"
if ! grep -q "udp2raw-tunnel" "$UMAKEFILE"; then
    sed -i 's/for i in $(dir_y) ;/for i in $(dir_y) udp2raw-tunnel custom-extras ;/g' "$UMAKEFILE"
    sed -i 's/for i in `ls -d \*` ;/for i in `ls -d *` udp2raw-tunnel custom-extras ;/g' "$UMAKEFILE"
    echo "  PATCHED"
else
    echo "  ALREADY PATCHED"
fi
grep "udp2raw-tunnel" "$UMAKEFILE" | head -3
echo "  VERIFIED"

############################################################
# 5. WebUI — Advanced_udp2raw.asp v2
############################################################
echo ">>> WebUI setup..."
echo "  www: $WWW"

cat > "$WWW/Advanced_udp2raw.asp" << 'ASPEOF'
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>udp2raw FakeTCP Tunnel</title>
<link rel="stylesheet" type="text/css" href="/bootstrap/css/bootstrap.min.css">
<link rel="stylesheet" type="text/css" href="/bootstrap/css/main.css">
<script src="/state.js"></script>
<script src="/popup.js"></script>
<script src="/general.js"></script>
<script>
function initial(){
    show_banner(2);
    show_menu(5,-1,0);
    show_footer();
    change_enabled();
    poll_status();
}

function change_enabled(){
    var en = (document.form.udp2raw_enabled.value=="1");
    var ids=["udp2raw_server","udp2raw_port","udp2raw_password",
             "udp2raw_local_port","udp2raw_rawmode","udp2raw_mtu","udp2raw_mss"];
    for(var i=0;i<ids.length;i++){
        var r=document.getElementById("row_"+ids[i]);
        if(r) r.style.display=en?"":"none";
    }
    var b=document.getElementById("row_buttons");
    if(b) b.style.display=en?"":"none";
}

function poll_status(){
    var x=new XMLHttpRequest();
    x.open("GET","/cgi-bin/udp2raw_status.sh?t="+Date.now(),true);
    x.onload=function(){
        var el=document.getElementById("status_text");
        if(!el)return;
        var t=x.responseText||"";
        if(t.indexOf("RUNNING")>=0){
            el.innerHTML='<span style="color:#27AE60;font-weight:bold">\u25CF RUNNING</span>';
            var m=t.match(/PID (\d+)/);
            if(m) el.innerHTML+=' (PID '+m[1]+')';
            var ip=t.match(/inet addr:([0-9.]+)/)||t.match(/ip=([0-9.]+)/);
            if(ip) el.innerHTML+=' &mdash; VPN: '+ip[1];
        } else {
            el.innerHTML='<span style="color:#E74C3C;font-weight:bold">\u25CF STOPPED</span>';
        }
    };
    x.onerror=function(){ /* ignore */ };
    x.send();
}

function run_cmd(cmd, delay){
    var x=new XMLHttpRequest();
    x.open("GET","/cgi-bin/udp2raw_action.sh?act="+cmd+"&t="+Date.now(),true);
    x.send();
    document.getElementById("status_text").innerHTML=
        '<span style="color:#F39C12;font-weight:bold">\u25CF '+cmd+'...</span>';
    setTimeout(poll_status, delay||5000);
}

function do_apply(){
    showLoading();
    document.form.action_mode.value=" Apply ";
    document.form.submit();
    setTimeout(function(){ hideLoading(); }, 3000);
}

function show_log(){
    var x=new XMLHttpRequest();
    x.open("GET","/cgi-bin/udp2raw_log.sh?t="+Date.now(),true);
    x.onload=function(){
        var el=document.getElementById("log_area");
        el.value=x.responseText||"No logs";
        el.style.display="";
        el.scrollTop=el.scrollHeight;
    };
    x.send();
}
</script>
</head>
<body onload="initial();" onunload="return unload_body();">
<div id="TopBanner"></div>
<div id="Loading" class="popup_bg"></div>
<iframe name="hidden_frame" id="hidden_frame" src="" width="0" height="0" frameborder="0"></iframe>
<form method="post" name="form" id="form" action="/start_apply.htm" target="hidden_frame">
<input type="hidden" name="current_page" value="Advanced_udp2raw.asp">
<input type="hidden" name="action_mode" value=" Apply ">
<input type="hidden" name="action_script" value="">
<input type="hidden" name="group_id" value="">
<input type="hidden" name="modified" value="0">
<input type="hidden" name="preferred_lang" id="preferred_lang" value="<% nvram_get_x("","preferred_lang"); %>">
<table class="content" align="center" cellpadding="0" cellspacing="0">
<tr>
<td width="17">&nbsp;</td>
<td valign="top" width="202">
    <div id="mainMenu"></div>
    <div id="subMenu"></div>
</td>
<td valign="top">
<div id="tabMenu" class="submenuBlock"></div>
<table width="98%" border="0" align="left" cellpadding="0" cellspacing="0">
<tr><td align="left" valign="top">
<table width="760px" border="0" cellpadding="5" cellspacing="0" class="FormTitle" id="FormTitle">
<tr><td bgcolor="#4D595D" valign="top">
<div>&nbsp;</div>
<div class="formfonttitle">udp2raw FakeTCP Tunnel</div>
<div style="margin:10px 0 10px 5px;" class="splitLine"></div>
<div class="formfontdesc" style="padding-bottom:10px;">
    OpenVPN через FakeTCP туннель для обхода DPI.<br>
    UDP трафик упаковывается в TCP-подобные пакеты, невидимые для глубокой инспекции.
</div>

<!-- Status -->
<table width="100%" border="1" align="center" cellpadding="4" cellspacing="0" bordercolor="#6b8fa3" class="FormTable">
<tr><th width="30%">Статус</th><td><span id="status_text">Загрузка...</span></td></tr>
</table>
<div style="height:8px;"></div>

<!-- Enable -->
<table width="100%" border="1" align="center" cellpadding="4" cellspacing="0" bordercolor="#6b8fa3" class="FormTable">
<tr><th width="30%">Включить udp2raw</th><td>
    <select name="udp2raw_enabled" class="input_option" onchange="change_enabled()">
        <option value="0" <% nvram_match_x("","udp2raw_enabled","0","selected"); %>>Выключен</option>
        <option value="1" <% nvram_match_x("","udp2raw_enabled","1","selected"); %>>Включён</option>
    </select>
</td></tr>
</table>
<div style="height:8px;"></div>

<!-- Settings -->
<table width="100%" border="1" align="center" cellpadding="4" cellspacing="0" bordercolor="#6b8fa3" class="FormTable">
<thead><tr><td colspan="2">Настройки туннеля</td></tr></thead>
<tr id="row_udp2raw_server"><th width="30%">Сервер (IP)</th>
    <td><input type="text" name="udp2raw_server" class="input_25_table" maxlength="64"
         value="<% nvram_get_x("","udp2raw_server"); %>" placeholder="89.39.70.224"></td></tr>
<tr id="row_udp2raw_port"><th>Порт сервера</th>
    <td><input type="text" name="udp2raw_port" class="input_6_table" maxlength="5"
         value="<% nvram_get_x("","udp2raw_port"); %>" placeholder="4096"></td></tr>
<tr id="row_udp2raw_password"><th>Пароль</th>
    <td><input type="password" name="udp2raw_password" class="input_25_table" maxlength="64"
         value="<% nvram_get_x("","udp2raw_password"); %>"></td></tr>
<tr id="row_udp2raw_local_port"><th>Локальный порт</th>
    <td><input type="text" name="udp2raw_local_port" class="input_6_table" maxlength="5"
         value="<% nvram_get_x("","udp2raw_local_port"); %>" placeholder="3333"></td></tr>
<tr id="row_udp2raw_rawmode"><th>Режим</th><td>
    <select name="udp2raw_rawmode" class="input_option">
        <option value="faketcp" <% nvram_match_x("","udp2raw_rawmode","faketcp","selected"); %>>FakeTCP</option>
        <option value="udp" <% nvram_match_x("","udp2raw_rawmode","udp","selected"); %>>UDP</option>
        <option value="icmp" <% nvram_match_x("","udp2raw_rawmode","icmp","selected"); %>>ICMP</option>
    </select>
</td></tr>
<tr id="row_udp2raw_mtu"><th>VPN MTU</th>
    <td><input type="text" name="udp2raw_mtu" class="input_6_table" maxlength="5"
         value="<% nvram_get_x("","udp2raw_mtu"); %>" placeholder="1000"></td></tr>
<tr id="row_udp2raw_mss"><th>VPN MSS</th>
    <td><input type="text" name="udp2raw_mss" class="input_6_table" maxlength="5"
         value="<% nvram_get_x("","udp2raw_mss"); %>" placeholder="900"></td></tr>
</table>
<div style="height:8px;"></div>

<!-- Buttons -->
<table width="100%" border="1" align="center" cellpadding="4" cellspacing="0" bordercolor="#6b8fa3" class="FormTable" id="row_buttons">
<thead><tr><td colspan="2">Управление</td></tr></thead>
<tr><th width="30%">Полный VPN</th><td>
    <input type="button" class="btn btn-success" style="width:180px;margin:2px" value="&#9654; Запустить VPN" onclick="run_cmd('fullstart',20000)">
    <input type="button" class="btn btn-danger" style="width:180px;margin:2px" value="&#9632; Остановить VPN" onclick="run_cmd('fullstop',3000)">
</td></tr>
<tr><th>Только udp2raw</th><td>
    <input type="button" class="btn btn-primary" style="width:130px;margin:2px" value="Start" onclick="run_cmd('start',5000)">
    <input type="button" class="btn btn-warning" style="width:130px;margin:2px" value="Stop" onclick="run_cmd('stop',2000)">
    <input type="button" class="btn btn-info" style="width:130px;margin:2px" value="Restart" onclick="run_cmd('restart',6000)">
</td></tr>
<tr><th>Лог</th><td>
    <input type="button" class="btn btn-default" style="width:130px" value="Показать лог" onclick="show_log()">
    <br><br>
    <textarea id="log_area" style="display:none;width:95%;height:220px;font-family:Consolas,monospace;font-size:11px;background:#1a1a2e;color:#0f0;padding:8px;border-radius:4px;" readonly></textarea>
</td></tr>
</table>
<div style="height:8px;"></div>

<!-- Apply -->
<div class="apply_gen">
    <input class="button_gen" onclick="do_apply()" type="button" value="Сохранить"/>
</div>

</td></tr></table>
</td></tr></table>
</td></tr></table>
</form>
<div id="footer"></div>
</body>
</html>
ASPEOF
echo "  Created Advanced_udp2raw.asp v2"

############################################################
# 5b. CGI scripts for WebUI actions
############################################################
CGI_DIR="$WWW/cgi-bin"
mkdir -p "$CGI_DIR"

# Status CGI
cat > "$CGI_DIR/udp2raw_status.sh" << 'CGIST'
#!/bin/sh
echo "Content-Type: text/plain"
echo ""
udp2raw-ctl status 2>/dev/null
# Show VPN IP if connected
for t in tun0 tun1 tun2; do
    ifconfig "$t" 2>/dev/null | grep "inet addr" && break
done
CGIST
chmod +x "$CGI_DIR/udp2raw_status.sh"

# Action CGI
cat > "$CGI_DIR/udp2raw_action.sh" << 'CGIACT'
#!/bin/sh
echo "Content-Type: text/plain"
echo ""
ACT=$(echo "$QUERY_STRING" | sed 's/.*act=//;s/&.*//')
case "$ACT" in
    start)     udp2raw-ctl start 2>&1 ;;
    stop)      udp2raw-ctl stop 2>&1 ;;
    restart)   udp2raw-ctl restart 2>&1 ;;
    fullstart) fl-vpn-start 2>&1 & echo "Starting VPN in background..." ;;
    fullstop)  fl-vpn-stop 2>&1 ;;
    *) echo "Unknown action: $ACT" ;;
esac
CGIACT
chmod +x "$CGI_DIR/udp2raw_action.sh"

# Log CGI
cat > "$CGI_DIR/udp2raw_log.sh" << 'CGILOG'
#!/bin/sh
echo "Content-Type: text/plain"
echo ""
echo "=== udp2raw log ==="
tail -30 /tmp/udp2raw.log 2>/dev/null || echo "(empty)"
echo ""
echo "=== OpenVPN log ==="
tail -30 /tmp/openvpn.log 2>/dev/null || echo "(empty)"
echo ""
echo "=== fl-vpn log ==="
tail -20 /tmp/fl-vpn.log 2>/dev/null || echo "(empty)"
CGILOG
chmod +x "$CGI_DIR/udp2raw_log.sh"

############################################################
# 6. state.js menu patch
############################################################
echo ">>> Patching state.js menu..."
STATEJS="$WWW/state.js"
if [ -f "$STATEJS" ] && ! grep -q "Advanced_udp2raw" "$STATEJS"; then
    # Try to add to Дополнительно section (5) or VPN section
    if grep -q "menuL2_title\[5\]" "$STATEJS"; then
        LAST=$(grep -n "menuL3_link\[5\]" "$STATEJS" | tail -1 | cut -d: -f1)
        CNT=$(grep -c "menuL3_title\[5\]" "$STATEJS")
        if [ -n "$LAST" ]; then
            sed -i "${LAST}a\\
menuL3_title[5][${CNT}] = \"udp2raw Tunnel\";\\
menuL3_link[5][${CNT}] = \"Advanced_udp2raw.asp\";" "$STATEJS"
            echo "  state.js patched"
        fi
    fi
fi
grep -q "Advanced_udp2raw" "$STATEJS" 2>/dev/null && echo "  Menu OK" || echo "  WARN: menu not patched (cosmetic)"

############################################################
# 7. nvram defaults
############################################################
echo ">>> nvram defaults..."
DEFAULTS_H="$TRUNK/user/shared/defaults.h"
if [ -f "$DEFAULTS_H" ] && ! grep -q "udp2raw_enabled" "$DEFAULTS_H"; then
    LAST_LINE=$(grep -n '{ "' "$DEFAULTS_H" | tail -1 | cut -d: -f1)
    if [ -n "$LAST_LINE" ]; then
        sed -i "${LAST_LINE}a\\
\t{ \"udp2raw_enabled\", \"0\" },\\
\t{ \"udp2raw_server\", \"\" },\\
\t{ \"udp2raw_port\", \"4096\" },\\
\t{ \"udp2raw_password\", \"millenium2026\" },\\
\t{ \"udp2raw_local_port\", \"3333\" },\\
\t{ \"udp2raw_rawmode\", \"faketcp\" },\\
\t{ \"udp2raw_mtu\", \"1000\" },\\
\t{ \"udp2raw_mss\", \"900\" }," "$DEFAULTS_H"
        echo "  defaults.h patched"
    fi
else
    echo "  defaults.h already done"
fi

############################################################
# 8. Branding
############################################################
echo ">>> Branding..."
BOOT_MSG="$TRUNK/user/scripts/autostart.sh"
# Any additional branding goes here

############################################################
# Summary
############################################################
echo "============================================"
echo "  MILLENIUM Group VPN — build ready v2.0"
echo "  - udp2raw 20230206.0 (mipsel)"
echo "  - WebUI: Advanced_udp2raw.asp v2"
echo "  - udp2raw-ctl v2 (RST fix)"
echo "  - fl-vpn-start v2 (MTU/MSS/NAT/DNS)"
echo "  - fl-vpn-stop"
echo "  - CGI scripts for WebUI actions"
echo "============================================"
echo "=== DIAGNOSTICS ==="
echo "--- udp2raw files ---"
ls -la "$UDP2RAW_DIR/files/"
echo "--- udp2raw Makefile ---"
grep -v "^$" "$UDP2RAW_DIR/Makefile"
echo "--- user/Makefile grep ---"
grep "udp2raw-tunnel" "$UMAKEFILE" | head -3
echo "--- www ---"
ls "$WWW/Advanced_udp2raw.asp" "$CGI_DIR"/*.sh 2>/dev/null
echo "=== END ==="
