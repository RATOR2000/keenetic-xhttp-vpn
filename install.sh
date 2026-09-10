#!/bin/sh
# Keenetic Extra / Entware mipselsf-k3.4
# VLESS + XHTTP + TLS + TUN
set -eu
BASE=/opt/kvpn
CONF="$BASE/config.json"
LOG="$BASE/xray.log"
PID="$BASE/xray.pid"
WEBPID="$BASE/web.pid"
PORT=18080
SERVER=cdn.mytestlanding.shop
SNI=cdn.mytestlanding.shop
VPORT=443
PATH_X=/videotest/download
say(){ printf '%s\n' "$*"; }
err(){ say "ERROR: $*" >&2; exit 1; }
UUID="${1:-${VLESS_UUID:-}}"
case "$UUID" in ????????-????-????-????-????????????) ;; *) err "VLESS UUID was not supplied. Run: sh /tmp/kvpn-install.sh YOUR-UUID";; esac
[ "$(id -u)" = 0 ] || err "Run as root."
command -v opkg >/dev/null 2>&1 || err "Entware/opkg not found."
[ -f /opt/etc/entware_release ] || err "/opt/etc/entware_release not found."
opkg print-architecture | awk '$2=="mipsel-3.4"{ok=1} END{exit ok?0:1}' || err "This installer requires Entware mipsel-3.4."
[ -c /dev/net/tun ] || err "/dev/net/tun is missing."
say "[1/7] Installing dependencies..."
opkg update >/dev/null 2>&1 || err "opkg update failed."
opkg install xray-core busybox >/dev/null 2>&1 || err "Could not install xray-core/busybox."
XRAY="$(command -v xray 2>/dev/null || true)"
if [ -z "$XRAY" ]; then for p in /opt/sbin/xray /opt/bin/xray /usr/bin/xray /usr/sbin/xray; do [ -x "$p" ] && { XRAY="$p"; break; }; done; fi
[ -x "$XRAY" ] || err "Xray binary not found."
say "Xray: $($XRAY version 2>/dev/null | head -1 || true)"
mkdir -p "$BASE/www/cgi-bin"
say "[2/7] Writing Xray configuration..."
cat > "$CONF" <<EOF
{
  "log":{"loglevel":"warning","access":"$BASE/access.log","error":"$LOG"},
  "inbounds":[{"tag":"tun-in","protocol":"tun","settings":{"name":"kvpn0","mtu":1400,"gateway":["172.19.0.1/30"]}}],
  "outbounds":[
    {"tag":"proxy","protocol":"vless","settings":{"vnext":[{"address":"$SERVER","port":$VPORT,"users":[{"id":"$UUID","encryption":"none"}]}]},"streamSettings":{"network":"xhttp","security":"tls","tlsSettings":{"serverName":"$SNI","allowInsecure":false,"alpn":["h2"]},"xhttpSettings":{"host":"","path":"$PATH_X","mode":"packet-up","extra":{"uplinkHTTPMethod":"GET","xPaddingBytes":"100-1000","xPaddingHeader":"X-Cache","xPaddingKey":"_dc","xPaddingMethod":"tokenish","xPaddingObfsMode":true,"xPaddingPlacement":"queryInHeader","xmux":{"cMaxReuseTimes":0,"hKeepAlivePeriod":0,"hMaxRequestTimes":"100-200","hMaxReusableSecs":"300-600","maxConcurrency":0,"maxConnections":2}}}}},
    {"tag":"direct","protocol":"freedom"},
    {"tag":"block","protocol":"blackhole"}
  ],
  "routing":{"domainStrategy":"AsIs","rules":[{"type":"field","ip":["10.0.0.0/8","100.64.0.0/10","127.0.0.0/8","169.254.0.0/16","172.16.0.0/12","192.0.0.0/24","192.0.2.0/24","192.168.0.0/16","198.18.0.0/15","198.51.100.0/24","203.0.113.0/24","224.0.0.0/4","240.0.0.0/4"],"outboundTag":"direct"}]}
}
EOF
say "[3/7] Validating configuration..."
"$XRAY" run -test -config "$CONF" >/tmp/kvpn-test.txt 2>&1 || { cat /tmp/kvpn-test.txt; err "Xray rejected the configuration."; }
say "[4/7] Installing VPN controller..."
cat > "$BASE/kvpn" <<'EOF'
#!/bin/sh
BASE=/opt/kvpn
CONF="$BASE/config.json"
PID="$BASE/xray.pid"
LOG="$BASE/xray.log"
SERVER=cdn.mytestlanding.shop
find_xray(){ X="$(command -v xray 2>/dev/null || true)"; if [ -n "$X" ] && [ -x "$X" ]; then printf '%s\n' "$X"; return 0; fi; for p in /opt/sbin/xray /opt/bin/xray /usr/bin/xray /usr/sbin/xray; do [ -x "$p" ] && { printf '%s\n' "$p"; return 0; }; done; return 1; }
wan_if(){ ip route show default 2>/dev/null | awk 'NR==1{print $5;exit}'; }
server_ip(){ getent ahostsv4 "$SERVER" 2>/dev/null | awk 'NR==1{print $1;exit}'; }
add_routes(){ WAN=$(wan_if); [ -n "$WAN" ] || { echo "No default WAN interface."; return 1; }; SIP=$(server_ip); [ -n "$SIP" ] || { echo "Cannot resolve $SERVER."; return 1; }; GW=$(ip route show default 2>/dev/null | awk 'NR==1{for(i=1;i<=NF;i++)if($i=="via"){print $(i+1);exit}}'); if [ -n "$GW" ]; then ip route replace "$SIP/32" via "$GW" dev "$WAN" 2>/dev/null || ip route replace "$SIP/32" dev "$WAN"; else ip route replace "$SIP/32" dev "$WAN" 2>/dev/null || true; fi; ip route replace 0.0.0.0/1 dev kvpn0; ip route replace 128.0.0.0/1 dev kvpn0; }
del_routes(){ ip route del 0.0.0.0/1 dev kvpn0 2>/dev/null || true; ip route del 128.0.0.0/1 dev kvpn0 2>/dev/null || true; }
start(){ if [ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null; then echo "VPN already running (PID $(cat "$PID"))."; return 0; fi; XRAY=$(find_xray) || { echo "Xray binary not found."; return 1; }; rm -f "$PID"; "$XRAY" run -config "$CONF" >>"$LOG" 2>&1 & echo $! >"$PID"; sleep 2; if ! kill -0 "$(cat "$PID")" 2>/dev/null; then echo "VPN failed to start:"; tail -40 "$LOG" 2>/dev/null || true; rm -f "$PID"; return 1; fi; sleep 1; ip link show kvpn0 >/dev/null 2>&1 || { echo "kvpn0 was not created."; stop; return 1; }; add_routes || { stop; return 1; }; echo "VPN started (PID $(cat "$PID"))."; }
stop(){ del_routes; if [ -f "$PID" ]; then kill "$(cat "$PID")" 2>/dev/null || true; sleep 1; kill -9 "$(cat "$PID")" 2>/dev/null || true; rm -f "$PID"; fi; echo "VPN stopped."; }
status(){ if [ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null; then echo "RUNNING (PID $(cat "$PID"))."; ip -brief addr show kvpn0 2>/dev/null || true; ip route show | grep -E '(^0\.0\.0\.0/1|^128\.0\.0\.0/1)' 2>/dev/null || true; else echo "STOPPED."; return 1; fi; }
restart(){ stop; sleep 1; start; }
log(){ tail -100 "$LOG" 2>/dev/null || echo "No log yet."; }
case "${1:-status}" in start) start;; stop) stop;; restart) restart;; status) status;; log) log;; *) echo "Usage: $0 {start|stop|restart|status|log}"; exit 2;; esac
EOF
chmod +x "$BASE/kvpn"
say "[5/7] Installing web panel..."
cat > "$BASE/www/index.html" <<'EOF'
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Keenetic VPN</title><style>body{font-family:Arial,sans-serif;background:#eef7fb;margin:0;color:#123}main{max-width:760px;margin:30px auto;padding:20px}.card{background:#fff;border-radius:18px;padding:22px;margin:12px 0;box-shadow:0 4px 20px #0001}.btn{border:0;border-radius:12px;padding:11px 16px;margin:5px;cursor:pointer;background:#dff2ff}pre{white-space:pre-wrap;background:#0c1720;color:#d8f3ff;border-radius:12px;padding:15px;max-height:350px;overflow:auto}.ok{color:#098b55}.bad{color:#c33}</style></head><body><main><div class="card"><h1>🌐 Keenetic VPN</h1><div id="status">Loading...</div><button class="btn" onclick="act('start')">Start</button><button class="btn" onclick="act('restart')">Restart</button><button class="btn" onclick="act('stop')">Stop</button><button class="btn" onclick="load()">Refresh</button></div><div class="card"><b>VLESS + XHTTP + TLS</b><p>Server: cdn.mytestlanding.shop:443<br>SNI: cdn.mytestlanding.shop<br>Path: /videotest/download<br>TUN: kvpn0</p><small>UUID is stored only in /opt/kvpn/config.json.</small></div><div class="card"><b>Log</b><pre id="log">Loading...</pre></div></main><script>async function api(x){return (await fetch('/cgi-bin/kvpn.cgi?'+x,{cache:'no-store'})).text()}async function load(){document.getElementById('status').innerHTML=await api('status=1');document.getElementById('log').textContent=await api('log=1')}async function act(x){await api(x+'=1');setTimeout(load,800)}load();setInterval(load,5000)</script></body></html>
EOF
cat > "$BASE/www/cgi-bin/kvpn.cgi" <<'EOF'
#!/bin/sh
echo 'Content-Type: text/html; charset=utf-8'
echo
case "$QUERY_STRING" in
 *status=1*) if /opt/kvpn/kvpn status >/tmp/kvpn-status 2>&1; then printf '<span class="ok">● VPN process is RUNNING</span><pre>'; else printf '<span class="bad">● VPN process is STOPPED</span><pre>'; fi; sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g' /tmp/kvpn-status; printf '</pre>';;
 *log=1*) /opt/kvpn/kvpn log;; *start=1*) /opt/kvpn/kvpn start;; *stop=1*) /opt/kvpn/kvpn stop;; *restart=1*) /opt/kvpn/kvpn restart;; *) echo 'Keenetic VPN';; esac
EOF
chmod +x "$BASE/www/cgi-bin/kvpn.cgi"
cat > "$BASE/start-web.sh" <<'EOF'
#!/bin/sh
BASE=/opt/kvpn
PID=$BASE/web.pid
[ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null && exit 0
HTTPD=/opt/bin/busybox
[ -x "$HTTPD" ] || HTTPD=/bin/busybox
"$HTTPD" httpd -f -p 0.0.0.0:18080 -h "$BASE/www" >/dev/null 2>&1 & echo $! >"$PID"
sleep 1
kill -0 "$(cat "$PID")" 2>/dev/null || { rm -f "$PID"; exit 1; }
EOF
chmod +x "$BASE/start-web.sh"
cat > /opt/etc/init.d/S98kvpn-web <<'EOF'
#!/bin/sh
case "$1" in start) /opt/kvpn/start-web.sh;; stop) [ -f /opt/kvpn/web.pid ] && kill "$(cat /opt/kvpn/web.pid)" 2>/dev/null || true; rm -f /opt/kvpn/web.pid;; restart) "$0" stop; "$0" start;; esac
EOF
cat > /opt/etc/init.d/S99kvpn <<'EOF'
#!/bin/sh
case "$1" in start) /opt/kvpn/kvpn start >/dev/null 2>&1;; stop) /opt/kvpn/kvpn stop >/dev/null 2>&1;; restart) /opt/kvpn/kvpn restart >/dev/null 2>&1;; esac
EOF
chmod +x /opt/etc/init.d/S98kvpn-web /opt/etc/init.d/S99kvpn
say "[6/7] Starting VPN..."
/opt/kvpn/kvpn stop >/dev/null 2>&1 || true
/opt/kvpn/kvpn start || err "VPN could not be started. Run: /opt/kvpn/kvpn log"
say "[7/7] Starting web panel..."
/opt/kvpn/start-web.sh || err "Web panel failed to start."
ROUTER_IP="$(ip -4 addr show 2>/dev/null | awk '/inet / && $NF!="lo" {sub(/\/.*$/, "", $2); if($2 ~ /^192\.168\./){print $2; exit}}')"
[ -n "$ROUTER_IP" ] || ROUTER_IP='<router-ip>'
say "KVPN installed successfully."
say "Web panel: http://$ROUTER_IP:$PORT/"
say "CLI: /opt/kvpn/kvpn status"
say "Logs: /opt/kvpn/kvpn log"
say "Config: $CONF"
