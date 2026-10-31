#!/bin/bash
#
# odyssey-setup.sh — configure two Samsung Odyssey G93SC panels on an Apple Silicon Mac.
#
# Background (measured on a MacBook Pro M5 Pro, 2026-09):
#   * Samsung reports a different EDID modelNumber per input port, so BetterDisplay's
#     default "vendorModelSerial" identification spawns a new display entry on every
#     reconnect and silently drops its settings. The alphanumeric serial is stable, so
#     this script pins identification to it.
#   * Only one display pipe (dispext0) exposes the 7680x4608 link container required for
#     5120x1440 @ 240Hz. Whichever panel lands on that pipe gets 240Hz; the other caps at
#     120Hz. This is an SoC limit — no dock, KVM or cable changes it.
#   * The panel's HDMI input caps at 5120x1440 @ 120Hz regardless of pipe. 240Hz is
#     DisplayPort-only.
#   * Switching ports/cables reassigns which panel is on the fast pipe, so this script
#     picks the best mode each display actually offers rather than hardcoding one.
#
# Usage:
#   ./odyssey-setup.sh            apply settings
#   ./odyssey-setup.sh --check    report only, change nothing
#
set -uo pipefail

RES="5120x1440"                        # target resolution
PRODUCT="Odyssey G93SC"                # panels to manage when layout.conf does not exist yet
LAYOUT_FILE="$(cd "$(dirname "$0")" && pwd)/layout.conf"

MODE="apply"
case "${1:-}" in
    --check)          MODE="check" ;;
    --save-layout)    MODE="save-layout" ;;
    --restore-layout) MODE="restore-layout" ;;
    "")               MODE="apply" ;;
    *) echo "usage: $0 [--check|--save-layout|--restore-layout]"; exit 2 ;;
esac
CHECK_ONLY=0
[ "$MODE" = "check" ] && CHECK_ONLY=1

# Prefer the app binary so the script works without Homebrew.
BD=""
for c in "/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay" \
         "$(command -v betterdisplaycli 2>/dev/null)"; do
    [ -n "$c" ] && [ -x "$c" ] && BD="$c" && break
done
if [ -z "$BD" ]; then
    echo "ERROR: BetterDisplay not found."
    echo "  Install the app from https://betterdisplay.pro (Pro licence required for"
    echo "  resolution protection), or: brew install waydabber/betterdisplay/betterdisplaycli"
    exit 1
fi

if ! pgrep -xq BetterDisplay; then
    echo "BetterDisplay is not running; starting it."
    open -a BetterDisplay || exit 1
    sleep 10
fi

# tagID for a given alphanumeric serial, empty if that panel is not connected.
tag_for_serial() {
    "$BD" get --identifiers 2>/dev/null \
      | tr -d '\n' | sed 's/},{/}\
{/g' \
      | grep -F "\"$1\"" \
      | sed -n 's/.*"tagID" *: *"\([0-9]*\)".*/\1/p' | head -1
}

# Highest fixed-refresh mode at $RES for a tagID: prints "<modeNumber> <hz>".
best_mode() {
    "$BD" get --tagID="$1" --displayModeList 2>/dev/null \
      | awk -v res="$RES" '
          $3 == res && $4 ~ /^[0-9]+Hz$/ {
              hz = $4; sub(/Hz$/, "", hz); hz += 0
              if (hz > best) { best = hz; mode = $1 }
          }
          END { if (mode != "") print mode, best }'
}

current_mode() {
    "$BD" get --tagID="$1" --displayModeList 2>/dev/null | grep -i "Current" | head -1
}

fast_pipe() {   # non-zero means this display is on the 240Hz-capable pipe
    "$BD" get --tagID="$1" --connectionModeListAll 2>/dev/null | grep -c 7680x4608
}

placement_of() { "$BD" get --tagID="$1" --placement 2>/dev/null | tr -d '[:space:]'; }

# The panels, by alphanumeric serial. layout.conf is the source of truth once it exists;
# before that (fresh machine), every connected "$PRODUCT" is taken.
SERIALS=()
if [ -s "$LAYOUT_FILE" ]; then
    while IFS='=' read -r k _; do
        [ -n "$k" ] && [ "$k" != "PRIMARY" ] && SERIALS+=("$k")
    done < "$LAYOUT_FILE"
else
    while read -r s; do [ -n "$s" ] && SERIALS+=("$s"); done < <(
        "$BD" get --identifiers 2>/dev/null \
          | tr -d '\n' | sed 's/},{/}\
{/g' \
          | grep -F "\"productName\" : \"$PRODUCT\"" \
          | sed -n 's/.*"alphanumericSerial" *: *"\([^"]*\)".*/\1/p')
fi
if [ "${#SERIALS[@]}" -eq 0 ]; then
    echo "ERROR: no $PRODUCT connected and no $LAYOUT_FILE. Connect the panels and retry."
    exit 1
fi

# --- layout save / restore -------------------------------------------------
# Screen arrangement (which panel sits left/right) is a display *group* property.
# `placement` is the position in the global logical-pixel space, as "XxY".
# NOTE: untested — both panels were disconnected when this was written.
if [ "$MODE" = "save-layout" ]; then
    primary=$(grep '^PRIMARY=' "$LAYOUT_FILE" 2>/dev/null || true)   # keep the 240Hz preference
    : > "$LAYOUT_FILE"
    [ -n "$primary" ] && echo "$primary" >> "$LAYOUT_FILE"
    saved=0
    for serial in "${SERIALS[@]}"; do
        tag=$(tag_for_serial "$serial")
        [ -z "$tag" ] && { echo "[$serial] not connected — skipped"; continue; }
        pos=$(placement_of "$tag")
        if [ -n "$pos" ]; then
            echo "$serial=$pos" >> "$LAYOUT_FILE"
            echo "[$serial] placement $pos saved"
            saved=$((saved+1))
        else
            echo "[$serial] could not read placement"
        fi
    done
    [ "$saved" -gt 0 ] && echo "Written to $LAYOUT_FILE" || echo "Nothing saved."
    exit 0
fi

if [ "$MODE" = "restore-layout" ]; then
    [ -f "$LAYOUT_FILE" ] || { echo "No saved layout at $LAYOUT_FILE — run --save-layout first."; exit 1; }
    while IFS='=' read -r serial pos; do
        [ -z "${serial:-}" ] || [ "$serial" = "PRIMARY" ] && continue
        tag=$(tag_for_serial "$serial")
        [ -z "$tag" ] && { echo "[$serial] not connected — skipped"; continue; }
        "$BD" set --tagID="$tag" --placement="$pos" >/dev/null 2>&1
        echo "[$serial] placement restored to $pos (now $(placement_of "$tag"))"
    done < "$LAYOUT_FILE"
    exit 0
fi

echo "BetterDisplay: $BD"
echo "Mode: $([ $CHECK_ONLY -eq 1 ] && echo 'check only' || echo 'apply')"
echo

rc=0
for serial in "${SERIALS[@]}"; do
    tag=$(tag_for_serial "$serial")
    if [ -z "$tag" ]; then
        echo "[$serial] not connected — skipped"
        echo
        continue
    fi

    pipe=$(fast_pipe "$tag")
    read -r mode hz <<< "$(best_mode "$tag")"

    echo "[$serial] tagID=$tag"
    echo "  fast pipe (7680x4608 containers) : $pipe $([ "$pipe" -gt 0 ] && echo '-> 240Hz capable' || echo '-> capped at 120Hz')"
    echo "  best $RES mode available         : ${mode:-none} (${hz:-?}Hz)"
    echo "  current                          : $(current_mode "$tag")"

    if [ -z "$mode" ]; then
        echo "  WARNING: no $RES mode offered. Check the cable, the port, and that the"
        echo "           monitor OSD has 'Display Port Ver.' set to 1.4."
        rc=1
        echo
        continue
    fi

    if [ $CHECK_ONLY -eq 0 ]; then
        # Stable identification across the KVM's changing model numbers.
        "$BD" set --tagID="$tag" --identificationMethod=alphanumericSerial >/dev/null 2>&1

        # --resolution/--refreshRate silently fails to change refresh; mode number works.
        "$BD" set --tagID="$tag" --displayModeNumber="$mode" >/dev/null 2>&1
        sleep 4

        # Re-apply the mode on every reconnect (KVM switches, sleep/wake).
        "$BD" set --tagID="$tag" --protectResolution=on >/dev/null 2>&1
        sleep 1

        echo "  applied                          : mode $mode (${hz}Hz), identification + protection set"
    fi
    echo
done

# Keep the screen arrangement (which panel is left/right) across reconnects.
if [ $CHECK_ONLY -eq 0 ]; then
    if "$BD" set --deviceType=DisplayGroup --layoutProtection=on >/dev/null 2>&1; then
        echo "Display group layout protection: on"
    else
        echo "Display group layout protection: could not be set (check it in the UI)"
    fi
else
    echo "Saved layout file: $([ -f "$LAYOUT_FILE" ] && cat "$LAYOUT_FILE" | tr '\n' ' ' || echo 'none')"
fi
echo

echo "Reminder: resolution protection guards the resolution, not the refresh rate."
echo "Re-run this script after changing cables or ports."
exit $rc
