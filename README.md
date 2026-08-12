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
- 🎛️ Full CLI: `start`, `stop`, `status`, `set port`, `set ip`, `show config`
- 🐍 Self-contained Python SOCKS5 server (RFC 1928), generated on first run
- 🔄 Handles IPv4, domain names, and IPv6 targets
- 🛡️ Restarts cleanly — a PID file tracks the running proxy, and a previous
  instance is verified and stopped before starting a new one
- 🧵 Per-connection threading, partial-read safe, `sendall`-based relay
- ⚡ Performance-tuned: 64 KiB relay buffers, `TCP_NODELAY`, and larger
  kernel socket buffers for low-latency, high-throughput transfers
- 🔒 Optional username/password authentication (RFC 1929), off by default

## Requirements

- [Termux](https://termux.com) on Android (F-Droid build recommended)
- `python` (installed automatically by the script if missing)

## Installation

1. Copy the script into Termux's bin directory and make it executable:

   ```bash
   cp socks5-proxy "$PREFIX/bin/socks5-proxy"
   chmod +x "$PREFIX/bin/socks5-proxy"
   ```

   (If you cloned this repo, the file is already executable.)

2. Run it:

   ```bash
   socks5-proxy
   ```

   On first run, Python will be installed automatically if needed.

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
| `socks5-proxy status` | Show whether the proxy is running + saved settings |
| `socks5-proxy set port 1080` | Save the listening port |
| `socks5-proxy set ip 192.168.1.10` | Save the listening IP (`0.0.0.0` = all interfaces) |
| `socks5-proxy set auth myuser mypass` | Enable username/password auth (RFC 1929) |
| `socks5-proxy unset auth` | Disable authentication |
| `socks5-proxy show config` | Show the saved port, IP, and auth state |
| `socks5-proxy help` | Show the help screen |

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
| Change port | `socks5-proxy set port 1080` |
| Change listening IP | `socks5-proxy set ip 0.0.0.0` |
| Uninstall | `rm -rf $PREFIX/etc/socks5-proxy && rm $PREFIX/bin/socks5-proxy` |

## How it works

| File | Purpose |
|------|---------|
| `$PREFIX/etc/socks5-proxy/config` | Remembers the port and listening IP |
| `$PREFIX/etc/socks5-proxy/socks5_server.py` | The generated Python SOCKS5 server |
| `$PREFIX/etc/socks5-proxy/pid` | PID of the currently running proxy |

The proxy listens on the configured IP (default `0.0.0.0` — all interfaces)
at the chosen port, and relays TCP traffic in both directions using one
thread per connection.

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
socks5-proxy set auth myuser mypassword   # enable auth
socks5-proxy unset auth                   # disable auth
```

Notes:

- The change applies on the next `start` (restart the proxy if it's running).
- Credentials are stored in plaintext in the config file
  (`$PREFIX/etc/socks5-proxy/config`).
- Only run the proxy on networks you trust, and stop it when you don't need
  it (`socks5-proxy stop`). To limit exposure, bind to a specific interface
  instead of all interfaces: `socks5-proxy set ip 192.168.1.10`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the commit conventions.
