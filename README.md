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
  to that window. Minimized windows are shown too, and clicking restores them.
- **Snap windows to edges** — drag a window to a screen edge to snap it, Aero
  Snap-style: left edge for the left half, right edge for the right half, top
  edge to maximize. A preview shows where it'll land before you let go.
- **Snap icons to a grid** — makes macOS's "Snap to Grid" the default everywhere,
  on the desktop and in Finder icon views, so files always line up to a tidy grid.
  On by default; folders you've individually arranged keep their own layout, and
  turning it off restores what you had. No permissions needed.
- **Starts at login** and stays out of your way in the menu bar.
- **Settings window** (⌘,) to toggle tweaks, manage the exclusion list, and grant
  permissions — no Terminal required.

More tweaks are on the [roadmap](#roadmap) — and the module system makes adding
one straightforward (see [CONTRIBUTING](CONTRIBUTING.md)).

## Install

### Homebrew (recommended)

```bash
brew install --cask v2matosevic/tap/winhub
```

### Direct download

Grab `WinHub.dmg` from the [latest release](https://github.com/v2matosevic/WinHub/releases),
open it, and drag **WinHub** into **Applications**.

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
| **Accessibility** | Close-to-quit, window raising | Observe window close events and raise windows. |
| **Screen Recording** | Dock hover previews | Capture the thumbnail images of your windows. |

Accessibility takes effect immediately. **Screen Recording only applies on a
fresh launch** — after granting it, use **Relaunch WinHub** from the menu. If
WinHub isn't listed under *Privacy & Security → Screen & System Audio
Recording*, add it with the `+` button.

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

- Quarter-tiling (corner snap) and keyboard snap shortcuts
- Alt+Tab per-window switching
- Cut & paste files in Finder (⌘X)
- A real preferences window (exclusions, hover delay)

Got an idea? [Open an issue](https://github.com/v2matosevic/WinHub/issues).

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE) © 2026 Version2

<div align="center"><sub>Made by <b>Version2</b>.</sub></div>
