# Contributing to WinHub

Thanks for your interest! WinHub is a small, focused macOS utility, and it's
designed so that adding a new tweak is a self-contained job.

## Getting set up

```bash
git clone https://github.com/v2matosevic/WinHub.git
cd WinHub
./build.sh            # release build → WinHub.app
swift build           # quick compile check, no app bundle
```

You need Apple's Command Line Tools (Swift 6+) on macOS 14+. A full Xcode
install is **not** required.

For day-to-day work, run `./Scripts/dev_identity.sh` once. It creates a stable
self-signed identity so macOS keeps your Accessibility / Screen Recording grants
across rebuilds (ad-hoc signing changes the code hash every build and resets
them).

## Project layout

```
Sources/WinHub/
  main.swift              entry point — menu-bar agent (LSUIElement)
  AppDelegate.swift       status item, menu, login item, reconcile timer
  Permissions.swift       Accessibility / Screen Recording checks + prompts
  UpdateChecker.swift     manual "Check for Updates…" against GitHub releases
  Modules/                one file per tweak, each a HubModule
    Module.swift          the HubModule protocol
    ModuleManager.swift   registry + persisted on/off state + start logic
    CloseToQuitModule.swift, DockPreviewModule.swift, SnapToGridModule.swift,
    FinderKeysModule.swift, NotchModule.swift
  DockPreview/            Dock hit-testing, ScreenCaptureKit, the preview panel
  Snap/                   Aero Snap: drag + keyboard zones, overlay, Snap Assist
  FinderKeys/             the Finder key-translation event tap
  SystemMonitor/          menu-bar RAM/temp/CPU read-out + daily stats
  Notch/                  the Dynamic-Island hub, media watcher, shelf, visualizer
  Preferences/            the SwiftUI Settings window
Scripts/                  build helpers (icon, dmg, dev identity)
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the design in depth.

## Adding a module

A module is one tweak. To add one:

1. Create a class conforming to `HubModule` (`id`, `title`, `summary`,
   `requiredPermissions`, `start()`, `stop()`). Put anything beyond a single file
   in its own directory, with the `HubModule` itself staying a thin entry point
   in `Modules/` (see `NotchModule` → `Notch/`, `FinderKeysModule` → `FinderKeys/`).
2. Register it in `ModuleManager.init`.

That's it — the menu toggle, persisted enabled-state, permission prompts, and
the "start once permissions are granted" logic are all handled for you. Set
`isAvailable = false` while a module is still a work in progress; it shows in the
menu as "coming next" with a disabled toggle.

If your module has options, follow the existing pattern rather than inventing
one: a `<Name>Settings` enum of `UserDefaults` keys with a `registerDefaults()`
called from `ModuleManager.init`, values read **live** at the point of use (so a
toggle applies without restarting the module), and a `Section` in
`Preferences/PreferencesView.swift`. Never observe
`UserDefaults.didChangeNotification` from a module that also *writes* defaults —
it fires synchronously on your own write and recurses.

### If it runs all the time, measure it

WinHub sits in the menu bar 24/7, so an always-on module's idle cost is the whole
app's floor. Before opening a PR for one, profile it:

```bash
sample $(pgrep -x WinHub) 6 -f /tmp/winhub.sample
```

Look at what the main thread does between events. Two things that have bitten
this codebase already, both worth checking for: synchronous IPC (IOKit, AX,
`cfprefsd`) on the main thread, and rebuilding UI on a timer when nothing it
displays has changed. Gate expensive work behind a cheap test — `DockAccessibility.isInDockBand`
is the model: a pure-geometry point comparison that lets a 16 fps hover poll skip
the Accessibility round-trip on almost every tick.

## Code style

- Match the surrounding code: clear names, comments that explain *why* (the AX /
  ScreenCaptureKit / TCC corners are where this matters most).
- Keep modules independent — no cross-module dependencies.
- Swift 5 language mode (set in `Package.swift`) keeps the AppKit + C-API interop
  ergonomic; please don't switch the package to strict Swift 6 concurrency.

## Submitting changes

1. Fork and branch from `main`.
2. Make sure `swift build` is clean.
3. For anything touching Accessibility, Screen Recording or the event tap,
   **verify the real behavior** (grant the permission and try it) — a clean build
   isn't proof. Say in the PR what you actually observed.
4. Add a `CHANGELOG.md` entry under an `## [Unreleased]` heading.
5. Open a pull request describing what changed and why.

### Anything that intercepts input

The Finder keys module rewrites keys the user presses all day, and a wrong guess
there means someone can't press Return. If you touch `FinderKeys/` or add
another interception, hold the same line it does: a cheap cached gate so other
apps cost one branch, pass through on any modifier, pass through on any focus
you can't positively clear, a hard `AXUIElementSetMessagingTimeout` on anything
queried from the keystroke path, and re-enable the tap on
`tapDisabledByTimeout`. Ship it off by default.

## Reporting bugs

[Open an issue](https://github.com/v2matosevic/WinHub/issues) with your macOS
version, which module is involved, and steps to reproduce.
