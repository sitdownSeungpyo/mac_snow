#!/bin/bash
# Builds build/WinterDesk.app with swiftc (no Xcode project needed).
set -euo pipefail
cd "$(dirname "$0")"

APP="build/WinterDesk.app"
# Architectures to build: host arch by default; e.g. ARCHS="arm64 x86_64" for a universal binary.
read -r -a ARCH_LIST <<< "${ARCHS:-$(uname -m)}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

compile() {  # compile <arch> <output>
  swiftc -O -swift-version 5 \
    -target "$1-apple-macos13.0" \
    -framework AppKit -framework SpriteKit -framework ServiceManagement -framework ApplicationServices -framework Carbon -framework IOKit \
    Sources/*.swift \
    -o "$2"
}

if [ "${#ARCH_LIST[@]}" -eq 1 ]; then
  compile "${ARCH_LIST[0]}" "$APP/Contents/MacOS/WinterDesk"
else
  SLICES=()
  for A in "${ARCH_LIST[@]}"; do
    compile "$A" "build/WinterDesk-$A"
    SLICES+=("build/WinterDesk-$A")
  done
  lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/WinterDesk"
  rm -f "${SLICES[@]}"
fi

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
