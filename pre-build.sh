#!/usr/bin/env bash
set -e

# ----------------------------------------------------------------------
# XOR-patch OpenVPN (оставил без изменений)
# ----------------------------------------------------------------------
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

# ----------------------------------------------------------------------
# Кастомизация WebUI (оставил как у тебя)
# ----------------------------------------------------------------------
CUSTOM_MODEL="FastLink  (private build)"
CUSTOM_FOOTER="© 2025 FastLink Team.  Powered by Padavan-NG"

sed -i '
  s/^Web_Title=.*/Web_Title=ZVMODELVZ Wireless Router/;
' padavan-ng/trunk/romfs/www/*.dict 2>/dev/null || true

find padavan-ng/trunk -name '*.dict' -print0 | while IFS= read -r -d '' F; do
  sed -i "s/ZVMODELVZ/${CUSTOM_MODEL//\//\\/}/g" "$F"
  sed -i "s/ZVCOPYRVZ/${CUSTOM_FOOTER//\//\\/}/g" "$F"
done

# ----------------------------------------------------------------------
# AmneziaWG + obfs4proxy : простая интеграция в WebUI через romfs
# ----------------------------------------------------------------------

set -e

ROMFS=padavan-ng/trunk/romfs

# 1) Директории и автозапусковые маркеры
mkdir -p "$ROMFS/etc/storage/amneziawg" \
         "$ROMFS/etc/storage/obfs4" \
         "$ROMFS/www/cgi-bin" \
         "$ROMFS/www"

# 2) Клиент AmneziaWG (на базе твоего client.sh, слегка упрощён)
cat > "$ROMFS/etc/storage/amneziawg/client.sh" <<'EOF'
#!/bin/sh
# Minimal AmneziaWG client for Padavan (wg0.conf in /etc/storage/amneziawg)
# start|stop|restart|autostart {enable|disable}|status

set -eu
LOG="logger -t amneziawg"
CFG_DIR="/etc/storage/amneziawg"
CFG_FILE="$(ls -1 ${CFG_DIR}/*.conf 2>/dev/null | head -n1 || true)"
IFACE="$(basename "$CFG_FILE" .conf 2>/dev/null || echo wg0)"
[ -z "$IFACE" ] && IFACE=wg0
FWMARK=51820
TABLE=$FWMARK

status() {
  ip link show dev "$IFACE" >/dev/null 2>&1 || { echo "down"; return 1; }
  echo "up"
}

start() {
  if ip link show dev "$IFACE" >/dev/null 2>&1; then
    $LOG "iface $IFACE already exists"; exit 0
  fi
  [ -f "$CFG_FILE" ] || { $LOG "no config (*.conf) in $CFG_DIR"; exit 1; }
  modprobe amneziawg 2>/dev/null || true
  ip link add "$IFACE" type amneziawg
  # Вычислим Address= (первую)
  ADDR="$(sed -n 's/^[[:space:]]*Address[[:space:]]*=\(.*\)$/\1/p' "$CFG_FILE" | tr ',' ' ' | awk '{print $1}' | head -1)"
  [ -n "$ADDR" ] && ip addr add "$ADDR" dev "$IFACE" || true
  # MTU (опц.)
  MTU="$(sed -n 's/^[[:space:]]*MTU[[:space:]]*=\(.*\)$/\1/p' "$CFG_FILE" | head -1)"
  [ -n "$MTU" ] || MTU=1420
  awg setconf "$IFACE" "$CFG_FILE"
  ip link set "$IFACE" up mtu "$MTU"

  # Маршрутизация: если AllowedIPs содержит 0.0.0.0/0 — делаем дефолт через IFACE
  if grep -qiE '^AllowedIPs\s*=.*(^|,| )0\.0\.0\.0/0(,| |$)' "$CFG_FILE"; then
    awg set "$IFACE" fwmark $FWMARK
    ip route add default dev "$IFACE" table $TABLE 2>/dev/null || true
    ip rule add not fwmark $FWMARK table $TABLE pref 30001 2>/dev/null || true
    ip rule add table main suppress_prefixlength 0 pref 30000 2>/dev/null || true
    sysctl -q net.ipv4.conf.all.src_valid_mark=1 2>/dev/null || true
    # Немного mangle для сохранения марки UDP коннектов
    iptables -t mangle -I POSTROUTING -m mark --mark $FWMARK -p udp -j CONNMARK --save-mark 2>/dev/null || true
    iptables -t mangle -I PREROUTING -p udp -j CONNMARK --restore-mark 2>/dev/null || true
  else
    # частичный трафик
    ALLOWED="$(sed -n 's/^[[:space:]]*AllowedIPs[[:space:]]*=\(.*\)$/\1/p' "$CFG_FILE" | tr ',' ' ')"
    for net in $ALLOWED; do
      echo "$net" | grep -q '\.' || continue
      ip rule add to "$net" table $TABLE pref 5000 2>/dev/null || true
    done
    ip route add default dev "$IFACE" table $TABLE 2>/dev/null || true
  fi
  $LOG "started $IFACE"
}

stop() {
  ip link show dev "$IFACE" >/dev/null 2>&1 || { $LOG "iface $IFACE not found"; exit 0; }
  # Убираем правила
  ip rule del table $TABLE 2>/dev/null || true
  ip rule del pref 30000 2>/dev/null || true
  ip rule del pref 30001 2>/dev/null || true
  ip route flush table $TABLE 2>/dev/null || true
  # Чистим mangle
  iptables -t mangle -D POSTROUTING -m mark --mark $FWMARK -p udp -j CONNMARK --save-mark 2>/dev/null || true
  iptables -t mangle -D PREROUTING -p udp -j CONNMARK --restore-mark 2>/dev/null || true
  ip link del "$IFACE"
  $LOG "stopped $IFACE"
}

autostart() {
  case "${1:-}" in
    enable) touch /etc/storage/amneziawg/.autostart ;;
    disable) rm -f /etc/storage/amneziawg/.autostart ;;
    *) echo "usage: $0 autostart {enable|disable}"; exit 1 ;;
  esac
}

case "${1:-}" in
  start) start ;;
  stop)  stop ;;
  restart) stop; start ;;
  status) status ;;
  autostart) autostart "${2:-}" ;;
  *) echo "usage: $0 {start|stop|restart|status|autostart}"; exit 1 ;;
esac
EOF
chmod +x "$ROMFS/etc/storage/amneziawg/client.sh"

# 3) CGI для страницы AmneziaWG (сохранить конфиг/кнопки управления)
cat > "$ROMFS/www/cgi-bin/AmneziaWG" <<'EOF'
#!/bin/sh
echo "Content-Type: text/plain; charset=utf-8"
echo
ACTION="${QUERY_STRING##action=}"
read_body() { cat; }
cfg_dir="/etc/storage/amneziawg"
cfg_file="$cfg_dir/wg0.conf"
mkdir -p "$cfg_dir"

case "$ACTION" in
  save)
    # тело запроса — это содержимое конфигурации
    read_body > "$cfg_file"
    echo "saved"
    ;;
  start)
    /etc/storage/amneziawg/client.sh start && echo "started" || echo "error"
    ;;
  stop)
    /etc/storage/amneziawg/client.sh stop && echo "stopped" || echo "error"
    ;;
  status)
    /etc/storage/amneziawg/client.sh status
    ;;
  autoon)
    /etc/storage/amneziawg/client.sh autostart enable && echo "autostart=on"
    ;;
  autooff)
    /etc/storage/amneziawg/client.sh autostart disable && echo "autostart=off"
    ;;
  *)
    echo "unknown"
    ;;
esac
EOF
chmod +x "$ROMFS/www/cgi-bin/AmneziaWG"

# 4) Простая WebUI-страница AmneziaWG
cat > "$ROMFS/www/Advanced_AmneziaWG_Content.asp" <<'EOF'
<!DOCTYPE html>
<html><head>
<meta charset="utf-8">
<title>AmneziaWG</title>
<script>
function ajax(method, url, body, cb){
  var x=new XMLHttpRequest();
  x.open(method,url,true);
  x.onreadystatechange=function(){ if(x.readyState==4) cb(x.status,x.responseText); };
  if(body!=null) x.setRequestHeader('Content-Type','text/plain;charset=utf-8');
  x.send(body);
}
function saveCfg(){
  var t=document.getElementById('cfg').value;
  ajax('POST','/cgi-bin/AmneziaWG?action=save',t,function(s,r){ alert('Save: '+r); });
}
function startWG(){ ajax('GET','/cgi-bin/AmneziaWG?action=start',null,function(s,r){ alert(r); }); }
function stopWG(){ ajax('GET','/cgi-bin/AmneziaWG?action=stop',null,function(s,r){ alert(r); }); }
function statusWG(){ ajax('GET','/cgi-bin/AmneziaWG?action=status',null,function(s,r){ document.getElementById('st').innerText=r; }); }
function autoOn(){ ajax('GET','/cgi-bin/AmneziaWG?action=autoon',null,function(s,r){ alert(r); }); }
function autoOff(){ ajax('GET','/cgi-bin/AmneziaWG?action=autooff',null,function(s,r){ alert(r); }); }
window.onload=function(){ statusWG(); };
</script>
<style>
textarea{width:100%;height:320px;font-family:monospace;}
.btns button{margin:4px;}
</style>
</head>
<body>
<h2>AmneziaWG (wg0.conf)</h2>
<div class="btns">
  <button onclick="saveCfg()">Save</button>
  <button onclick="startWG()">Start</button>
  <button onclick="stopWG()">Stop</button>
  <button onclick="statusWG()">Status</button>
  <button onclick="autoOn()">Autostart ON</button>
  <button onclick="autoOff()">Autostart OFF</button>
  <span id="st" style="margin-left:10px;color:#090;"></span>
</div>
<p>Вставьте сюда конфиг WireGuard (AmneziaWG совместим по формату; специфичные поля S1..H4 тоже будут переданы утилите).</p>
<textarea id="cfg"><?asp
  nvram_dump("/etc/storage/amneziawg/wg0.conf");
?></textarea>
</body></html>
EOF

# 5) obfs4: минимальный раннер + CGI + страница
cat > "$ROMFS/etc/storage/obfs4/run.sh" <<'EOF'
#!/bin/sh
# Храним произвольную команду запуска obfs4proxy в /etc/storage/obfs4/cmd
CMD_FILE="/etc/storage/obfs4/cmd"
LOG="/var/log/obfs4proxy.log"
PID="/var/run/obfs4proxy.pid"
start() {
  [ -f "$CMD_FILE" ] || { echo "no cmd"; exit 1; }
  sh -c "$(cat "$CMD_FILE")" >>"$LOG" 2>&1 &
  echo $! > "$PID"
  logger -t obfs4 "started"
}
stop() {
  [ -f "$PID" ] && kill "$(cat "$PID")" 2>/dev/null || true
  rm -f "$PID"
  logger -t obfs4 "stopped"
}
case "${1:-}" in
  start) start ;;
  stop) stop ;;
  restart) stop; start ;;
  *) echo "usage: $0 {start|stop|restart}"; exit 1 ;;
esac
EOF
chmod +x "$ROMFS/etc/storage/obfs4/run.sh"

cat > "$ROMFS/www/cgi-bin/obfs4" <<'EOF'
#!/bin/sh
echo "Content-Type: text/plain; charset=utf-8"
echo
ACTION="${QUERY_STRING##action=}"
read_body(){ cat; }
mkdir -p /etc/storage/obfs4
case "$ACTION" in
  save)
    read_body > /etc/storage/obfs4/cmd
    echo "saved"
    ;;
  start)
/etc/storage/obfs4/run.sh start && echo "started" || echo "error"
    ;;
  stop)
/etc/storage/obfs4/run.sh stop && echo "stopped" || echo "error"
    ;;
  *)
    echo "unknown"
    ;;
esac
EOF
chmod +x "$ROMFS/www/cgi-bin/obfs4"

cat > "$ROMFS/www/Advanced_obfs4_Content.asp" <<'EOF'
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>obfs4proxy</title>
<script>
function ajax(m,u,b,cb){var x=new XMLHttpRequest();x.open(m,u,true);
x.onreadystatechange=function(){if(x.readyState==4)cb(x.status,x.responseText)};
if(b!=null)x.setRequestHeader('Content-Type','text/plain;charset=utf-8');x.send(b);}
function save(){ajax('POST','/cgi-bin/obfs4?action=save',document.getElementById('cmd').value,function(s,r){alert(r);});}
function start(){ajax('GET','/cgi-bin/obfs4?action=start',null,function(s,r){alert(r);});}
function stop(){ajax('GET','/cgi-bin/obfs4?action=stop',null,function(s,r){alert(r);});}
</script>
<style>textarea{width:100%;height:180px;font-family:monospace;}</style>
</head><body>
<h2>obfs4proxy</h2>
<p>Укажи команду запуска (пример):<br>
<code>/usr/sbin/obfs4proxy -enableLogging -logLevel INFO -state /etc/storage/obfs4/state -transports obfs4 -proxylisten 127.0.0.1:1050</code></p>
<textarea id="cmd"><?asp nvram_dump("/etc/storage/obfs4/cmd"); ?></textarea><br>
<button onclick="save()">Save</button>
<button onclick="start()">Start</button>
<button onclick="stop()">Stop</button>
</body></html>
EOF

# 6) Добавим пункты меню (просто ссылки на наши ASP-страницы)
# Вариант «мягкой» вставки: если существует файл меню – допишем
MENU_JS="$ROMFS/www/Advanced_menuTree.js"
if [ -f "$MENU_JS" ]; then
  # если ещё нет, добавим под раздел VPN
  grep -q 'Advanced_AmneziaWG_Content.asp' "$MENU_JS" || \
    sed -i 's|\(Advanced_OpenVPNClient_Content\.asp[^"]*"\?\),|\1,\n["AmneziaWG","Advanced_AmneziaWG_Content.asp"],|;' "$MENU_JS"
  grep -q 'Advanced_obfs4_Content.asp' "$MENU_JS" || \
    sed -i 's|\(Advanced_OpenVPNClient_Content\.asp[^"]*"\?\),|\1,\n["obfs4proxy","Advanced_obfs4_Content.asp"],|;' "$MENU_JS"
fi

# 7) Автостарт после полного запуска (если включён)
STARTED="$ROMFS/etc/storage/started_script.sh"
mkdir -p "$(dirname "$STARTED")"
cat >> "$STARTED" <<'EOF'

# === AmneziaWG/obfs4 auto hooks ===
if [ -f /etc/storage/amneziawg/.autostart ]; then
  /etc/storage/amneziawg/client.sh start
fi
# Для obfs4 сделай вручную, если нужно:
# [ -f /etc/storage/obfs4/.autostart ] && /etc/storage/obfs4/run.sh start
EOF

echo ">>> prebuild.sh finished OK"
