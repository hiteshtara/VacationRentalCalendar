#!/bin/bash
# Renders the app icon and packs it into Resources/AppIcon.icns.
set -euo pipefail
cd "$(dirname "$0")/.."
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET" Resources
swift Scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo "wrote Resources/AppIcon.icns ($(wc -c < Resources/AppIcon.icns) bytes)"
