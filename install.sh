#!/bin/bash
#
# install.sh — set up Display Guard on this Mac, in one go.
#
# Before running: install BetterDisplay (Pro), connect both panels over DisplayPort, and
# arrange them in System Settings > Displays the way you want them. The current
# arrangement is saved as the one to enforce.
#
# Safe to re-run: every step replaces what a previous run installed.
#
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

step() { printf '\n== %s\n' "$*"; }
fail() { echo "ERROR: $*"; exit 1; }

step "Prerequisites"
[ -x /Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay ] \
    || fail "BetterDisplay not found in /Applications. Install it from https://betterdisplay.pro"
xcrun --find swiftc >/dev/null 2>&1 \
    || fail "Swift compiler missing. Run: xcode-select --install   then re-run this script."
pgrep -xq BetterDisplay || { open -a BetterDisplay; sleep 10; }
echo "BetterDisplay and swiftc OK"

# Two tools enforcing different layouts made the panels flicker on 2026-10-31.
if grep -qs '^[[:space:]]*screenWatcher:start()' "$HOME/.hammerspoon/init.lua"; then
    echo "WARNING: ~/.hammerspoon/init.lua still runs a screen watcher. It will fight"
    echo "         Display Guard and make the panels flicker. Comment out screenWatcher:start()."
fi

step "BetterDisplay settings (identification, resolution protection)"
./odyssey-setup.sh || fail "odyssey-setup.sh failed, see above."

if [ ! -s layout.conf ]; then
    step "Saving the current arrangement to layout.conf"
    ./odyssey-setup.sh --save-layout
fi
echo "Enforced layout:"; sed 's/^/  /' layout.conf

step "Reconciler agent (every 15s)"
./install-agent.sh | head -1

step "Menu bar app"
./menubar/build.sh | tail -1

step "Done"
echo "Look for the two-screen icon in the menu bar."
