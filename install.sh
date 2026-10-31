#!/bin/bash
#
# install.sh — build Display Guard from source and install it to /Applications.
#
# Without Xcode tools, download the .dmg from the GitHub Releases page instead.
# The app does the rest on first launch (BetterDisplay settings, screen arrangement,
# reconciler agent, start at login).
#
set -euo pipefail
xcrun --find swiftc >/dev/null 2>&1 || {
    echo "Swift compiler missing. Run: xcode-select --install   or use the .dmg from GitHub Releases."
    exit 1
}
"$(cd "$(dirname "$0")" && pwd)/menubar/build.sh" --install
