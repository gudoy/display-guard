#!/bin/bash
#
# build.sh — build Display Guard.app (universal), and optionally install it or package it.
#
#   ./build.sh             build into build/Display Guard.app
#   ./build.sh --install   build, then install to /Applications and launch it
#   ./build.sh --dmg       build, then package build/DisplayGuard-<version>.dmg
#
# The app carries the scripts (reconcile.sh, odyssey-setup.sh, install-agent.sh) and sets
# everything else up itself on launch, so installing is just copying it to /Applications.
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
VERSION="1.2"
OUT="$ROOT/build"
APP="$OUT/Display Guard.app"
ID="com.diginja.displays.menubar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
    swiftc -O -target "$arch-apple-macos13.0" -o "$OUT/DisplayGuard-$arch" "$HERE"/*.swift
done
lipo -create -output "$APP/Contents/MacOS/DisplayGuard" "$OUT"/DisplayGuard-arm64 "$OUT"/DisplayGuard-x86_64
rm -f "$OUT"/DisplayGuard-arm64 "$OUT"/DisplayGuard-x86_64

# AppIcon.icns is generated from AppIcon.svg and committed, so building needs no extra tool.
cp "$HERE/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Display Guard</string>
    <key>CFBundleDisplayName</key><string>Display Guard</string>
    <key>CFBundleIdentifier</key><string>$ID</string>
    <key>CFBundleExecutable</key><string>DisplayGuard</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
codesign --force --sign - "$APP"
echo "Built: $APP"

case "${1:-}" in
    --install)
        pkill -x DisplayGuard 2>/dev/null || true
        sleep 1
        rm -rf "/Applications/Display Guard.app" "$HOME/Applications/Display Guard.app"
        ditto "$APP" "/Applications/Display Guard.app"
        open "/Applications/Display Guard.app"
        echo "Installed: /Applications/Display Guard.app"
        ;;
    --dmg)
        STAGE="$OUT/dmg"
        DMG="$OUT/DisplayGuard-$VERSION.dmg"
        rm -rf "$STAGE" "$DMG"
        mkdir -p "$STAGE"
        ditto "$APP" "$STAGE/Display Guard.app"
        ln -s /Applications "$STAGE/Applications"
        hdiutil create -quiet -volname "Display Guard" -srcfolder "$STAGE" -format UDZO "$DMG"
        rm -rf "$STAGE"
        echo "Packaged: $DMG"
        ;;
    "") ;;
    *) echo "usage: $0 [--install|--dmg]"; exit 2 ;;
esac
