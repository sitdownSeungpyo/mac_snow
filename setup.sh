#!/bin/bash
# WinterDesk setup for macOS 13+. Installs or updates the latest release into ~/Applications.
#
#   Install / update:  curl -fsSL https://github.com/sitdownSeungpyo/mac_snow/releases/latest/download/setup.sh | bash
#   Uninstall:         curl -fsSL https://github.com/sitdownSeungpyo/mac_snow/releases/latest/download/setup.sh | bash -s -- --uninstall
#   As a file:         bash setup.sh [--uninstall]
#
# Downloads WinterDesk-macos-universal.zip, checks its SHA256 against SHA256SUMS.txt, quits a running
# WinterDesk, installs ~/Applications/WinterDesk.app, clears the quarantine flag and opens it. The app
# turns on Launch at Login by itself on its first run from ~/Applications. Re-running updates in place.
# Testing: --source-zip <zip> (SHA256SUMS.txt next to it), --no-open.
set -euo pipefail

# Everything is inside one { } group so `curl | bash` parses the whole script before running any of it.
{
REPO="sitdownSeungpyo/mac_snow"
BASE_URL="https://github.com/$REPO/releases/latest/download"
ZIP_NAME="WinterDesk-macos-universal.zip"
DEST="$HOME/Applications/WinterDesk.app"
AGENT="$HOME/Library/LaunchAgents/com.local.winterdesk.plist"

say()  { printf '  %s  /  %s\n' "$1" "$2"; }
fail() { printf '\n  WinterDesk setup failed: %s\n  설치에 실패했습니다. 위 메시지를 확인한 뒤 다시 실행해 주세요.\n' "$1" >&2; exit 1; }

UNINSTALL=0
OPEN=1
SOURCE_ZIP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --uninstall) UNINSTALL=1 ;;
    --no-open) OPEN=0 ;;
    --source-zip) [ $# -ge 2 ] || fail "--source-zip needs a path"; SOURCE_ZIP="$2"; shift ;;
    -h|--help) sed -n '2,11p' "$0" 2>/dev/null || true; exit 0 ;;
    *) fail "unknown option: $1" ;;
  esac
  shift
done

case "$(uname -s)" in
  Darwin) ;;
  MINGW*|MSYS*|CYGWIN*)
    echo "This is the macOS installer. On Windows, run this in PowerShell instead:"
    echo "  Windows에서는 PowerShell에서 아래 명령을 실행하세요:"
    echo "  irm $BASE_URL/setup.ps1 | iex"
    exit 1 ;;
  *)
    echo "WinterDesk runs on macOS 13+ and Windows 10/11 only (this system: $(uname -s))."
    echo "WinterDesk는 macOS 13 이상과 Windows 10/11에서만 실행됩니다."
    echo "  macOS:   curl -fsSL $BASE_URL/setup.sh | bash"
    echo "  Windows: irm $BASE_URL/setup.ps1 | iex   (PowerShell)"
    exit 1 ;;
esac

major="$(sw_vers -productVersion | cut -d. -f1)"
if [ "${major:-0}" -lt 13 ]; then
  fail "macOS 13 or later is required (this Mac: $(sw_vers -productVersion)) / macOS 13 이상이 필요합니다"
fi

quit_app() {
  pgrep -x WinterDesk >/dev/null 2>&1 || return 0
  say "Quitting the running WinterDesk" "실행 중인 WinterDesk를 종료합니다"
  pkill -x WinterDesk 2>/dev/null || true   # SIGTERM, like install.sh
  for _ in $(seq 1 25); do
    pgrep -x WinterDesk >/dev/null 2>&1 || return 0
    sleep 0.2
  done
  pkill -9 -x WinterDesk 2>/dev/null || true
  sleep 0.5
}

echo
echo "  WinterDesk setup"
echo

if [ "$UNINSTALL" = 1 ]; then
  quit_app
  # The LaunchAgent fallback the app writes (Sources/LoginItem.swift); only ours, by label.
  if [ -f "$AGENT" ] && grep -q "com.local.winterdesk" "$AGENT"; then
    rm -f "$AGENT"
    say "Launch at Login (LaunchAgent) removed" "로그인 시 실행 해제"
  fi
  if [ -d "$DEST" ]; then
    rm -rf "$DEST"
    say "App removed: $DEST" "앱 삭제 완료"
  fi
  say "WinterDesk uninstalled. Settings (com.local.winterdesk) are kept" "WinterDesk 제거 완료. 설정은 남아 있습니다"
  echo "  If WinterDesk still appears in System Settings > General > Login Items, remove it there."
  echo "  시스템 설정 > 일반 > 로그인 항목에 남아 있으면 그곳에서 삭제하세요."
  exit 0
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/winterdesk-setup.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

if [ -n "$SOURCE_ZIP" ]; then
  ZIP="$SOURCE_ZIP"
  SUMS="$(dirname "$SOURCE_ZIP")/SHA256SUMS.txt"
  ZIP_KEY="$(basename "$SOURCE_ZIP")"
  [ -f "$ZIP" ] || fail "source zip not found: $ZIP"
  [ -f "$SUMS" ] || fail "SHA256SUMS.txt not found next to $ZIP"
else
  ZIP="$TMP/$ZIP_NAME"
  SUMS="$TMP/SHA256SUMS.txt"
  ZIP_KEY="$ZIP_NAME"
  say "Downloading the latest release" "최신 버전을 내려받는 중"
  curl -fsSL --retry 3 -o "$ZIP" "$BASE_URL/$ZIP_NAME" || fail "download failed: $BASE_URL/$ZIP_NAME"
  curl -fsSL --retry 3 -o "$SUMS" "$BASE_URL/SHA256SUMS.txt" || fail "download failed: $BASE_URL/SHA256SUMS.txt"
fi

expected="$(awk -v f="$ZIP_KEY" '{ n = $2; sub(/^\*/, "", n); if (n == f) { print tolower($1); exit } }' "$SUMS")"
[ -n "$expected" ] || fail "SHA256SUMS.txt has no entry for $ZIP_KEY"
actual="$(shasum -a 256 "$ZIP" | awk '{ print tolower($1) }')"
[ "$expected" = "$actual" ] || fail "SHA256 mismatch for $ZIP_KEY: expected $expected, got $actual. The download may be corrupted; try again."
say "SHA256 verified" "SHA256 확인 완료"

# Extract to a temp folder first so a bad archive never half-replaces the install.
ditto -x -k "$ZIP" "$TMP/stage" || fail "could not extract $ZIP_KEY"
[ -f "$TMP/stage/WinterDesk.app/Contents/MacOS/WinterDesk" ] || fail "WinterDesk.app not found in $ZIP_KEY"

quit_app
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto "$TMP/stage/WinterDesk.app" "$DEST" || fail "could not write $DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
say "Installed: $DEST" "설치 완료"

if [ "$OPEN" = 1 ]; then
  open "$DEST" || fail "could not open $DEST"
  say "WinterDesk started: click the snowflake in the menu bar" "WinterDesk 실행됨: 메뉴 막대의 눈송이 아이콘을 클릭하세요"
  say "Launch at Login turns on automatically on first run" "로그인 시 자동 실행은 첫 실행 때 자동으로 켜집니다"
  say "Emergency quit: Control+Option+Command+Q" "비상 종료: Control+Option+Command+Q"
fi
echo
say "Done" "완료"
exit 0
}
