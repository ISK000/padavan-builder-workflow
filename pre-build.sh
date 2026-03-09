#!/usr/bin/env bash
############################################################
# MILLENIUM Group — Padavan-NG pre-build v15.0
#
# ROOT CAUSE FIXED IN v15.0:
#
#  httpd → notify_rc("restart_udp2raw") → rc демон
#  rc НЕ ЗНАЛ сервис "restart_udp2raw" → молча игнорировал.
#  nvram сохранялся, скрипт НЕ вызывался.
#
#  FIX: патч rc/rc.c — добавляем обработчик restart_udp2raw
#  рядом с restart_zapret (тот же паттерн).
#  ASP использует action_script="restart_udp2raw" (имя сервиса).
############################################################
set -euo pipefail

TRUNK="padavan-ng/trunk"
UDP2RAW_DIR="$TRUNK/user/udp2raw-tunnel"
WWW="$TRUNK/user/www/n56u_ribbon_fixed"
ROMFS_STORAGE="$TRUNK/romfs/etc/storage"
ROMFS_SBIN="$TRUNK/romfs/sbin"

echo "============================================"
echo "  MILLENIUM Group VPN — pre-build v15.0"
echo "  FIX: rc.c патч — restart_udp2raw как сервис"
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
# 4. Shell скрипты (udp2raw-ctl, fl-vpn-*)
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

cat > "$UDP2RAW_DIR/files/fl-vpn-stop" << 'STOPEOF'
#!/bin/sh
[ -f /tmp/udp2raw_srv ] && { . /tmp/udp2raw_srv; ip route del "$SRV/32" 2>/dev/null; }
udp2raw-ctl stop 2>/dev/null
nvram set udp2raw_status="DISCONNECTED"
nvram set udp2raw_active=""
STOPEOF
chmod +x "$UDP2RAW_DIR/files/fl-vpn-stop"

cat > "$UDP2RAW_DIR/files/fl-vpn-switch" << 'SWEOF'
#!/bin/sh
C=$(cat /tmp/vpn_idx 2>/dev/null || echo 0)
echo "$C" > /tmp/vpn_skip
fl-vpn-stop; sleep 1
fl-vpn-start &
SWEOF
chmod +x "$UDP2RAW_DIR/files/fl-vpn-switch"

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
# 5. restart_udp2raw — скрипт вызываемый rc демоном
############################################################
echo ">>> [5] restart_udp2raw (rc service script)"
mkdir -p "$ROMFS_SBIN"

cat > "$ROMFS_SBIN/restart_udp2raw" << 'RSTEOF'
#!/bin/sh
# Вызывается rc демоном через notify_rc("restart_udp2raw").
# httpd уже сохранил udp2raw_enable + udp2raw_servers в nvram.
# Этот скрипт просто читает nvram и запускает/останавливает.

LOG="/tmp/udp2raw_restart.log"
exec >> "$LOG" 2>&1
echo "=== restart_udp2raw $(date) ==="

EN=$(nvram get udp2raw_enable 2>/dev/null || echo 0)
SRVS=$(nvram get udp2raw_servers 2>/dev/null || echo "")

[ -z "$EN" ] && EN=0
echo "  EN=$EN SRVS=$SRVS"

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
cp "$ROMFS_SBIN/restart_udp2raw" "$UDP2RAW_DIR/files/restart_udp2raw"
chmod +x "$UDP2RAW_DIR/files/restart_udp2raw"
echo "  Created restart_udp2raw"

############################################################
# 6. WAN hook
############################################################
echo ">>> [6] WAN hook → romfs"
mkdir -p "$ROMFS_STORAGE"

WAN_HOOK="$ROMFS_STORAGE/started_wan_hook.sh"
if [ -f "$WAN_HOOK" ] && grep -q "fl-vpn-watchdog" "$WAN_HOOK"; then
    echo "  Already patched: $WAN_HOOK"
else
    cat > "$WAN_HOOK" << 'HOOKEOF'
#!/bin/sh
# MILLENIUM VPN v15.0 — udp2raw autostart at WAN up
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
    echo "  Created $WAN_HOOK"
fi
chmod +x "$WAN_HOOK"

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
# 9. Makefile для udp2raw-tunnel
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
	$(ROMFSINST) -p +x files/fl-vpn-status    /usr/bin/fl-vpn-status
	$(ROMFSINST) -p +x files/restart_udp2raw  /sbin/restart_udp2raw
	@echo "[udp2raw-tunnel] DONE"

clean:
	@echo "[udp2raw-tunnel] clean"
MKEOF

############################################################
# 10. ASP + status endpoint
############################################################
echo ">>> [9] WebUI ASP"
cat > "$WWW/millenium_status.asp" << 'EOF'
<% nvram_get_x("", "udp2raw_status"); %>|<% nvram_get_x("", "udp2raw_active"); %>
EOF

# v15.0 ASP — action_script="restart_udp2raw" (имя сервиса для rc)
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
    show_banner(0); show_menu(7,-1,0); show_footer();
    load_body(); load_servers(); syncToggle(); syncLogLevel();
    update_status();
    var ld = document.getElementById('Loading');
    if (ld) ld.style.display = 'none';
    inject_menu();
    setInterval(poll_status, 5000);
}

function poll_status(){
    $j.get('/millenium_status.asp?t=' + Date.now(), function(d){
        var p = d.split('|');
        if (p.length >= 2){ m_status = p[0].trim(); m_active = p[1].trim(); update_status(); }
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
        info.innerHTML = '<i>Перебор серверов...</i>';
    } else {
        el.innerHTML = '<span class="label label-important" style="font-size:14px;padding:5px 12px;">&#x25CB; Туннель выкл.</span>';
        info.innerHTML = (s && s != 'DISCONNECTED') ? '<span style="color:#c00">' + s + '</span>' : '';
    }
}

function syncToggle(){
    var val = document.getElementById('udp2raw_enable_val').value || '0';
    var sel = document.getElementById('udp2raw_enable_sel');
    if (sel) { sel.value = val; change_enabled(); }
}
function onEnableChange(val){ change_enabled(); }
function change_enabled(){
    var sel = document.getElementById('udp2raw_enable_sel');
    showhide_div('cfg_main', sel && sel.value === '1');
}
function load_servers(){
    var fld = document.getElementById('udp2raw_servers_stored');
    if (fld) document.getElementById('srv_text').value = fld.value.replace(/%/g, '\n');
}
function syncLogLevel(){
    var val = document.getElementById('udp2raw_loglevel_val').value || '0';
    var sel = document.getElementById('udp2raw_loglevel_sel');
    if (!sel) return;
    for (var i = 0; i < sel.options.length; i++)
        if (sel.options[i].value === val){ sel.selectedIndex = i; break; }
}

/* v15.0 FIX: action_script = "restart_udp2raw" (имя сервиса для rc демона).
 * httpd сохраняет nvram → notify_rc("restart_udp2raw") → rc вызывает /sbin/restart_udp2raw.
 * Штатный механизм Padavan, как restart_zapret, restart_tor и др. */
function applyRule(){
    var sv = document.getElementById('srv_text').value;
    sv = sv.replace(/\r\n/g, '\n').replace(/\n+/g, '\n').replace(/^\n|\n$/g, '');
    document.form.udp2raw_servers.value = sv.replace(/\n/g, '%');
    document.form.action_mode.value    = ' Apply ';
    document.form.current_page.value   = 'Advanced_udp2raw.asp';
    document.form.next_page.value      = 'Advanced_udp2raw.asp';
    document.form.action_script.value  = 'restart_udp2raw';

    var btn = document.getElementById('save_btn');
    if (btn) { btn.value = 'Сохранение...'; btn.disabled = true; }
    document.form.submit();
    setTimeout(function(){ window.location.href = '/Advanced_udp2raw.asp'; }, 4000);
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
<iframe name="hidden_frame" id="hidden_frame" src="" width="0" height="0" frameborder="0" style="position:absolute;"></iframe>

<form method="post" name="form" id="ruleForm" action="/start_apply.htm" target="hidden_frame">
<input type="hidden" name="current_page"  value="Advanced_udp2raw.asp">
<input type="hidden" name="next_page"     value="Advanced_udp2raw.asp">
<input type="hidden" name="next_host"     value="">
<input type="hidden" name="sid_list"      value="">
<input type="hidden" name="group_id"      value="">
<input type="hidden" name="action_mode"   value="">
<input type="hidden" name="action_script" value="restart_udp2raw">
<input type="hidden" name="flag"          value="">
<input type="hidden" id="udp2raw_enable_val" value="<% nvram_get_x("", "udp2raw_enable"); %>">
<input type="hidden" name="udp2raw_servers" id="udp2raw_servers_submit" value="">
<input type="hidden" id="udp2raw_servers_stored" value="<% nvram_get_x("", "udp2raw_servers"); %>">
<input type="hidden" name="udp2raw_loglevel" id="udp2raw_loglevel_val" value="<% nvram_get_x("", "udp2raw_loglevel"); %>">

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
          DPI видит обычный TCP. Туннель стартует автоматически при поднятии WAN.<br>
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
              <select name="udp2raw_enable" id="udp2raw_enable_sel" class="span3" onchange="onEnableChange(this.value);">
                <option value="0">OFF</option>
                <option value="1">ON</option>
              </select>
            </td>
          </tr>
        </table>

        <div id="cfg_main" style="display:none;">
        <table class="table">
          <tr><th colspan="2" style="background:#E3E3E3;">Список серверов</th></tr>
          <tr><td colspan="2">
              <textarea id="srv_text" rows="6" wrap="off" spellcheck="false" class="span12"
                style="font-family:'Courier New';font-size:12px;"
                placeholder="89.39.70.30:4096:millenium2026&#10;server2.example.com:4096:millenium2026"></textarea>
              <div class="help-text">Формат: ХОСТ:ПОРТ:ПАРОЛЬ, один на строку. Автоматический failover.</div>
          </td></tr>
          <tr>
            <th width="50%">Подробное логирование</th>
            <td>
              <select id="udp2raw_loglevel_sel" class="span4" onchange="document.getElementById('udp2raw_loglevel_val').value=this.value;">
                <option value="0">Отключено</option>
                <option value="3">Включено (уровень 3)</option>
                <option value="5">Максимальное (уровень 5)</option>
              </select>
              <div class="help-text">Логи в /tmp/udp2raw.log</div>
            </td>
          </tr>
        </table>
        </div>

        <table class="table"><tr>
            <td style="border:0 none;text-align:center;">
              <input type="button" id="save_btn" class="btn btn-primary" style="width:219px"
                onclick="applyRule();" value="Сохранить и применить">
              <div class="help-text" style="text-align:center;margin-top:8px;">
                Статус обновляется каждые 5 сек.</div>
            </td>
        </tr></table>

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
echo "  Created Advanced_udp2raw.asp v15.0"

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
# 12. nvram defaults (defaults.c)
############################################################
echo ">>> [11] nvram defaults"
patch_nvram_defaults() {
    local FILE="$1" LABEL="$2"
    [ -f "$FILE" ] || return
    grep -q "udp2raw_enable" "$FILE" && { echo "  Already patched ($LABEL)"; return; }
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
# 13. variables.c — httpd whitelist
############################################################
echo ">>> [12] variables.c"
HTTPD_VARS="$TRUNK/user/httpd/variables.c"
if [ ! -f "$HTTPD_VARS" ]; then
    echo "  WARN: variables.c not found"
else
    cat > /tmp/patch_udp2raw_vars.py << 'PATCHPY'
import re, sys
FILE = sys.argv[1]
NEW_VARS = ["udp2raw_enable", "udp2raw_servers", "udp2raw_status", "udp2raw_active", "udp2raw_loglevel"]
with open(FILE) as f:
    content = f.read()
if "udp2raw_enable" in content:
    print("  Already patched:", FILE); sys.exit(0)
print("  Patching:", FILE)
m = re.search(r'struct\s+variable\s+\w+\s*\[\s*\]\s*=\s*\{', content)
if not m:
    m = re.search(r'\bvariables\s*\[\s*\]\s*=\s*\{', content)
if not m:
    print("  ERROR: variables array not found"); sys.exit(1)
arr_open = m.end() - 1
depth = 0; arr_close = None
for i in range(arr_open, len(content)):
    if content[i] == '{': depth += 1
    elif content[i] == '}':
        depth -= 1
        if depth == 0: arr_close = i; break
if arr_close is None:
    print("  ERROR: closing brace not found"); sys.exit(1)
arr_body = content[arr_open+1:arr_close]
ENTRY_RE = re.compile(r'^([\t ]+)\{([^}]+)\}', re.MULTILINE)
entries = ENTRY_RE.findall(arr_body)
if not entries:
    print("  ERROR: no entries found"); sys.exit(1)
indent = entries[0][0]
new_entries = ""
for var in NEW_VARS:
    new_entries += indent + '{"' + var + '", "' + var + '", NULL, 1},\n'
null_m = re.search(r'(\{NULL\s*,)', content[arr_open:arr_close])
if null_m:
    insert_pos = arr_open + null_m.start()
    new_content = content[:insert_pos] + new_entries + content[insert_pos:]
else:
    before = content[:arr_close].rstrip('\n\r')
    if before and not before.endswith(','): before += ','
    new_content = before + "\n" + new_entries + content[arr_close:]
with open(FILE, 'w') as f:
    f.write(new_content)
print("  SUCCESS")
PATCHPY
    python3 /tmp/patch_udp2raw_vars.py "$HTTPD_VARS"
    grep -n "udp2raw" "$HTTPD_VARS" && echo "  VERIFY OK" || echo "  VERIFY FAILED!"
fi

############################################################
# 14. vpnc_cus3 MTU defaults
############################################################
echo ">>> [13] MTU defaults (vpnc_cus3)"
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
############################################################
############################################################
############################################################
# 15. ★ КЛЮЧЕВОЙ ФИКС v15.0 ★
#     rc.c содержит ТАБЛИЦУ сервисов (не if/else цепочку).
#     Каждый сервис: { "restart_xxx", script, nvram_var, ... }
#     Нужно добавить строку в эту таблицу рядом с restart_zapret.
############################################################
echo ">>> [14] ★ rc.c — add udp2raw to service table"

cat > /tmp/patch_rc_udp2raw.py << 'RCPY'
import sys, re, os

RC = "padavan-ng/trunk/user/rc/rc.c"

with open(RC) as f:
    content = f.read()
    lines = content.split('\n')

if "restart_udp2raw" in content:
    print("  Already patched")
    sys.exit(0)

print(f"  rc.c: {len(lines)} lines")

# Strategy: find the line containing "restart_zapret" (as a string literal)
# This is in a table/array — we insert a similar entry after it

zapret_line = None
for i, line in enumerate(lines):
    if '"restart_zapret"' in line:
        zapret_line = i
        print(f"  Found 'restart_zapret' at line {i+1}: {line.rstrip()}")
        break

if zapret_line is None:
    # Maybe it's defined via macro or concatenation
    # Search for just zapret in context of a struct/array initialization
    for i, line in enumerate(lines):
        if 'zapret' in line and ('{' in line or '"' in line):
            print(f"  zapret ref at {i+1}: {line.rstrip()}")
            # Show context
            for j in range(max(0,i-3), min(len(lines), i+5)):
                print(f"    {j+1}: {lines[j].rstrip()}")
            zapret_line = i
            break

if zapret_line is None:
    # Last resort: search for zapret.sh
    for i, line in enumerate(lines):
        if 'zapret.sh' in line:
            zapret_line = i
            print(f"  Found zapret.sh at line {i+1}: {line.rstrip()}")
            break

if zapret_line is None:
    print("  ERROR: cannot find zapret in rc.c at all")
    # Dump all lines containing 'zapret'
    for i, line in enumerate(lines):
        if 'zapret' in line.lower():
            print(f"    {i+1}: {line.rstrip()}")
    sys.exit(1)

# Show surrounding context (10 lines before and after)
print(f"  --- Context around line {zapret_line+1} ---")
for j in range(max(0, zapret_line-10), min(len(lines), zapret_line+15)):
    marker = " >>>" if j == zapret_line else "    "
    print(f"  {marker} {j+1}: {lines[j].rstrip()}")
print(f"  --- End context ---")

# Determine the format of the table entry by analyzing the zapret line
zline = lines[zapret_line]

# Case 1: full entry on one line: { "restart_zapret", ... },
if '{' in zline and 'restart_zapret' in zline:
    # Copy the format, replace zapret with udp2raw
    new_line = zline.replace('restart_zapret', 'restart_udp2raw')
    new_line = new_line.replace('zapret.sh', 'restart_udp2raw')
    new_line = new_line.replace('zapret_enable', 'udp2raw_enable')
    new_line = new_line.replace('zapret', 'udp2raw')
    
    # But we need /sbin/restart_udp2raw as the script path
    # Replace whatever script path is there
    new_line = re.sub(r'"/usr/bin/[^"]*"', '"/sbin/restart_udp2raw"', new_line)
    
    lines.insert(zapret_line + 1, new_line)
    print(f"  Inserted (case 1): {new_line.rstrip()}")

# Case 2: entry spans multiple lines 
elif '"restart_zapret"' in zline:
    # Find the end of this entry (next line with }, or next entry with {)
    entry_end = zapret_line
    for j in range(zapret_line, min(zapret_line + 10, len(lines))):
        if '}' in lines[j] and j >= zapret_line:
            entry_end = j
            break
    
    # Copy all lines of this entry
    entry_lines = lines[zapret_line:entry_end+1]
    new_entry = []
    for el in entry_lines:
        nl = el.replace('restart_zapret', 'restart_udp2raw')
        nl = nl.replace('zapret.sh', 'restart_udp2raw')
        nl = nl.replace('zapret_enable', 'udp2raw_enable')
        nl = nl.replace('/usr/bin/zapret', '/sbin/restart_udp2raw')
        nl = nl.replace('zapret', 'udp2raw')
        new_entry.append(nl)
    
    for idx, nl in enumerate(new_entry):
        lines.insert(entry_end + 1 + idx, nl)
    print(f"  Inserted (case 2, {len(new_entry)} lines)")
    for nl in new_entry:
        print(f"    {nl.rstrip()}")

# Case 3: zapret.sh found (not restart_zapret as literal)
else:
    # Get indent
    indent = re.match(r'^(\s*)', zline).group(1)
    
    # Look at the surrounding structure to understand format
    # Find the entry that contains this line
    entry_start = zapret_line
    for j in range(zapret_line, max(0, zapret_line-5), -1):
        if '{' in lines[j]:
            entry_start = j
            break
    entry_end = zapret_line
    for j in range(zapret_line, min(zapret_line+5, len(lines))):
        if '}' in lines[j]:
            entry_end = j
            break
    
    entry_lines = lines[entry_start:entry_end+1]
    print(f"  Entry block ({entry_start+1}-{entry_end+1}):")
    for el in entry_lines:
        print(f"    {el.rstrip()}")
    
    # Clone and modify
    new_entry = []
    for el in entry_lines:
        nl = el.replace('restart_zapret', 'restart_udp2raw')
        nl = nl.replace('zapret.sh', 'restart_udp2raw')
        nl = nl.replace('/usr/bin/zapret', '/sbin/restart_udp2raw')
        nl = nl.replace('zapret_enable', 'udp2raw_enable')
        nl = nl.replace('zapret', 'udp2raw')
        new_entry.append(nl)
    
    for idx, nl in enumerate(new_entry):
        lines.insert(entry_end + 1 + idx, nl)
    print(f"  Inserted (case 3, {len(new_entry)} lines)")
    for nl in new_entry:
        print(f"    {nl.rstrip()}")

# Write
content = '\n'.join(lines)
with open(RC, 'w') as f:
    f.write(content)

# Verify
with open(RC) as f:
    v = f.read()
if "restart_udp2raw" in v:
    vlines = v.split('\n')
    for i, line in enumerate(vlines):
        if 'restart_udp2raw' in line:
            for j in range(max(0,i-2), min(len(vlines),i+5)):
                print(f"  {j+1}: {vlines[j]}")
            break
    print("  VERIFY OK")
else:
    print("  VERIFY FAILED!")
    sys.exit(1)
RCPY

python3 /tmp/patch_rc_udp2raw.py
RC_RESULT=$?

if [ "$RC_RESULT" -ne 0 ]; then
    echo "  *** CRITICAL: rc.c patch FAILED ***"
    echo "  Without this patch, WebUI button will NOT work."
    exit 1
fi

############################################################
echo ""
echo "============================================"
echo "  MILLENIUM Group VPN — build ready v15.0"
echo ""
echo "  КЛЮЧЕВОЙ ФИКС v15.0:"
echo "  rc.c пропатчен — restart_udp2raw зарегистрирован"
echo "  как сервис в handle_notifications()."
echo "  httpd -> notify_rc -> rc -> /sbin/restart_udp2raw"
echo "  Штатный механизм Padavan (как restart_zapret)."
echo "============================================"

echo ""
echo "=== DIAGNOSTICS ==="
echo "--- Files ---"
ls -la "$UDP2RAW_DIR/files/" 2>/dev/null
echo "--- rc.c patch ---"
grep -n "restart_udp2raw" "$TRUNK"/user/rc/*.c 2>/dev/null || echo "NOT FOUND in rc/*.c"
echo "--- variables.c ---"
grep "udp2raw_enable" "$TRUNK/user/httpd/variables.c" 2>/dev/null || echo "NOT FOUND"
echo "--- ASP ---"
grep "action_script" "$WWW/Advanced_udp2raw.asp" 2>/dev/null | head -3
echo "=== END ==="
