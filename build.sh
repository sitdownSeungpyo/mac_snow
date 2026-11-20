#!/bin/bash
# Builds build/WinterDesk.app with swiftc (no Xcode project needed).
set -euo pipefail
cd "$(dirname "$0")"

APP="build/WinterDesk.app"
ARCH="$(uname -m)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 \
  -target "${ARCH}-apple-macos13.0" \
  -framework AppKit -framework SpriteKit -framework ServiceManagement -framework ApplicationServices -framework Carbon -framework IOKit \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/WinterDesk"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>WinterDesk</string>
    <key>CFBundleIdentifier</key><string>com.local.winterdesk</string>
    <key>CFBundleName</key><string>WinterDesk</string>
    <key>CFBundleDisplayName</key><string>WinterDesk</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force -s - --identifier com.local.winterdesk "$APP"
echo "Built $APP"
