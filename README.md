<div align="center">

<img src="docs/icon.png" alt="WinHub" width="128" height="128">

# WinHub

**Windows comforts for macOS.**

A lightweight menu-bar app that brings back the little habits you miss after
switching from Windows — one toggle at a time.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)](#requirements)
[![Release](https://img.shields.io/github/v/release/v2matosevic/WinHub?include_prereleases)](https://github.com/v2matosevic/WinHub/releases)

</div>

---

## Why

macOS is great, but if your muscle memory comes from Windows, a few things feel
wrong: closing the last window doesn't quit the app, and hovering the Dock
doesn't show you window previews. WinHub adds those behaviors back as small,
independent **modules** you turn on or off from the menu bar. No Dock icon, no
clutter — it just sits in your status bar.

## Features

- **Close button quits the app** — closing an app's last window quits it,
  Windows-style. It's a graceful quit, so apps with unsaved work still prompt
  you. A built-in safe list (Finder, System Settings, Dock, Control Center)
  is never quit, and you can exclude any other app from **Settings**.
- **Dock hover previews** — hover a Dock icon to see live thumbnails of that
  app's windows, like the Windows taskbar. Click a thumbnail to jump straight
  to that window, or click its **⊗** to close that window (gracefully — unsaved
  work still prompts). Minimized windows are shown too, and clicking restores
  them.
- **Snap windows to edges** — drag a window to a screen edge to snap it, Aero
  Snap-style: left/right edge for half the screen, a **corner for a quarter**,
  top edge to maximize. A preview shows where it'll land before you let go, and
  dragging a snapped window away **restores its original size** — just like
  Windows. On the keyboard, **⌃⌥ + arrows** walk the full Windows ladder:
  **←/→** for halves (press again at the edge to continue onto the next
  display), **↑/↓** to step half ↔ quarter ↔ maximize, **⌃⌥↓** at the bottom to
  restore.
- **Snap Assist** — snap a window to a half and the empty half offers your other
  windows as live thumbnails (minimized ones included): click one, arrow to it
  and press Return, or hit its number. Quarter snaps chain — fill the sibling
  quarter, then the opposite half, Windows 11 style. The picker only appears
  when there's actually room: zones already holding a snapped window are
  skipped, and a half with one quarter taken shrinks to the free quarter.
  (Thumbnails need Screen Recording permission; requested on first use.)
- **Windows keys in Finder** *(off by default)* — **Delete** moves the selection
  to the Trash, **F2** renames it, **Return** opens it. Each key is translated
  into the macOS shortcut that already does the job, so Finder's own undo and
  save prompts behave exactly as they always did. Only while Finder is
  frontmost, never with a modifier held, and never while you're typing a name or
  a search — pick which of the three you want in **Settings**.
- **Snap icons to a grid** — makes macOS's "Snap to Grid" the default everywhere,
  on the desktop and in Finder icon views, so files always line up to a tidy grid.
  On by default; folders you've individually arranged keep their own layout, and
  turning it off restores what you had. No permissions needed.
- **Dynamic notch** *(off by default)* — turns the MacBook notch into a
  Dynamic-Island-style hub. While music plays, a live activity sits beside the
  notch — album art on one side, a **real-time audio visualizer** on the other
  that reacts to the actual sound. Hover to expand it into a full player: artwork
  with an ambient glow pulled from the cover art, a scrubber, and transport
  controls. Drop files, links, or text onto the notch to stash them on a
  **shelf**, drag them back out anywhere, or AirDrop the lot in one click.
  Now-playing data comes from the bundled
  [MediaRemoteAdapter](https://github.com/ungive/mediaremote-adapter) (BSD-3),
  so it works on macOS 15.4+ where Apple locked down MediaRemote. The notch
  itself needs no permissions; the live visualizer optionally asks for
  system-audio access (you can turn it off to keep the smooth fallback motion).
- **Starts at login** and stays out of your way in the menu bar — and out of your
  battery's: when you're not using a tweak, WinHub's idle cost is near zero.
- **Settings window** (⌘,) to toggle tweaks, manage the exclusion list, and grant
  permissions — no Terminal required. **Check for Updates…** in the menu tells you
  when a new version is out.

More tweaks are on the [roadmap](#roadmap) — and the module system makes adding
one straightforward (see [CONTRIBUTING](CONTRIBUTING.md)).

## Install

Download `WinHub.dmg` from the [latest release](https://github.com/v2matosevic/WinHub/releases),
open it, and drag **WinHub** into **Applications**. (Or [build from
source](#building-from-source) — it's a single script.)

### First launch (one time)

WinHub isn't notarized by Apple, so macOS blocks the very first launch
regardless of how you installed it. Clear it once, either way:

- **Right-click** WinHub in Applications → **Open** → **Open**, or
- run `xattr -dr com.apple.quarantine /Applications/WinHub.app`

After that it launches normally. A warning-free double-click would require Apple
notarization (a paid Apple Developer account) — on the roadmap if there's demand.

## Permissions

WinHub asks only for what each module needs, and only when you enable it:

| Permission | Used by | Why |
| --- | --- | --- |
| **Accessibility** | Close-to-quit, snapping, window raising, Finder keys | Observe window close events, move and raise windows, and read Finder's keyboard focus. |
| **Screen Recording** | Dock hover previews | Capture the thumbnail images of your windows. |
| **System Audio Recording** | Dynamic notch's live visualizer *(optional)* | Read the audio levels that drive the equalizer. Decline it and the bars fall back to smooth motion. |

What it does with each one, and what it stores, is spelled out in
[SECURITY.md](SECURITY.md) — short version: nothing leaves your Mac, and the
only network request is the manual update check.

Accessibility takes effect immediately. **Screen Recording only applies on a
fresh launch** — after granting it, use **Relaunch WinHub** from the menu. If
WinHub isn't listed under *Privacy & Security → Screen & System Audio
Recording*, add it with the `+` button. The audio visualizer needs macOS 14.2+
and is the only thing that ever touches audio — WinHub records nothing; it reads
levels to animate the bars and stops the moment music does.

## Requirements

- macOS 14 (Sonoma) or later.

## Building from source

You only need Apple's Command Line Tools (Swift 6+) — no full Xcode required.

```bash
git clone https://github.com/v2matosevic/WinHub.git
cd WinHub
./build.sh            # builds and code-signs WinHub.app
open WinHub.app
```

If you're iterating, set up a stable local signing identity once so your
permission grants survive rebuilds:

```bash
./Scripts/dev_identity.sh
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how the app is structured
and how to add a module.

## Roadmap

- Alt+Tab per-window switching
- Cut & paste files in Finder (⌘X)
- Apple notarization for warning-free installs

Got an idea? [Open an issue](https://github.com/v2matosevic/WinHub/issues).

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE) © 2026 Version2

<div align="center"><sub>Made by <b>Version2</b>.</sub></div>
