#!/bin/bash
#
# reconcile.sh — force the two Odyssey G93SC panels back to the intended state.
#
# Why this exists: after a wake or a reconnect macOS re-arbitrates display bandwidth and
# regularly lands on a bad combination — both panels reaching for 240Hz, neither getting
# it, and one of them dropping below 5120x1440. BetterDisplay's own protections are not
# enough: protectResolution guards the resolution but not the refresh rate, and layout
# protection does not always survive a cold wake.
#
# The fix is ordered, not declarative. Only one panel can hold 240Hz at a time, so the
# secondary must be pushed down to 120Hz *first* to free the budget, and only then is the
# primary raised to 240Hz. Applying them in the other order fails.
#
# Idempotent and cheap: a full state read is ~0.4s and nothing is written when the state
# already matches, so this is safe to run on a short timer.
#
# Run by com.diginja.displays.reconcile (LaunchAgent), every 15s and at login.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LAYOUT_FILE="$HERE/layout.conf"
LOG="$HERE/reconcile.log"
# The panels are the serials listed in layout.conf (machine-local, written by install.sh).
SERIALS=()
while IFS='=' read -r k _; do
    [ -n "$k" ] && [ "$k" != "PRIMARY" ] && SERIALS+=("$k")
done < "$LAYOUT_FILE" 2>/dev/null
[ "${#SERIALS[@]}" -eq 0 ] && exit 0
RES="5120x1440"
HI="240Hz"
LO="120Hz"
PAUSE_FILE="$HERE/paused"
# Paused from the menu bar app: do nothing. RECONCILE_FORCE=1 overrides ("Repair now").
[ -f "$PAUSE_FILE" ] && [ -z "${RECONCILE_FORCE:-}" ] && exit 0

# Which panel to prefer for 240Hz when it is capable: PRIMARY=<serial> in layout.conf.
# Absent or "auto" means auto-detect.
PIN_PRIMARY="$(sed -n 's/^PRIMARY=//p' "$LAYOUT_FILE" 2>/dev/null | head -1)"
[ "$PIN_PRIMARY" = "auto" ] && PIN_PRIMARY=""

BD=""
for c in "/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay" \
         "$(command -v betterdisplaycli 2>/dev/null)"; do
    [ -n "$c" ] && [ -x "$c" ] && BD="$c" && break
done
[ -z "$BD" ] && exit 0
pgrep -xq BetterDisplay || exit 0          # nothing to do until the app is up

log() {
    printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"
    # keep the log from growing without bound
    if [ "$(wc -l < "$LOG" 2>/dev/null || echo 0)" -gt 2000 ]; then
        tail -n 500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
    fi
}

tag_for_serial() {
    "$BD" get --identifiers 2>/dev/null \
      | tr -d '\n' | sed 's/},{/}\
{/g' \
      | grep -F "\"$1\"" \
      | sed -n 's/.*"tagID" *: *"\([0-9]*\)".*/\1/p' | head -1
}

# Mode number for an exact resolution + refresh, empty if not offered.
# Looked up fresh each run: mode numbers are not stable across reconnects.
mode_num() {
    "$BD" get --tagID="$1" --displayModeList 2>/dev/null \
      | awk -v res="$RES" -v hz="$2" '$3 == res && $4 == hz { print $1; exit }'
}

current_res_hz() {
    # With Adaptive-Sync/VRR active the current mode reads as a range, e.g. "48-120Hz".
    # Normalize to the top of the range so it compares equal to "120Hz"; otherwise the
    # mode is re-applied on every run and the panel blanks every ~15s.
    "$BD" get --tagID="$1" --displayModeList 2>/dev/null \
      | awk '/Current/ { hz = $4; sub(/^[0-9.]+-/, "", hz); print $3, hz; exit }'
}

placement_of() { "$BD" get --tagID="$1" --placement 2>/dev/null | tr -d '[:space:]'; }

apply_mode() {   # tag, modeNumber, label
    "$BD" set --tagID="$1" --displayModeNumber="$2" >/dev/null 2>&1
    sleep 3
}

# ---- circuit breaker -------------------------------------------------------
# Every correction blanks the panels. If corrections keep coming, something is fighting
# this script (another tool, or a state it misreads — "48-120Hz" on 2026-10-31), and
# carrying on makes the screens flicker forever. Pause instead and tell the user.
# A "RESUMED" log line (written by the menu bar app) restarts the count.
BREAKER_MAX=10
BREAKER_WINDOW_MIN=5
if [ -z "${RECONCILE_FORCE:-}" ] && [ -f "$LOG" ]; then
    since=$(date -v-"${BREAKER_WINDOW_MIN}"M '+%Y-%m-%d %H:%M:%S')
    recent=$(awk -v since="$since" '
        / (RESUMED|BREAKER)/        { n = 0; next }
        substr($0, 1, 19) >= since  { n++ }
        END                         { print n + 0 }' "$LOG")
    if [ "$recent" -ge "$BREAKER_MAX" ]; then
        msg="$recent corrections en $BREAKER_WINDOW_MIN min, pause automatique"
        echo "$msg" > "$PAUSE_FILE"
        log "BREAKER: $msg"
        osascript -e "display notification \"$msg. Menu Display Guard pour reprendre.\" with title \"Écrans : boucle détectée\"" >/dev/null 2>&1
        exit 0
    fi
fi

# ---- collect state --------------------------------------------------------
declare -a present=() tags=() hi_mode=() lo_mode=()
for serial in "${SERIALS[@]}"; do
    tag=$(tag_for_serial "$serial")
    [ -z "$tag" ] && continue
    present+=("$serial"); tags+=("$tag")
    hi_mode+=("$(mode_num "$tag" "$HI")")
    lo_mode+=("$(mode_num "$tag" "$LO")")
done
[ "${#present[@]}" -eq 0 ] && exit 0

# ---- choose the panel that gets 240Hz -------------------------------------
primary_idx=-1
for i in "${!present[@]}"; do
    [ -n "${hi_mode[$i]}" ] || continue
    if [ -n "$PIN_PRIMARY" ] && [ "${present[$i]}" = "$PIN_PRIMARY" ]; then primary_idx=$i; break; fi
    [ $primary_idx -lt 0 ] && primary_idx=$i
done

# ---- desired mode per panel ----------------------------------------------
declare -a want_hz=() want_mode=()
for i in "${!present[@]}"; do
    if [ "$i" -eq "$primary_idx" ]; then
        want_hz+=("$HI"); want_mode+=("${hi_mode[$i]}")
    else
        want_hz+=("$LO"); want_mode+=("${lo_mode[$i]}")
    fi
done

# ---- reconcile: secondaries down first, then the primary up ---------------
changed=0
for pass in secondary primary; do
    for i in "${!present[@]}"; do
        [ "$pass" = "secondary" ] && [ "$i" -eq "$primary_idx" ] && continue
        [ "$pass" = "primary" ]   && [ "$i" -ne "$primary_idx" ] && continue
        [ -z "${want_mode[$i]}" ] && continue

        read -r cur_res cur_hz <<< "$(current_res_hz "${tags[$i]}")"
        if [ "$cur_res" != "$RES" ] || [ "$cur_hz" != "${want_hz[$i]}" ]; then
            apply_mode "${tags[$i]}" "${want_mode[$i]}"
            read -r new_res new_hz <<< "$(current_res_hz "${tags[$i]}")"
            log "${present[$i]}: ${cur_res:-?} ${cur_hz:-?} -> ${new_res:-?} ${new_hz:-?}"
            changed=1
        fi
    done
done

# ---- restore the arrangement ---------------------------------------------
if [ -f "$LAYOUT_FILE" ]; then
    while IFS='=' read -r serial pos; do
        [ -z "${serial:-}" ] || [ -z "${pos:-}" ] && continue
        [ "$serial" = "PRIMARY" ] && continue
        tag=$(tag_for_serial "$serial")
        [ -z "$tag" ] && continue
        cur=$(placement_of "$tag")
        if [ -n "$cur" ] && [ "$cur" != "$pos" ]; then
            "$BD" set --tagID="$tag" --placement="$pos" >/dev/null 2>&1
            sleep 1
            log "$serial: placement $cur -> $(placement_of "$tag") (wanted $pos)"
            changed=1
        fi
    done < "$LAYOUT_FILE"
fi

exit 0
