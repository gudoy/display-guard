#!/bin/bash
#
# build.sh — compile Display Guard and start it at login.
#
#   ./build.sh            build, install to ~/Applications, start now and at every login
#   ./build.sh --remove   stop it and remove the app and its LaunchAgent
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/Display Guard.app"
BIN="$APP/Contents/MacOS/DisplayGuard"
LABEL="com.diginja.displays.menubar"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true

if [ "${1:-}" = "--remove" ]; then
    rm -rf "$APP" "$PLIST"
    echo "Removed Display Guard. The reconciler agent is untouched."
    exit 0
fi

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$HOME/Library/LaunchAgents"
swiftc -O -o "$BIN" "$HERE/DisplayGuard.swift"
# AppIcon.icns is generated from AppIcon.svg and committed, so building needs no extra tool.
cp "$HERE/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Display Guard</string>
    <key>CFBundleIdentifier</key><string>$LABEL</string>
    <key>CFBundleExecutable</key><string>DisplayGuard</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
codesign --force --sign - "$APP"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>Program</key><string>$BIN</string>
    <key>EnvironmentVariables</key>
    <dict><key>DISPLAY_SETUP_DIR</key><string>$(dirname "$HERE")</string></dict>
    <key>RunAtLoad</key><true/>
    <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
EOF
launchctl bootstrap "gui/$UID" "$PLIST"
echo "Display Guard installed and running: $APP"
