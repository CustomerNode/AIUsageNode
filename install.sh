#!/usr/bin/env bash
# AI Usage Node — installer
# Installs the applet into ~/.local/share/cinnamon/applets/ and (optionally)
# adds it to the bottom panel.
#
# Usage:
#   ./install.sh          # install only; you add it via panel right-click
#   ./install.sh --add    # also drop it into the bottom panel automatically
#
set -euo pipefail

UUID="aiusagenode@CustomerNode"
DEST="$HOME/.local/share/cinnamon/applets/$UUID"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

# When piped from curl, $SRC_DIR is /dev/fd/* — fall back to a clone.
if [[ ! -d "$SRC_DIR/$UUID" ]]; then
    TMP="$(mktemp -d)"
    echo "[ai-usage-node] cloning into $TMP ..."
    git clone --depth 1 https://github.com/CustomerNode/AIUsageNode.git "$TMP" >/dev/null
    SRC_DIR="$TMP"
fi

if [[ ! -d "$SRC_DIR/$UUID" ]]; then
    echo "ERROR: source applet directory not found at $SRC_DIR/$UUID" >&2
    exit 1
fi

# Sanity check: claude CLI present?
if ! command -v claude >/dev/null 2>&1; then
    echo "WARNING: 'claude' CLI not found on PATH. The applet needs Claude Code installed and logged in to fetch usage data."
    echo "         Install: https://docs.claude.com/claude-code"
fi

# Sanity check: cinnamon present?
if ! command -v cinnamon >/dev/null 2>&1; then
    echo "ERROR: cinnamon not found. This applet only runs on the Cinnamon desktop." >&2
    exit 1
fi

mkdir -p "$DEST"
cp -f "$SRC_DIR/$UUID/"*.js   "$DEST/"
cp -f "$SRC_DIR/$UUID/"*.json "$DEST/"
cp -f "$SRC_DIR/$UUID/"*.svg  "$DEST/"
echo "[ai-usage-node] installed to $DEST"

if [[ "${1:-}" == "--add" ]]; then
    NEXT_ID="$(gsettings get org.cinnamon next-applet-id)"
    NEW_ENTRY="panel1:right:0:$UUID:$NEXT_ID"
    export CUR="$(gsettings get org.cinnamon enabled-applets)"
    export UUID NEW_ENTRY
    NEW="$(python3 -c '
import ast, os
cur = ast.literal_eval(os.environ["CUR"])
uuid = os.environ["UUID"]
entry = os.environ["NEW_ENTRY"]
if not any(uuid in x for x in cur):
    cur.append(entry)
print(repr(cur))
')"
    gsettings set org.cinnamon enabled-applets "$NEW"
    gsettings set org.cinnamon next-applet-id $((NEXT_ID + 1))
    echo "[ai-usage-node] added to bottom panel."
fi

echo
echo "Next steps:"
echo "  1. If the applet doesn't appear immediately, restart Cinnamon (Ctrl+Alt+Esc)."
if [[ "${1:-}" != "--add" ]]; then
    echo "  2. Right-click the panel -> Applets -> 'AI Usage Node' -> Add to panel."
fi
echo "  3. Right-click the sparkle icon -> Configure to tweak thresholds and refresh."
echo
