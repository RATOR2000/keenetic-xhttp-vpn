#!/bin/sh
# Keenetic Extra / Entware mipselsf-k3.4
# VLESS + XHTTP + TLS + TUN
# Xray is installed from Entware.
set -eu

BASE=/opt/kvpn
CONF="$BASE/config.json"
LOG="$BASE/xray.log"
PID="$BASE/xray.pid"
WEBPID="$BASE/web.pid"
PORT=18080

UUID=""
if [ -r /dev/tty ]; then
  printf "Enter VLESS UUID: " > /dev/tty
  IFS= read -r UUID < /dev/tty || true
fi
case "$UUID" in
  ????????-????-????-????-????????????) ;;
  *) echo "ERROR: invalid or empty VLESS UUID."; exit 1 ;;
esac
SERVER="cdn.mytestlanding.shop"
SNI="cdn.mytestlanding.shop"
VPORT=443
PATH_X="/videotest/download"

mkdir -p "$BASE/www" "$BASE/run"

echo "[1/7] Checking Entware..."
command -v opkg >/dev/null 2>&1 || { echo "ERROR: opkg not found. Entware is not available."; exit 1; }
[ -f /opt/etc/entware_release ] || { echo "ERROR: /opt/etc/entware_release not found."; exit 1; }

ARCH="$(opkg print-architecture | awk '$2=="mipsel-3.4"{print $2; exit}')"
[ "$ARCH" = "mipsel-3.4" ] || { echo "ERROR: expected mipsel-3.4 Entware."; exit 1; }

echo "[2/7] Checking TUN..."
[ -c /dev/net/tun ] || { echo "ERROR: /dev/net/tun is missing."; exit 1; }

echo "[3/7] Installing Xray and web helper..."
opkg update >/dev/null
opkg install xray-core busybox >/dev/null 2>&1 || opkg install xray-core

XRAY="$(command -v xray || true)"
[ -x "$XRAY" ] || XRAY="/opt/bin/xray"
[ -x "$XRAY" ] || { echo "ERROR: xray binary not found after installation."; exit 1; }

VER="$("$XRAY" version 2>/dev/null | head -1 || true)"
echo "       $VER"

echo "[4/7] Writing Xray configuration..."
cat > "$CONF" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "$BASE/access.log",
    "error": "$LOG"
  },
  "inbounds": [
    {
      "tag": "tun-in",
      "protocol": "tun",
      "settings": {
        "name": "kvpn0",
        "mtu": 1400,
        "gateway": ["172.19.0.1/30"]
      }
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "$SERVER",
            "port": $VPORT,
            "users": [
              {
                "id": "$UUID",
                "encryption": "none"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "tlsSettings": {
          "serverName": "$SNI",
          "allowInsecure": false,
          "alpn": ["h2"]
        },
        "xhttpSettings": {
          "host": "",
          "path": "$PATH_X",
          "mode": "packet-up",
          "extra": {
            "uplinkHTTPMethod": "GET",
            "xPaddingBytes": "100-1000",
            "xPaddingHeader": "X-Cache",
            "xPaddingKey": "_dc",
            "xPaddingMethod": "tokenish",
            "xPaddingObfsMode": true,
            "xPaddingPlacement": "queryInHeader",
            "xmux": {
              "cMaxReuseTimes": 0,
              "hKeepAlivePeriod": 0,
              "hMaxRequestTimes": "100-200",
              "hMaxReusableSecs": "300-600",
              "maxConcurrency": 0,
              "maxConnections": 2
            }
          }
        }
      }
    },
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "ip": ["127.0.0.0/8", "169.254.0.0/16", "224.0.0.0/4", "240.0.0.0/4"],
        "outboundTag": "direct"
      }
    ]
  }
}
EOF

echo "[5/7] Validating configuration..."
"$XRAY" run -test -config "$CONF" >/tmp/kvpn-test.txt 2>&1 || {
  cat /tmp/kvpn-test.txt
  echo "ERROR: Xray rejected the configuration."
  exit 1
}

cat > "$BASE/kvpn" <<'EOF'
#!/bin/sh
BASE=/opt/kvpn
CONF=$BASE/config.json
PID=$BASE/xray.pid
LOG=$BASE/xray.log
XRAY=/opt/bin/xray
SERVER=cdn.mytestlanding.shop

get_wan() {
  ip route show default 2>/dev/null | awk 'NR==1 {print $5; exit}'
}
get_server_ip() {
  getent ahostsv4 "$SERVER" 2>/dev/null | awk 'NR==1{print $1; exit}'
}
add_routes() {
  WAN="$(get_wan)"
  [ -n "$WAN" ] || { echo "No default WAN interface found."; return 1; }
  SIP="$(get_server_ip)"
  [ -n "$SIP" ] || { echo "Could not resolve $SERVER."; return 1; }
  GW="$(ip route show default 2>/dev/null | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')"

  if [ -n "$GW" ]; then
    ip route replace "$SIP/32" via "$GW" dev "$WAN" 2>/dev/null || ip route replace "$SIP/32" dev "$WAN"
  else
    ip route replace "$SIP/32" dev "$WAN" 2>/dev/null || true
  fi

  ip route replace 0.0.0.0/1 dev kvpn0
  ip route replace 128.0.0.0/1 dev kvpn0
}
del_routes() {
  ip route del 0.0.0.0/1 dev kvpn0 2>/dev/null || true
  ip route del 128.0.0.0/1 dev kvpn0 2>/dev/null || true
}
start() {
  if [ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null; then
    echo "VPN already running (PID $(cat "$PID"))."
    return 0
  fi
  rm -f "$PID"
  "$XRAY" run -config "$CONF" >>"$LOG" 2>&1 &
  echo $! > "$PID"
  sleep 2
  if ! kill -0 "$(cat "$PID")" 2>/dev/null; then
    echo "VPN failed to start. Last log:"
    tail -30 "$LOG" 2>/dev/null || true
    rm -f "$PID"
    return 1
  fi
  sleep 1
  if ! ip link show kvpn0 >/dev/null 2>&1; then
    echo "Xray started but kvpn0 was not created."
    stop
    return 1
  fi
  add_routes || { stop; return 1; }
  echo "VPN started (PID $(cat "$PID"))."
}
stop() {
  del_routes
  if [ -f "$PID" ]; then
    kill "$(cat "$PID")" 2>/dev/null || true
    sleep 1
    kill -9 "$(cat "$PID")" 2>/dev/null || true
    rm -f "$PID"
  fi
  echo "VPN stopped."
}
status() {
  if [ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null; then
    echo "CONNECTED/PROCESS RUNNING (PID $(cat "$PID"))."
    ip -brief addr show kvpn0 2>/dev/null || true
    echo "Routes:"
    ip route show | grep -E '(^0\.0\.0\.0/1|^128\.0\.0\.0/1)' 2>/dev/null || true
  else
    echo "STOPPED."
    return 1
  fi
}
restart() { stop; sleep 1; start; }
log() { tail -80 "$LOG" 2>/dev/null || echo "No log yet."; }
case "${1:-status}" in
  start) start ;;
  stop) stop ;;
  restart) restart ;;
  status) status ;;
  log) log ;;
  *) echo "Usage: $0 {start|stop|restart|status|log}"; exit 2 ;;
esac
EOF
chmod +x "$BASE/kvpn"

cat > "$BASE/www/index.html" <<'EOF'
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Keenetic VPN</title><style>
body{font-family:Arial,sans-serif;background:#eef7fb;margin:0;color:#123}
main{max-width:760px;margin:30px auto;padding:20px}.card{background:white;border-radius:18px;padding:22px;margin:12px 0;box-shadow:0 4px 20px #0001}
h1{margin-top:0}.ok{color:#098b55}.bad{color:#c33}.btn{border:0;border-radius:12px;padding:11px 16px;margin:5px;cursor:pointer;background:#dff2ff}
pre{white-space:pre-wrap;background:#0c1720;color:#d8f3ff;border-radius:12px;padding:15px;max-height:350px;overflow:auto}
small{color:#667}
</style></head><body><main>
<div class="card"><h1>🌐 Keenetic VPN</h1><div id="status">Loading…</div>
<p><button class="btn" onclick="act('start')">Start</button><button class="btn" onclick="act('restart')">Restart</button><button class="btn" onclick="act('stop')">Stop</button><button class="btn" onclick="load()">Refresh</button></p></div>
<div class="card"><b>Connection</b><p>VLESS + XHTTP + TLS</p><p>Server: cdn.mytestlanding.shop:443<br>SNI: cdn.mytestlanding.shop<br>Path: /videotest/download<br>TUN: kvpn0</p><small>UUID is stored only on the router in /opt/kvpn/config.json.</small></div>
<div class="card"><b>Log</b><pre id="log">Loading…</pre></div>
</main><script>
async function api(x){let r=await fetch('/cgi-bin/kvpn.cgi?'+x,{cache:'no-store'});return r.text()}
async function load(){document.getElementById('status').innerHTML=await api('status=1');document.getElementById('log').textContent=await api('log=1')}
async function act(x){await api(x+'=1');setTimeout(load,700)} load();setInterval(load,5000)
</script></body></html>
EOF

mkdir -p "$BASE/www/cgi-bin"
cat > "$BASE/www/cgi-bin/kvpn.cgi" <<'EOF'
#!/bin/sh
echo "Content-Type: text/html; charset=utf-8"
echo
case "$QUERY_STRING" in
  *status=1*)
    if /opt/kvpn/kvpn status >/tmp/kvpn-status 2>&1; then
      printf '<span class="ok">● VPN process is RUNNING</span><pre>'
      sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g' /tmp/kvpn-status
      printf '</pre>'
    else
      printf '<span class="bad">● VPN process is STOPPED</span><pre>'
      sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g' /tmp/kvpn-status
      printf '</pre>'
    fi
    ;;
  *log=1*) /opt/kvpn/kvpn log ;;
  *start=1*) /opt/kvpn/kvpn start ;;
  *stop=1*) /opt/kvpn/kvpn stop ;;
  *restart=1*) /opt/kvpn/kvpn restart ;;
  *) echo "Keenetic VPN" ;;
esac
EOF
chmod +x "$BASE/www/cgi-bin/kvpn.cgi"

cat > /opt/etc/init.d/S99kvpn <<'EOF'
#!/bin/sh
case "$1" in
  start) /opt/kvpn/kvpn start >/dev/null 2>&1 ;;
  stop) /opt/kvpn/kvpn stop >/dev/null 2>&1 ;;
  restart) /opt/kvpn/kvpn restart >/dev/null 2>&1 ;;
esac
EOF
chmod +x /opt/etc/init.d/S99kvpn

cat > "$BASE/start-web.sh" <<'EOF'
#!/bin/sh
BASE=/opt/kvpn
PID=$BASE/web.pid
[ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null && exit 0
/opt/bin/busybox httpd -f -p 0.0.0.0:18080 -h "$BASE/www" >/dev/null 2>&1 &
echo $! > "$PID"
EOF
chmod +x "$BASE/start-web.sh"

cat > /opt/etc/init.d/S98kvpn-web <<'EOF'
#!/bin/sh
case "$1" in
  start) /opt/kvpn/start-web.sh ;;
  stop) [ -f /opt/kvpn/web.pid ] && kill "$(cat /opt/kvpn/web.pid)" 2>/dev/null || true; rm -f /opt/kvpn/web.pid ;;
  restart) "$0" stop; "$0" start ;;
esac
EOF
chmod +x /opt/etc/init.d/S98kvpn-web

echo "[6/7] Starting VPN..."
/opt/kvpn/kvpn stop >/dev/null 2>&1 || true
/opt/kvpn/kvpn start

echo "[7/7] Starting web panel..."
/opt/kvpn/start-web.sh

echo
echo "=============================================="
echo " KVPN installed."
echo " Web panel: http://<router-ip>:$PORT/"
echo " CLI:       /opt/kvpn/kvpn status"
echo " Logs:      /opt/kvpn/kvpn log"
echo " Config:    $CONF"
echo "=============================================="
echo
echo "IMPORTANT:"
echo "This configuration uses manual split-default routes through Xray TUN."
echo "If LAN internet breaks, run: /opt/kvpn/kvpn stop"
echo "The original Keenetic WAN configuration is not modified."
