#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# install.sh — install socks5-proxy into $PREFIX/bin (Termux)
#
#   Usage:
#     bash install.sh                 install (or update) socks5-proxy
#     bash install.sh --prefix <dir>  install into <dir>/bin instead of $PREFIX
#     bash install.sh --no-restart    update without restarting a running proxy
#     bash install.sh --uninstall     remove the installed copy (config kept)
#
#   Re-running the installer updates an existing installation: versions are
#   compared (same version = nothing to do), and a running proxy is restarted
#   with the new code so the update takes effect immediately.
#
# The installed copy is verified (syntax-checked and compared byte-for-byte
# with the source) before the script reports success.
# =============================================================================

GREEN=$'\033[0;32m'   # green  — success messages
YELLOW=$'\033[1;33m'  # yellow — informational text
RED=$'\033[0;31m'     # red    — errors
NC=$'\033[0m'         # no color — resets formatting back to default

# Resolve the repository directory from this script's own location, so it
# works no matter where install.sh is invoked from.
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$SOURCE_DIR/socks5-proxy"

# Termux always sets $PREFIX (e.g. /data/data/com.termux/files/usr); fall
# back to the well-known default when running outside Termux.
PREFIX_DIR="${PREFIX:-/data/data/com.termux/files/usr}"

mode="install"
do_restart=1   # restart a running proxy after an update so it takes effect
while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)
            [ -n "${2:-}" ] || { echo -e "${RED}❌ --prefix needs a directory argument${NC}" >&2; exit 1; }
            PREFIX_DIR="$2"
            shift 2
            ;;
        --uninstall)
            mode="uninstall"
            shift
            ;;
        --no-restart)
            do_restart=0
            shift
            ;;
        -h|--help)
            echo "Usage: bash install.sh [--prefix <dir>] [--no-restart] [--uninstall]"
            exit 0
            ;;
        *)
            echo -e "${RED}❌ Unknown option: $1${NC}" >&2
            echo "Usage: bash install.sh [--prefix <dir>] [--no-restart] [--uninstall]" >&2
            exit 1
            ;;
    esac
done

DEST="$PREFIX_DIR/bin/socks5-proxy"
CONFIG_DIR="$PREFIX_DIR/etc/socks5-proxy"

# ----------------------------------------------------------------------------
# get_version — print the VERSION= line from a socks5-proxy script
#   Args: $1 = path to the script
# ----------------------------------------------------------------------------
get_version() {
    sed -n 's/^VERSION="\([^"]*\)"/\1/p' "$1" | head -1
}

# ----------------------------------------------------------------------------
# proxy_is_running — is a proxy started under this prefix still alive?
#   Mirrors the launcher's stop check: the PID file must exist, the PID must
#   be alive, and its command line must be the generated server (so stale or
#   foreign PID files are ignored).
# ----------------------------------------------------------------------------
proxy_is_running() {
    [ -f "$CONFIG_DIR/pid" ] || return 1
    local pid
    pid=$(cat "$CONFIG_DIR/pid" 2>/dev/null || true)
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    grep -q "socks5_server.py" "/proc/$pid/cmdline" 2>/dev/null
}

# ----------------------------------------------------------------------------
# Uninstall: remove the installed copy. The saved config under
# $PREFIX/etc/socks5-proxy is deliberately left in place.
# ----------------------------------------------------------------------------
if [ "$mode" = "uninstall" ]; then
    if [ -f "$DEST" ]; then
        rm -f "$DEST"
        echo -e "${GREEN}✅ Removed $DEST${NC}"
    else
        echo -e "${YELLOW}ℹ️  Nothing to uninstall — $DEST does not exist.${NC}"
    fi
    echo -e "${YELLOW}ℹ️  Saved settings are kept at $PREFIX_DIR/etc/socks5-proxy/ — remove that directory manually to fully clean up.${NC}"
    exit 0
fi

# ----------------------------------------------------------------------------
# Install
# ----------------------------------------------------------------------------
if [ ! -f "$SOURCE" ]; then
    echo -e "${RED}❌ Not found: $SOURCE${NC}" >&2
    echo -e "${YELLOW}   Run this script from the repository root.${NC}" >&2
    exit 1
fi

# Never install a broken script
if ! bash -n "$SOURCE"; then
    echo -e "${RED}❌ socks5-proxy has a syntax error — install aborted.${NC}" >&2
    exit 1
fi

mkdir -p "$PREFIX_DIR/bin" || {
    echo -e "${RED}❌ Could not create $PREFIX_DIR/bin${NC}" >&2
    exit 1
}

was_update=0
OLD_VERSION=""
if [ -f "$DEST" ]; then
    was_update=1
    OLD_VERSION=$(get_version "$DEST")
fi

NEW_VERSION=$(get_version "$SOURCE")

# Nothing to do when the same version is already installed AND the copy is
# still intact (a corrupt same-version copy falls through and gets repaired)
if [ "$was_update" -eq 1 ] && [ -n "$OLD_VERSION" ] && [ "$OLD_VERSION" = "$NEW_VERSION" ] \
        && cmp -s "$SOURCE" "$DEST"; then
    echo -e "${YELLOW}ℹ️  socks5-proxy v$NEW_VERSION is already installed — nothing to update.${NC}"
    exit 0
fi

cp "$SOURCE" "$DEST"
chmod 755 "$DEST"

# Verify the copy really matches the source before claiming success
if ! cmp -s "$SOURCE" "$DEST"; then
    echo -e "${RED}❌ Installed copy differs from the source — check permissions/disk space.${NC}" >&2
    rm -f "$DEST"
    exit 1
fi

if [ "$was_update" -eq 1 ]; then
    if [ -n "$OLD_VERSION" ] && [ -n "$NEW_VERSION" ] && [ "$OLD_VERSION" != "$NEW_VERSION" ]; then
        echo -e "${GREEN}✅ Updated $DEST (v$OLD_VERSION → v$NEW_VERSION)${NC}"
    else
        echo -e "${GREEN}✅ Updated $DEST${NC}"
    fi
elif [ -n "$NEW_VERSION" ]; then
    echo -e "${GREEN}✅ Installed $DEST (v$NEW_VERSION)${NC}"
else
    echo -e "${GREEN}✅ Installed $DEST${NC}"
fi

# An update only takes effect for a running proxy once it is restarted with
# the new binary (the generated server is rewritten at every start).
if [ "$was_update" -eq 1 ] && proxy_is_running; then
    if [ "$do_restart" -eq 1 ]; then
        echo -e "${YELLOW}ℹ️  A proxy is running — restarting it with the new version...${NC}"
        PREFIX="$PREFIX_DIR" "$DEST" restart < /dev/null >/dev/null 2>&1
        if proxy_is_running; then
            echo -e "${GREEN}✅ Proxy restarted with the new version.${NC}"
        else
            echo -e "${YELLOW}⚠️  Could not restart the proxy — start it with: ${GREEN}socks5-proxy${NC}"
        fi
    else
        echo -e "${YELLOW}ℹ️  A proxy is running — restart it to apply the update (socks5-proxy restart).${NC}"
    fi
fi
echo -e ""
echo -e "${YELLOW}Next steps:${NC}"
echo -e "   Run:            ${GREEN}socks5-proxy${NC}"
echo -e "   First-run help: ${GREEN}socks5-proxy help${NC}"
echo -e ""
if ! command -v socks5-proxy >/dev/null 2>&1; then
    echo -e "${YELLOW}ℹ️  $PREFIX_DIR/bin is not on your PATH yet — add it:${NC}"
    echo -e "   ${GREEN}export PATH=\"$PREFIX_DIR/bin:\$PATH\"${NC}"
fi
echo -e "   Uninstall:      ${GREEN}bash $SOURCE_DIR/install.sh --uninstall${NC}"
