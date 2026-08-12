#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# install.sh — install socks5-proxy into $PREFIX/bin (Termux)
#
#   Usage:
#     bash install.sh                 install (or update) socks5-proxy
#     bash install.sh --prefix <dir>  install into <dir>/bin instead of $PREFIX
#     bash install.sh --uninstall     remove the installed copy (config kept)
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
        -h|--help)
            echo "Usage: bash install.sh [--prefix <dir>] [--uninstall]"
            exit 0
            ;;
        *)
            echo -e "${RED}❌ Unknown option: $1${NC}" >&2
            echo "Usage: bash install.sh [--prefix <dir>] [--uninstall]" >&2
            exit 1
            ;;
    esac
done

DEST="$PREFIX_DIR/bin/socks5-proxy"

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
[ -f "$DEST" ] && was_update=1

cp "$SOURCE" "$DEST"
chmod 755 "$DEST"

# Verify the copy really matches the source before claiming success
if ! cmp -s "$SOURCE" "$DEST"; then
    echo -e "${RED}❌ Installed copy differs from the source — check permissions/disk space.${NC}" >&2
    rm -f "$DEST"
    exit 1
fi

if [ "$was_update" -eq 1 ]; then
    echo -e "${GREEN}✅ Updated $DEST${NC}"
else
    echo -e "${GREEN}✅ Installed $DEST${NC}"
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
