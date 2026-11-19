#!/bin/bash
# Builds WinterDesk.app, replaces the copy in ~/Applications and launches it.
# The app registers itself to launch at login on its first run (SMAppService, or a
# ~/Library/LaunchAgents fallback for this ad-hoc signed build). Not run automatically.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

# Stop the running instance (graceful first, then forced).
pkill -x WinterDesk 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
  pgrep -x WinterDesk >/dev/null || break
  sleep 0.3
done
pkill -9 -x WinterDesk 2>/dev/null || true

DEST="$HOME/Applications/WinterDesk.app"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto build/WinterDesk.app "$DEST"
open "$DEST"
echo "Installed and launched $DEST"
echo "Emergency quit: Control+Option+Command+Q"
