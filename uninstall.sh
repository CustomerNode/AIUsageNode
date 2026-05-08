#!/usr/bin/env bash
# AI Usage Node — uninstaller
set -euo pipefail

UUID="aiusagenode@CustomerNode"
DEST="$HOME/.local/share/cinnamon/applets/$UUID"

# Remove from any panel zones
CUR="$(gsettings get org.cinnamon enabled-applets)"
NEW="$(CUR="$CUR" python3 -c "
import ast, os
cur = ast.literal_eval(os.environ['CUR'])
cur = [x for x in cur if '$UUID' not in x]
print(repr(cur))
")"
gsettings set org.cinnamon enabled-applets "$NEW"

# Remove the applet directory
if [[ -d "$DEST" ]]; then
    rm -rf "$DEST"
    echo "[ai-usage-node] removed $DEST"
fi

echo "[ai-usage-node] uninstalled. Restart Cinnamon (Ctrl+Alt+Esc) if anything looks stuck."
