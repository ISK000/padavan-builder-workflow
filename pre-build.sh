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

# ----------------------------------------------------------------------
# GUI shim: WireGuard/AmneziaWG + obfs4proxy (nvram + автоскрипты)
# ----------------------------------------------------------------------
set -e
ROOT="padavan-ng/trunk"

# Каталоги
mkdir -p "$ROOT/romfs/usr/bin"
mkdir -p "$ROOT/romfs/etc/storage/wireguard"
mkdir -p "$ROOT/romfs/www"

# -----------------------------
# 1) WireGuard client wrapper
# -----------------------------
cat > "$ROOT/romfs/usr/bin/awg-client" <<'EOF'
#!/bin/sh
# Wrapper запускает установленный в /etc/storage/wireguard/client.sh
set -e
SCRIPT="/etc/storage/wireguard/client.sh"
[ -x "$SCRIPT" ] || { echo "Missing $SCRIPT"; exit 1; }
exec "$SCRIPT" "$@"
EOF
chmod +x "$ROOT/romfs/usr/bin/awg-client"

# -----------------------------
# 2) ВАШ client.sh (ровно как дали)
# -----------------------------
cat > "$ROOT/romfs/etc/storage/wireguard/client.sh" <<'EOF'
#! /bin/busybox sh
set -euo pipefail

log="logger -t wireguard"

dir="$(cd -- "$(dirname "$0")" &> /dev/null && pwd)"
config_file="$(ls -v "${dir}"/*conf | head -1)"
iface="$(basename "$config_file" .conf)"
wan="$(ip route | grep 'default via' | head -1 | awk '{print $5}')"
wan_mtu="$(cat /sys/class/net/${wan}/mtu)"
mtu=$(( wan_mtu > 0 ? wan_mtu - 80 : 1500 - 80 ))
fwmark=51820
routes_table=$fwmark

filtered_config=""
filtered_config_file="/tmp/wireguard.${iface}.filtered.conf"
preup="/tmp/wireguard.${iface}.preup.sh"
postup="/tmp/wireguard.${iface}.postup.sh"
predown="/tmp/wireguard.${iface}.predown.sh"
postdown="/tmp/wireguard.${iface}.postdown.sh"
client_addr=""
client_mask=""
server_addr=""
server_port=""
allowed_ips=""

traffic_rules_def_pref=5000
traffic_rules_suppressor_pref=30000

die() {
  $log "${1}. Exit."
  exit 1
}

cleanup() {
  rm -f "$filtered_config_file" "$preup" "$postup" "$predown" "$postdown" || :
}

wait_online() {
  local i=0
  until ping -c 1 -W 1 $1 &> /dev/null; do
    i=$(( i < 300 ? i + 1 : i ))
    $log "No ping response from $1, waiting $i sec..."
    sleep $i
  done
}

validate_iface_name() {
  [ -z "$(echo "$1" | sed -E 's/^[a-zA-Z0-9_=+.-]{1,15}//')" ] || return 1
}

get_valid_addrs() {
  addrs="$(echo "$1" | sed 's/,/ /g')"
  for addr in $addrs; do
    if echo "$addr" | grep -q '\.'; then
      echo -n "$addr "
    fi
  done
}

trim_spaces() {
  echo "$1" | sed -E 's/ +/ /g;s/^ //;s/ $//'
}

trim_eof_newlines() {
  sed -i -e :a -e '/^\n*$/{$d;N;};/\n$/ba' "$1"
}

add_to_filtered_config() {
  filtered_config="${filtered_config}${1}"$'\n'
}

parse_config() {
  $log "Parsing config"
  dos2unix -u "$1"
  local line key val addr cidr err

  while read -r line || [ -n "$line" ]; do
    [ -z "$line" ] ||
    [ "${line:0:1}" = "#" ] && continue

    case "$line" in
      PreUp*)    echo "$line" | cut -d '=' -f 2- >> "$preup"    ;;
      PostUp*)   echo "$line" | cut -d '=' -f 2- >> "$postup"   ;;
      PreDown*)  echo "$line" | cut -d '=' -f 2- >> "$predown"  ;;
      PostDown*) echo "$line" | cut -d '=' -f 2- >> "$postdown" ;;
    esac

    line="$(echo "$line" | sed 's/ //g')"
    key="$(echo "$line" | cut -d '=' -f 1)"
    val="$(echo "$line" | cut -d '=' -f 2-)"

    case "$key" in
      Address)
        [ -n "$client_addr" ] && continue
        cidr="$(get_valid_addrs "$val" | cut -d ' ' -f 1)"
        client_addr="$(echo "$cidr" | cut -d '/' -f 1)"
        client_mask="$(echo "$cidr" | cut -d '/' -f 2)"
        [ "$client_addr" = "$client_mask" ] && client_mask="32"
        ;;

      Endpoint)
        [ -n "$server_addr" ] && continue
        addr="$(get_valid_addrs "$val" | cut -d ' ' -f 1)"
        server_addr="$(echo "$addr" | cut -d ':' -f 1)"
        server_port="$(echo "$addr" | cut -d ':' -f 2)"
        add_to_filtered_config "${key}=${server_addr}:${server_port}"
        ;;

      AllowedIPs)
        allowed_ips="$allowed_ips $(get_valid_addrs "$val")"
        ;;

      MTU)
        mtu="$val"
        ;;

      \[*|PrivateKey|PublicKey|PresharedKey|PersistentKeepalive|ListenPort)
        add_to_filtered_config "$line"
        ;;

      *)
        $log "Ignoring config entry: $key"
        continue
        ;;
    esac
  done < "$1"

  allowed_ips="$(trim_spaces "$allowed_ips")"
  add_to_filtered_config "AllowedIPs=$(echo "$allowed_ips" | sed 's/ /,/g')"

  err=""
  [ -z "$server_addr" ] && err="No valid server address in config file"
  [ -z "$allowed_ips" ] && err="No valid allowed IPs in config file"
  [ -n "$err" ] && die "$err"

  if [ "$1" = "$config_file" ]; then
    echo "$filtered_config" > "$filtered_config_file"
  fi
}

configure_traffic_rules() {
  local client_cidr action def_route

  if [ -z "$client_addr" ]; then
    parse_config "$filtered_config_file"
    client_cidr="$(ip -o -4 addr list $iface | awk '{print $4}')"
    client_addr="$(echo $client_cidr | cut -d '/' -f 1)"
    client_mask="$(echo $client_cidr | cut -d '/' -f 2)"
  fi

  def_route=0
  echo "$allowed_ips" | grep -q '/0' && def_route=1

  case "$1" in
    enable)
      ip link show $iface &> /dev/null || { $log "Nonexistent interface $iface"; return 1; }
      configure_traffic_rules disable &> /dev/null

      action="-I"
      $log "Setting up traffic rules..."

      ip route add default dev $iface table $routes_table

      if [ $def_route = 1 ]; then
        wg set $iface fwmark $fwmark
        ip rule add not fwmark $fwmark table $routes_table pref $(( traffic_rules_suppressor_pref + 1 ))
        ip rule add table main suppress_prefixlength 0 pref $traffic_rules_suppressor_pref
        sysctl -q net.ipv4.conf.all.src_valid_mark=1
      else
        for i in $allowed_ips; do
          ip rule add to $i table $routes_table pref $traffic_rules_def_pref
        done
      fi
      ;;

    disable)
      action="-D"
      $log "Removing traffic rules... "

      ip route del default table $routes_table || :
      ip rule del table $routes_table || :
      ip rule del pref $traffic_rules_suppressor_pref || :
      ;;

    *)
      $log "Wrong argument: 'enable' or 'disable' expected. Doing nothing." >&2
      return
      ;;
  esac

  if [ $def_route = 1 ]; then
    iptables -t mangle $action POSTROUTING -m mark --mark $fwmark -p udp -j CONNMARK --save-mark || :
    iptables -t mangle $action PREROUTING -p udp -j CONNMARK --restore-mark || :
  fi

  iptables $action INPUT -i $iface -j ACCEPT || :
  iptables -t nat $action POSTROUTING -o $iface -j SNAT --to $client_addr || :
  iptables -t mangle $action FORWARD ! -o br0 -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu || :
}

start() {
  $log "Starting"
  ip link show dev "$iface" &> /dev/null && die "'$iface' already exists"
  validate_iface_name "$iface" || die "Invalid interface name"
  cleanup
  parse_config "$config_file"

  $log "Setting up interface"
  [ -f "$preup" ] && . "$preup"
  modprobe wireguard
  ip link add $iface type wireguard
  ip addr add $client_addr/$client_mask dev $iface
  wg setconf $iface "$filtered_config_file"
  ip link set $iface up mtu $mtu

  configure_traffic_rules enable
  [ -f "$postup" ] && . "$postup"
}

stop() {
  $log "Stopping"
  [ -f "$predown" ] && . "$predown"
  configure_traffic_rules disable
  ip link del $iface
  [ -f "$postdown" ] && . "$postdown"
  cleanup
}

autostart() {
  local script_path mark_start mark_end

  script_path="${dir}/$(basename "$0")"
  mark_start="### $script_path autostart: begin"
  mark_end="### $script_path autostart: end"

  autostart_target="/etc/storage/post_wan_script.sh"
  traffic_rules_target="/etc/storage/post_iptables_script.sh"

  case "$1" in
    enable)
      $log "Enabling autostart"

      trim_eof_newlines "$autostart_target"

      printf "%s\n" \
      "" \
      "$mark_start" \
      "case \"\$1\" in" \
      "  up) \"$script_path\" start ;;" \
      "  down) \"$script_path\" stop ;;" \
      "esac" \
      "$mark_end" \
      >> "$autostart_target"

      trim_eof_newlines "$traffic_rules_target"

      printf "%s\n" \
      "" \
      "$mark_start" \
      "\"$script_path\" traffic-rules enable" \
      "$mark_end" \
      >> "$traffic_rules_target"
      ;;

    disable)
      $log "Disabling autostart"

      sed -i "\|^$mark_start|,\|^$mark_end|d" "$autostart_target"
      sed -i "\|^$mark_start|,\|^$mark_end|d" "$traffic_rules_target"

      trim_eof_newlines "$autostart_target"
      trim_eof_newlines "$traffic_rules_target"
      ;;

    *)
      $log "Wrong argument: 'enable' or 'disable' expected. Doing nothing." >&2
      return
      ;;
  esac
}

case "$1" in
  start)
    start
    ;;

  stop)
    stop
    ;;

  restart)
    stop
    start
    ;;

  traffic-rules)
    configure_traffic_rules "$2"
    ;;

  autostart)
    autostart "$2"
    ;;

  *)
    echo "Usage: $0 {start|stop}" >&2
    exit 1
    ;;
esac

$log "Done"
exit 0
EOF
chmod +x "$ROOT/romfs/etc/storage/wireguard/client.sh"

# Пример конфига
cat > "$ROOT/romfs/etc/storage/wireguard/wg0.conf.example" <<'EOF'
# Example WireGuard config
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

# --------------------------------------
# 3) Автозагрузка WG по nvram-флагу
# --------------------------------------
# started_script: при amneziawg_enable=1 — запускаем клиента
awk '1; END{
print "";
print "### WG/AmneziaWG autoload (begin)";
print "if [ \"$(nvram get amneziawg_enable 2>/dev/null)\" = \"1\" ]; then";
print "  [ -x /usr/bin/awg-client ] && /usr/bin/awg-client start || :";
print "fi";
print "### WG/AmneziaWG autoload (end)";
}' "$ROOT/romfs/etc/storage/started_script.sh" 2>/dev/null > "$ROOT/romfs/etc/storage/started_script.sh.new" || true
mv -f "$ROOT/romfs/etc/storage/started_script.sh.new" "$ROOT/romfs/etc/storage/started_script.sh" 2>/dev/null || true
chmod +x "$ROOT/romfs/etc/storage/started_script.sh" 2>/dev/null || true

# post_wan_script: up -> start, down -> stop (если включено)
awk '1; END{
print "";
print "### WG/AmneziaWG client on WAN (begin)";
print "case \"$1\" in";
print "  up)";
print "    if [ \"$(nvram get amneziawg_enable 2>/dev/null)\" = \"1\" ]; then";
print "      [ -x /usr/bin/awg-client ] && /usr/bin/awg-client start || :";
print "    fi";
print "    ;;";
print "  down)";
print "    [ -x /usr/bin/awg-client ] && /usr/bin/awg-client stop || :";
print "    ;;";
print "esac";
print "### WG/AmneziaWG client on WAN (end)";
}' "$ROOT/romfs/etc/storage/post_wan_script.sh" 2>/dev/null > "$ROOT/romfs/etc/storage/post_wan_script.sh.new" || true
mv -f "$ROOT/romfs/etc/storage/post_wan_script.sh.new" "$ROOT/romfs/etc/storage/post_wan_script.sh" 2>/dev/null || true
chmod +x "$ROOT/romfs/etc/storage/post_wan_script.sh" 2>/dev/null || true

# --------------------------------------
# 4) GUI страница: VPN → AmneziaWG
# --------------------------------------
cat > "$ROOT/romfs/www/Advanced_AmneziaWG.asp" <<'EOF'
<% nvram_set("amneziawg_enable", nvram_get("amneziawg_enable")=="1"?"1":"0"); %>
<% nvram_set("amneziawg_iface",  nvram_get("amneziawg_iface")!=""?nvram_get("amneziawg_iface"):"wg0"); %>
<html>
<head>
<meta http-equiv="Content-Type" content="text/html; charset=utf-8">
<title>AmneziaWG / WireGuard</title>
<link rel="stylesheet" type="text/css" href="style.css">
<script type="text/javascript" src="state.js"></script>
</head>
<body>
<div class="content">
  <div class="title">AmneziaWG / WireGuard</div>
  <form method="post" action="applyapp.cgi" onsubmit="return true;">
    <input type="hidden" name="current_page" value="Advanced_AmneziaWG.asp">
    <input type="hidden" name="next_page" value="Advanced_AmneziaWG.asp">
    <input type="hidden" name="sid_list" value="AmneziaWG;">
    <table class="formlist">
      <tr>
        <th>Включить</th>
        <td>
          <input type="checkbox" name="amneziawg_enable" value="1" <% if(nvram_get("amneziawg_enable")=="1") write("checked"); %> />
        </td>
      </tr>
      <tr>
        <th>Имя интерфейса</th>
        <td>
          <input type="text" name="amneziawg_iface" value="<% nvram_get("amneziawg_iface"); %>" />
          <div class="hint">Используется файл <code>/etc/storage/wireguard/&lt;iface&gt;.conf</code> (например <code>wg0.conf</code>).</div>
        </td>
      </tr>
      <tr>
        <th>Как пользоваться</th>
        <td>
          <div class="hint">
            1) Скопируйте ваш <code>client.sh</code> и конфиг(и) WG в <code>/etc/storage/wireguard</code>;<br/>
            2) Имя файла <code>&lt;iface&gt;.conf</code> задаёт интерфейс (например, <code>wg0.conf</code> → <code>wg0</code>);<br/>
            3) Нажмите Apply и/или перезапустите WAN.
          </div>
        </td>
      </tr>
    </table>
    <div class="apply_gen">
      <input class="button_gen" type="submit" name="action_mode" value="Apply" />
    </div>
  </form>
</div>
</body>
</html>
EOF

# Добавим пункт меню VPN → AmneziaWG (если дерево меню стандартное)
MENU="$ROOT/romfs/www/state.js"
if grep -q "menu_vpn" "$MENU" 2>/dev/null; then
  sed -i '/Advanced_Wireguard\.asp/ a\ \ \ \ menu_vpn.push(["AmneziaWG","Advanced_AmneziaWG.asp","amneziawg"]);' "$MENU" || true
fi
find "$ROOT/romfs/www" -name "*.dict" -print0 | while IFS= read -r -d '' D; do
  grep -q "AmneziaWG" "$D" || printf "\nAmneziaWG=AmneziaWG\n" >> "$D"
done

# --------------------------------------
# 5) obfs4proxy: сервис + GUI
# --------------------------------------
# Хуки запуска/остановки по nvram obfs4_enable/obfs4_args
awk '1; END{
print "";
print "### obfs4proxy service (begin)";
print "OBFS4_BIN=/usr/sbin/obfs4proxy";
print "OBFS4_PID=/var/run/obfs4proxy.pid";
print "start_obfs4(){";
print "  [ \"$(nvram get obfs4_enable 2>/dev/null)\" = \"1\" ] || return 0;";
print "  args=\"$(nvram get obfs4_args 2>/dev/null)\";";
print "  [ -x \"$OBFS4_BIN\" ] || return 0;";
print "  kill_obfs4; sleep 1;";
print "  nohup $OBFS4_BIN $args >/tmp/obfs4proxy.log 2>&1 & echo $! > $OBFS4_PID;";
print "}";
print "kill_obfs4(){";
print "  [ -f $OBFS4_PID ] && kill $(cat $OBFS4_PID) 2>/dev/null || true; rm -f $OBFS4_PID || :;";
print "}";
print "# start on boot if enabled";
print "if [ \"$(nvram get obfs4_enable 2>/dev/null)\" = \"1\" ]; then start_obfs4; fi";
print "### obfs4proxy service (end)";
}' "$ROOT/romfs/etc/storage/started_script.sh" 2>/dev/null > "$ROOT/romfs/etc/storage/started_script.sh.new" || true
mv -f "$ROOT/romfs/etc/storage/started_script.sh.new" "$ROOT/romfs/etc/storage/started_script.sh" 2>/dev/null || true

awk '1; END{
print "";
print "### obfs4proxy on WAN (begin)";
print "case \"$1\" in";
print "  up)";
print "    if [ \"$(nvram get obfs4_enable 2>/dev/null)\" = \"1\" ]; then";
print "      start_obfs4";
print "    fi";
print "    ;;";
print "  down)";
print "    kill_obfs4";
print "    ;;";
print "esac";
print "### obfs4proxy on WAN (end)";
}' "$ROOT/romfs/etc/storage/post_wan_script.sh" 2>/dev/null > "$ROOT/romfs/etc/storage/post_wan_script.sh.new" || true
mv -f "$ROOT/romfs/etc/storage/post_wan_script.sh.new" "$ROOT/romfs/etc/storage/post_wan_script.sh" 2>/dev/null || true

# GUI страница: Services → obfs4proxy
cat > "$ROOT/romfs/www/Advanced_obfs4.asp" <<'EOF'
<% nvram_set("obfs4_enable", nvram_get("obfs4_enable")=="1"?"1":"0"); %>
<% nvram_set("obfs4_args",   nvram_get("obfs4_args")); %>
<html>
<head>
<meta http-equiv="Content-Type" content="text/html; charset=utf-8">
<title>obfs4proxy</title>
<link rel="stylesheet" type="text/css" href="style.css">
<script type="text/javascript" src="state.js"></script>
</head>
<body>
<div class="content">
  <div class="title">obfs4proxy</div>
  <form method="post" action="applyapp.cgi" onsubmit="return true;">
    <input type="hidden" name="current_page" value="Advanced_obfs4.asp">
    <input type="hidden" name="next_page" value="Advanced_obfs4.asp">
    <input type="hidden" name="sid_list" value="obfs4;">
    <table class="formlist">
      <tr>
        <th>Включить</th>
        <td>
          <input type="checkbox" name="obfs4_enable" value="1" <% if(nvram_get("obfs4_enable")=="1") write("checked"); %> />
        </td>
      </tr>
      <tr>
        <th>Параметры запуска</th>
        <td>
          <input style="width:100%" type="text" name="obfs4_args" value="<% nvram_get("obfs4_args"); %>" />
          <div class="hint">
            Здесь укажите командную строку для <code>/usr/sbin/obfs4proxy</code> (например, режим клиента/порт/target).<br/>
            Лог: <code>/tmp/obfs4proxy.log</code>.
          </div>
        </td>
      </tr>
    </table>
    <div class="apply_gen">
      <input class="button_gen" type="submit" name="action_mode" value="Apply" />
    </div>
  </form>
</div>
</body>
</html>
EOF

# Включим пункт меню Services → obfs4proxy
if grep -q "menu_services" "$MENU" 2>/dev/null; then
  sed -i '/Advanced_SOCKS\.asp/ a\ \ \ \ menu_services.push(["obfs4proxy","Advanced_obfs4.asp","obfs4"]);' "$MENU" || true
fi
find "$ROOT/romfs/www" -name "*.dict" -print0 | while IFS= read -r -d '' D; do
  grep -q "obfs4proxy" "$D" || printf "\nobfs4proxy=obfs4proxy\n" >> "$D"
done

echo ">>> GUI shims added: AmneziaWG/WG + obfs4proxy"
