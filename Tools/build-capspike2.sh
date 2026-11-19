#!/bin/bash
# Builds build/capspike2: several cap windows using the app's own CapWindow/CapMover/SkyLight code.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13.0" \
  -framework AppKit -framework SpriteKit -framework ServiceManagement -framework ApplicationServices -framework Carbon -framework IOKit \
  $(ls Sources/*.swift | grep -v '/main.swift$') Tools/capspike2/main.swift -o build/capspike2
codesign --force -s - build/capspike2
echo "Built build/capspike2"
