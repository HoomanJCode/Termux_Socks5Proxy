# Termux SOCKS5 Proxy

Turn your Android phone (running [Termux](https://termux.com)) into a SOCKS5
proxy server that any device on your local network can use.

On the first run you choose a port; the script saves it together with the
listening IP, detects your phone's LAN address, generates a small Python
SOCKS5 server, and runs it in the background — printing ready-to-use
connection details. Later runs start instantly with the saved settings.

## Features

- 📌 Remembers the port and listening IP (stored in a config file)
- 📶 Auto-detects your Wi-Fi/LAN IP address
- 🎛️ Full CLI: `start`, `stop`, `restart`, `reset`, `status`, `logs`,
  `set port`, `set ip`, `set auth`, `set idle`, `set maxconns`, `set loglevel`,
  `show config`, `--version`
- 🐍 Self-contained Python SOCKS5 server (RFC 1928), generated on first run
- 🔄 Handles IPv4, domain names, and IPv6 — as CONNECT targets **and** as the
  listening address (`set ip ::` = dual-stack)
- 📦 UDP ASSOCIATE (RFC 1928) — UDP-based apps (video calls, games, DNS) work
  through the proxy too, with multiple concurrent clients supported
- 🛡️ Restarts cleanly — a PID file tracks the running proxy, and a previous
  instance is verified and stopped before starting a new one
- 🧵 Per-connection threading, partial-read safe, `sendall`-based relay,
  and graceful half-closes — a client that finished sending but is still
  reading (e.g. a download) keeps receiving the full reply
- ⏱️ Idle timeout (default 600s) — connections with no traffic are closed,
  and a configurable connection cap (default 256) rejects floods
- 📝 Failures are logged to `proxy.log` (rotated at 1 MiB), and CONNECT
  errors return the proper SOCKS5 reply code (refused vs unreachable)
- ⚡ Performance-tuned: 64 KiB relay buffers, `TCP_NODELAY`, and larger
  kernel socket buffers for low-latency, high-throughput transfers
- 🔒 Optional username/password authentication (RFC 1929), off by default,
  with hidden password prompt and brute-force throttling
- 📊 Live stats in `status` (uptime, active connections, bytes relayed) and
  a `logs` command, plus the most recent connections with per-connection
  byte counts — and a live watch mode (`status -w`) that redraws in place

## Requirements

- [Termux](https://termux.com) on Android (F-Droid build recommended)
- `python` (installed automatically by the script if missing)

## Installation

From the repository directory, run the installer:

```bash
bash install.sh
```

This copies `socks5-proxy` into `$PREFIX/bin`, makes it executable, and
verifies the installed copy before reporting success. You can then run it
from anywhere:

```bash
socks5-proxy
```

On first run, Python will be installed automatically if needed.

Re-running the installer **updates** an existing installation: it compares
versions (the same version is a no-op), prints the `old → new` version
change, and — if the proxy is running — restarts it with the new code so
the update takes effect immediately.

### Installer options

| Command | Description |
|---------|-------------|
| `bash install.sh` | Install, or update an existing installation |
| `bash install.sh --prefix /path` | Install into `/path/bin` instead of `$PREFIX` |
| `bash install.sh --no-restart` | Update without restarting a running proxy |
| `bash install.sh --uninstall` | Remove the installed copy (settings are kept) |
| `bash install.sh --help` | Show usage |

For a full cleanup, also remove the settings directory:
`rm -rf $PREFIX/etc/socks5-proxy`.

### Manual alternative

If you prefer not to use the installer:

```bash
cp socks5-proxy "$PREFIX/bin/socks5-proxy"
chmod +x "$PREFIX/bin/socks5-proxy"
```

## Usage

Run the script:

```bash
socks5-proxy
```

- **First run:** you'll be asked for a port (Enter uses the default `1080`).
  The port is saved, so later runs start immediately with no prompt.

### CLI commands

Run `socks5-proxy help` (`-h` / `--help` also work) for the full help screen.

| Command | Description |
|---------|-------------|
| `socks5-proxy` | Start the proxy (uses the saved port & IP) |
| `socks5-proxy 9999` | Start on port 9999 (and save it) |
| `socks5-proxy stop` | Stop the running proxy |
| `socks5-proxy restart` | Stop and start again (applies saved changes) |
| `socks5-proxy reset` | Restart with fresh traffic counters (clears stats + conns) |
| `socks5-proxy status` | Show running state + saved settings + live stats (bytes, recent connections) |
| `socks5-proxy status -w [secs]` | Live-updating status, redrawn every N seconds (default 2) — Ctrl+C to stop |
| `socks5-proxy logs` | Show the proxy log (follows live while running); colorized when on a terminal |
| `socks5-proxy logs --color` | Force colored log lines (errors red, warnings yellow, connections cyan, banner green) |
| `socks5-proxy set port 1080` | Save the listening port |
| `socks5-proxy set ip 192.168.1.10` | Save the listening IP (`0.0.0.0` = all IPv4 interfaces, `::` = all IPv4 + IPv6) |
| `socks5-proxy set auth myuser` | Enable auth — you'll be prompted for the password (hidden) |
| `socks5-proxy set auth myuser mypass` | Enable auth with an explicit password |
| `socks5-proxy set idle 900` | Close connections idle for 15 minutes (default 600s) |
| `socks5-proxy set maxconns 64` | Allow at most 64 simultaneous connections (default 256) |
| `socks5-proxy set loglevel info` | Log verbosity: `debug`, `info`, `warning`, `error` (default `warning`) |
| `socks5-proxy unset auth` | Disable authentication |
| `socks5-proxy unset idle` | Restore the default idle timeout |
| `socks5-proxy unset maxconns` | Restore the default connection limit |
| `socks5-proxy unset loglevel` | Restore the default log level (warning) |
| `socks5-proxy show config` | Show the saved port, IP, auth state, and log level |
| `socks5-proxy --version` | Print the version |

### Configure your other devices

| Setting | Value |
|---------|-------|
| Type    | SOCKS5 |
| Host    | `<the IP shown by the script>` |
| Port    | `<the port you chose>` |

### Test it

```bash
curl --socks5 <PHONE_IP>:<PORT> https://api.ipify.org
```

If it prints your public IP, the proxy is working. With authentication
enabled, include the credentials:

```bash
curl --socks5 <USER>:<PASS>@<PHONE_IP>:<PORT> https://api.ipify.org
```

## Quick reference

| Action | Command |
|--------|---------|
| Start | `socks5-proxy` |
| Stop | `socks5-proxy stop` |
| Watch connections | `socks5-proxy logs` |
| Change port | `socks5-proxy set port 1080` |
| Change listening IP | `socks5-proxy set ip 0.0.0.0` |
| Apply changes while running | `socks5-proxy restart` |
| Clear traffic counters | `socks5-proxy reset` |
| Uninstall | `bash install.sh --uninstall && rm -rf $PREFIX/etc/socks5-proxy` |

## How it works

| File | Purpose |
|------|---------|
| `$PREFIX/etc/socks5-proxy/config` | Saved settings: port, IP, auth user/pass, idle timeout, max connections, log level (permissions 600) |
| `$PREFIX/etc/socks5-proxy/socks5_server.py` | The generated Python SOCKS5 server |
| `$PREFIX/etc/socks5-proxy/pid` | PID of the currently running proxy |
| `$PREFIX/etc/socks5-proxy/proxy.log` | Proxy output (view with `socks5-proxy logs`; rotated to `proxy.log.1` past 1 MiB) |
| `$PREFIX/etc/socks5-proxy/stats` | Live stats for `status` (uptime, connections, bytes) |
| `$PREFIX/etc/socks5-proxy/conns` | Recent connections with bytes relayed (for `status`) |

The proxy listens on the configured IP (default `0.0.0.0` — all interfaces)
at the chosen port. It relays TCP traffic in both directions with one thread
per connection; UDP ASSOCIATE uses a dedicated dispatcher thread that routes
each datagram to its client's own relay thread, so concurrent UDP clients
never steal each other's packets. `status` reads the live stats file written
by the server every couple of seconds, plus a list of recent connections
with how many bytes were relayed in each direction.

A relay that moves no data for the idle timeout (default 600s) is closed to
free its thread and sockets, and once the connection cap (default 256) is
reached new clients are closed without a handshake. TCP tunnels propagate
half-closes: when one side stops sending, the proxy signals that with a FIN
instead of tearing the whole tunnel down, so the other side's remaining data
still gets through. CONNECT failures are logged to `proxy.log` and return the
proper SOCKS5 reply code (0x05 refused, 0x04 unreachable, 0x01 general).

The log level (default `warning`, so the log only shows problems — failed
connects, rejected clients, errors) can be raised to `info` to also record
every connection or `debug` for full verbosity, or lowered to `error` to only
keep genuine failures. At `debug`, each tunnel also logs why it ended
(`up=eof|idle|reset|teardown down=...`) with the bytes relayed and duration —
so you can tell whether the proxy closed it (idle) or a peer did (eof/reset).
The startup banner is always logged so `logs` still confirms the proxy is
running at any level. Changes apply on restart.

## Testing

Run the test suite from the repo root:

```bash
bash tests/run.sh
```

It checks bash syntax, that the embedded Python compiles, the config/IP/port
helper functions, the SOCKS5 protocol (CONNECT with IPv4 and domain names,
UDP ASSOCIATE, IPv6, auth and throttling, FRAG handling, unreachable targets,
concurrent connections, large payloads), byte accounting, the CLI, and a full
start/stop/restart cycle. It uses a temporary prefix, so it never touches
your real configuration.

## Troubleshooting

**"Could not detect your Android IP!"**
The script tries `wlan0`, `wlan1`, then any `192.168.x.x` / `10.x.x.x`
address. If it fails, run `ip -4 addr` yourself and use that IP manually.

**Proxy fails to start**
The port may already be in use, or Python didn't install. Run it in the
foreground to see the error (the IP argument is optional):

```bash
python "$PREFIX/etc/socks5-proxy/socks5_server.py" 1080 0.0.0.0
```

**Nothing can connect**
Make sure the phone and the client are on the **same network**, and check that
your router doesn't block client-to-client traffic (AP isolation).

## Security

> ⚠️ **No authentication by default!** Unless you enable it, the proxy is
> open to anyone who can reach it.

Authentication is **off by default**. To require a username and password
(RFC 1929):

```bash
socks5-proxy set auth myuser        # prompts for the password (hidden)
socks5-proxy unset auth             # disable auth
```

Notes:

- The change applies on the next `start` (restart the proxy if it's running).
- Credentials are stored in plaintext in the config file
  (`$PREFIX/etc/socks5-proxy/config`, permissions 600, owned by your user).
- Failed login attempts are throttled (2 s per attempt) to slow brute force.
- Only run the proxy on networks you trust, and stop it when you don't need
  it (`socks5-proxy stop`). To limit exposure, bind to a specific interface
  instead of all interfaces: `socks5-proxy set ip 192.168.1.10`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the commit conventions. Please run
`bash tests/run.sh` before committing.
