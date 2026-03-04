#!/bin/bash
############################################################
# MILLENIUM Group — Padavan-NG pre-build v3.0
#
# Proper integration using real Padavan ASP template
# - ASP page with sidebar/menu/footer (from vpncli.asp)
# - nvram for all settings (no broken CGI)
# - Watchdog reads nvram, manages VPN state
# - Failover across multiple servers
############################################################
set -euo pipefail

TRUNK="padavan-ng/trunk"
UDP2RAW_DIR="$TRUNK/user/udp2raw-tunnel"
WWW="$TRUNK/user/www/n56u_ribbon_fixed"

echo "============================================"
echo "  MILLENIUM Group VPN — pre-build v3.0"
echo "============================================"

echo ">>> refresh padavan-ng/trunk/user/openvpn"

############################################################
# 1. udp2raw binary
############################################################
echo ">>> Setting up udp2raw-tunnel"
mkdir -p "$UDP2RAW_DIR/files"

echo ">>> Downloading pre-compiled udp2raw binary"
curl -sL -o /tmp/udp2raw_binaries.tar.gz \
  https://github.com/wangyu-/udp2raw/releases/download/20230206.0/udp2raw_binaries.tar.gz

echo ">>> Archive contents:"
cd /tmp && tar xzf udp2raw_binaries.tar.gz && ls udp2raw_*
cp udp2raw_mips24kc_le "$OLDPWD/$UDP2RAW_DIR/files/udp2raw"
chmod +x "$OLDPWD/$UDP2RAW_DIR/files/udp2raw"
cd "$OLDPWD"
echo ">>> Binary: $(ls -la $UDP2RAW_DIR/files/udp2raw)"

############################################################
# 2. udp2raw-ctl
############################################################
cat > "$UDP2RAW_DIR/files/udp2raw-ctl" << 'CTLEOF'
#!/bin/sh
PIDFILE="/var/run/udp2raw.pid"
LOGFILE="/tmp/udp2raw.log"

do_start() {
    [ -f /tmp/udp2raw_srv ] && . /tmp/udp2raw_srv || { echo "No server"; return 1; }
    [ -z "$SRV" ] && return 1
    killall udp2raw 2>/dev/null; sleep 1
    iptables -C OUTPUT -p tcp --dport "$PRT" --tcp-flags RST RST -j DROP 2>/dev/null || \
        iptables -A OUTPUT -p tcp --dport "$PRT" --tcp-flags RST RST -j DROP
    /usr/bin/udp2raw -c -l "127.0.0.1:3333" -r "${SRV}:${PRT}" \
        -k "$KEY" --raw-mode faketcp --cipher-mode xor --auth-mode simple \
        -a --log-level 3 > "$LOGFILE" 2>&1 &
    echo $! > "$PIDFILE"; sleep 2
    kill -0 $(cat "$PIDFILE") 2>/dev/null && echo "OK" || { echo "FAIL"; return 1; }
}
do_stop() {
    [ -f /tmp/udp2raw_srv ] && { . /tmp/udp2raw_srv; iptables -D OUTPUT -p tcp --dport "${PRT:-4096}" --tcp-flags RST RST -j DROP 2>/dev/null; }
    [ -f "$PIDFILE" ] && kill $(cat "$PIDFILE") 2>/dev/null; rm -f "$PIDFILE"; killall udp2raw 2>/dev/null
}
case "${1:-}" in start) do_start;; stop) do_stop;; restart) do_stop; sleep 2; do_start;;
status) [ -f "$PIDFILE" ] && kill -0 $(cat "$PIDFILE") 2>/dev/null && echo "RUNNING" || echo "STOPPED";;
*) echo "Usage: udp2raw-ctl {start|stop|restart|status}";; esac
CTLEOF
chmod +x "$UDP2RAW_DIR/files/udp2raw-ctl"

############################################################
# 3. fl-vpn-start — failover + OpenVPN
############################################################
cat > "$UDP2RAW_DIR/files/fl-vpn-start" << 'VPNEOF'
#!/bin/sh
LOG="/tmp/fl-vpn.log"
exec > "$LOG" 2>&1
echo "=== fl-vpn-start $(date) ==="

# Read servers from nvram (delimiter >)
SERVERS=$(nvram get udp2raw_servers 2>/dev/null)
[ -z "$SERVERS" ] && { echo "No servers configured"; nvram set udp2raw_status="NO CONFIG"; exit 1; }

fl-vpn-stop 2>/dev/null; sleep 2
nvram set udp2raw_status="CONNECTING..."

SKIP=$(cat /tmp/vpn_skip 2>/dev/null || echo "-1")
OK=0

# Write server list to temp file for line-by-line reading
echo "$SERVERS" | tr '>' '\n' > /tmp/vpn_srvlist

IDX=0
while IFS='' read -r line; do
    [ -z "$line" ] && continue
    echo "$line" | grep -q "^#" && continue
    S=$(echo "$line"|cut -d: -f1); P=$(echo "$line"|cut -d: -f2); K=$(echo "$line"|cut -d: -f3-)
    [ -z "$S" ] && continue; [ -z "$P" ] && P=4096; [ -z "$K" ] && K=changeme

    if [ "$IDX" -le "$SKIP" ] && [ "$SKIP" -ge 0 ]; then
        IDX=$((IDX+1)); continue
    fi

    echo ">>> [$IDX] $S:$P"
    ping -c 2 -W 4 "$S" >/dev/null 2>&1 || { echo "  unreachable"; IDX=$((IDX+1)); continue; }

    echo "SRV=$S" > /tmp/udp2raw_srv; echo "PRT=$P" >> /tmp/udp2raw_srv; echo "KEY=$K" >> /tmp/udp2raw_srv
    udp2raw-ctl start || { IDX=$((IDX+1)); continue; }

    # Route real server via WAN
    WG=$(ip route|grep default|awk '{print $3}'|head -1); WI=$(ip route|grep default|awk '{print $5}'|head -1)
    [ -n "$WG" ] && { ip route del "$S/32" 2>/dev/null; ip route add "$S/32" via "$WG" dev "$WI"; }

    # Start OpenVPN
    OVPN="/tmp/fl-ovpn.conf"
    cat > "$OVPN" << EOF
client
dev tun
proto udp
remote 127.0.0.1 3333
resolv-retry infinite
nobind
persist-key
persist-tun
tun-mtu 1000
mssfix 900
auth SHA256
cipher AES-128-GCM
data-ciphers CHACHA20-POLY1305:AES-256-GCM:AES-128-GCM
tls-crypt /etc/storage/openvpn/client/ta.key
ca /etc/storage/openvpn/client/ca.crt
cert /etc/storage/openvpn/client/client.crt
key /etc/storage/openvpn/client/client.key
scramble obfuscate millenium2026
route $S 255.255.255.255 net_gateway
verb 3
EOF
    killall openvpn 2>/dev/null; sleep 1
    openvpn --config "$OVPN" --daemon --log /tmp/openvpn.log

    W=0; TUN=""
    while [ $W -lt 30 ]; do
        for t in tun0 tun1 tun2; do ip link show "$t" 2>/dev/null|grep -q UP && { TUN="$t"; break 2; }; done
        sleep 2; W=$((W+2))
    done

    if [ -n "$TUN" ]; then
        VIP=$(ip -4 addr show "$TUN"|awk '/inet /{print $2}'|cut -d/ -f1)
        echo "  CONNECTED $TUN $VIP via $S"
        echo "$IDX" > /tmp/vpn_idx

        # NAT + MSS
        LAN=$(ip -4 addr show br0|awk '/inet /{print $2}'|sed 's|/.*||;s|\.[0-9]*$|.0/24|')
        [ -z "$LAN" ] && LAN="192.168.30.0/24"
        iptables -t mangle -D FORWARD -o "$TUN" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 900 2>/dev/null
        iptables -t mangle -D FORWARD -i "$TUN" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 900 2>/dev/null
        iptables -t mangle -A FORWARD -o "$TUN" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 900
        iptables -t mangle -A FORWARD -i "$TUN" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 900
        iptables -t nat -D POSTROUTING -o "$TUN" -s "$LAN" -j MASQUERADE 2>/dev/null
        iptables -t nat -I POSTROUTING 1 -o "$TUN" -s "$LAN" -j MASQUERADE
        iptables -C FORWARD -i br0 -o "$TUN" -j ACCEPT 2>/dev/null || iptables -A FORWARD -i br0 -o "$TUN" -j ACCEPT
        iptables -C FORWARD -i "$TUN" -o br0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$TUN" -o br0 -m state --state RELATED,ESTABLISHED -j ACCEPT
        echo "server=94.140.14.14" > /tmp/dnsmasq.servers; echo "server=8.8.8.8" >> /tmp/dnsmasq.servers
        killall -HUP dnsmasq 2>/dev/null

        nvram set udp2raw_status="CONNECTED"
        nvram set udp2raw_active="$S:$P"
        nvram set udp2raw_vpnip="$VIP"
        echo "=== DONE $(date) ==="
        OK=1; break
    fi
    echo "  timeout"; killall openvpn 2>/dev/null; udp2raw-ctl stop; IDX=$((IDX+1)); sleep 2
done < /tmp/vpn_srvlist

# Retry from 0 if skipped
if [ "$OK" != "1" ] && [ "$SKIP" -ge 0 ]; then
    echo "Retry from 0"; echo "-1" > /tmp/vpn_skip; exec fl-vpn-start
fi
[ "$OK" != "1" ] && { nvram set udp2raw_status="ALL FAILED"; echo "FATAL: all failed"; }
VPNEOF
chmod +x "$UDP2RAW_DIR/files/fl-vpn-start"

############################################################
# 4. fl-vpn-stop
############################################################
cat > "$UDP2RAW_DIR/files/fl-vpn-stop" << 'STOPEOF'
#!/bin/sh
killall openvpn 2>/dev/null; sleep 1
for t in tun0 tun1 tun2; do
    iptables -t nat -D POSTROUTING -o "$t" -j MASQUERADE 2>/dev/null
    iptables -t mangle -D FORWARD -o "$t" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 900 2>/dev/null
    iptables -t mangle -D FORWARD -i "$t" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 900 2>/dev/null
    iptables -D FORWARD -i br0 -o "$t" -j ACCEPT 2>/dev/null
    iptables -D FORWARD -i "$t" -o br0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
done
[ -f /tmp/udp2raw_srv ] && { . /tmp/udp2raw_srv; ip route del "$SRV/32" 2>/dev/null; }
udp2raw-ctl stop 2>/dev/null
rm -f /tmp/dnsmasq.servers; killall -HUP dnsmasq 2>/dev/null
nvram set udp2raw_status="DISCONNECTED"
nvram set udp2raw_active=""
nvram set udp2raw_vpnip=""
STOPEOF
chmod +x "$UDP2RAW_DIR/files/fl-vpn-stop"

############################################################
# 5. fl-vpn-switch
############################################################
cat > "$UDP2RAW_DIR/files/fl-vpn-switch" << 'SWEOF'
#!/bin/sh
C=$(cat /tmp/vpn_idx 2>/dev/null||echo 0)
echo "$C" > /tmp/vpn_skip
fl-vpn-stop; sleep 2; fl-vpn-start &
SWEOF
chmod +x "$UDP2RAW_DIR/files/fl-vpn-switch"

############################################################
# 6. fl-vpn-watchdog — checks nvram enable flag
############################################################
cat > "$UDP2RAW_DIR/files/fl-vpn-watchdog" << 'WDEOF'
#!/bin/sh
LOG="/tmp/fl-vpn-wd.log"
[ -f "$LOG" ] && [ $(wc -c < "$LOG") -gt 20000 ] && tail -30 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"

EN=$(nvram get udp2raw_enable 2>/dev/null)

# If disabled, make sure everything is stopped
if [ "$EN" != "1" ]; then
    pidof udp2raw >/dev/null 2>&1 && { fl-vpn-stop; echo "$(date '+%H:%M') disabled, stopped" >> "$LOG"; }
    exit 0
fi

# Enabled — check health
TUN=""
for t in tun0 tun1 tun2; do
    ip link show "$t" 2>/dev/null|grep -q UP && { TUN="$t"; break; }
done

if [ -z "$TUN" ]; then
    echo "$(date '+%H:%M') no tun, starting" >> "$LOG"
    fl-vpn-start >> "$LOG" 2>&1 &
    exit 0
fi

ping -c 2 -W 5 -I "$TUN" 10.8.0.1 >/dev/null 2>&1 || {
    echo "$(date '+%H:%M') gw down, switching" >> "$LOG"
    fl-vpn-switch >> "$LOG" 2>&1 &
    exit 0
}

pidof udp2raw >/dev/null || {
    echo "$(date '+%H:%M') udp2raw dead" >> "$LOG"
    fl-vpn-start >> "$LOG" 2>&1 &
}
WDEOF
chmod +x "$UDP2RAW_DIR/files/fl-vpn-watchdog"

############################################################
# 7. fl-vpn-status
############################################################
cat > "$UDP2RAW_DIR/files/fl-vpn-status" << 'STEOF'
#!/bin/sh
echo "=== MILLENIUM VPN ==="
echo -n "Enable:  "; nvram get udp2raw_enable 2>/dev/null || echo "0"
echo -n "Status:  "; nvram get udp2raw_status 2>/dev/null || echo "?"
echo -n "Server:  "; nvram get udp2raw_active 2>/dev/null || echo "-"
echo -n "VPN IP:  "; nvram get udp2raw_vpnip 2>/dev/null || echo "-"
echo -n "udp2raw: "; pidof udp2raw >/dev/null && echo "ON ($(pidof udp2raw))" || echo "OFF"
echo -n "openvpn: "; pidof openvpn >/dev/null && echo "ON ($(pidof openvpn))" || echo "OFF"
STEOF
chmod +x "$UDP2RAW_DIR/files/fl-vpn-status"

echo ">>> udp2raw-tunnel package ready"

############################################################
# 8. custom-extras fix
############################################################
echo ">>> custom-extras ready"
CUSTOM_DIR="$TRUNK/user/custom-extras"
if [ -d "$CUSTOM_DIR" ]; then
    mkdir -p "$CUSTOM_DIR/files/etc/storage/wireguard"
    [ -f "$CUSTOM_DIR/Makefile" ] && ! grep -q "mkdir -p" "$CUSTOM_DIR/Makefile" && \
        sed -i '/ROMFSINST.*wireguard/i\\tmkdir -p $(ROOTDIR)/romfs/etc/storage/wireguard' "$CUSTOM_DIR/Makefile"
fi

############################################################
# 9. Patch user/Makefile
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
# 10. Makefile for udp2raw-tunnel
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
	$(ROMFSINST) -p +x files/fl-vpn-switch /usr/bin/fl-vpn-switch
	$(ROMFSINST) -p +x files/fl-vpn-watchdog /usr/bin/fl-vpn-watchdog
	$(ROMFSINST) -p +x files/fl-vpn-status /usr/bin/fl-vpn-status
	@echo "[udp2raw-tunnel] DONE"

clean:
	@echo "[udp2raw-tunnel] clean"
MKEOF

############################################################
# 11. ASP page — proper Padavan template
############################################################
echo ">>> WebUI setup..."
echo "  www: $WWW"

# Remove old broken files
rm -f "$WWW/Advanced_udp2raw.asp"
rm -rf "$WWW/cgi-bin"

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
$j(document).ready(function() {
    init_itoggle('udp2raw_enable', change_udp2raw_enabled);
});
</script>

<script>
<% login_state_hook(); %>

var udp2raw_status = '<% nvram_get_x("", "udp2raw_status"); %>';
var udp2raw_active = '<% nvram_get_x("", "udp2raw_active"); %>';
var udp2raw_vpnip = '<% nvram_get_x("", "udp2raw_vpnip"); %>';

function initial(){
    show_banner(0);
    show_menu(7, -1, 0);
    show_footer();
    change_udp2raw_enabled();
    load_servers();
    update_status();
    load_body();
    // Ensure loading overlay is hidden (fixes desktop click issue)
    var ld = document.getElementById('Loading');
    if(ld) ld.style.display = 'none';
    // Self-inject menu entry if not present
    inject_menu();
}

function inject_menu(){
    var sub = document.getElementById('subMenu');
    if(!sub) return;
    if(sub.innerHTML.indexOf('Advanced_udp2raw')>=0) return;
    // Find or create MILLENIUM VPN link in sidebar
    var items = sub.getElementsByTagName('a');
    var found = false;
    for(var i=0; i<items.length; i++){
        if(items[i].href && items[i].href.indexOf('Advanced_udp2raw')>=0){found=true;break;}
    }
    if(!found){
        var groups = sub.getElementsByClassName('accordion-group');
        if(groups.length > 0){
            var last = groups[groups.length-1];
            var d = document.createElement('div');
            d.className='accordion-group';
            d.innerHTML='<div class="accordion-heading"><a class="accordion-toggle" style="padding:5px 15px;" href="/Advanced_udp2raw.asp"><b>MILLENIUM VPN</b></a></div>';
            last.parentNode.insertBefore(d, last.nextSibling);
        }
    }
}

function update_status(){
    var s = udp2raw_status || 'DISCONNECTED';
    var el = document.getElementById('vpn_status');
    if (!el) return;
    if (s == 'CONNECTED') {
        el.innerHTML = '<span class="label label-success">\u25CF \u041F\u043E\u0434\u043A\u043B\u044E\u0447\u0435\u043D\u043E</span>';
        var info = '';
        if (udp2raw_active) info += '\u0421\u0435\u0440\u0432\u0435\u0440: ' + udp2raw_active;
        if (udp2raw_vpnip) info += ' &nbsp; VPN IP: ' + udp2raw_vpnip;
        document.getElementById('vpn_info').innerHTML = info;
    } else if (s == 'CONNECTING...') {
        el.innerHTML = '<span class="label label-warning">\u25CF \u041F\u043E\u0434\u043A\u043B\u044E\u0447\u0435\u043D\u0438\u0435...</span>';
        document.getElementById('vpn_info').innerHTML = '';
    } else {
        el.innerHTML = '<span class="label label-important">\u25CB \u041E\u0442\u043A\u043B\u044E\u0447\u0435\u043D\u043E</span>';
        document.getElementById('vpn_info').innerHTML = s != 'DISCONNECTED' ? s : '';
    }
}

function change_udp2raw_enabled(){
    var v = document.form.udp2raw_enable[0].checked;
    showhide_div('tbl_udp2raw_cfg', v);
}

function load_servers(){
    var s = document.form.udp2raw_servers_hidden.value || '';
    document.getElementById('udp2raw_servers_text').value = s.replace(/>/g, '\n');
}

function applyRule(){
    // Convert textarea newlines to > for nvram
    var ta = document.getElementById('udp2raw_servers_text');
    var val = ta.value.replace(/\r\n/g, '\n').replace(/\n+/g, '\n').replace(/^\n|\n$/g, '');
    document.form.udp2raw_servers.value = val.replace(/\n/g, '>');

    showLoading();
    document.form.action_mode.value = " Apply ";
    document.form.current_page.value = "/Advanced_udp2raw.asp";
    document.form.next_page.value = "";
    document.form.submit();
}

function done_validating(action){
}
</script>

<style>
.srv-help { color: #888; font-size: 11px; margin-top: 4px; }
.status-box { background: #f5f5f5; border-radius: 4px; padding: 10px 15px; margin: 10px; }
</style>

</head>

<body onload="initial();" onunload="unload_body();">

<div class="wrapper">
    <div class="container-fluid" style="padding-right: 0px">
        <div class="row-fluid">
            <div class="span3"><center><div id="logo"></div></center></div>
            <div class="span9"><div id="TopBanner"></div></div>
        </div>
    </div>
    <br>
    <div id="Loading" class="popup_bg"></div>
    <iframe name="hidden_frame" id="hidden_frame" src="" width="0" height="0" frameborder="0" style="position: absolute;"></iframe>

    <form method="post" name="form" id="ruleForm" action="/start_apply.htm" target="hidden_frame">
    <input type="hidden" name="current_page" value="Advanced_udp2raw.asp">
    <input type="hidden" name="next_page" value="">
    <input type="hidden" name="next_host" value="">
    <input type="hidden" name="sid_list" value="LANHostConfig;">
    <input type="hidden" name="group_id" value="">
    <input type="hidden" name="action_mode" value="">
    <input type="hidden" name="action_script" value="">
    <input type="hidden" name="flag" value="">
    <input type="hidden" name="udp2raw_servers" value="">
    <input type="hidden" name="udp2raw_servers_hidden" value="<% nvram_get_x("", "udp2raw_servers"); %>">

    <div class="container-fluid">
        <div class="row-fluid">
            <div class="span3">
                <div class="well sidebar-nav side_nav" style="padding: 0px;">
                    <ul id="mainMenu" class="clearfix"></ul>
                    <ul class="clearfix">
                        <li><div id="subMenu" class="accordion"></div></li>
                    </ul>
                </div>
            </div>

            <div class="span9">
                <div class="box well grad_colour_dark_blue">
                    <div id="tabMenu"></div>
                    <h2 class="box_head round_top">MILLENIUM VPN &mdash; udp2raw FakeTCP</h2>

                    <div class="round_bottom">

                        <div class="alert alert-info" style="margin: 10px;">
                            OpenVPN через FakeTCP туннель для обхода DPI.
                            UDP трафик упаковывается в TCP-подобные пакеты,
                            невидимые для глубокой инспекции.
                        </div>

                        <!-- Status -->
                        <div class="status-box">
                            <span id="vpn_status"></span>
                            &nbsp; <span id="vpn_info" style="color:#555;"></span>
                        </div>

                        <!-- Enable toggle -->
                        <table class="table">
                            <tr>
                                <th width="50%" style="padding-bottom: 0px; border-top: 0 none;">Включить MILLENIUM VPN</th>
                                <td style="padding-bottom: 0px; border-top: 0 none;">
                                    <div class="main_itoggle">
                                        <div id="udp2raw_enable_on_of">
                                            <input type="checkbox" id="udp2raw_enable_fake"
                                                <% nvram_match_x("", "udp2raw_enable", "1", "value=1 checked"); %>
                                                <% nvram_match_x("", "udp2raw_enable", "0", "value=0"); %>>
                                        </div>
                                    </div>
                                    <div style="position: absolute; margin-left: -10000px;">
                                        <input type="radio" name="udp2raw_enable" id="udp2raw_enable_1" class="input" value="1" onclick="change_udp2raw_enabled();"
                                            <% nvram_match_x("", "udp2raw_enable", "1", "checked"); %>>Да
                                        <input type="radio" name="udp2raw_enable" id="udp2raw_enable_0" class="input" value="0" onclick="change_udp2raw_enabled();"
                                            <% nvram_match_x("", "udp2raw_enable", "0", "checked"); %>>Нет
                                    </div>
                                </td>
                            </tr>
                        </table>

                        <!-- Configuration -->
                        <table class="table" id="tbl_udp2raw_cfg" style="display:none">
                            <tr>
                                <th colspan="2" style="background-color: #E3E3E3;">Список серверов</th>
                            </tr>
                            <tr>
                                <td colspan="2">
                                    <textarea id="udp2raw_servers_text" rows="5" wrap="off" spellcheck="false"
                                        class="span12" style="font-family:'Courier New'; font-size:12px;"
                                        placeholder="IP:PORT:PASSWORD&#10;89.39.70.224:4096:millenium2026&#10;185.x.x.x:4096:millenium2026"></textarea>
                                    <div class="srv-help">
                                        Формат: IP:PORT:PASSWORD &mdash; один сервер на строку.
                                        При отказе первого &mdash; автоматически переключается на следующий.
                                    </div>
                                </td>
                            </tr>
                        </table>

                        <!-- Apply -->
                        <table class="table">
                            <tr>
                                <td style="border: 0 none; padding: 0px;">
                                    <center>
                                        <input name="button" type="button" class="btn btn-primary" style="width: 219px"
                                            onclick="applyRule();" value="Сохранить"/>
                                    </center>
                                </td>
                            </tr>
                        </table>

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
echo "  Created Advanced_udp2raw.asp v3 (proper Padavan template)"

############################################################
# 12. Patch state.js for menu item
############################################################
echo ">>> Patching state.js menu..."
STATEJS="$WWW/state.js"
POPUPJS="$WWW/popup.js"

if [ -f "$STATEJS" ] && ! grep -q "Advanced_udp2raw" "$STATEJS"; then
    # === DIAGNOSTIC: dump menu structure ===
    echo "  --- state.js: lines with .asp in arrays ---"
    grep -n 'Advanced_Wireless_Content\|Advanced_LAN\|menuL2_title\|menuL2_link' "$STATEJS" | head -15
    echo "  --- state.js: lines with 'new Array.*\.asp' ---"
    grep -n 'new Array.*\.asp' "$STATEJS" | head -10
    echo "  --- state.js: lines 410-430 ---"
    sed -n '410,430p' "$STATEJS"
    echo "  --- state.js: lines with menuL2 ---"
    grep -n 'menuL2' "$STATEJS" | head -20
    echo "  ==="

    INSERTED=0

    # METHOD 1: Static menuL2_link array (padavan-ng style)
    # Look for: menuL2_link = new Array("", "Advanced_Wireless_Content.asp", ...);
    if grep -q 'menuL2_link.*new Array' "$STATEJS"; then
        echo "  Found menuL2_link static array"
        # Add our page to the end of the array
        sed -i 's|\(menuL2_link = new Array([^)]*\))|\1.concat(["Advanced_udp2raw.asp"])|' "$STATEJS"
        sed -i 's|\(menuL2_title = new Array([^)]*\))|\1.concat(["MILLENIUM VPN"])|' "$STATEJS"
        INSERTED=1
        echo "  OK: appended to static menuL2 arrays via concat"

    # METHOD 2: Dynamic menuL2_num++ style (classic padavan)
    elif grep -q 'menuL2_num' "$STATEJS"; then
        echo "  Found menuL2_num dynamic style"
        LAST=$(grep -n 'menuL2_num' "$STATEJS" | tail -1 | cut -d: -f1)
        sed -i "${LAST}a\\
    menuL2_title[menuL2_num] = \"MILLENIUM VPN\";\\
    menuL2_link[menuL2_num] = \"Advanced_udp2raw.asp\";\\
    menuL2_num++;" "$STATEJS"
        INSERTED=1
        echo "  OK: added via menuL2_num++ (line $LAST)"

    # METHOD 3: Look for menuL2_link as plain array assignment
    elif grep -q 'menuL2_link\[' "$STATEJS"; then
        echo "  Found menuL2_link[N] indexed style"
        LAST_IDX=$(grep -o 'menuL2_link\[[0-9]*\]' "$STATEJS" | tail -1 | grep -o '[0-9]*')
        LAST_LINE=$(grep -n "menuL2_link\[$LAST_IDX\]" "$STATEJS" | tail -1 | cut -d: -f1)
        NEXT_IDX=$((LAST_IDX + 1))
        sed -i "${LAST_LINE}a\\
menuL2_title[$NEXT_IDX] = \"MILLENIUM VPN\";\\
menuL2_link[$NEXT_IDX] = \"Advanced_udp2raw.asp\";" "$STATEJS"
        INSERTED=1
        echo "  OK: added as menuL2[${NEXT_IDX}] after line $LAST_LINE"
    fi

    # METHOD 4: Fallback - patch popup.js to inject menu entry
    if [ "$INSERTED" = "0" ] && [ -f "$POPUPJS" ]; then
        echo "  No standard menuL2 found. Trying popup.js..."
        echo "  --- popup.js: menu generation patterns ---"
        grep -n 'subMenu\|menuL2\|sidebar\|mainMenu\|Advanced_' "$POPUPJS" | head -15
        echo "  ==="

        # Try appending menu entry via JavaScript injection at end of build_menu function
        if grep -q 'Advanced_Personalization' "$POPUPJS"; then
            LINE=$(grep -n 'Advanced_Personalization' "$POPUPJS" | tail -1 | cut -d: -f1)
            sed -i "${LINE}a\\
// MILLENIUM VPN menu entry\\
if(typeof(menuL2_title)!='undefined'){menuL2_title.push('MILLENIUM VPN');menuL2_link.push('Advanced_udp2raw.asp');}" "$POPUPJS"
            INSERTED=1
            echo "  OK: injected into popup.js after Personalization (line $LINE)"
        fi
    fi

    # METHOD 5: Ultimate fallback - inject via our ASP page itself
    if [ "$INSERTED" = "0" ]; then
        echo "  WARNING: Could not add menu item via state.js or popup.js"
        echo "  Page accessible at: /Advanced_udp2raw.asp"
        echo "  Will add self-injection in ASP page"
    fi

    # Verify
    grep -n "udp2raw\|MILLENIUM" "$STATEJS" "$POPUPJS" 2>/dev/null | head -5
else
    [ -f "$STATEJS" ] && echo "  ALREADY PATCHED" || echo "  WARN: state.js not found"
fi

############################################################
# 13. nvram defaults
############################################################
echo ">>> nvram defaults..."
DEFAULTS_H="$TRUNK/user/shared/defaults.h"

if [ -f "$DEFAULTS_H" ] && ! grep -q "udp2raw_enable" "$DEFAULTS_H"; then
    # Diagnostic: show file structure
    echo "  --- defaults.h: last 10 lines ---"
    tail -10 "$DEFAULTS_H"
    echo "  --- defaults.h: terminator patterns ---"
    grep -n '0.*0\|NULL\|{.*}' "$DEFAULTS_H" | tail -5
    echo "  --- defaults.h: last 3 entries ---"
    grep -n '".*".*".*"' "$DEFAULTS_H" | tail -3
    echo "  ==="

    INSERTED=0

    # Method 1: { 0, 0 }  
    if grep -q '{ 0, 0 }' "$DEFAULTS_H"; then
        sed -i '/{ 0, 0 }/i\\t{ "udp2raw_enable", "0" },\n\t{ "udp2raw_servers", "" },\n\t{ "udp2raw_status", "" },\n\t{ "udp2raw_active", "" },\n\t{ "udp2raw_vpnip", "" },' "$DEFAULTS_H"
        INSERTED=1; echo "  defaults.h: inserted before { 0, 0 }"

    # Method 2: {0, 0}
    elif grep -q '{0, 0}' "$DEFAULTS_H"; then
        sed -i '/{0, 0}/i\\t{ "udp2raw_enable", "0" },\n\t{ "udp2raw_servers", "" },\n\t{ "udp2raw_status", "" },\n\t{ "udp2raw_active", "" },\n\t{ "udp2raw_vpnip", "" },' "$DEFAULTS_H"
        INSERTED=1; echo "  defaults.h: inserted before {0, 0}"

    # Method 3: { NULL, NULL }
    elif grep -q 'NULL.*NULL' "$DEFAULTS_H"; then
        TERM_LINE=$(grep -n 'NULL.*NULL' "$DEFAULTS_H" | tail -1 | cut -d: -f1)
        sed -i "${TERM_LINE}i\\\\t{ \"udp2raw_enable\", \"0\" },\\n\\t{ \"udp2raw_servers\", \"\" },\\n\\t{ \"udp2raw_status\", \"\" },\\n\\t{ \"udp2raw_active\", \"\" },\\n\\t{ \"udp2raw_vpnip\", \"\" }," "$DEFAULTS_H"
        INSERTED=1; echo "  defaults.h: inserted before NULL,NULL (line $TERM_LINE)"

    # Method 4: Find last line with {"...", "..."} and insert after
    else
        LAST_ENTRY=$(grep -n '"[^"]*".*"[^"]*"' "$DEFAULTS_H" | tail -1 | cut -d: -f1)
        if [ -n "$LAST_ENTRY" ]; then
            sed -i "${LAST_ENTRY}a\\\\t{ \"udp2raw_enable\", \"0\" },\\n\\t{ \"udp2raw_servers\", \"\" },\\n\\t{ \"udp2raw_status\", \"\" },\\n\\t{ \"udp2raw_active\", \"\" },\\n\\t{ \"udp2raw_vpnip\", \"\" }," "$DEFAULTS_H"
            INSERTED=1; echo "  defaults.h: appended after last entry (line $LAST_ENTRY)"
        fi
    fi

    if [ "$INSERTED" = "0" ]; then
        echo "  SKIP: cannot find insertion point in defaults.h"
        echo "  nvram will be initialized at runtime via scripts"
    else
        grep -n "udp2raw" "$DEFAULTS_H" | head -5
    fi
elif [ -f "$DEFAULTS_H" ]; then
    echo "  defaults.h: already has udp2raw entries"
else
    echo "  SKIP: defaults.h not found"
fi

############################################################
# 14. Branding
############################################################
echo ">>> Branding..."

############################################################
echo "============================================"
echo "  MILLENIUM Group VPN — build ready v3.0"
echo "  - udp2raw 20230206.0 (mipsel)"
echo "  - WebUI: Advanced_udp2raw.asp v3 (Padavan native)"
echo "  - udp2raw-ctl + RST fix"
echo "  - fl-vpn-start (multi-server failover)"
echo "  - fl-vpn-stop / fl-vpn-switch"
echo "  - fl-vpn-watchdog (cron, nvram-aware)"
echo "  - fl-vpn-status"
echo "============================================"

echo "=== DIAGNOSTICS ==="
echo "--- udp2raw files ---"
ls -la "$UDP2RAW_DIR/files/"
echo "--- udp2raw Makefile ---"
cat "$UDP2RAW_DIR/Makefile"
echo "--- user/Makefile grep ---"
grep "udp2raw-tunnel" "$TRUNK/user/Makefile" || echo "(not found)"
echo "--- www ---"
ls "$WWW/Advanced_udp2raw.asp" 2>/dev/null || echo "(missing)"
echo "=== END ==="
