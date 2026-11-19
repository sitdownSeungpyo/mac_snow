#!/bin/bash
# Builds build/capspike (live feasibility spike for per-window cap windows; see Tools/capspike/main.swift).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13.0" \
  -framework AppKit -framework QuartzCore \
  Sources/CapGeometry.swift Tools/capspike/main.swift -o build/capspike
codesign --force -s - build/capspike
echo "Built build/capspike"
