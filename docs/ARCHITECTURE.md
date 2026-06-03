# Architecture

WinHub is a native macOS menu-bar app built with Swift Package Manager. It runs
as an `LSUIElement` agent — no Dock icon, no main window — and hosts a set of
independent **modules**, each a small quality-of-life tweak you can toggle on or
off.

## Overview

```
main.swift            NSApplication + AppDelegate, .accessory activation policy
AppDelegate.swift     status item, menu, login item, permission rows, reconcile timer
Permissions.swift     Permission enum (.accessibility / .screenRecording) + prompts
AppInfo.swift         name / version from the bundle
LoginItem.swift       launch-at-login via SMAppService

Modules/
  Module.swift        the HubModule protocol
  ModuleManager.swift registry, persisted on/off state, start/stop logic
  CloseToQuitModule.swift
  DockPreviewModule.swift

DockPreview/
  DockAccessibility.swift   cursor → Dock-tile hit-testing, orientation, minimized windows
  WindowThumbnails.swift    ScreenCaptureKit capture of an app's windows
  DockPreviewPanel.swift    the floating, non-activating preview panel
```

## The module system

Everything user-facing is a `HubModule`:

```swift
protocol HubModule: AnyObject {
    var id: String { get }                       // stable persistence key
    var title: String { get }
    var summary: String { get }
    var requiredPermissions: [Permission] { get }
    var isAvailable: Bool { get }                // false = roadmap stub (disabled in menu)
    var isRunning: Bool { get }
    func start()
    func stop()
}
```

`ModuleManager` owns the list, persists each module's enabled-state in
`UserDefaults` (`module.<id>.enabled`), starts enabled modules at launch
(`bootstrap()`), and re-checks on a timer (`reconcile()`) so a module starts as
soon as its permission is granted. `AppDelegate` renders the list as menu
toggles and surfaces a "Grant <permission>" row under any enabled module that's
still missing one.

## Modules

### CloseToQuitModule (Accessibility)

Creates one `AXObserver` per regular running app (an `AppWatcher`). It watches
`kAXWindowCreatedNotification` to register a `kAXUIElementDestroyedNotification`
on each window. When a window is destroyed, it waits ~0.15s for AX to settle,
recounts the app's standard windows (subrole `AXStandardWindow`), and if none
remain calls `NSRunningApplication.terminate()` — a graceful quit, so unsaved
work still prompts. A denylist (Finder, System Settings, Dock, Control Center,
Notification Center, WindowManager, WinHub itself) plus a user-defined
`closeToQuit.userExclusions` list are never quit.

The AXObserver callback is a C function pointer, so it's a free function; the
`refcon` carries the (unretained) `AppWatcher`, kept alive by the manager's
`watchers` dictionary.

### DockPreviewModule (Accessibility + Screen Recording)

Polls the cursor at ~16 fps (reading the cursor location needs no extra
permission), hit-tests the Dock with
`AXUIElementCopyElementAtPosition` on `com.apple.dock`, and resolves the tile to
a running app. On hover it captures that app's on-screen windows via
`SCScreenshotManager.captureImage` and shows them in a borderless,
non-activating `DockPreviewPanel`. Clicking a thumbnail raises the window via AX
(`kAXRaiseAction`), un-minimizing it first if needed. Minimized windows are
listed with the app icon as a placeholder, since macOS can't live-capture them.
The panel anchors above the tile (bottom Dock) or beside it (left/right Dock).

### SnapModule (Accessibility)

Windows-style Aero Snap. A global monitor catches `leftMouseDown`/`leftMouseUp`;
between them a ~20 fps timer polls the cursor (`Sources/WinHub/Snap/`). On
mouse-down it captures the window under the cursor via
`AXUIElementCopyElementAtPosition` (climbing to the `AXWindow` ancestor) and its
start position. The module engages only once that window actually moves (so plain
clicks and in-window text drags are ignored). While dragging near a screen edge it
shows a translucent, click-through `SnapOverlay` previewing the target — left
edge → left half, right edge → right half, top edge → maximize (to
`visibleFrame`, so the menu bar and Dock are respected). On release it sets the
window's `AXPosition`/`AXSize` (`WindowAX.setFrame`, position-size-position to
beat apps that clamp). Coordinate conversions live in `ScreenGeometry`.

## Settings window

A SwiftUI grouped `Form` (`Sources/WinHub/Preferences/`) hosted in an `NSWindow`
via `NSHostingController`, opened from the menu's "Settings…" item (⌘,) or
`open WinHub.app --args --settings`. `PreferencesModel` (an `ObservableObject`)
bridges the view to the shared `ModuleManager`, `LoginItem`, and the
`closeToQuit.userExclusions` defaults key, so the window and the menu bar stay in
sync (`manager.onChange` refreshes both). Exclusions are managed with an
`NSOpenPanel` app picker rather than `defaults write`.

## Permissions & code signing

Both Dock previews and window raising depend on TCC permissions, and there are
two traps worth knowing:

- **Ad-hoc signing resets grants on every rebuild** (the code hash changes).
  `Scripts/dev_identity.sh` creates a stable, trusted self-signed identity so the
  bundle's Designated Requirement stays constant and grants persist;
  `build.sh` uses it automatically when present.
- **Screen Recording only takes effect on a fresh launch.** After the user
  grants it, the running process still can't capture until relaunched — hence the
  **Relaunch WinHub** menu item. The app also only appears in the Screen
  Recording list once it has requested access.

Accessibility is gentler — `AXIsProcessTrusted()` reflects the grant live, which
is why `reconcile()` can start that module without a relaunch.

## Build & packaging

- `build.sh` — release build, assembles `WinHub.app`, writes the Info.plist, and
  code-signs (stable identity if present, else ad-hoc).
- `Scripts/make_icon.swift` — generates `Resources/WinHub.icns` and a README PNG
  from a vector drawing.
- `Scripts/make_dmg.sh` — packages a drag-to-install `WinHub.dmg`.

## Conventions

- Swift 5 language mode (`Package.swift`) — the Accessibility C-callbacks and
  main-actor AppKit usage are cleaner than fighting strict Swift 6 concurrency.
- `platforms: [.macOS(.v14)]`.
- Editors may show "cannot find type" across files until a build indexes the
  module; trust `swift build`.
