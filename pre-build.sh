#!/usr/bin/env bash
############################################################
# MILLENIUM Group — Padavan-NG pre-build v6.0
#
# Фиксы v6.0 относительно v5.0:
#   - iptables RST suppression: -I OUTPUT 1 + dedup (было -A, не работало)
#   - WebUI: action_script="restart_udp2raw" → VPN стартует по toggle+Save
#   - WebUI: next_page="Advanced_udp2raw.asp" → страница не пропадает
#   - WebUI: change_enabled() читает реальное состояние через getElementById
#   - romfs: /sbin/restart_udp2raw — вызывается Padavan после сохранения
#   - WAN hook: iptables RST rule при каждом поднятии WAN (до watchdog)
#   - nvram: tun-mtu 1300 / mssfix 1260 по умолчанию (vpnc_cus3)
############################################################
set -euo pipefail

TRUNK="padavan-ng/trunk"
UDP2RAW_DIR="$TRUNK/user/udp2raw-tunnel"
WWW="$TRUNK/user/www/n56u_ribbon_fixed"
ROMFS_STORAGE="$TRUNK/romfs/etc/storage"
ROMFS_SBIN="$TRUNK/romfs/sbin"

echo "============================================"
echo "  MILLENIUM Group VPN — pre-build v6.0"
echo "  Out of box — no manual setup required"
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
#
# FIX v6.0: iptables использует -I OUTPUT 1 вместо -A OUTPUT.
# В Padavan firewall есть правила DROP которые стоят в цепочке
# раньше. -A добавляет в конец — RST не перехватывается до DROP.
# Решение: сначала удаляем старое правило (dedup), потом -I pos 1.
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

    # FIX v6.0: dedup + INSERT в позицию 1 (не APPEND в конец)
    # -A не работает в Padavan — правила DROP стоят раньше в цепочке
    iptables -D OUTPUT -p tcp --dport "$PRT" --tcp-flags RST RST -j DROP 2>/dev/null
    iptables -I OUTPUT 1 -p tcp --dport "$PRT" --tcp-flags RST RST -j DROP

    /usr/bin/udp2raw -c \
        -l "127.0.0.1:3333" \
        -r "${SRV}:${PRT}" \
        -k "$KEY" \
        --raw-mode faketcp \
        --cipher-mode xor \
        --auth-mode simple \
        -a --log-level 3 > "$LOGFILE" 2>&1 &
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
echo "$SERVERS" | tr '>' '\n' > /tmp/vpn_srvlist

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
#
# FIX v6.0: Padavan после сохранения формы запускает /sbin/restart_<script>.
# Без этого скрипта toggle и "Сохранить" не запускали/останавливали VPN.
# Теперь: Save → Padavan вызывает restart_udp2raw → fl-vpn-start/stop.
############################################################
echo ">>> [5] restart_udp2raw (Padavan action_script hook)"
mkdir -p "$ROMFS_SBIN"

cat > "$ROMFS_SBIN/restart_udp2raw" << 'RSTEOF'
#!/bin/sh
# Вызывается Padavan как action_script после сохранения WebUI формы.
# action_script="restart_udp2raw" в Advanced_udp2raw.asp
EN=$(nvram get udp2raw_enable 2>/dev/null)
if [ "$EN" = "1" ]; then
    /usr/bin/fl-vpn-start &
else
    /usr/bin/fl-vpn-stop
fi
RSTEOF
chmod +x "$ROMFS_SBIN/restart_udp2raw"
echo "  Created $ROMFS_SBIN/restart_udp2raw"

############################################################
# 11. WAN hook вшитый в romfs
#
# FIX v6.0: iptables RST suppression добавляем ДО запуска watchdog.
# Из логов: без этого правила udp2raw застревал на handshake2
# с "auth_verify failed" — ядро отправляло RST и сессия рвалась.
############################################################
echo ">>> [6] WAN hook → romfs (out of box autostart)"
mkdir -p "$ROMFS_STORAGE"

WAN_HOOK="$ROMFS_STORAGE/started_wan_hook.sh"
if [ -f "$WAN_HOOK" ]; then
    if ! grep -q "fl-vpn-watchdog" "$WAN_HOOK"; then
        cat >> "$WAN_HOOK" << 'HOOKEOF'

# MILLENIUM VPN — udp2raw autostart v6.0
# FIX: iptables RST suppression ДО watchdog — иначе handshake не проходит
sleep 3
PRT=$(nvram get udp2raw_servers 2>/dev/null | cut -d'>' -f1 | cut -d: -f2)
if [ -n "$PRT" ] && echo "$PRT" | grep -qE '^[0-9]+$'; then
    iptables -D OUTPUT -p tcp --dport "$PRT" --tcp-flags RST RST -j DROP 2>/dev/null
    iptables -I OUTPUT 1 -p tcp --dport "$PRT" --tcp-flags RST RST -j DROP
fi
sleep 2 && /usr/bin/fl-vpn-watchdog &
HOOKEOF
        echo "  Appended to existing $WAN_HOOK"
    else
        echo "  Already patched: $WAN_HOOK"
    fi
else
    cat > "$WAN_HOOK" << 'HOOKEOF'
#!/bin/sh
# MILLENIUM VPN — udp2raw autostart v6.0
# Запускается автоматически при поднятии WAN.
# Watchdog ставит себя в cron и следит за туннелем.

# FIX v6.0: iptables RST suppression нужен ДО запуска udp2raw.
# Без него клиент не проходит handshake2 (auth_verify failed в логах).
sleep 3
PRT=$(nvram get udp2raw_servers 2>/dev/null | cut -d'>' -f1 | cut -d: -f2)
if [ -n "$PRT" ] && echo "$PRT" | grep -qE '^[0-9]+$'; then
    iptables -D OUTPUT -p tcp --dport "$PRT" --tcp-flags RST RST -j DROP 2>/dev/null
    iptables -I OUTPUT 1 -p tcp --dport "$PRT" --tcp-flags RST RST -j DROP
fi
sleep 2 && /usr/bin/fl-vpn-watchdog &
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
    [ -f "$CUSTOM_DIR/Makefile" ] && ! grep -q "mkdir -p" "$CUSTOM_DIR/Makefile" && \
        sed -i '/ROMFSINST.*wireguard/i\\tmkdir -p $(ROOTDIR)/romfs/etc/storage/wireguard' "$CUSTOM_DIR/Makefile"
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
	$(ROMFSINST) -p +x files/fl-vpn-status    /usr/bin/fl-vpn-status
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
# 16. ASP страница MILLENIUM VPN v6.0
#
# FIX v6.0 относительно v5.0:
#
# 1. action_script="restart_udp2raw"
#    Было: action_script="" → после Save Padavan ничего не запускал,
#    VPN не стартовал. Теперь Padavan вызывает /sbin/restart_udp2raw.
#
# 2. next_page="Advanced_udp2raw.asp"
#    Было: next_page="" → после Save браузер уходил на пустую страницу.
#    Теперь редирект обратно на ту же страницу.
#
# 3. change_enabled() через getElementById
#    Было: document.form.udp2raw_enable[0].checked — ненадёжно в Padavan,
#    иногда form array не строился при загрузке.
#    Теперь: getElementById('udp2raw_enable_1').checked — всегда работает.
#
# 4. Убран showLoading() из applyRule()
#    В некоторых сборках Padavan showLoading() блокировал UI overlay
#    и toggle визуально зависал (не реагировал на клики).
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
var m_active  = '<% nvram_get_x("", "udp2raw_active"); %>';

function initial(){
    show_banner(0); show_menu(7,-1,0); show_footer();
    change_enabled(); load_servers(); update_status(); load_body();
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

// FIX v6.0: getElementById вместо form array — надёжнее в Padavan WebUI
function change_enabled(){
    var r1      = document.getElementById('udp2raw_enable_1');
    var enabled = r1 && r1.checked;
    showhide_div('cfg_main', enabled);
}

function load_servers(){
    var s = document.form.udp2raw_servers_h.value || '';
    document.getElementById('srv_text').value = s.replace(/>/g, '\n');
}

// FIX v6.0:
//   - убран showLoading() — блокировал UI overlay в ряде сборок Padavan
//   - next_page → возврат на ту же страницу (было "" → пустая страница)
//   - action_script → Padavan вызовет /sbin/restart_udp2raw после Save
function applyRule(){
    var sv = document.getElementById('srv_text').value;
    sv = sv.replace(/\r\n/g, '\n').replace(/\n+/g, '\n').replace(/^\n|\n$/g, '');
    document.form.udp2raw_servers.value  = sv.replace(/\n/g, '>');
    document.form.action_mode.value      = ' Apply ';
    document.form.current_page.value     = 'Advanced_udp2raw.asp';
    document.form.next_page.value        = 'Advanced_udp2raw.asp';
    document.form.action_script.value    = 'restart_udp2raw';
    document.form.submit();
}

function done_validating(action){}
</script>
<style>
.help-text  { color:#888; font-size:11px; margin-top:3px; }
.status-box { background:#f5f5f5; border-radius:6px; padding:12px 16px; margin:10px; }
</style>
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
<input type="hidden" name="udp2raw_servers" value="">
<input type="hidden" name="udp2raw_servers_h"
    value="<% nvram_get_x("", "udp2raw_servers"); %>">

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
              <div class="main_itoggle">
                <div id="udp2raw_enable_on_of">
                  <input type="checkbox" id="udp2raw_enable_fake"
                    <% nvram_match_x("", "udp2raw_enable", "1", "value=1 checked"); %>
                    <% nvram_match_x("", "udp2raw_enable", "0", "value=0"); %>>
                </div>
              </div>
              <div style="position:absolute;margin-left:-10000px;">
                <input type="radio" name="udp2raw_enable" id="udp2raw_enable_1"
                    class="input" value="1"
                    onclick="change_enabled();"
                    <% nvram_match_x("", "udp2raw_enable", "1", "checked"); %>>Да
                <input type="radio" name="udp2raw_enable" id="udp2raw_enable_0"
                    class="input" value="0"
                    onclick="change_enabled();"
                    <% nvram_match_x("", "udp2raw_enable", "0", "checked"); %>>Нет
              </div>
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
echo "  Created Advanced_udp2raw.asp v6.0"

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
# 18. nvram defaults
#
# FIX v6.0: добавлены vpnc_cus3 defaults с tun-mtu 1300 mssfix 1260.
# Из логов роутера: OpenVPN слал пакеты 1425 байт через udp2raw →
# "huge packet warn" → нестабильное соединение.
# vpnc_cus3 — nvram переменная для custom params в OpenVPN client WebUI.
# После прошивки в разделе VPN Client → Custom Config будет стоять
# tun-mtu 1300 / mssfix 1260 автоматически.
############################################################
echo ">>> [11] nvram defaults"
for F in \
    "$TRUNK/user/shared/defaults.h" \
    "$TRUNK/user/shared/defaults.c" \
    "$TRUNK/user/rc/defaults.c" \
    "$TRUNK/user/httpd/variables.c"; do
    [ -f "$F" ] && grep -q 'router_defaults\|nvram_pair' "$F" || continue

    # udp2raw vars
    if ! grep -q "udp2raw_enable" "$F"; then
        for TERM in '{ 0, 0 }' '{0, 0}'; do
            if grep -q "$TERM" "$F"; then
                LINE=$(grep -n "$TERM" "$F" | tail -1 | cut -d: -f1)
                sed -i "${LINE}i\\
\t{ \"udp2raw_enable\",  \"0\" },\\
\t{ \"udp2raw_servers\", \"\" },\\
\t{ \"udp2raw_status\",  \"\" },\\
\t{ \"udp2raw_active\",  \"\" }," "$F"
                echo "  Added udp2raw defaults to: $F"
                break
            fi
        done
    else
        echo "  Already patched (udp2raw): $F"
    fi

    # FIX v6.0: OpenVPN MTU defaults (vpnc_cus3)
    if ! grep -q "vpnc_cus3.*tun-mtu" "$F"; then
        for TERM in '{ 0, 0 }' '{0, 0}'; do
            if grep -q "$TERM" "$F"; then
                LINE=$(grep -n "$TERM" "$F" | tail -1 | cut -d: -f1)
                sed -i "${LINE}i\\
\t{ \"vpnc_cus3\", \"tun-mtu 1300\\\\nmssfix 1260\" }," "$F"
                echo "  Added vpnc_cus3 MTU defaults to: $F"
                break
            fi
        done
    else
        echo "  vpnc_cus3 already patched: $F"
    fi
    break
done

############################################################
echo ""
echo "============================================"
echo "  MILLENIUM Group VPN — build ready v6.0"
echo ""
echo "  Что исправлено vs v5.0:"
echo "  - iptables: -I OUTPUT 1 + dedup (было -A)"
echo "  - WebUI toggle+Save: теперь реально запускают VPN"
echo "  - WebUI redirect: возврат на страницу после Save"
echo "  - romfs: /sbin/restart_udp2raw (action_script hook)"
echo "  - WAN hook: iptables RST при каждом поднятии WAN"
echo "  - nvram: tun-mtu 1300 / mssfix 1260 по умолчанию"
echo ""
echo "  После прошивки — только 3 действия:"
echo "  1. WebUI → MILLENIUM VPN → ввести серверы"
echo "     → toggle ON → Сохранить и применить"
echo "  2. VPN клиент → remote 127.0.0.1, порт 3333"
echo "  3. Готово. Всё работает само."
echo "============================================"

echo ""
echo "=== DIAGNOSTICS ==="
ls -la "$UDP2RAW_DIR/files/" 2>/dev/null
echo "--- /sbin/restart_udp2raw ---"
cat "$ROMFS_SBIN/restart_udp2raw" 2>/dev/null || echo "NOT FOUND"
echo "--- WAN hook ---"
cat "$ROMFS_STORAGE/started_wan_hook.sh" 2>/dev/null || echo "NOT FOUND"
ls "$WWW/Advanced_udp2raw.asp" "$WWW/millenium_status.asp" 2>/dev/null && echo "ASP OK"
echo "=== END ==="
