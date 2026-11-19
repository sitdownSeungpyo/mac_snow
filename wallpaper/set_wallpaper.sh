#!/usr/bin/env bash
# Set winter-night.png as the wallpaper on every desktop.
# Saves the current wallpaper path(s) first so restore_wallpaper.sh can undo it.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$DIR/winter-night.png"
DEST_DIR="$HOME/Pictures/WinterDesk"
DEST="$DEST_DIR/winter-night.png"
SAVE="$DIR/previous_wallpaper.txt"

[[ -f "$SRC" ]] || { echo "missing $SRC (run the generator first)" >&2; exit 1; }

# 1. Save current wallpaper(s), one path per desktop/screen, in desktop order.
#    If a save already exists (e.g. the script was run before), keep it so the
#    true original is never overwritten by the WinterDesk image.
if [[ -s "$SAVE" ]]; then
  echo "keeping existing $SAVE"
else
  osascript -e 'set AppleScript'"'"'s text item delimiters to linefeed' \
            -e 'tell application "System Events" to set pics to picture of every desktop' \
            -e 'return pics as text' > "$SAVE"
  echo "saved current wallpaper(s) to $SAVE:"
  sed 's/^/  /' "$SAVE"
  # Built-in/dynamic wallpapers report "missing value" (no file path), so also
  # back up the macOS wallpaper store; restore_wallpaper.sh puts it back.
  STORE="$HOME/Library/Application Support/com.apple.wallpaper/Store/Index.plist"
  if [[ -f "$STORE" ]]; then
    cp -p "$STORE" "$DIR/previous_wallpaper_store.plist"
    echo "backed up wallpaper store to $DIR/previous_wallpaper_store.plist"
  fi
fi

# 2. Copy the image to a stable location.
mkdir -p "$DEST_DIR"
cp -f "$SRC" "$DEST"

# 3. Apply to all desktops.
osascript -e "tell application \"System Events\" to tell every desktop to set picture to POSIX file \"$DEST\""
echo "wallpaper set to $DEST"
