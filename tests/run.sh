#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Test suite for socks5-proxy
#
#   Run with:  bash tests/run.sh
#
# Covers: bash syntax, embedded Python, bash helper functions, the SOCKS5
# protocol (CONNECT, UDP ASSOCIATE, IPv6, auth, throttling), the CLI, and a
# real start/stop cycle. Prints PASS/FAIL per test and exits non-zero if any
# test fails.
#
# Uses a temporary PREFIX so it never touches the real Termux config.
# =============================================================================

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/socks5-proxy"

PASS=0
FAIL=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok() { PASS=$((PASS + 1)); echo "PASS - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; }
chk() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

strip_colors() { sed 's/\x1b\[[0-9;]*m//g'; }

# ---------------------------------------------------------------------------
echo "=== 1. bash syntax ==="
bash -n "$SCRIPT" && ok "bash -n" || bad "bash -n"

# ---------------------------------------------------------------------------
echo "=== 2. embedded Python compiles ==="
sed -n '/<< .EOL.$/,/^EOL$/p' "$SCRIPT" | sed '1d;$d' > "$TMP/server.py"
python3 -m py_compile "$TMP/server.py" && ok "py_compile" || bad "py_compile"

# ---------------------------------------------------------------------------
echo "=== 3. bash helper functions ==="
export PREFIX="$TMP/prefix"
export CONFIG_DIR="$PREFIX/etc/socks5-proxy"
export CONFIG_FILE="$CONFIG_DIR/config"
mkdir -p "$CONFIG_DIR"
# Source only the function definitions (everything before the CLI section)
sed -n '1,/^# Command-line interface$/p' "$SCRIPT" | sed '$d' > "$TMP/funcs.sh"
# shellcheck source=/dev/null
source "$TMP/funcs.sh"

chk "port 1080 valid"        'is_valid_port 1080'
chk "port 0 invalid"         '! is_valid_port 0'
chk "port 65536 invalid"     '! is_valid_port 65536'
chk "port abc invalid"       '! is_valid_port abc'
chk "ip 192.168.1.1 valid"   'is_valid_ip 192.168.1.1'
chk "ip 256.1.1.1 invalid"   '! is_valid_ip 256.1.1.1'
chk "ip leading-zero ok"     'is_valid_ip 192.168.08.1'
chk "ip :: valid"            'is_valid_ip ::'
chk "ip ::1 valid"           'is_valid_ip ::1'
chk "ip 2001:db8::1 valid"   'is_valid_ip 2001:db8::1'
chk "ip garbage invalid"     '! is_valid_ip garbage'
chk "ip 1.2.3 invalid"       '! is_valid_ip 1.2.3'

save_config PROXY_PORT 2020
chk "save_config writes key" \
    '[ "$(grep -c "^PROXY_PORT=2020$" "$CONFIG_FILE")" = "1" ]'
save_config PROXY_IP 127.0.0.1
chk "save_config merges keys" \
    '[ "$(grep -c "^PROXY_PORT=2020$" "$CONFIG_FILE")" = "1" ] && [ "$(grep -c "^PROXY_IP=127.0.0.1$" "$CONFIG_FILE")" = "1" ]'
chk "config file is 600"     '[ "$(stat -c %a "$CONFIG_FILE")" = "600" ]'
remove_config PROXY_PORT
chk "remove_config deletes key" '! grep -q "^PROXY_PORT=" "$CONFIG_FILE"'
chk "remove_config keeps others" \
    '[ "$(grep -c "^PROXY_IP=127.0.0.1$" "$CONFIG_FILE")" = "1" ]'

# Tampered config must be parsed, never executed
printf 'PROXY_PORT=9090; echo HACKED > %s/hacked.txt\n' "$TMP" > "$CONFIG_FILE"
chk "tampered config not executed" \
    '! grep -q HACKED "$TMP/hacked.txt" 2>/dev/null'
chk "tampered config parsed literally" \
    '[ "$(get_stored_port)" = "9090; echo HACKED > '"$TMP"'/hacked.txt" ]'

# ---------------------------------------------------------------------------
echo "=== 4. SOCKS5 protocol tests ==="
PYPROXY="python3 $TMP/server.py"
export SOCKS5_USER=""
export SOCKS5_PASS=""
SOCKS5_STATS="$CONFIG_DIR/stats" python3 - "$TMP" <<'PYEOF'
import os, socket, struct, subprocess, sys, threading, time

tmp = sys.argv[1]
pass_, fail = 0, 0
def chk(n, c):
    global pass_, fail
    if c: pass_ += 1; print("PASS - %s" % n)
    else: fail += 1; print("FAIL - %s" % n)

# --- TCP echo sink -------------------------------------------------------
ts = socket.socket(); ts.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
ts.bind(('127.0.0.1', 0)); ts.listen(5)
tport = ts.getsockname()[1]
def tcp_echo(c):
    while True:
        d = c.recv(65536)
        if not d: break
        c.sendall(d)
    c.close()
def tcp_loop():
    while True:
        try: c, _ = ts.accept()
        except OSError: return
        threading.Thread(target=tcp_echo, args=(c,), daemon=True).start()
threading.Thread(target=tcp_loop, daemon=True).start()

# --- UDP echo sink -------------------------------------------------------
us = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); us.bind(('127.0.0.1', 0))
us.settimeout(0.2); uport = us.getsockname()[1]
def udp_loop():
    while True:
        try: d, a = us.recvfrom(4096)
        except socket.timeout: continue
        except OSError: return
        us.sendto(d, a)
threading.Thread(target=udp_loop, daemon=True).start()

# --- start the proxy ------------------------------------------------------
srv_port = 19300
p = subprocess.Popen([sys.executable, os.path.join(tmp, 'server.py'),
                      str(srv_port), '127.0.0.1'],
                     stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
time.sleep(1)
chk("proxy starts", p.poll() is None)

def connect():
    s = socket.create_connection(('127.0.0.1', srv_port), timeout=5)
    s.sendall(b'\x05\x01\x00')
    assert s.recv(2) == b'\x05\x00'
    return s

# CONNECT (IPv4)
s = connect()
s.sendall(b'\x05\x01\x00\x01' + socket.inet_aton('127.0.0.1') + struct.pack('>H', tport))
chk("CONNECT reply 0x00", s.recv(10)[1] == 0x00)
s.sendall(b'hello-connect')
chk("CONNECT relay echo", s.recv(13) == b'hello-connect')
s.close()

# BIND rejected
s = connect()
s.sendall(b'\x05\x02\x00\x01' + socket.inet_aton('127.0.0.1') + struct.pack('>H', 1))
chk("BIND rejected 0x07", s.recv(10)[1] == 0x07)
s.close()

# UDP ASSOCIATE roundtrip
s = connect()
s.sendall(b'\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00')
resp = s.recv(10)
chk("UDP ASSOCIATE reply 0x00", resp[1] == 0x00)
bnd_port = struct.unpack('>H', resp[8:10])[0]
chk("UDP relay port = proxy port", bnd_port == srv_port)
c = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); c.settimeout(3)
hdr = b'\x00\x00\x00\x01' + socket.inet_aton('127.0.0.1') + struct.pack('>H', uport)
msg = b'udp-payload'
c.sendto(hdr + msg, ('127.0.0.1', bnd_port))
rep, _ = c.recvfrom(4096)
chk("UDP relay echo", rep[10:] == msg)
s.close(); c.close()

p.terminate(); p.wait(); ts.close(); us.close()
print("RESULT: %d passed, %d failed" % (pass_, fail))
sys.exit(1 if fail else 0)
PYEOF
[ $? -eq 0 ] && ok "protocol suite passed" || bad "protocol suite failed"

# ---------------------------------------------------------------------------
echo "=== 5. IPv6 listener (skipped if no IPv6 loopback) ==="
SOCKS5_STATS="$CONFIG_DIR/stats" python3 - "$TMP" <<'PYEOF'
import os, socket, struct, subprocess, sys, time
tmp = sys.argv[1]
def has_v6():
    try:
        s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
        s.bind(('::1', 0)); s.close(); return True
    except OSError: return False
if not has_v6():
    print("SKIP - no IPv6 loopback"); sys.exit(0)
pass_, fail = 0, 0
def chk(n, c):
    global pass_, fail
    if c: pass_ += 1; print("PASS - %s" % n)
    else: fail += 1; print("FAIL - %s" % n)
srv = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(('::1', 0)); srv.listen(5); tport = srv.getsockname()[1]
def echo(c):
    while True:
        d = c.recv(65536)
        if not d: break
        c.sendall(d)
    c.close()
def loop():
    while True:
        try: c, _ = srv.accept()
        except OSError: return
        threading.Thread(target=echo, args=(c,), daemon=True).start()
import threading
threading.Thread(target=loop, daemon=True).start()
p = subprocess.Popen([sys.executable, os.path.join(tmp, 'server.py'),
                      '19301', '::1'], stdout=subprocess.DEVNULL,
                     stderr=subprocess.PIPE)
time.sleep(1)
chk("IPv6 proxy starts", p.poll() is None)
s = socket.create_connection(('::1', 19301), timeout=5)
s.sendall(b'\x05\x01\x00'); chk("IPv6 handshake", s.recv(2) == b'\x05\x00')
s.sendall(b'\x05\x01\x00\x04' + socket.inet_pton(socket.AF_INET6, '::1')
          + struct.pack('>H', tport))
chk("IPv6 CONNECT reply 0x00", s.recv(10)[1] == 0x00)
s.sendall(b'v6-echo'); chk("IPv6 relay echo", s.recv(7) == b'v6-echo')
s.close(); p.terminate(); p.wait()
print("RESULT: %d passed, %d failed" % (pass_, fail))
sys.exit(1 if fail else 0)
PYEOF
[ $? -eq 0 ] && ok "IPv6 suite passed" || bad "IPv6 suite failed"

# ---------------------------------------------------------------------------
echo "=== 6. auth + throttle ==="
SOCKS5_STATS="$CONFIG_DIR/stats" python3 - "$TMP" <<'PYEOF'
import os, socket, subprocess, sys, time
tmp = sys.argv[1]
pass_, fail = 0, 0
def chk(n, c):
    global pass_, fail
    if c: pass_ += 1; print("PASS - %s" % n)
    else: fail += 1; print("FAIL - %s" % n)
env = dict(os.environ)
env.update({'SOCKS5_USER': 'alice', 'SOCKS5_PASS': 'hunter2'})
p = subprocess.Popen([sys.executable, os.path.join(tmp, 'server.py'),
                      '19302', '127.0.0.1'], env=env,
                     stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
time.sleep(1)
def login(user, pw):
    s = socket.create_connection(('127.0.0.1', 19302), timeout=6)
    s.sendall(b'\x05\x01\x02')
    assert s.recv(2) == b'\x05\x02'
    s.sendall(bytes([1, len(user)]) + user.encode()
              + bytes([len(pw)]) + pw.encode())
    rep = s.recv(2); s.close(); return rep
chk("correct creds accepted", login('alice', 'hunter2') == b'\x01\x00')
chk("wrong creds rejected", login('alice', 'nope') == b'\x01\x01')
t0 = time.time()
chk("next attempt throttled", login('alice', 'nope2') == b'\x01\x01')
dt = time.time() - t0
chk("throttle delays ~2s (got %.1fs)" % dt, dt >= 1.8)
p.terminate(); p.wait()
print("RESULT: %d passed, %d failed" % (pass_, fail))
sys.exit(1 if fail else 0)
PYEOF
[ $? -eq 0 ] && ok "auth suite passed" || bad "auth suite failed"

# ---------------------------------------------------------------------------
echo "=== 7. CLI (set/show/status/version) ==="
rm -rf "$PREFIX"
mkdir -p "$CONFIG_DIR"

chk "set port saves" \
    'bash "$SCRIPT" set port 1234 >/dev/null 2>&1 && grep -q "^PROXY_PORT=1234$" "$CONFIG_FILE"'
chk "invalid port rejected" \
    '! bash "$SCRIPT" set port 99999 >/dev/null 2>&1'
chk "set ip saves" \
    'bash "$SCRIPT" set ip 192.168.1.50 >/dev/null 2>&1 && grep -q "^PROXY_IP=192.168.1.50$" "$CONFIG_FILE"'
chk "set ip :: saves" \
    'bash "$SCRIPT" set ip :: >/dev/null 2>&1 && grep -q "^PROXY_IP=::$" "$CONFIG_FILE"'
chk "invalid ip rejected" \
    '! bash "$SCRIPT" set ip not-an-ip >/dev/null 2>&1'
chk "set auth saves" \
    'bash "$SCRIPT" set auth myuser mypass >/dev/null 2>&1 && grep -q "^PROXY_USER=myuser$" "$CONFIG_FILE"'
chk "set auth stores password" \
    'grep -q "^PROXY_PASS=mypass$" "$CONFIG_FILE"'
chk "auth password never shown in config output" \
    '! bash "$SCRIPT" show config | grep -q mypass'
chk "unset auth removes" \
    'bash "$SCRIPT" unset auth >/dev/null 2>&1 && ! grep -q "^PROXY_USER=" "$CONFIG_FILE"'
chk "show config prints port" \
    'bash "$SCRIPT" show config | grep -q "1234"'
chk "--version prints" \
    'bash "$SCRIPT" --version | grep -q "v[0-9]"'
chk "unknown command rejected" \
    '! bash "$SCRIPT" bogus >/dev/null 2>&1'

# ---------------------------------------------------------------------------
echo "=== 8. end-to-end start/stop ==="
pkill -f '[s]ocks5_server.py' 2>/dev/null
sleep 1
printf 'PROXY_PORT=19310\nPROXY_IP=127.0.0.1\n' > "$CONFIG_FILE"
( bash "$SCRIPT" start >/dev/null 2>&1 & )
sleep 4
chk "e2e: status shows running" \
    'bash "$SCRIPT" status | strip_colors | grep -q "Running: yes"'
chk "e2e: listens on saved port" \
    'python3 -c "import socket; s=socket.create_connection((\"127.0.0.1\",19310),timeout=3); s.close()"'
chk "e2e: proxy.log written" \
    '[ -f "$CONFIG_DIR/proxy.log" ] && grep -q "SOCKS5 proxy running" "$CONFIG_DIR/proxy.log"'
chk "e2e: stats file written" \
    '[ -f "$CONFIG_DIR/stats" ] && grep -q "^START=" "$CONFIG_DIR/stats"'
chk "e2e: status shows uptime" \
    'bash "$SCRIPT" status | strip_colors | grep -q "Uptime:"'
bash "$SCRIPT" stop >/dev/null 2>&1
sleep 1
chk "e2e: status shows stopped" \
    'bash "$SCRIPT" status | strip_colors | grep -q "Running: no"'
chk "e2e: port released" \
    '! python3 -c "import socket; s=socket.create_connection((\"127.0.0.1\",19310),timeout=2); s.close()" 2>/dev/null'
chk "e2e: no leftover proxy" \
    '[ "$(ps aux | grep -c "[s]ocks5_server")" = "0" ]'
rm -rf "$PREFIX"

# ---------------------------------------------------------------------------
echo
echo "=============================="
echo "  $PASS passed, $FAIL failed"
echo "=============================="
[ "$FAIL" -eq 0 ]
