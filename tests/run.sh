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

# Kill any proxy left over from an interrupted previous run so the fixed
# test ports are never already in use. (The [s] trick prevents pkill from
# matching this very command line.)
pkill -f '[s]ocks5_server.py' 2>/dev/null
sleep 1

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
# Source only the function definitions (everything before the command
# dispatch at the bottom, which would otherwise execute on source)
sed -n '1,/^# Command dispatch$/p' "$SCRIPT" | sed '$d' > "$TMP/funcs.sh"
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
echo "=== 4b. concurrent UDP clients (no packet loss) ==="
SOCKS5_STATS="$CONFIG_DIR/stats" python3 - "$TMP" <<'PYEOF'
import os, socket, struct, subprocess, sys, threading, time
tmp = sys.argv[1]

pass_, fail = 0, 0
def chk(n, c):
    global pass_, fail
    if c: pass_ += 1; print("PASS - %s" % n)
    else: fail += 1; print("FAIL - %s" % n)

# Two UDP echo sinks (one per client) so replies are distinguishable
sinks = []
for _ in range(2):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(('127.0.0.1', 0)); s.settimeout(0.2)
    sinks.append(s)
def sink_loop(s):
    while True:
        try: d, a = s.recvfrom(4096)
        except socket.timeout: continue
        except OSError: return
        s.sendto(d, a)
for s in sinks:
    threading.Thread(target=sink_loop, args=(s,), daemon=True).start()

p = subprocess.Popen([sys.executable, os.path.join(tmp, 'server.py'),
                      '19340', '127.0.0.1'],
                     stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
time.sleep(1)
chk("proxy starts", p.poll() is None)

# Open a UDP association. src_ip is bound on both the TCP and UDP sockets so
# the relay sees two genuinely different source addresses.
def open_client(src_ip):
    t = socket.create_connection(('127.0.0.1', 19340), timeout=5,
                                 source_address=(src_ip, 0))
    t.sendall(b'\x05\x01\x00')
    assert t.recv(2) == b'\x05\x00'
    t.sendall(b'\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00')
    resp = t.recv(10)
    bnd = struct.unpack('>H', resp[8:10])[0]
    u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    u.bind((src_ip, 0))      # send from the given source address
    u.settimeout(6)
    return t, u, bnd

# Two concurrent clients from *different* source IPs (both loopback)
c1 = open_client('127.0.0.1')
c2 = open_client('127.0.0.2')

# Interleave 60 datagrams per client; every one must come back intact
N = 60
hdr1 = b'\x00\x00\x00\x01' + socket.inet_aton('127.0.0.1') + struct.pack('>H', sinks[0].getsockname()[1])
hdr2 = b'\x00\x00\x00\x01' + socket.inet_aton('127.0.0.1') + struct.pack('>H', sinks[1].getsockname()[1])
for i in range(N):
    c1[1].sendto(hdr1 + b'c1-%d' % i, ('127.0.0.1', c1[2]))
    c2[1].sendto(hdr2 + b'c2-%d' % i, ('127.0.0.1', c2[2]))

# Collect all replies on both sockets
seen1, seen2, deadline = set(), set(), time.time() + 8
while time.time() < deadline and (len(seen1) < N or len(seen2) < N):
    for sock, seen in ((c1[1], seen1), (c2[1], seen2)):
        try:
            r, _ = sock.recvfrom(65536)
            seen.add(r[10:])
        except socket.timeout:
            pass
chk("client1 got all %d replies" % N, len(seen1) == N)
chk("client2 got all %d replies" % N, len(seen2) == N)
chk("no cross-talk: client1 payloads only",
    all(r.startswith(b'c1-') for r in seen1) and len(seen1) == N)
chk("no cross-talk: client2 payloads only",
    all(r.startswith(b'c2-') for r in seen2) and len(seen2) == N)

c1[0].close(); c2[0].close(); c1[1].close(); c2[1].close()

# Same-IP clients (dante-style): UDP socket on the SAME local port as the
# TCP connection, so the relay can tell the two associations apart.
def open_client_sameport():
    # pick a free UDP port, then reuse it as the TCP source port
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    probe.bind(('127.0.0.1', 0))
    port = probe.getsockname()[1]
    probe.close()
    t = socket.create_connection(('127.0.0.1', 19340), timeout=5,
                                 source_address=('127.0.0.1', port))
    t.sendall(b'\x05\x01\x00')
    assert t.recv(2) == b'\x05\x00'
    t.sendall(b'\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00')
    resp = t.recv(10)
    bnd = struct.unpack('>H', resp[8:10])[0]
    u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    u.bind(('127.0.0.1', port))   # same local port as the TCP connection
    u.settimeout(6)
    return t, u, bnd

c3 = open_client_sameport()
c4 = open_client_sameport()
for tag, cli, hdr in (('c3', c3, hdr1), ('c4', c4, hdr2)):
    cli[1].sendto(hdr + b'%s-first' % tag.encode(), ('127.0.0.1', cli[2]))
    r, _ = cli[1].recvfrom(65536)
    chk("%s: first datagram routed correctly" % tag, r[10:] == b'%s-first' % tag.encode())
c3[0].close(); c4[0].close(); c3[1].close(); c4[1].close()

p.terminate(); p.wait()
for s in sinks: s.close()
print("RESULT: %d passed, %d failed" % (pass_, fail))
sys.exit(1 if fail else 0)
PYEOF
[ $? -eq 0 ] && ok "concurrent UDP suite passed" || bad "concurrent UDP suite failed"

# ---------------------------------------------------------------------------
echo "=== 4c. bytes relayed tracking ==="
SOCKS5_STATS="$CONFIG_DIR/stats" SOCKS5_CONNS="$CONFIG_DIR/conns" python3 - "$TMP" <<'PYEOF'
import os, socket, struct, subprocess, sys, threading, time
tmp = sys.argv[1]
pass_, fail = 0, 0
def chk(n, c):
    global pass_, fail
    if c: pass_ += 1; print("PASS - %s" % n)
    else: fail += 1; print("FAIL - %s" % n)

# TCP echo sink
sink = socket.socket(); sink.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sink.bind(('127.0.0.1', 0)); sink.listen(5)
tport = sink.getsockname()[1]
def echo(c):
    while True:
        d = c.recv(65536)
        if not d: break
        c.sendall(d)
    c.close()
def loop():
    while True:
        try: c, _ = sink.accept()
        except OSError: return
        threading.Thread(target=echo, args=(c,), daemon=True).start()
threading.Thread(target=loop, daemon=True).start()

stats = os.path.join(tmp, 'stats-bytes')
conns = os.path.join(tmp, 'conns-bytes')
env = dict(os.environ, SOCKS5_STATS=stats, SOCKS5_CONNS=conns)
p = subprocess.Popen([sys.executable, os.path.join(tmp, 'server.py'),
                      '19350', '127.0.0.1'], env=env,
                     stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
time.sleep(1)
chk("bytes: proxy starts", p.poll() is None)

# Relay a known payload through CONNECT (echo sink doubles it back)
s = socket.create_connection(('127.0.0.1', 19350), timeout=5)
s.sendall(b'\x05\x01\x00'); assert s.recv(2) == b'\x05\x00'
s.sendall(b'\x05\x01\x00\x01' + socket.inet_aton('127.0.0.1') + struct.pack('>H', tport))
assert s.recv(10)[1] == 0x00
payload = b'x' * 50000
s.sendall(payload)
got = b''
while len(got) < len(payload):
    got += s.recv(65536)
peer = '127.0.0.1:%d' % s.getsockname()[1]
s.close()

# The stats writer flushes every 2s — wait until it has actually persisted
# the counted bytes (a flush with 0s appears first, before the connection's
# byte counts are folded into the totals, so loop until the numbers land).
ready = False
for _ in range(20):
    time.sleep(0.5)
    try:
        st = open(stats).read()
        up = int([l.split('=', 1)[1] for l in st.splitlines() if l.startswith('UP=')][0])
        down = int([l.split('=', 1)[1] for l in st.splitlines() if l.startswith('DOWN=')][0])
        if up >= len(payload) and down >= len(payload):
            ready = True
            break
    except (OSError, IndexError, ValueError):
        pass
chk("bytes: stats file flushed", ready)
chk("bytes: UP counts relayed bytes", up == len(payload))
chk("bytes: DOWN counts relayed bytes", down == len(payload))

cn = open(conns).read()
lines = [l for l in cn.strip().splitlines() if l]
chk("bytes: conns file has one connection", len(lines) == 1)
start, peer2, dest, upc, downc, secs = lines[0].split('|')
chk("bytes: conns records up bytes", int(upc) == len(payload))
chk("bytes: conns records down bytes", int(downc) == len(payload))
chk("bytes: conns records destination", dest == '127.0.0.1:%d' % tport)
chk("bytes: conns records peer", peer2 == peer)

p.terminate(); p.wait(); sink.close()
print("RESULT: %d passed, %d failed" % (pass_, fail))
sys.exit(1 if fail else 0)
PYEOF
[ $? -eq 0 ] && ok "bytes tracking suite passed" || bad "bytes tracking suite failed"

# ---------------------------------------------------------------------------
echo "=== 4d. extended protocol (domain, failures, concurrency) ==="
SOCKS5_STATS="$CONFIG_DIR/stats" python3 - "$TMP" <<'PYEOF'
import os, socket, struct, subprocess, sys, threading, time
tmp = sys.argv[1]
pass_, fail = 0, 0
def chk(n, c):
    global pass_, fail
    if c: pass_ += 1; print("PASS - %s" % n)
    else: fail += 1; print("FAIL - %s" % n)

# TCP echo sink
sink = socket.socket(); sink.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sink.bind(('127.0.0.1', 0)); sink.listen(16)
tport = sink.getsockname()[1]
def echo(c):
    while True:
        d = c.recv(65536)
        if not d: break
        c.sendall(d)
    c.close()
def loop():
    while True:
        try: c, _ = sink.accept()
        except OSError: return
        threading.Thread(target=echo, args=(c,), daemon=True).start()
threading.Thread(target=loop, daemon=True).start()

p = subprocess.Popen([sys.executable, os.path.join(tmp, 'server.py'),
                      '19360', '127.0.0.1'],
                     stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
time.sleep(1)
chk("ext: proxy starts", p.poll() is None)

def connect():
    s = socket.create_connection(('127.0.0.1', 19360), timeout=5)
    s.sendall(b'\x05\x01\x00')
    assert s.recv(2) == b'\x05\x00'
    return s

# Domain-name CONNECT (ATYP 0x03)
s = connect()
domain = b'localhost'
s.sendall(b'\x05\x01\x00\x03' + bytes([len(domain)]) + domain + struct.pack('>H', tport))
chk("domain CONNECT reply 0x00", s.recv(10)[1] == 0x00)
s.sendall(b'domain-ok')
chk("domain CONNECT relay echo", s.recv(9) == b'domain-ok')
s.close()

# CONNECT to a refused target (nothing listens on port 1) -> REP 0x05
s = connect()
s.sendall(b'\x05\x01\x00\x01' + socket.inet_aton('127.0.0.1') + struct.pack('>H', 1))
chk("refused target -> REP 0x05", s.recv(10)[1] == 0x05)
s.close()

# Wrong SOCKS version -> connection closed without a reply. The server may
# tear it down with a clean EOF or a RST (if unread data was pending), so
# both count as "rejected".
s = socket.create_connection(('127.0.0.1', 19360), timeout=5)
s.sendall(b'\x04\x01\x00')   # VER 4 is not SOCKS5
rejected = False
try:
    rejected = s.recv(2) == b''
except ConnectionResetError:
    rejected = True
chk("wrong version rejects connection", rejected)
s.close()

# UDP ASSOCIATE with FRAG != 0 must be dropped (no reply)
s = connect()
s.sendall(b'\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00')
resp = s.recv(10)
bnd = struct.unpack('>H', resp[8:10])[0]
# need a UDP sink that echoes so a dropped FRAG datagram is detectable
us = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); us.bind(('127.0.0.1', 0))
us.settimeout(0.2); uport = us.getsockname()[1]
def udp_loop():
    while True:
        try: d, a = us.recvfrom(4096)
        except socket.timeout: continue
        except OSError: return
        us.sendto(d, a)
threading.Thread(target=udp_loop, daemon=True).start()
c = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); c.settimeout(1.5)
hdr = b'\x00\x00\x00\x01' + socket.inet_aton('127.0.0.1') + struct.pack('>H', uport)
c.sendto(b'\x00\x00\x01' + hdr[3:] + b'frag', ('127.0.0.1', bnd))  # FRAG=1
no_reply = True
try:
    c.recvfrom(4096); no_reply = False
except socket.timeout:
    pass
chk("UDP FRAG!=0 datagram dropped", no_reply)
# and a normal datagram still works on the same association
c.sendto(hdr + b'after-frag', ('127.0.0.1', bnd))
rep, _ = c.recvfrom(4096)
chk("UDP relay still works after FRAG drop", rep[10:] == b'after-frag')
s.close(); c.close(); us.close()

# Several concurrent TCP connections, each with distinct payloads
N = 8
clients = []
for i in range(N):
    s = connect()
    s.sendall(b'\x05\x01\x00\x01' + socket.inet_aton('127.0.0.1') + struct.pack('>H', tport))
    assert s.recv(10)[1] == 0x00
    clients.append(s)
for i, s in enumerate(clients):
    s.sendall(b'conn-%d' % i)
for i, s in enumerate(clients):
    chk("concurrent conn %d echoes its own payload" % i, s.recv(7) == b'conn-%d' % i)
for s in clients:
    s.close()

# A larger payload (1 MiB) round-trips intact
s = connect()
s.sendall(b'\x05\x01\x00\x01' + socket.inet_aton('127.0.0.1') + struct.pack('>H', tport))
assert s.recv(10)[1] == 0x00
big = os.urandom(1024 * 1024)
s.sendall(big)
got = b''
while len(got) < len(big):
    got += s.recv(65536)
chk("1 MiB payload round-trips intact", got == big)
s.close()

# Half-close regression: a client that finishes sending (shutdown SHUT_WR)
# but keeps reading must still receive the FULL reply. The proxy has to
# propagate the half-close instead of closing the whole tunnel (which would
# truncate in-flight downloads).
s = connect()
s.sendall(b'\x05\x01\x00\x01' + socket.inet_aton('127.0.0.1') + struct.pack('>H', tport))
assert s.recv(10)[1] == 0x00
payload = b'half-close-' * 4096   # ~45 KiB — spans many relay loops
s.sendall(payload)
s.shutdown(socket.SHUT_WR)        # done sending — still reading
half_got = b''
while len(half_got) < len(payload):
    d = s.recv(65536)
    if not d:
        break   # proxy closed too early — the bug this guards against
    half_got += d
chk("half-close: full reply delivered after client shutdown", half_got == payload)
s.close()

p.terminate(); p.wait(); sink.close()
print("RESULT: %d passed, %d failed" % (pass_, fail))
sys.exit(1 if fail else 0)
PYEOF
[ $? -eq 0 ] && ok "extended protocol suite passed" || bad "extended protocol suite failed"

# ---------------------------------------------------------------------------
echo "=== 4e. limits (idle timeout, connection cap) ==="
SOCKS5_STATS="$CONFIG_DIR/stats" python3 - "$TMP" <<'PYEOF'
import os, socket, struct, subprocess, sys, threading, time
tmp = sys.argv[1]
pass_, fail = 0, 0
def chk(n, c):
    global pass_, fail
    if c: pass_ += 1; print("PASS - %s" % n)
    else: fail += 1; print("FAIL - %s" % n)

# TCP echo sink
sink = socket.socket(); sink.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sink.bind(('127.0.0.1', 0)); sink.listen(16)
tport = sink.getsockname()[1]
def echo(c):
    while True:
        d = c.recv(65536)
        if not d: break
        c.sendall(d)
    c.close()
def loop():
    while True:
        try: c, _ = sink.accept()
        except OSError: return
        threading.Thread(target=echo, args=(c,), daemon=True).start()
threading.Thread(target=loop, daemon=True).start()

def handshake(port):
    s = socket.create_connection(('127.0.0.1', port), timeout=5)
    s.sendall(b'\x05\x01\x00'); assert s.recv(2) == b'\x05\x00'
    return s

# --- idle timeout: a connection that goes quiet is closed by the proxy
env = dict(os.environ, SOCKS5_IDLE_TIMEOUT='2')
p = subprocess.Popen([sys.executable, os.path.join(tmp, 'server.py'),
                      '19361', '127.0.0.1'], env=env,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(1)
chk("limit: idle proxy starts", p.poll() is None)

s = handshake(19361)
s.sendall(b'\x05\x01\x00\x01' + socket.inet_aton('127.0.0.1') + struct.pack('>H', tport))
assert s.recv(10)[1] == 0x00
s.settimeout(6)
closed = False
try:
    closed = s.recv(1) == b''
except (ConnectionResetError, socket.timeout):
    closed = True
chk("limit: idle connection closed by proxy", closed)
s.close()

# --- connection cap: MAX_CONNS=1 rejects extras, then frees the slot
env2 = dict(os.environ, SOCKS5_MAX_CONNS='1')
p2 = subprocess.Popen([sys.executable, os.path.join(tmp, 'server.py'),
                       '19362', '127.0.0.1'], env=env2,
                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(1)
chk("limit: capped proxy starts", p2.poll() is None)

a = socket.create_connection(('127.0.0.1', 19362), timeout=5)   # fills the slot
b = socket.create_connection(('127.0.0.1', 19362), timeout=5)   # must be closed
b.settimeout(3)
rejected = False
try:
    rejected = b.recv(1) == b''
except (ConnectionResetError, OSError):
    rejected = True
chk("limit: extra connection rejected at cap", rejected)
# the client that already holds the slot still works
b.close()
a.sendall(b'\x05\x01\x00')
chk("limit: existing connection unaffected", a.recv(2) == b'\x05\x00')
a.close()
time.sleep(0.5)
# once a slot frees up, new clients are accepted again
c = socket.create_connection(('127.0.0.1', 19362), timeout=5)
c.sendall(b'\x05\x01\x00')
chk("limit: slot reused after client disconnects", c.recv(2) == b'\x05\x00')
c.close()

p.terminate(); p.wait(); p2.terminate(); p2.wait(); sink.close()
print("RESULT: %d passed, %d failed" % (pass_, fail))
sys.exit(1 if fail else 0)
PYEOF
[ $? -eq 0 ] && ok "limits suite passed" || bad "limits suite failed"

# ---------------------------------------------------------------------------
echo "=== 4f. connection type matrix (commands x address types) ==="
python3 - "$TMP" <<'PYEOF'
import os, socket, struct, subprocess, sys, threading, time
tmp = sys.argv[1]
pass_, fail = 0, 0
def chk(n, c):
    global pass_, fail
    if c: pass_ += 1; print("PASS - %s" % n)
    else: fail += 1; print("FAIL - %s" % n)

def have_v6():
    try:
        s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
        s.bind(('::1', 0)); s.close(); return True
    except OSError:
        return False
V6 = have_v6()

# --- TCP echo sink -------------------------------------------------------
ts = socket.socket(); ts.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
ts.bind(('127.0.0.1', 0)); ts.listen(5); tport = ts.getsockname()[1]
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

v6sink = None
if V6:
    v6sink = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
    v6sink.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    v6sink.bind(('::1', 0)); v6sink.listen(5); v6tport = v6sink.getsockname()[1]
    def v6_loop():
        while True:
            try: c, _ = v6sink.accept()
            except OSError: return
            threading.Thread(target=tcp_echo, args=(c,), daemon=True).start()
    threading.Thread(target=v6_loop, daemon=True).start()

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

# --- servers: plain + auth-enabled ---------------------------------------
srv_port = 19305
p = subprocess.Popen([sys.executable, os.path.join(tmp, 'server.py'),
                      str(srv_port), '127.0.0.1'],
                     stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
env = dict(os.environ, SOCKS5_USER='alice', SOCKS5_PASS='hunter2')
auth_port = 19306
pa = subprocess.Popen([sys.executable, os.path.join(tmp, 'server.py'),
                       str(auth_port), '127.0.0.1'], env=env,
                      stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
time.sleep(1)
chk("proxy starts", p.poll() is None)
chk("auth proxy starts", pa.poll() is None)

def handshake(port, methods=b'\x00'):
    s = socket.create_connection(('127.0.0.1', port), timeout=5)
    s.settimeout(5)
    s.sendall(b'\x05' + bytes([len(methods)]) + methods)
    return s, s.recv(2)

def connect_req(port, cmd, atyp, addr_bytes, dst_port):
    s, _ = handshake(port)
    s.sendall(b'\x05' + bytes([cmd]) + b'\x00' + bytes([atyp])
              + addr_bytes + struct.pack('>H', dst_port))
    return s

# --- TCP CONNECT: every address type -------------------------------------
s = connect_req(srv_port, 0x01, 0x01, socket.inet_aton('127.0.0.1'), tport)
chk("CONNECT IPv4 -> REP 0x00", s.recv(10)[1] == 0x00)
s.sendall(b'ipv4'); chk("CONNECT IPv4 relays", s.recv(4) == b'ipv4')
s.close()

s = connect_req(srv_port, 0x01, 0x03, b'\x09localhost', tport)
chk("CONNECT domain -> REP 0x00", s.recv(10)[1] == 0x00)
s.sendall(b'dom'); chk("CONNECT domain relays", s.recv(3) == b'dom')
s.close()

if V6:
    s = connect_req(srv_port, 0x01, 0x04,
                    socket.inet_pton(socket.AF_INET6, '::1'), v6tport)
    chk("CONNECT IPv6 -> REP 0x00", s.recv(10)[1] == 0x00)
    s.sendall(b'v6t'); chk("CONNECT IPv6 relays", s.recv(3) == b'v6t')
    s.close()
else:
    print("SKIP - CONNECT IPv6 target (no IPv6 loopback)")

# unknown ATYP in the request -> connection dropped without a reply
s = socket.create_connection(('127.0.0.1', srv_port), timeout=5)
s.settimeout(3)
s.sendall(b'\x05\x01\x00'); assert s.recv(2) == b'\x05\x00'
s.sendall(b'\x05\x01\x00\x05\x01\x02\x03\x04\x00\x01')   # ATYP 5
closed = False
try:
    closed = s.recv(10) == b''
except (ConnectionResetError, socket.timeout):
    closed = True
chk("CONNECT unknown ATYP -> dropped", closed)
s.close()

# unknown command -> REP 0x07 (same as BIND)
s = connect_req(srv_port, 0x04, 0x01, socket.inet_aton('127.0.0.1'), tport)
chk("unknown CMD -> REP 0x07", s.recv(10)[1] == 0x07)
s.close()

s = connect_req(srv_port, 0x02, 0x01, socket.inet_aton('127.0.0.1'), 1)
chk("BIND -> REP 0x07", s.recv(10)[1] == 0x07)
s.close()

# --- UDP ASSOCIATE: target address types inside the datagram --------------
def udp_assoc(port=srv_port):
    t, _ = handshake(port)
    t.sendall(b'\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00')
    resp = t.recv(10)
    assert resp[1] == 0x00
    bnd = struct.unpack('>H', resp[8:10])[0]
    u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); u.settimeout(4)
    return t, u, bnd

def udp_roundtrip(u, bnd, hdr, payload):
    u.sendto(hdr + payload, ('127.0.0.1', bnd))
    return u.recvfrom(65536)[0]

hdr4 = b'\x00\x00\x00\x01' + socket.inet_aton('127.0.0.1') + struct.pack('>H', uport)
t, u, bnd = udp_assoc()
rep = udp_roundtrip(u, bnd, hdr4, b'udp4')
chk("UDP IPv4 target echo", rep[10:] == b'udp4')
t.close(); u.close()

name = b'localhost'
hdr3 = b'\x00\x00\x00\x03' + bytes([len(name)]) + name + struct.pack('>H', uport)
t, u, bnd = udp_assoc()
rep = udp_roundtrip(u, bnd, hdr3, b'udp-dom')
off = 3 + 1 + 1 + len(name) + 2
chk("UDP domain target echo", rep[off:] == b'udp-dom')
chk("UDP domain reply carries ATYP+name",
    rep[3:5] == b'\x03\x09' and rep[5:14] == name)
t.close(); u.close()

if V6:
    u6 = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM); u6.bind(('::1', 0))
    u6.settimeout(0.2); u6port = u6.getsockname()[1]
    def udp6_loop():
        while True:
            try: d, a = u6.recvfrom(4096)
            except socket.timeout: continue
            except OSError: return
            u6.sendto(d, a)
    threading.Thread(target=udp6_loop, daemon=True).start()
    hdr6 = b'\x00\x00\x00\x04' + socket.inet_pton(socket.AF_INET6, '::1') \
        + struct.pack('>H', u6port)
    t, u, bnd = udp_assoc()
    rep = udp_roundtrip(u, bnd, hdr6, b'udp6')
    chk("UDP IPv6 target echo", rep[22:] == b'udp6')
    t.close(); u.close(); u6.close()
else:
    print("SKIP - UDP IPv6 target (no IPv6 loopback)")

# unknown ATYP inside a datagram -> dropped, association keeps working
t, u, bnd = udp_assoc()
u.sendto(b'\x00\x00\x00\x05' + socket.inet_aton('127.0.0.1')
         + struct.pack('>H', uport) + b'bad', ('127.0.0.1', bnd))
dropped = True
try:
    u.recvfrom(65536); dropped = False
except socket.timeout:
    pass
chk("UDP unknown ATYP datagram dropped", dropped)
rep = udp_roundtrip(u, bnd, hdr4, b'alive')
chk("UDP association survives bad datagram", rep[10:] == b'alive')
t.close(); u.close()

# --- authentication method negotiation ------------------------------------
s, r = handshake(auth_port, b'\x00')         # offers only no-auth
chk("auth on, no-auth offered -> REP 0xFF", r == b'\x05\xff')
s.close()
s, r = handshake(auth_port, b'\x00\x02')     # offers no-auth AND user/pass
chk("auth on, user/pass offered -> method 0x02", r == b'\x05\x02')
s.close()
s, r = handshake(srv_port, b'\x00\x02')      # auth off
chk("auth off -> no-auth method 0x00", r == b'\x05\x00')
s.close()

# --- debug log level: connection lifecycle details -------------------------
dbg_port = 19307
env_dbg = dict(os.environ, SOCKS5_LOG_LEVEL='debug', SOCKS5_IDLE_TIMEOUT='3')
pd = subprocess.Popen([sys.executable, os.path.join(tmp, 'server.py'),
                       str(dbg_port), '127.0.0.1'], env=env_dbg,
                      stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
time.sleep(1)
chk("debug proxy starts", pd.poll() is None)
# a sink that accepts but never sends, so the 3s idle timeout must kill the
# tunnel — the debug log has to say so (up=idle/down=idle)
silent = socket.socket(); silent.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
silent.bind(('127.0.0.1', 0)); silent.listen(1)
silent_port = silent.getsockname()[1]
def hold(c):
    time.sleep(6)
    c.close()
def hold_loop():
    try:
        c, _ = silent.accept()
        threading.Thread(target=hold, args=(c,), daemon=True).start()
    except OSError:
        pass
threading.Thread(target=hold_loop, daemon=True).start()
s, _ = handshake(dbg_port)
s.sendall(b'\x05\x01\x00\x01' + socket.inet_aton('127.0.0.1')
          + struct.pack('>H', silent_port))
chk("debug CONNECT ok", s.recv(10)[1] == 0x00)
time.sleep(6)   # give the 3s idle timeout time to tear the tunnel down
s.close(); silent.close()
pd.terminate(); pd.wait()   # stop it first — reading the pipe needs EOF
err = pd.stdout.read().decode('utf-8', 'replace')
chk("debug logs tunnel established", 'tunnel' in err and 'established' in err)
chk("debug logs tunnel closed with reasons", 'closed: up=' in err)
chk("debug shows the idle teardown", 'up=idle' in err or 'down=idle' in err)


p.terminate(); p.wait(); pa.terminate(); pa.wait()
ts.close(); us.close()
if v6sink: v6sink.close()
print("RESULT: %d passed, %d failed" % (pass_, fail))
sys.exit(1 if fail else 0)
PYEOF
[ $? -eq 0 ] && ok "connection type matrix passed" || bad "connection type matrix failed"

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
echo "=== 6b. auth + UDP ASSOCIATE ==="
SOCKS5_STATS="$CONFIG_DIR/stats" python3 - "$TMP" <<'PYEOF'
import os, socket, struct, subprocess, sys, threading, time
tmp = sys.argv[1]
pass_, fail = 0, 0
def chk(n, c):
    global pass_, fail
    if c: pass_ += 1; print("PASS - %s" % n)
    else: fail += 1; print("FAIL - %s" % n)

# UDP echo sink
us = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); us.bind(('127.0.0.1', 0))
us.settimeout(0.2); uport = us.getsockname()[1]
def udp_loop():
    while True:
        try: d, a = us.recvfrom(4096)
        except socket.timeout: continue
        except OSError: return
        us.sendto(d, a)
threading.Thread(target=udp_loop, daemon=True).start()

env = dict(os.environ)
env.update({'SOCKS5_USER': 'alice', 'SOCKS5_PASS': 'hunter2'})
p = subprocess.Popen([sys.executable, os.path.join(tmp, 'server.py'),
                      '19362', '127.0.0.1'], env=env,
                     stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
time.sleep(1)
chk("auth+udp: proxy starts", p.poll() is None)

# Authenticated login then UDP ASSOCIATE
s = socket.create_connection(('127.0.0.1', 19362), timeout=5)
s.sendall(b'\x05\x01\x02'); assert s.recv(2) == b'\x05\x02'
s.sendall(b'\x01\x05alice\x07hunter2')
chk("auth+udp: login accepted", s.recv(2) == b'\x01\x00')
s.sendall(b'\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00')
resp = s.recv(10)
chk("auth+udp: ASSOCIATE reply 0x00", resp[1] == 0x00)
bnd = struct.unpack('>H', resp[8:10])[0]
c = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); c.settimeout(3)
hdr = b'\x00\x00\x00\x01' + socket.inet_aton('127.0.0.1') + struct.pack('>H', uport)
c.sendto(hdr + b'auth-udp', ('127.0.0.1', bnd))
rep, _ = c.recvfrom(4096)
chk("auth+udp: relay echo works", rep[10:] == b'auth-udp')
s.close(); c.close(); us.close()
p.terminate(); p.wait()
print("RESULT: %d passed, %d failed" % (pass_, fail))
sys.exit(1 if fail else 0)
PYEOF
[ $? -eq 0 ] && ok "auth+udp suite passed" || bad "auth+udp suite failed"

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
chk "help renders" \
    'bash "$SCRIPT" help | strip_colors | grep -q "COMMANDS"'
chk "logs with no log file is harmless" \
    'bash "$SCRIPT" logs | strip_colors | grep -q "No log file"'
# colorize_log (used by `logs --color`) maps log lines to colors by level
chk "colorize_log: errors red" \
    'echo "Error handling client: boom" | colorize_log | grep -qF "$RED"'
chk "colorize_log: warnings yellow" \
    'echo "CONNECT host:1 failed: timed out" | colorize_log | grep -qF "$YELLOW"'
chk "colorize_log: rejected yellow" \
    'echo "Rejected connection from 1.2.3.4:5 (limit 256 reached)" | colorize_log | grep -qF "$YELLOW"'
chk "colorize_log: connections cyan" \
    'echo "Connection from 127.0.0.1:1234" | colorize_log | grep -qF "$CYAN"'
chk "colorize_log: banner green" \
    'echo "SOCKS5 proxy running on 0.0.0.0:10806" | colorize_log | grep -qF "$GREEN"'
chk "colorize_log: plain lines untouched" \
    '[ "$(echo "some other line" | colorize_log)" = "some other line" ]'
chk "logs --color forces color when piped" \
    'echo "CONNECT x:1 failed: nope" > "$CONFIG_DIR/proxy.log" && bash "$SCRIPT" logs --color 2>/dev/null | grep -qF "${YELLOW}CONNECT x:1 failed"'
chk "logs stays plain when piped" \
    '! bash "$SCRIPT" logs 2>/dev/null | grep -qF "${YELLOW}CONNECT x:1 failed"'
chk "stop with no pid file is harmless" \
    'bash "$SCRIPT" stop | strip_colors | grep -q "not running"'
# Hidden password prompt: `set auth user` with no password argument reads it
# via read -s, so the password never appears in argv or history.
chk "set auth prompts hidden for password" \
    'printf "hunter2\n" | bash "$SCRIPT" set auth promptuser >/dev/null 2>&1 && grep -q "^PROXY_PASS=hunter2$" "$CONFIG_FILE"'
chk "set auth hidden prompt saved user" \
    'grep -q "^PROXY_USER=promptuser$" "$CONFIG_FILE"'
chk "unset auth cleans both keys" \
    'bash "$SCRIPT" unset auth >/dev/null 2>&1 && ! grep -q "^PROXY_USER=\|^PROXY_PASS=" "$CONFIG_FILE"'
# format_uptime / format_bytes are pure bash helpers. The uptime checks use
# range regexes because a second can tick between the arg's `date +%s` and
# set/unset idle and maxconns validate, save, and restore config keys
chk "set idle saves config" \
    'bash "$SCRIPT" set idle 60 >/dev/null 2>&1 && grep -q "^IDLE_TIMEOUT=60$" "$CONFIG_FILE"'
chk "set idle rejects <10" \
    '! bash "$SCRIPT" set idle 5 >/dev/null 2>&1'
chk "set maxconns saves config" \
    'bash "$SCRIPT" set maxconns 100 >/dev/null 2>&1 && grep -q "^MAX_CONNS=100$" "$CONFIG_FILE"'
chk "set maxconns rejects 0" \
    '! bash "$SCRIPT" set maxconns 0 >/dev/null 2>&1'
chk "unset idle restores default" \
    'bash "$SCRIPT" unset idle >/dev/null 2>&1 && ! grep -q "^IDLE_TIMEOUT=" "$CONFIG_FILE"'
chk "unset maxconns restores default" \
    'bash "$SCRIPT" unset maxconns >/dev/null 2>&1 && ! grep -q "^MAX_CONNS=" "$CONFIG_FILE"'
chk "set loglevel saves config" \
    'bash "$SCRIPT" set loglevel info >/dev/null 2>&1 && grep -q "^LOG_LEVEL=info$" "$CONFIG_FILE"'
chk "set loglevel rejects invalid" \
    '! bash "$SCRIPT" set loglevel verbose >/dev/null 2>&1'
chk "show config prints log level" \
    'bash "$SCRIPT" show config | strip_colors | grep -q "Log level: info"'
chk "unset loglevel restores default" \
    'bash "$SCRIPT" unset loglevel >/dev/null 2>&1 && ! grep -q "^LOG_LEVEL=" "$CONFIG_FILE"'
# status --watch must not hang when stdout is not a terminal: it prints a
# single snapshot and returns (the loop only runs on a real terminal)
chk "status -w prints a snapshot when not a terminal" \
    'bash "$SCRIPT" status -w < /dev/null | grep -q "SOCKS5 Proxy Status"'
chk "status -w rejects a bad interval" \
    '! bash "$SCRIPT" status -w 0 >/dev/null 2>&1 && ! bash "$SCRIPT" status -w abc >/dev/null 2>&1'

# the one computed inside format_uptime (90s -> "1m 30s" or "1m 31s").
chk "format_uptime seconds"    '[[ "$(format_uptime $(date +%s))" =~ ^(0s|1s)$ ]]'
chk "format_uptime minutes"    '[[ "$(format_uptime $(( $(date +%s) - 90 )))" =~ ^1m[[:space:]][0-9]+s$ ]]'
chk "format_uptime hours"      '[[ "$(format_uptime $(( $(date +%s) - 3661 )))" =~ ^1h[[:space:]][0-9]+m[[:space:]][0-9]+s$ ]]'
chk "format_bytes bytes"       '[ "$(format_bytes 900)" = "900 B" ]'
chk "format_bytes KiB"         '[ "$(format_bytes 1536)" = "1.5 KiB" ]'
chk "format_bytes MiB"         '[ "$(format_bytes 3145728)" = "3.0 MiB" ]'
chk "format_bytes GiB"         '[ "$(format_bytes 5368709120)" = "5.0 GiB" ]'

# ---------------------------------------------------------------------------
echo "=== 8. end-to-end start/stop ==="
printf 'PROXY_PORT=19310\nPROXY_IP=127.0.0.1\n' > "$CONFIG_FILE"
( bash "$SCRIPT" start >/dev/null 2>&1 & )
sleep 4
chk "e2e: status shows running" \
    'bash "$SCRIPT" status | strip_colors | grep -q "Running: yes"'
chk "e2e: listens on saved port" \
    'python3 -c "import socket; s=socket.create_connection((\"127.0.0.1\",19310),timeout=3); s.close()"'
# logs follows while running — bounded by timeout so tail -f cannot hang
# the suite; skipped gracefully on systems without the timeout utility
if command -v timeout >/dev/null 2>&1; then
    chk "e2e: logs shows live output" \
        'timeout 2 bash "$SCRIPT" logs 2>/dev/null | strip_colors | grep -q "SOCKS5 proxy running"'
else
    chk "e2e: logs shows live output" \
        'tail -n 30 "$CONFIG_DIR/proxy.log" | strip_colors | grep -q "SOCKS5 proxy running"'
fi
# Restarting while already running must replace the old proxy, not fail
OLD_PID=$(cat "$CONFIG_DIR/pid")
( bash "$SCRIPT" start >/dev/null 2>&1 & )
sleep 4
NEW_PID=$(cat "$CONFIG_DIR/pid" 2>/dev/null || echo "")
chk "e2e: restart replaces proxy" \
    '[ -n "$NEW_PID" ] && [ "$NEW_PID" != "$OLD_PID" ] && bash "$SCRIPT" status | strip_colors | grep -q "Running: yes"'
chk "e2e: old proxy stopped after restart" \
    '! kill -0 "$OLD_PID" 2>/dev/null'
chk "e2e: only one proxy after restart" \
    '[ "$(ps aux | grep -c "[s]ocks5_server")" = "1" ]'
# Relay real data through the running proxy so the conns file gets an entry
python3 - <<'PYEOF'
import socket, struct, subprocess, threading, time
# local echo sink
sink = socket.socket(); sink.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sink.bind(('127.0.0.1', 0)); sink.listen(5)
tport = sink.getsockname()[1]
def echo(c):
    while True:
        d = c.recv(65536)
        if not d: break
        c.sendall(d)
    c.close()
def loop():
    while True:
        try: c, _ = sink.accept()
        except OSError: return
        threading.Thread(target=echo, args=(c,), daemon=True).start()
threading.Thread(target=loop, daemon=True).start()
# SOCKS5 CONNECT through the proxy
s = socket.create_connection(('127.0.0.1', 19310), timeout=5)
s.sendall(b'\x05\x01\x00'); assert s.recv(2) == b'\x05\x00'
s.sendall(b'\x05\x01\x00\x01' + socket.inet_aton('127.0.0.1') + struct.pack('>H', tport))
assert s.recv(10)[1] == 0x00
s.sendall(b'e2e-bytes')
assert s.recv(9) == b'e2e-bytes'
# a refused target gets REP 0x05 and a line in the proxy log
r = socket.create_connection(('127.0.0.1', 19310), timeout=5)
r.sendall(b'\x05\x01\x00'); assert r.recv(2) == b'\x05\x00'
r.sendall(b'\x05\x01\x00\x01' + socket.inet_aton('127.0.0.1') + struct.pack('>H', 1))
assert r.recv(10)[1] == 0x05
r.close()
s.close(); sink.close()
time.sleep(3)   # let the stats writer flush the conns file
PYEOF
chk "e2e: conns file has an entry" \
    '[ -s "$CONFIG_DIR/conns" ]'
chk "e2e: proxy.log written" \
    '[ -f "$CONFIG_DIR/proxy.log" ] && grep -q "SOCKS5 proxy running" "$CONFIG_DIR/proxy.log"'
chk "e2e: stats file written" \
    '[ -f "$CONFIG_DIR/stats" ] && grep -q "^START=" "$CONFIG_DIR/stats"'
chk "e2e: status shows uptime" \
    'bash "$SCRIPT" status | strip_colors | grep -q "Uptime:"'
chk "e2e: status shows traffic bytes" \
    'bash "$SCRIPT" status | strip_colors | grep -q "Traffic:"'
chk "e2e: status renders formatted byte count" \
    'bash "$SCRIPT" status | strip_colors | grep -qE "Traffic: [0-9]+(\\.[0-9])? [A-Z]?i?B up"'
chk "e2e: status shows recent connections" \
    'bash "$SCRIPT" status | strip_colors | grep -q "Recent connections"'
chk "e2e: conns file written" \
    '[ -f "$CONFIG_DIR/conns" ]'
chk "e2e: refused connect logged" \
    'grep -q "CONNECT 127.0.0.1:1 failed" "$CONFIG_DIR/proxy.log"'
# status -w under a real pseudo-terminal must keep redrawing (>= 2 snapshots
# in ~3s at a 1s interval) instead of exiting after the first frame
SCRIPT="$SCRIPT" python3 - <<'PYEOF'
import os, pty, signal, subprocess, sys, time
m, s = pty.openpty()
p = subprocess.Popen(['bash', os.environ['SCRIPT'], 'status', '-w', '1'],
                     stdin=s, stdout=s, stderr=s, env=dict(os.environ))
time.sleep(3.2)
p.send_signal(signal.SIGINT)   # Ctrl+C — must hit the cursor-restore trap
# stop the watcher BEFORE draining, or read() never EOFs
p.wait(timeout=3)
os.close(s)
out = b''
while True:
    try:
        d = os.read(m, 65536)
        if not d: break
        out += d
    except OSError:
        break
os.close(m)
# >= 2 redraws, the live header, and the cursor was restored on Ctrl+C
if (out.count(b'===== SOCKS5 Proxy Status =====') >= 2 and b'live status' in out
        and b'\x1b[?25h' in out):
    print('PASS - e2e: status -w redraws live snapshots')
    sys.exit(0)
print('FAIL - e2e: status -w redraws live snapshots')
sys.exit(1)
PYEOF
[ $? -eq 0 ] && ok "e2e: status -w redraws live snapshots" || bad "e2e: status -w redraws live snapshots"

# `reset` restarts the proxy with fresh counters and clears the conns file
bash "$SCRIPT" reset >/dev/null 2>&1
sleep 3
RESET_PID=$(cat "$CONFIG_DIR/pid" 2>/dev/null || echo "")
chk "e2e: reset restarts the proxy" \
    '[ -n "$RESET_PID" ] && bash "$SCRIPT" status | strip_colors | grep -q "Running: yes"'
chk "e2e: reset clears conns file" \
    '[ ! -s "$CONFIG_DIR/conns" ]'

# the `restart` command replaces the running proxy in one step
bash "$SCRIPT" restart >/dev/null 2>&1
sleep 3
RESTART_PID=$(cat "$CONFIG_DIR/pid" 2>/dev/null || echo "")
chk "e2e: restart command replaces proxy" \
    '[ -n "$RESTART_PID" ] && [ "$RESTART_PID" != "$RESET_PID" ] && bash "$SCRIPT" status | strip_colors | grep -q "Running: yes"'

# log rotation: a proxy.log over 1 MiB is moved aside on the next start
bash "$SCRIPT" stop >/dev/null 2>&1
sleep 1
python3 -c "open('$CONFIG_DIR/proxy.log','w').write('x'*2097152)"
bash "$SCRIPT" start >/dev/null 2>&1
sleep 3
chk "e2e: oversized log rotated to proxy.log.1" \
    '[ -f "$CONFIG_DIR/proxy.log.1" ]'
chk "e2e: fresh log written after rotation" \
    'grep -q "SOCKS5 proxy running" "$CONFIG_DIR/proxy.log"'

bash "$SCRIPT" stop >/dev/null 2>&1
sleep 1
chk "e2e: status shows stopped" \
    'bash "$SCRIPT" status | strip_colors | grep -q "Running: no"'
chk "e2e: port released" \
    '! python3 -c "import socket; s=socket.create_connection((\"127.0.0.1\",19310),timeout=2); s.close()" 2>/dev/null'
chk "e2e: no leftover proxy" \
    '[ "$(ps aux | grep -c "[s]ocks5_server")" = "0" ]'

# --- log level end-to-end ---------------------------------------------------
# Default is warning: the startup banner is always shown, but the per-
# connection "Connection from ..." lines are info-only and must be hidden.
printf 'PROXY_PORT=19311\nPROXY_IP=127.0.0.1\n' > "$CONFIG_FILE"
( bash "$SCRIPT" start >/dev/null 2>&1 & )
sleep 3
python3 - <<'PYEOF'
import socket, struct, threading
sink = socket.socket(); sink.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sink.bind(('127.0.0.1', 0)); sink.listen(1)
tport = sink.getsockname()[1]
def echo(c):
    while True:
        d = c.recv(65536)
        if not d: break
        c.sendall(d)
    c.close()
def loop():
    try:
        c, _ = sink.accept()
        echo(c)
    except OSError:
        pass
threading.Thread(target=loop, daemon=True).start()
s = socket.create_connection(('127.0.0.1', 19311), timeout=5)
s.sendall(b'\x05\x01\x00'); assert s.recv(2) == b'\x05\x00'
s.sendall(b'\x05\x01\x00\x01' + socket.inet_aton('127.0.0.1') + struct.pack('>H', tport))
assert s.recv(10)[1] == 0x00
s.sendall(b'loglvl'); assert s.recv(6) == b'loglvl'
s.close(); sink.close()
import time; time.sleep(2)
PYEOF
chk "loglevel e2e: default (warning) hides connection lines" \
    '! grep -q "Connection from" "$CONFIG_DIR/proxy.log"'
chk "loglevel e2e: startup banner always present" \
    'grep -q "SOCKS5 proxy running" "$CONFIG_DIR/proxy.log"'
# switching to info makes the per-connection lines appear after a restart.
# The log is cleared first so the info-level checks only see fresh output.
bash "$SCRIPT" set loglevel info >/dev/null 2>&1
: > "$CONFIG_DIR/proxy.log"
bash "$SCRIPT" restart >/dev/null 2>&1
sleep 3
python3 - <<'PYEOF'
import socket, struct, threading
sink = socket.socket(); sink.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sink.bind(('127.0.0.1', 0)); sink.listen(1)
tport = sink.getsockname()[1]
def echo(c):
    while True:
        d = c.recv(65536)
        if not d: break
        c.sendall(d)
    c.close()
def loop():
    try:
        c, _ = sink.accept()
        echo(c)
    except OSError:
        pass
threading.Thread(target=loop, daemon=True).start()
s = socket.create_connection(('127.0.0.1', 19311), timeout=5)
s.sendall(b'\x05\x01\x00'); assert s.recv(2) == b'\x05\x00'
s.sendall(b'\x05\x01\x00\x01' + socket.inet_aton('127.0.0.1') + struct.pack('>H', tport))
assert s.recv(10)[1] == 0x00
s.sendall(b'loglvl'); assert s.recv(6) == b'loglvl'
s.close(); sink.close()
# a refused target still logs a warning at info level
r = socket.create_connection(('127.0.0.1', 19311), timeout=5)
r.sendall(b'\x05\x01\x00'); assert r.recv(2) == b'\x05\x00'
r.sendall(b'\x05\x01\x00\x01' + socket.inet_aton('127.0.0.1') + struct.pack('>H', 1))
assert r.recv(10)[1] == 0x05
r.close()
import time; time.sleep(2)
PYEOF
chk "loglevel e2e: info shows connection lines" \
    'grep -q "Connection from" "$CONFIG_DIR/proxy.log"'
chk "loglevel e2e: warning still logged at info level" \
    'grep -q "CONNECT 127.0.0.1:1 failed" "$CONFIG_DIR/proxy.log"'
bash "$SCRIPT" stop >/dev/null 2>&1
sleep 1
chk "loglevel e2e: stopped cleanly" \
    '[ "$(ps aux | grep -c "[s]ocks5_server")" = "0" ]'
rm -rf "$PREFIX"

# ---------------------------------------------------------------------------
echo "=== 9. install.sh ==="
INSTALL_DIR="$TMP/install-prefix"
chk "install: copies into \$PREFIX/bin and is executable" \
    'bash "$ROOT/install.sh" --prefix "$INSTALL_DIR" >/dev/null 2>&1 && [ -x "$INSTALL_DIR/bin/socks5-proxy" ]'
chk "install: copy is byte-identical" \
    'cmp -s "$SCRIPT" "$INSTALL_DIR/bin/socks5-proxy"'
chk "install: installed script runs" \
    'PREFIX="$INSTALL_DIR" bash "$INSTALL_DIR/bin/socks5-proxy" --version | grep -q "v[0-9]"'
# Re-installing the SAME version is a no-op ("already installed")
chk "install: same version reports already installed" \
    'out=$(bash "$ROOT/install.sh" --prefix "$INSTALL_DIR" 2>&1); echo "$out" | grep -q "already installed" && cmp -s "$SCRIPT" "$INSTALL_DIR/bin/socks5-proxy"'
# A NEWER source version must be picked up as an update
mkdir -p "$TMP/v2"
cp "$SCRIPT" "$TMP/v2/socks5-proxy"
cp "$ROOT/install.sh" "$TMP/v2/install.sh"
sed -i 's/^VERSION="[^"]*"/VERSION="9.9.9"/' "$TMP/v2/socks5-proxy"
chk "install: version bump updates the installed copy" \
    'bash "$TMP/v2/install.sh" --prefix "$INSTALL_DIR" > "$TMP/install-out.txt" 2>&1 && PREFIX="$INSTALL_DIR" bash "$INSTALL_DIR/bin/socks5-proxy" --version | grep -q "v9.9.9"'
chk "install: update message shows the version change" \
    'grep -q "Updated" "$TMP/install-out.txt" && grep -q "v9.9.9" "$TMP/install-out.txt"'
chk "install: --no-restart is accepted" \
    'bash "$ROOT/install.sh" --prefix "$INSTALL_DIR" --no-restart >/dev/null 2>&1'
chk "install: --uninstall removes it" \
    'bash "$ROOT/install.sh" --prefix "$INSTALL_DIR" --uninstall >/dev/null 2>&1 && [ ! -f "$INSTALL_DIR/bin/socks5-proxy" ]'
chk "install: unknown option rejected" \
    '! bash "$ROOT/install.sh" --bogus >/dev/null 2>&1'
rm -rf "$INSTALL_DIR" "$TMP/v2" "$TMP/install-out.txt"

# ---------------------------------------------------------------------------
echo
echo "=============================="
echo "  $PASS passed, $FAIL failed"
echo "=============================="
[ "$FAIL" -eq 0 ]
