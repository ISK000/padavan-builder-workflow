#!/bin/bash
############################################################
# MILLENIUM Group — Padavan-NG pre-build v3.1
#
# Простая схема:
#   VPN клиент (Padavan) → OpenVPN remote 127.0.0.1 3333
#   MILLENIUM VPN → udp2raw серверы (домены, failover)
#
# Мы управляем ТОЛЬКО udp2raw. OpenVPN — стандартный Padavan.
############################################################
set -euo pipefail

TRUNK="padavan-ng/trunk"
UDP2RAW_DIR="$TRUNK/user/udp2raw-tunnel"
WWW="$TRUNK/user/www/n56u_ribbon_fixed"

echo "============================================"
echo "  MILLENIUM Group VPN — pre-build v3.1"
echo "============================================"

############################################################
# 1. udp2raw binary
############################################################
echo ">>> Setting up udp2raw-tunnel"
mkdir -p "$UDP2RAW_DIR/files"

curl -sL -o /tmp/udp2raw_binaries.tar.gz \
  https://github.com/wangyu-/udp2raw/releases/download/20230206.0/udp2raw_binaries.tar.gz
cd /tmp && tar xzf udp2raw_binaries.tar.gz && ls udp2raw_*
cp udp2raw_mips24kc_le "$OLDPWD/$UDP2RAW_DIR/files/udp2raw"
chmod +x "$OLDPWD/$UDP2RAW_DIR/files/udp2raw"
cd "$OLDPWD"
echo ">>> Binary: $(ls -la $UDP2RAW_DIR/files/udp2raw)"

############################################################
# 2. udp2raw-ctl (start/stop udp2raw binary)
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
# 3. fl-vpn-start — only udp2raw, with domain resolution
#    OpenVPN is managed by standard Padavan VPN client
############################################################
cat > "$UDP2RAW_DIR/files/fl-vpn-start" << 'VPNEOF'
#!/bin/sh
LOG="/tmp/fl-vpn.log"
exec > "$LOG" 2>&1
echo "=== fl-vpn-start $(date) ==="

SERVERS=$(nvram get udp2raw_servers 2>/dev/null)
[ -z "$SERVERS" ] && { echo "No servers"; nvram set udp2raw_status="NO CONFIG"; exit 1; }

fl-vpn-stop 2>/dev/null; sleep 1
nvram set udp2raw_status="CONNECTING..."

SKIP=$(cat /tmp/vpn_skip 2>/dev/null || echo "-1")
OK=0
echo "$SERVERS" | tr '>' '\n' > /tmp/vpn_srvlist

# DNS resolver
resolve_host() {
    local H="$1"
    echo "$H" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' && { echo "$H"; return; }
    local IP=$(nslookup "$H" 2>/dev/null | awk '/^Address/{if(NR>2)print $NF}' | head -1)
    echo "$IP" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' && { echo "$IP"; return; }
    IP=$(ping -c1 -W3 "$H" 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    [ -n "$IP" ] && echo "$IP"
}

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

    SIP=$(resolve_host "$S")
    if [ -z "$SIP" ]; then
        echo "  DNS fail: $S"; IDX=$((IDX+1)); continue
    fi
    [ "$SIP" != "$S" ] && echo "  resolved: $S -> $SIP"

    ping -c2 -W4 "$SIP" >/dev/null 2>&1 || { echo "  unreachable: $SIP"; IDX=$((IDX+1)); continue; }

    # Write server info for udp2raw-ctl
    echo "SRV=$SIP" > /tmp/udp2raw_srv
    echo "PRT=$P" >> /tmp/udp2raw_srv
    echo "KEY=$K" >> /tmp/udp2raw_srv

    # Start udp2raw
    udp2raw-ctl start || { IDX=$((IDX+1)); continue; }

    # Route server IP via WAN (so it doesn't loop through VPN)
    WG=$(ip route|grep default|awk '{print $3}'|head -1)
    WI=$(ip route|grep default|awk '{print $5}'|head -1)
    [ -n "$WG" ] && { ip route del "$SIP/32" 2>/dev/null; ip route add "$SIP/32" via "$WG" dev "$WI"; }

    echo "  udp2raw OK -> $S ($SIP):$P"
    echo "$IDX" > /tmp/vpn_idx

    nvram set udp2raw_status="CONNECTED"
    nvram set udp2raw_active="$S:$P"
    echo "=== DONE $(date) ==="
    OK=1; break

    IDX=$((IDX+1)); sleep 2
done < /tmp/vpn_srvlist

if [ "$OK" != "1" ] && [ "$SKIP" -ge 0 ]; then
    echo "Retry from 0"; echo "-1" > /tmp/vpn_skip; exec fl-vpn-start
fi
[ "$OK" != "1" ] && { nvram set udp2raw_status="ALL FAILED"; echo "FATAL: all failed"; }
VPNEOF
chmod +x "$UDP2RAW_DIR/files/fl-vpn-start"

############################################################
# 4. fl-vpn-stop — only udp2raw
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
# 5. fl-vpn-switch — next server
############################################################
cat > "$UDP2RAW_DIR/files/fl-vpn-switch" << 'SWEOF'
#!/bin/sh
C=$(cat /tmp/vpn_idx 2>/dev/null||echo 0)
echo "$C" > /tmp/vpn_skip
fl-vpn-stop; sleep 1; fl-vpn-start &
SWEOF
chmod +x "$UDP2RAW_DIR/files/fl-vpn-switch"

############################################################
# 6. fl-vpn-watchdog — cron, health check
############################################################
cat > "$UDP2RAW_DIR/files/fl-vpn-watchdog" << 'WDEOF'
#!/bin/sh
LOG="/tmp/fl-vpn-wd.log"
[ -f "$LOG" ] && [ $(wc -c < "$LOG") -gt 20000 ] && tail -30 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"

# Self-install cron
cru l 2>/dev/null | grep -q "fl-vpn-watchdog" || {
    cru a fl_vpn_wd "*/1 * * * * /usr/bin/fl-vpn-watchdog"
    echo "$(date '+%H:%M') cron installed" >> "$LOG"
}

EN=$(nvram get udp2raw_enable 2>/dev/null)

if [ "$EN" != "1" ]; then
    pidof udp2raw >/dev/null 2>&1 && { fl-vpn-stop; echo "$(date '+%H:%M') disabled, stopped" >> "$LOG"; }
    exit 0
fi

# Is udp2raw running?
if ! pidof udp2raw >/dev/null 2>&1; then
    echo "$(date '+%H:%M') udp2raw dead, starting" >> "$LOG"
    fl-vpn-start >> "$LOG" 2>&1 &
    exit 0
fi

# Is VPN tunnel alive? (OpenVPN managed by Padavan)
TUN=""
for t in tun0 tun1 tun2; do
    ip link show "$t" 2>/dev/null|grep -q UP && { TUN="$t"; break; }
done

if [ -n "$TUN" ]; then
    # Tunnel exists — ping gateway
    GW=$(ip route show dev "$TUN" 2>/dev/null | awk '/via/{print $3}' | head -1)
    [ -z "$GW" ] && GW="10.8.0.1"
    ping -c2 -W5 -I "$TUN" "$GW" >/dev/null 2>&1 || {
        echo "$(date '+%H:%M') gw unreachable ($GW), switching server" >> "$LOG"
        fl-vpn-switch >> "$LOG" 2>&1 &
    }
fi
# If no TUN — OpenVPN is still connecting, that's normal. Wait.
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
echo -n "udp2raw: "; pidof udp2raw >/dev/null && echo "ON ($(pidof udp2raw))" || echo "OFF"
echo -n "openvpn: "; pidof openvpn >/dev/null && echo "ON ($(pidof openvpn))" || echo "OFF"
for t in tun0 tun1 tun2; do
    ip link show "$t" 2>/dev/null|grep -q UP && {
        VIP=$(ip -4 addr show "$t"|awk '/inet /{print $2}'|cut -d/ -f1)
        echo "tunnel:  $t $VIP"
        break
    }
done
STEOF
chmod +x "$UDP2RAW_DIR/files/fl-vpn-status"

echo ">>> Scripts ready"

############################################################
# 8. custom-extras fix
############################################################
echo ">>> custom-extras"
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
# 11. Status AJAX endpoint
############################################################
echo ">>> WebUI setup..."
echo "  www: $WWW"

cat > "$WWW/millenium_status.asp" << 'STATUSEOF'
<% nvram_get_x("", "udp2raw_status"); %>|<% nvram_get_x("", "udp2raw_active"); %>
STATUSEOF

############################################################
# 12. ASP page — simple: servers + enable + status
############################################################
rm -f "$WWW/Advanced_udp2raw.asp"

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
$j(document).ready(function(){
    init_itoggle('udp2raw_enable', change_enabled);
});
</script>

<script>
<% login_state_hook(); %>

var m_status = '<% nvram_get_x("", "udp2raw_status"); %>';
var m_active = '<% nvram_get_x("", "udp2raw_active"); %>';

function initial(){
    show_banner(0);
    show_menu(7, -1, 0);
    show_footer();
    change_enabled();
    load_servers();
    update_status();
    load_body();
    var ld = document.getElementById('Loading');
    if(ld) ld.style.display = 'none';
    inject_menu();
    setInterval(poll_status, 5000);
}

function poll_status(){
    $j.get('/millenium_status.asp?t='+Date.now(), function(d){
        var p = d.split('|');
        if(p.length >= 2){
            m_status = p[0].trim();
            m_active = p[1].trim();
            update_status();
        }
    });
}

function inject_menu(){
    var sub = document.getElementById('subMenu');
    if(!sub) return;
    if(sub.innerHTML.indexOf('Advanced_udp2raw')>=0) return;
    var groups = sub.getElementsByClassName('accordion-group');
    if(groups.length > 0){
        var last = groups[groups.length-1];
        var d = document.createElement('div');
        d.className='accordion-group';
        d.innerHTML='<div class="accordion-heading"><a class="accordion-toggle" style="padding:5px 15px;" href="/Advanced_udp2raw.asp"><b>MILLENIUM VPN</b></a></div>';
        last.parentNode.insertBefore(d, last.nextSibling);
    }
}

function update_status(){
    var s = m_status || 'DISCONNECTED';
    var el = document.getElementById('vpn_status');
    var info = document.getElementById('vpn_info');
    if(!el) return;
    if(s == 'CONNECTED'){
        el.innerHTML = '<span class="label label-success" style="font-size:14px;padding:5px 12px;">\u25CF \u041f\u043e\u0434\u043a\u043b\u044e\u0447\u0435\u043d\u043e</span>';
        info.innerHTML = m_active ? '\u0421\u0435\u0440\u0432\u0435\u0440: <b>'+m_active+'</b>' : '';
    } else if(s == 'CONNECTING...'){
        el.innerHTML = '<span class="label label-warning" style="font-size:14px;padding:5px 12px;">\u25CF \u041f\u043e\u0434\u043a\u043b\u044e\u0447\u0435\u043d\u0438\u0435...</span>';
        info.innerHTML = '<i>\u041f\u0435\u0440\u0435\u0431\u043e\u0440 \u0441\u0435\u0440\u0432\u0435\u0440\u043e\u0432...</i>';
    } else {
        el.innerHTML = '<span class="label label-important" style="font-size:14px;padding:5px 12px;">\u25cb \u041e\u0442\u043a\u043b\u044e\u0447\u0435\u043d\u043e</span>';
        info.innerHTML = (s != 'DISCONNECTED' && s) ? '<span style="color:#c00">'+s+'</span>' : '';
    }
}

function change_enabled(){
    var v = document.form.udp2raw_enable[0].checked;
    showhide_div('cfg_main', v);
}

function load_servers(){
    var s = document.form.udp2raw_servers_h.value || '';
    document.getElementById('srv_text').value = s.replace(/>/g, '\n');
}

function applyRule(){
    var sv = document.getElementById('srv_text').value;
    sv = sv.replace(/\r\n/g,'\n').replace(/\n+/g,'\n').replace(/^\n|\n$/g,'');
    document.form.udp2raw_servers.value = sv.replace(/\n/g, '>');

    showLoading();
    document.form.action_mode.value = " Apply ";
    document.form.current_page.value = "/Advanced_udp2raw.asp";
    document.form.next_page.value = "";
    document.form.submit();
}

function done_validating(action){}
</script>

<style>
.help-text { color:#888; font-size:11px; margin-top:3px; }
.status-box { background:#f5f5f5; border-radius:6px; padding:12px 16px; margin:10px; }
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
    <iframe name="hidden_frame" id="hidden_frame" src="" width="0" height="0" frameborder="0" style="position:absolute;"></iframe>

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
    <input type="hidden" name="udp2raw_servers_h" value="<% nvram_get_x("", "udp2raw_servers"); %>">

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

                        <div class="alert alert-info" style="margin:10px;">
                            udp2raw &#x442;&#x443;&#x43d;&#x43d;&#x435;&#x43b;&#x44c; &#x434;&#x43b;&#x44f; &#x43e;&#x431;&#x445;&#x43e;&#x434;&#x430; DPI.
                            OpenVPN &#x43d;&#x430;&#x441;&#x442;&#x440;&#x430;&#x438;&#x432;&#x430;&#x435;&#x442;&#x441;&#x44f; &#x432;
                            <a href="/vpncli.asp"><b>VPN &#x43a;&#x43b;&#x438;&#x435;&#x43d;&#x442;</b></a>
                            &#x441; remote 127.0.0.1 3333.
                        </div>

                        <!-- STATUS -->
                        <div class="status-box">
                            <span id="vpn_status"></span>
                            <span id="vpn_info" style="color:#555; margin-left:10px;"></span>
                        </div>

                        <!-- ENABLE -->
                        <table class="table">
                            <tr>
                                <th width="50%" style="border-top:0 none;">&#x412;&#x43a;&#x43b;&#x44e;&#x447;&#x438;&#x442;&#x44c; udp2raw</th>
                                <td style="border-top:0 none;">
                                    <div class="main_itoggle">
                                        <div id="udp2raw_enable_on_of">
                                            <input type="checkbox" id="udp2raw_enable_fake"
                                                <% nvram_match_x("", "udp2raw_enable", "1", "value=1 checked"); %>
                                                <% nvram_match_x("", "udp2raw_enable", "0", "value=0"); %>>
                                        </div>
                                    </div>
                                    <div style="position:absolute; margin-left:-10000px;">
                                        <input type="radio" name="udp2raw_enable" id="udp2raw_enable_1" class="input" value="1" onclick="change_enabled();"
                                            <% nvram_match_x("", "udp2raw_enable", "1", "checked"); %>>&#x414;&#x430;
                                        <input type="radio" name="udp2raw_enable" id="udp2raw_enable_0" class="input" value="0" onclick="change_enabled();"
                                            <% nvram_match_x("", "udp2raw_enable", "0", "checked"); %>>&#x41d;&#x435;&#x442;
                                    </div>
                                </td>
                            </tr>
                        </table>

                        <!-- SERVERS -->
                        <div id="cfg_main" style="display:none;">
                        <table class="table">
                            <tr><th colspan="2" style="background:#E3E3E3;">&#x421;&#x435;&#x440;&#x432;&#x435;&#x440;&#x44b; udp2raw</th></tr>
                            <tr>
                                <td colspan="2">
                                    <textarea id="srv_text" rows="6" wrap="off" spellcheck="false"
                                        class="span12" style="font-family:'Courier New'; font-size:12px;"
                                        placeholder="first.zapalashnikov.ru:4096:password&#10;sakura.domain.space:4096:password&#10;89.39.70.224:4096:password"></textarea>
                                    <div class="help-text">
                                        &#x424;&#x43e;&#x440;&#x43c;&#x430;&#x442;: &#x425;&#x41e;&#x421;&#x422;:&#x41f;&#x41e;&#x420;&#x422;:&#x41f;&#x410;&#x420;&#x41e;&#x41b;&#x42c; &mdash;
                                        &#x434;&#x43e;&#x43c;&#x435;&#x43d;&#x44b; &#x438;&#x43b;&#x438; IP, &#x43e;&#x434;&#x438;&#x43d; &#x43d;&#x430; &#x441;&#x442;&#x440;&#x43e;&#x43a;&#x443;.
                                        &#x41f;&#x440;&#x438; &#x431;&#x43b;&#x43e;&#x43a;&#x438;&#x440;&#x43e;&#x432;&#x43a;&#x435; &mdash; &#x43f;&#x435;&#x440;&#x435;&#x43a;&#x43b;&#x44e;&#x447;&#x430;&#x435;&#x442;&#x441;&#x44f; &#x43d;&#x430; &#x441;&#x43b;&#x435;&#x434;&#x443;&#x44e;&#x449;&#x438;&#x439; &#x430;&#x432;&#x442;&#x43e;&#x43c;&#x430;&#x442;&#x438;&#x447;&#x435;&#x441;&#x43a;&#x438;.
                                    </div>
                                </td>
                            </tr>
                        </table>
                        </div>

                        <!-- SAVE -->
                        <table class="table">
                            <tr>
                                <td style="border:0 none;">
                                    <center>
                                        <input type="button" class="btn btn-primary" style="width:219px"
                                            onclick="applyRule();" value="&#x421;&#x43e;&#x445;&#x440;&#x430;&#x43d;&#x438;&#x442;&#x44c;">
                                    </center>
                                    <div class="help-text" style="text-align:center; margin-top:8px;">
                                        udp2raw &#x43f;&#x43e;&#x434;&#x43a;&#x43b;&#x44e;&#x447;&#x438;&#x442;&#x441;&#x44f; &#x432; &#x442;&#x435;&#x447;&#x435;&#x43d;&#x438;&#x435; 1 &#x43c;&#x438;&#x43d;.
                                        &#x421;&#x442;&#x430;&#x442;&#x443;&#x441; &#x43e;&#x431;&#x43d;&#x43e;&#x432;&#x43b;&#x44f;&#x435;&#x442;&#x441;&#x44f; &#x43a;&#x430;&#x436;&#x434;&#x44b;&#x435; 5 &#x441;&#x435;&#x43a;.
                                    </div>
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
echo "  Created Advanced_udp2raw.asp v3.1"

############################################################
# 13. Patch state.js
############################################################
echo ">>> Patching state.js menu..."
STATEJS="$WWW/state.js"

if [ -f "$STATEJS" ] && ! grep -q "Advanced_udp2raw" "$STATEJS"; then
    ML2_LINE=$(grep -n 'menuL2_link.*new Array' "$STATEJS" | head -1 | cut -d: -f1)
    if [ -n "$ML2_LINE" ]; then
        sed -i "${ML2_LINE}a\\
menuL2_title.push(\"MILLENIUM VPN\");\\
menuL2_link.push(\"Advanced_udp2raw.asp\");" "$STATEJS"
        echo "  OK: push() after line $ML2_LINE"
    else
        echo "  WARN: menuL2_link not found"
    fi
    grep -n "MILLENIUM\|udp2raw" "$STATEJS" | head -3
else
    [ -f "$STATEJS" ] && echo "  ALREADY PATCHED" || echo "  WARN: state.js not found"
fi

############################################################
# 14. nvram defaults
############################################################
echo ">>> nvram defaults..."
FOUND_DEFAULTS=""
for F in "$TRUNK/user/shared/defaults.h" "$TRUNK/user/shared/defaults.c" \
         "$TRUNK/user/rc/defaults.c" "$TRUNK/user/httpd/variables.c" \
         "$TRUNK/user/shared/flash.c"; do
    if [ -f "$F" ] && grep -q 'router_defaults\|nvram_pair' "$F"; then
        echo "  Found router_defaults in: $F"
        FOUND_DEFAULTS="$F"
        break
    fi
done

if [ -n "$FOUND_DEFAULTS" ] && ! grep -q "udp2raw_enable" "$FOUND_DEFAULTS"; then
    if grep -q '{ 0, 0 }' "$FOUND_DEFAULTS"; then
        sed -i '/{ 0, 0 }/i\\t{ "udp2raw_enable", "0" },\n\t{ "udp2raw_servers", "" },\n\t{ "udp2raw_status", "" },\n\t{ "udp2raw_active", "" },' "$FOUND_DEFAULTS"
        echo "  Inserted 4 nvram defaults"
    elif grep -q '{0, 0}' "$FOUND_DEFAULTS"; then
        sed -i '/{0, 0}/i\\t{ "udp2raw_enable", "0" },\n\t{ "udp2raw_servers", "" },\n\t{ "udp2raw_status", "" },\n\t{ "udp2raw_active", "" },' "$FOUND_DEFAULTS"
        echo "  Inserted 4 nvram defaults"
    elif grep -q 'NULL.*NULL' "$FOUND_DEFAULTS"; then
        TERM=$(grep -n 'NULL.*NULL' "$FOUND_DEFAULTS" | tail -1 | cut -d: -f1)
        sed -i "${TERM}i\\\\t{ \"udp2raw_enable\", \"0\" },\\n\\t{ \"udp2raw_servers\", \"\" },\\n\\t{ \"udp2raw_status\", \"\" },\\n\\t{ \"udp2raw_active\", \"\" }," "$FOUND_DEFAULTS"
        echo "  Inserted 4 nvram defaults"
    else
        echo "  SKIP: no terminator"
    fi
    grep -n "udp2raw" "$FOUND_DEFAULTS" 2>/dev/null | head -3
else
    echo "  SKIP: not found or already patched"
fi

############################################################
echo "============================================"
echo "  MILLENIUM Group VPN — build ready v3.1"
echo "  - udp2raw + domain resolution + failover"
echo "  - OpenVPN = standard Padavan VPN client"
echo "  - WebUI: servers + enable + auto-status"
echo "  - Watchdog: cron, auto-failover"
echo "  - nvram: 4 vars only"
echo "============================================"

echo "=== DIAGNOSTICS ==="
ls -la "$UDP2RAW_DIR/files/"
ls "$WWW/Advanced_udp2raw.asp" "$WWW/millenium_status.asp" 2>/dev/null
echo "=== END ==="
