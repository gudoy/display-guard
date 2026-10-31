# Dual Odyssey G93SC on an Apple Silicon Mac

Everything needed to reproduce the working display setup on another Mac.
Measured on a MacBook Pro M5 Pro (macOS 26.6.2) in September 2026 with two
Samsung Odyssey G93SC panels.

## Install on a Mac

1. Install BetterDisplay (<https://betterdisplay.pro>) and launch it once.
   A **Pro licence is required** — resolution protection is a Pro feature.
   Check your licence terms for whether it covers a second machine; buy a
   second seat if it does not.
2. Connect both panels over **DisplayPort** (USB-C to DP is fine) and arrange
   them in System Settings > Displays the way you want them.
3. Download `DisplayGuard-<version>.dmg` from the
   [Releases page](https://github.com/gudoy/display-guard/releases), open it and
   drag **Display Guard** into Applications.
4. Open Display Guard. The app is not signed with an Apple Developer ID, so the
   first time macOS refuses to open it: go to System Settings > Privacy & Security
   and click **Open Anyway**. This is needed only once.
5. Click **Configurer** in the welcome dialog.

On first launch the app copies its scripts to
`~/Library/Application Support/Display Guard`, applies the BetterDisplay
settings, saves the current arrangement to `layout.conf` there, installs the
reconciler agent and starts itself at every login. Installing a newer version
over it updates the scripts on the next launch and keeps the arrangement.

The panels are identified by their alphanumeric serial. On a fresh machine every
connected `Odyssey G93SC` is taken; after that, `layout.conf` is the list. After
replacing a panel, delete `layout.conf` and choose **Configurer les écrans…** in
the menu.

Uninstall: **Désinstaller Display Guard…** in the menu.

From source (needs `xcode-select --install`): clone the repo and run
`./install.sh`. `menubar/build.sh --dmg` builds the release image.

## Display Guard (menu bar)

Native Swift app (`menubar/`), no third-party dependency. It shows the state and
lets you pause/resume, repair now, choose the top panel and the preferred 240Hz
panel, and open the log. It never touches the displays itself: it only edits
`layout.conf` and the `paused` flag file, and `reconcile.sh` stays the single
enforcer. Two enforcers with different rules (an old Hammerspoon watcher) made
the panels flicker on 2026-10-31.

**Circuit breaker.** Every correction blanks the panels. If `reconcile.sh` makes
10 or more corrections within 5 minutes, something is fighting it, so it pauses
itself, writes the reason to `paused` and sends a notification. "Reprendre" in
the menu resumes and resets the count.

## The reconciler

The app installs it for you. By hand, from `~/Library/Application Support/Display Guard`:

```bash
./install-agent.sh --status   # is it running, and what has it fixed lately
```

It is a LaunchAgent that runs `reconcile.sh` at login and every 15s. It puts both
panels back to 5120x1440 (one at 240Hz, the other at 120Hz) and restores their positions,
with no interaction at all. A pass that finds nothing wrong costs ~1.2s and writes
nothing; only a genuine repair does work, and it logs to `reconcile.log`.

**Why a timer instead of BetterDisplay's own protections.** `protectResolution` guards the
resolution but not the refresh rate, so a silent 240→120 drop passes unnoticed, and layout
protection does not always survive a cold wake. The repair also has to be *ordered*: only
one panel can hold 240Hz at a time, so the secondary must be pushed to 120Hz first to free
the budget, and only then can the primary be raised to 240Hz. Doing it the other way round
fails. That ordering is the whole point of `reconcile.sh`.

Measured end to end: state broken at 10:28:56, fully repaired by 10:29:13 with no
intervention.

`reconcile.sh` auto-detects which panel currently has the 240Hz-capable pipe. To always
prefer one panel when it is capable, pick it in the menu, or add `PRIMARY=<serial>` to
`layout.conf`.

With Adaptive-Sync on, BetterDisplay reports the current mode as a range (`48-120Hz`);
`reconcile.sh` treats it as its top value.

## Screen arrangement (positions)

```bash
./odyssey-setup.sh --save-layout      # record each panel's placement to layout.conf
./odyssey-setup.sh --restore-layout   # put them back
```

A normal `./odyssey-setup.sh` run also turns on **display group layout protection**,
which keeps the arrangement (which panel sits left/right) across reconnects.

`layout.conf` holds one `SERIAL=XxY` line per panel, plus an optional
`PRIMARY=<serial>`. The underlying features are `placement` (position in the global logical-pixel
space) and `layoutProtection` (a display *group* property, not per-display).

## What the script sets, and why

**`identificationMethod = alphanumericSerial`** — Samsung reports a different
EDID `modelNumber` per input port on this panel (seen: 29780, 29782, 29790,
29795). BetterDisplay's default `vendorModelSerial` therefore fails to
recognise the panel after a reconnect, creates a fresh display entry, and
silently drops every setting attached to the old one. The alphanumeric serial
is the only identifier stable across all variants.

**`protectResolution = on`** at the best available mode — a KVM switch or a
sleep/wake cycle makes macOS renegotiate and fall back to a lower mode.
Protection re-applies it. Note it guards the **resolution only, not the refresh
rate**: a drop from 240Hz to 120Hz at the same resolution passes unnoticed.

## Hard limits worth knowing before debugging anything

**Only one display at a time does 240Hz.** With two panels connected, exactly
one of them gets the `7680x4608` link container that 5120x1440 @ 240Hz needs;
the other is offered only `6720x4608` and caps at 120Hz. The capability follows
the port, not the monitor and not the cable — swapping cables between
Thunderbolt ports moves it every time.

Do **not** assume a fixed framebuffer. An earlier version of this note claimed
`dispext0@B0000000` was always the fast pipe; that turned out to be wrong — it
has since been observed on `dispext1@90000000` instead. The `dispext` index is
not stable across reconnects. Always measure rather than assume; the script
reports it per display, or check by hand:

With only one panel connected, that panel gets 240Hz on whatever pipe it lands
on — the restriction only appears under two-display load.

Apple documents the same thing for two displays on M5 Pro: "one display up to
8K@60, 5K@120 or 4K@240, plus a second display up to 5K@120 or 4K@200". The
second tier (4K@200 ≈ 1.66 Gpx/s) sits just below what 5120x1440 @ 240Hz needs
(≈ 1.77 Gpx/s). M5 Max lists "two displays up to ... 4K@240", so it should do
240Hz on both — untested.

Check which display is on the fast pipe:

```bash
betterdisplaycli get --tagID=N --connectionModeListAll | grep -c 7680x4608
```

**HDMI caps at 120Hz.** 5120x1440 @ 240Hz is DisplayPort-only on this panel;
its HDMI 2.1 input reaches 240Hz only at 1920x1080 and 3840x1080. A documented
Odyssey G9 trait, nothing to do with the Mac or the cable.

**Do not route these panels through a USB-C dock.** A UGREEN 12-in-1
(B09N6T9NTS, HDMI 1 rated 8K@30) collapsed the display to 64 available modes
with no 5120x1440 entry at all. Thunderbolt 5 docks have the bandwidth on
paper, but M5 Pro + ultrawide + TB5 has a poor field record — test before
committing.

## Things that look promising and are not

**System EDID overrides no longer work for EDID replacement.** Writing a
corrected EDID to
`/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-<vid>/DisplayProductID-<pid>`
gets the `DisplayProductName` honoured but `IODisplayEDID` ignored — on Apple
Silicon the DCP reads EDID straight from hardware. Do not spend time on it.

**`overrideDefaultResolution`, `enforceOnConnect`, `defaultResolution*`** exist
as ivars inside the BetterDisplay binary but are not exposed through the CLI
and do nothing when written into the plist by hand.

**The KVM is not the EDID villain.** The panel's HDMI EDID reports
`extFlag=1` while carrying 4 blocks, and `BranchDeviceID` reads `pHDMIg`, with
the KVM entirely out of the chain — `pHDMIg` is the MacBook's own internal
DisplayPort-to-HDMI converter. What the KVM really does is force
disconnect/reconnect cycles on switch, which is what drops the mode.

## Gotchas

- `betterdisplaycli set --resolution=WxH --refreshRate=N` silently fails to
  change the refresh rate. Use `--displayModeNumber=N`, taken from
  `--displayModeList`.
- `betterdisplaycli get --protectResolution` always prints a malformed
  `false ? ON : OFF)`. It is a CLI formatting bug; read
  `protectResolution@Display:N` from the plist instead.
- `defaults import` **merges** into a domain rather than replacing it. To drop
  keys, `defaults delete <domain>` first, then import.
- Quit BetterDisplay before editing its plist, or it overwrites the file on exit.
- BetterDisplay timestamps (`lastConnected`, `lastUnseen`) use the Apple epoch
  in UTC.
- `/usr/bin/python3` is the Xcode stub and refuses to run without a licence
  agreement. This script uses only bash and awk to avoid it.
- Check the monitor OSD `Display Port Ver.` is **1.4**, not 1.2 — it silently
  caps the link rate and sometimes resets itself after a power cut.

## Optional: switch both panels to the PC over DDC

Both panels answer DDC. `inputSelect` reads 15 (DisplayPort 1); 17 is HDMI 1:

```bash
betterdisplaycli set --tagID=13 --vcp=inputSelect --ddc=17
betterdisplaycli set --tagID=23 --vcp=inputSelect --ddc=17
```

The way back (HDMI to DP) may not work from the Mac, since many monitors answer
DDC only on the active input.
