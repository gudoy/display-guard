# Display Guard

A small macOS menu bar app that keeps two Samsung Odyssey G9 ultrawides
(G93SC, 5120x1440) stacked on an Apple Silicon MacBook exactly the way you set
them up.

## What it fixes

1. **Wrong resolution after a wake or a reconnect.** After sleep, a KVM switch
   or replugging a cable, macOS renegotiates the displays and a G9 often comes
   back below 5120x1440 (3840x1080, for instance) or at the wrong refresh rate.
2. **Only one panel can run at 240 Hz.** With two G9s, a MacBook Pro M5 Pro can
   drive only one of them at 240 Hz. macOS often has both reaching for 240 Hz
   and one of them ends up degraded. The fix needs a precise order: the other
   panel down to 120 Hz first, then this one up to 240 Hz.
3. **Lost arrangement.** After a reconnect macOS swaps or shifts the top and
   bottom panels.
4. **Two panels with the same number.** Both G93SC report the same short
   serial number, so macOS and most tools mix them up. Display Guard tells them
   apart by their full serial (`HNTX…`, `HNTW…`).
5. **No flicker loop.** If something keeps undoing its corrections, the app
   pauses itself and tells you instead of making the screens blink forever.
6. **Which screen is which.** "Identify screens" shows a card on each screen
   with its position, serial and refresh rate.
7. **No third-party tool.** It talks to macOS directly: no BetterDisplay, no
   licence to buy.

## Install

1. Connect both panels over **DisplayPort** (USB-C to DP is fine) and arrange
   them in System Settings > Displays the way you want them.
2. Download `DisplayGuard-<version>.dmg` from the
   [Releases page](https://github.com/gudoy/display-guard/releases), open it and
   drag **Display Guard** into Applications.
3. Open Display Guard. The app is not signed with an Apple Developer ID, so the
   first time macOS refuses to open it: go to System Settings > Privacy &
   Security and click **Open Anyway**. This is needed only once.
4. Click **Set Up** in the welcome dialog. Display Guard saves the current
   arrangement and enforces it from then on.

It starts by itself at every login. Installing a newer version over it keeps
the saved arrangement. Requires macOS 13 or later; universal (Apple Silicon and
Intel).

The app is in English, or in French when macOS is set to French. Change it under
**Language** in the menu.

Uninstall: **Uninstall Display Guard…** in the menu.

## The menu

- State (active, paused, stopped) and the last correction made.
- **Pause / Resume.** A pause survives a restart.
- **Repair now**, even while paused.
- **Identify screens.**
- **Top screen** and **240 Hz screen** (Automatic, or a preferred panel).
- **Language**, **Open log**, **Uninstall**, **Quit**.

## How it works

One binary with two roles. The menu bar app (`DisplayGuard`) only edits the
settings and shows the state. The enforcer (`DisplayGuard --reconcile`) runs
every 15 seconds from a LaunchAgent: it reads `layout.conf`, puts every panel
back to 5120x1440 (others to 120 Hz first, then the chosen one to 240 Hz), then
restores all positions in one transaction. A pass that finds nothing wrong takes
about 0.3 s and changes nothing.

Keeping a single enforcer matters: on 2026-10-31 an old Hammerspoon script and
the reconciler enforced different layouts and moved the panels back and forth
every 20 seconds.

**Circuit breaker.** Every correction blanks the panels. Ten corrections or more
within 5 minutes means something is fighting the reconciler, so it pauses itself
and sends a notification. **Resume** restarts the count.

Everything lives in `~/Library/Application Support/Display Guard`:
`layout.conf` (one `SERIAL=XxY` line per panel, plus an optional
`PRIMARY=<serial>`), `reconcile.log`, and the `paused` flag.

macOS APIs used: CoreGraphics for positions; SkyLight's `CGS…DisplayMode` calls
for modes, because the public API hides some of them (the same calls
displayplacer uses); CoreDisplay and the IORegistry to read each panel's full
serial. The private symbols are looked up at runtime; if a future macOS removes
one, the app says so instead of misbehaving.

## Hard limits worth knowing

- **Only one display at a time does 240 Hz** on an M5 Pro with two panels. One
  display pipe gets the link 5120x1440 @ 240 Hz needs; the other caps at
  120 Hz. It follows the Thunderbolt port, not the monitor or the cable. Apple's
  own figures agree: "one display up to … 4K@240, plus a second display up to
  5K@120 or 4K@200". An M5 Max should do 240 Hz on both (untested).
- **HDMI caps at 120 Hz** on this panel; 5120x1440 @ 240 Hz is DisplayPort only.
- **Do not route these panels through a USB-C dock.** A UGREEN 12-in-1
  (B09N6T9NTS) collapsed the display to 3840x1080 @ 60 Hz.
- Set the monitor OSD **Display Port Ver.** to **1.4**, not 1.2; it silently
  caps the link and sometimes resets after a power cut.
- macOS reports a variable-refresh mode (48-120 Hz) the same way as the fixed
  one (120 Hz), so Display Guard treats them as equivalent.

## Build from source

Needs the Swift compiler (`xcode-select --install`).

```bash
./install.sh              # build and install to /Applications
menubar/build.sh --dmg    # build the release image in build/
```

`menubar/AppIcon.svg` is the icon source; `AppIcon.icns` is generated from it
and committed.
