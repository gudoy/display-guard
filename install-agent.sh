#!/bin/bash
#
# install-agent.sh — install (or reinstall) the display reconciler LaunchAgent.
#
# Generates the plist from the current user's paths, so it works on any Mac and under any
# username. Safe to re-run: it tears the old job down first.
#
#   ./install-agent.sh            install and start
#   ./install-agent.sh --status   show whether it is loaded
#   ./install-agent.sh --remove   stop and uninstall
#
set -uo pipefail

LABEL="com.diginja.displays.reconcile"
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/reconcile.sh"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

case "${1:-}" in
    --status)
        if launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1; then
            echo "Loaded."
            launchctl print "gui/$UID/$LABEL" 2>/dev/null \
              | grep -E "state =|run interval|last exit code" | sed 's/^[[:space:]]*/  /'
        else
            echo "Not loaded."
        fi
        echo
        echo "Recent activity:"
        tail -n 10 "$HERE/reconcile.log" 2>/dev/null | sed 's/^/  /' || echo "  (no log yet)"
        exit 0
        ;;
    --remove)
        launchctl bootout "gui/$UID/$LABEL" 2>/dev/null
        rm -f "$PLIST"
        echo "Removed. The reconciler no longer runs."
        exit 0
        ;;
    "") ;;
    *) echo "usage: $0 [--status|--remove]"; exit 2 ;;
esac

[ -x "$SCRIPT" ] || chmod +x "$SCRIPT" 2>/dev/null
[ -f "$SCRIPT" ] || { echo "ERROR: $SCRIPT not found."; exit 1; }

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$SCRIPT</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StartInterval</key>
    <integer>15</integer>
    <key>StandardOutPath</key>
    <string>$HERE/reconcile.err</string>
    <key>StandardErrorPath</key>
    <string>$HERE/reconcile.err</string>
    <key>ProcessType</key>
    <string>Background</string>
    <key>LowPriorityIO</key>
    <true/>
</dict>
</plist>
PLISTEOF

plutil -lint "$PLIST" >/dev/null || { echo "ERROR: generated plist is invalid."; exit 1; }

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null
launchctl bootstrap "gui/$UID" "$PLIST" || { echo "ERROR: launchctl bootstrap failed."; exit 1; }

echo "Installed and started: $LABEL"
echo "  script : $SCRIPT"
echo "  plist  : $PLIST"
echo "  log    : $HERE/reconcile.log"
echo
echo "It checks every 15s and repairs only when needed."
echo "Check it with: $0 --status"
