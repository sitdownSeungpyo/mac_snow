#!/usr/bin/env bash
# Restore the wallpaper(s) saved by set_wallpaper.sh.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAVE="$DIR/previous_wallpaper.txt"
[[ -s "$SAVE" ]] || { echo "no saved wallpaper at $SAVE" >&2; exit 1; }
STORE_BAK="$DIR/previous_wallpaper_store.plist"
STORE="$HOME/Library/Application Support/com.apple.wallpaper/Store/Index.plist"

# Built-in/dynamic wallpapers have no file path ("missing value"). In that case
# restore the backed-up wallpaper store and restart WallpaperAgent.
if ! grep -qv '^missing value$' "$SAVE"; then
  if [[ -f "$STORE_BAK" ]]; then
    cp -p "$STORE_BAK" "$STORE"
    killall WallpaperAgent 2>/dev/null || true
    echo "restored built-in wallpaper settings from $STORE_BAK"
    exit 0
  fi
  echo "original wallpaper was a built-in one and no store backup exists;" >&2
  echo "pick it again in System Settings > Wallpaper." >&2
  exit 1
fi

i=1
while IFS= read -r pic || [[ -n "$pic" ]]; do
  [[ -z "$pic" || "$pic" == "missing value" ]] && { i=$((i + 1)); continue; }
  if [[ -e "$pic" ]]; then
    osascript -e "tell application \"System Events\" to set picture of desktop $i to POSIX file \"$pic\"" \
      && echo "desktop $i -> $pic" || echo "desktop $i: could not set (screen gone?)" >&2
  else
    echo "desktop $i: saved file no longer exists: $pic" >&2
  fi
  i=$((i + 1))
done < "$SAVE"

# If there are more desktops now than were saved, give them the first saved picture.
count=$(osascript -e 'tell application "System Events" to count desktops')
first="$(grep -v '^missing value$' "$SAVE" | head -n1 || true)"
if [[ -n "$first" && -e "$first" && "$count" -ge "$i" ]]; then
  for ((j = i; j <= count; j++)); do
    osascript -e "tell application \"System Events\" to set picture of desktop $j to POSIX file \"$first\""
  done
fi
echo "restore done"
