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
UpdateChecker.swift   manual "Check for Updates…" against GitHub releases

Modules/
  Module.swift        the HubModule protocol
  ModuleManager.swift registry, persisted on/off state, start/stop logic
  CloseToQuitModule.swift
  DockPreviewModule.swift
  SnapToGridModule.swift
  NotchModule.swift

DockPreview/
  DockAccessibility.swift   cursor → Dock-tile hit-testing, orientation, minimized windows
  WindowThumbnails.swift    ScreenCaptureKit capture of an app's windows
  DockPreviewPanel.swift    the floating, non-activating preview panel

Snap/
  SnapModule.swift, SnapOverlay.swift, SnapHotkeys.swift, WindowAX.swift, ScreenGeometry.swift

Notch/
  NotchModule.swift       HubModule entry point; owns a NotchController
  NotchController.swift    window lifecycle, display changes, drag-to-shelf, visualizer gating
  NotchPanel.swift         borderless click-through NSPanel pinned over the notch
  NotchRootView.swift      the SwiftUI island: closed live activity + expanded hub
  NotchViewModel.swift     open/closed state, hover, tab, hit-test rect
  NotchGeometry/Shape/Style.swift   frame math, the notch silhouette, design tokens
  MediaWatcher.swift       now-playing state + transport via the media adapter
  SystemAudioLevels.swift  Core Audio tap → FFT → four band levels
  ShelfStore.swift, ShelfView.swift   the drop shelf + its UI

Resources/MediaRemoteAdapter/   vendored BSD-3 adapter (perl + framework + test client)
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
permission), but only hit-tests the Dock — `AXUIElementCopyElementAtPosition`
on a cached `com.apple.dock` element — when the cursor is inside the geometric
band along the Dock edge (`DockAccessibility.isInDockBand`), so an idle tick is
just a point comparison. On hover it captures that app's on-screen windows
concurrently via `SCScreenshotManager.captureImage` and shows them in a
borderless, non-activating `DockPreviewPanel`. Clicking a thumbnail raises the
window via AX (`kAXRaiseAction`), un-minimizing it first if needed; hovering a
thumbnail reveals an ⊗ that closes that window by pressing its AX close button
(graceful — save prompts still appear). Minimized windows are listed with the
app icon as a placeholder, since macOS can't live-capture them. The panel
anchors above the tile (bottom Dock) or beside it (left/right Dock).

### SnapModule (Accessibility)

Windows-style Aero Snap (`Sources/WinHub/Snap/`). Drag-driven: a global
`leftMouseDragged` monitor (throttled to ~20 Hz) resolves the window under the
cursor once per drag session via `AXUIElementCopyElementAtPosition` (climbing to
the `AXWindow` ancestor) — plain clicks cost nothing. The module engages only
once that window actually moves (so in-window text drags are ignored). While
dragging near a screen edge it shows a translucent, click-through `SnapOverlay`
previewing the target — left/right edge → half, a corner (within 120 pt of the
top/bottom of a side edge) → quarter, top edge → maximize (to `visibleFrame`, so
the menu bar and Dock are respected). Edges shared with another display don't
count (no snapping at the seam between monitors). On release it sets the window's
`AXPosition`/`AXSize` (`WindowAX.setFrame`, position-size-position to beat apps
that clamp).

Every snap is remembered in a small registry (window element → original +
snapped frame), which powers the other half of Aero Snap: dragging a snapped
window away restores its pre-snap size at the drop point. `SnapHotkeys`
(Carbon `RegisterEventHotKey`, no event tap) adds keyboard snapping on the
focused window: ⌃⌥← / ⌃⌥→ halves, ⌃⌥↑ maximize, ⌃⌥↓ restore. Coordinate
conversions live in `ScreenGeometry`.

### SnapToGridModule (no permissions)

Makes macOS's "Snap to Grid" icon arrangement the default on the desktop and in
Finder icon views by writing the relevant Finder/desktop view-settings defaults,
and restores the prior arrangement when turned off. Ships **on** by default — a
harmless, instantly-reversible default. Verify changes with `defaults read`
(cfprefsd is the source of truth; the raw plist on disk lags).

### NotchModule (no permissions; visualizer optionally uses System Audio)

A Dynamic-Island-style hub around the camera notch. `NotchModule` is a thin
`HubModule` that owns a `NotchController`, which manages the window lifecycle and
the supporting services.

- **NotchPanel** — a borderless, non-activating `NSPanel` at `mainMenu + 3`,
  dark-appearance, on all Spaces, pinned top-center over the notch
  (`NotchGeometry`). It's mostly transparent; a `hitTest` override consults
  `NotchViewModel.interactiveRect` so only the visible island catches clicks and
  the menu bar underneath stays usable. On screens with no notch it renders as a
  menu-bar-height pill on the main display.
- **NotchRootView / NotchViewModel** — the SwiftUI island. Closed, it shows the
  music live activity (album-art wing + visualizer wing) sized to the physical
  cutout; hovering (after a short delay) or clicking expands it with spring
  animations into the player or the shelf tab. The view-model holds the
  closed/open state, hover, active tab, and the interactive hit-rect.
- **MediaWatcher** — system-wide now-playing state and transport commands.
  Spawns `/usr/bin/perl mediaremote-adapter.pl … stream` (the vendored BSD-3
  [MediaRemoteAdapter](https://github.com/ungive/mediaremote-adapter)) and
  decodes its NDJSON diff stream; commands (`send`/`seek`) go through the same
  script. This is the only path that still reads MediaRemote on macOS 15.4+,
  where Apple restricted the framework to entitled processes — `/usr/bin/perl`
  is Apple-signed and dlopens the adapter framework. The artwork's vibrant
  accent color is extracted on a background queue (`ArtworkPalette`).
- **SystemAudioLevels** — the real visualizer (macOS 14.2+). A **global** Core
  Audio process tap (`CATapDescription` + a private-output aggregate device)
  feeds a 1024-point vDSP FFT, reduced to four log-spaced bands with per-band
  auto-gain and attack/release smoothing; the UI samples the levels per frame.
  It's gated on playback (Combine on `MediaWatcher`) so the tap — and the system
  recording indicator — exist only while music plays. A global tap is required
  because Chromium-based players (Spotify, browsers) render audio from a helper
  subprocess, not their main PID. Permission is requested up front; declining
  leaves a layered-sine choreographed fallback.
- **ShelfStore / ShelfView** — a drag-and-drop tray. Items (file bookmarks,
  links, text) persist as JSON in Application Support; `ShelfView` shows
  QuickLook thumbnails and one-tap AirDrop. `NotchController` also watches the
  drag pasteboard so dropping toward a *closed* notch pops the shelf open.

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

- **System Audio Recording** (notch visualizer only) behaves like Screen
  Recording: it needs a fresh launch to take effect, and an unauthorized tap
  silently delivers zeros rather than erroring. `SystemAudioLevels` requests it
  via `TCCAccessRequest(kTCCServiceAudioCapture)`; `NSAudioCaptureUsageDescription`
  in the Info.plist supplies the prompt text. It's the only permission a
  permission-free-by-default app ever asks for, and only after you enable the
  notch and play something.

## Build & packaging

- `build.sh` — release build, assembles `WinHub.app`, writes the Info.plist,
  bundles the vendored MediaRemoteAdapter (perl + test client into `Resources/`,
  the framework into `Frameworks/`), and code-signs nested-code-first with a
  stable identity if present, else ad-hoc.
- `Scripts/make_icon.swift` — generates `Resources/WinHub.icns` and a README PNG
  from a vector drawing.
- `Scripts/make_dmg.sh` — packages a drag-to-install `WinHub.dmg`.

## Conventions

- Swift 5 language mode (`Package.swift`) — the Accessibility C-callbacks and
  main-actor AppKit usage are cleaner than fighting strict Swift 6 concurrency.
- `platforms: [.macOS(.v14)]`.
- Editors may show "cannot find type" across files until a build indexes the
  module; trust `swift build`.
