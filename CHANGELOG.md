# Changelog

All notable changes to WinHub are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.3.0] — 2026-07-30

Windows keyboard habits reach Finder, and the always-on cost of the menu-bar
read-out drops by roughly 6×.

### Added
- **Windows keys in Finder** *(off by default)*. Delete moves the selection to
  the Trash, F2 renames it, Return opens it. Each key is translated into the
  macOS shortcut that already does the job (⌘⌫ / ↩ / ⌘↓), so Finder's own undo,
  sounds and confirmations are unchanged and WinHub never touches a file itself.
  The translations apply only while Finder is frontmost, never with a modifier
  held, and never while the keyboard is in a rename field, the search field, a
  dialog or a tracking menu. Each of the three is individually switchable in
  **Settings**.

### Changed
- **System monitor costs a fraction of what it did.** Idle CPU with the default
  set of tweaks drops from ~2% to ~0.3%. Readings now happen on a background
  queue instead of the main thread — `temperature()` is a synchronous IOKit call
  per sensor and was blocking the UI for ~18 ms every tick — the SF Symbol
  glyphs in the label are built once rather than rebuilt tens of thousands of
  times a day, and the menu-bar label is only re-rendered when the text it shows
  actually changes (setting it forces an Auto Layout pass and a layer redraw).
- **Die temperature is sampled on its own relaxed cadence** (~6 s) rather than
  every refresh. It's the most expensive reading and the slowest-moving one.
- **The read-out keeps updating while a menu is open.** Its timer now runs in
  common run-loop modes, so the "Now" row no longer freezes the moment you open
  the dropdown to look at it.

## [1.2.0] — 2026-07-22

Snap gets the rest of its Windows story: Snap Assist and the full Win+arrow
keyboard ladder.

### Added
- **Snap Assist.** Snapping a window to a half offers your other windows as
  live thumbnails in the empty half — click, arrows + Return, or number keys
  1–9 to place one there. Minimized windows are included as app-icon
  placeholders (with reserved slots so busy desktops don't crowd them out);
  picking one un-minimizes and snaps in one motion. Thumbnails need Screen
  Recording permission, requested contextually on first use — snapping itself
  never depends on it.
- **Quarter-snap chaining.** Snapping into a corner offers the sibling quarter,
  then the opposite half — the Windows 11 build-a-layout flow, with every
  already-placed window excluded from later pickers.
- **Keyboard quarters.** ⌃⌥↑/↓ now walk the Windows ladder relative to where
  the window sits: from a half, ↑/↓ step into the top/bottom quarter; from a
  quarter, back to the half or up to maximize; ⌃⌥↓ at the bottom restores the
  pre-snap frame, exactly as before.
- **Cross-display arrows.** ⌃⌥←/→ on an already-snapped half or quarter
  continues onto the adjacent display, entering from its near edge.

### Changed
- **Assist offers only what the layout allows.** Zones already holding a
  zone-shaped window are skipped entirely (two halves filled → no picker), and
  a half with one quarter taken shrinks the offer to the free quarter. Offers
  are checked against real on-screen frames at offer time, not the action that
  triggered them.
- **Snap tracking survives stubborn apps.** Windows that clamp their minimum
  size (so the achieved frame differs from the requested zone) are tracked by
  what they actually became — the arrow ladder and restore keep working on
  them.
- Window-list sweeps use a 0.25 s Accessibility messaging timeout so one hung
  app can't stall the picker (the system default is 6 s).

## [1.1.2] — 2026-07-02

A performance and efficiency pass over the always-on hot paths — WinHub runs
24/7, so idle cost matters.

### Fixed
- **System monitor no longer leaks Mach ports.** Each CPU/memory sample leaked
  two host-port references (~86k/day at the default interval). The port is now
  acquired once and reused.
- **Dock previews can no longer close the wrong window.** When a window's title
  changed between capture and click, the thumbnail's ⊗ used to fall back to the
  app's *first* window — now a failed match does nothing instead of closing an
  arbitrary window. (Click-to-raise keeps the benign fallback.)
- **Stale album art on track changes.** Skipping to a track that carries no
  artwork used to keep the previous track's cover and accent color in the notch;
  it now clears.

### Changed
- **Lighter media watching.** Album artwork is only decoded when it actually
  changes — previously the full cover was base64-decoded on the main thread on
  every progress update (several times a second while playing). Artwork is also
  downsampled once (max 512 px) off the main thread, so the ambient glow's blur
  no longer processes full-resolution art every frame.
- **Cheaper Dock hovering.** A cursor resting over the Dock no longer re-runs
  the Accessibility hit-test and app resolution 16×/second — it only re-checks
  when the cursor moves. The Dock's position is cached instead of read from
  preferences on every poll tick.
- **Leaner window thumbnails.** Previews capture at the size they're actually
  displayed (scaled for Retina) instead of up to 4–5× larger, and the system
  window list is briefly cached when sweeping across several Dock icons.

## [1.1.1] — 2026-06-27

### Fixed
- **Single-instance guard** — if WinHub is already running (e.g. the login item
  started it) and the app is opened again, the second copy now bows out instead
  of adding duplicate menu-bar items that fought over the space beside the notch.

## [1.1.0] — 2026-06-27

### Added
- **System monitor** module (on by default) — a compact, configurable read-out in
  the menu bar:
  - Shows **memory used** and **temperature** by default, with **CPU usage**
    available too — pick what appears from Settings.
  - **Real temperature on Apple Silicon**, read straight from the SoC die thermal
    sensors — no third-party helpers and no extra permission.
  - **Click for today's stats**: high, low, and average for each metric, reset at
    local midnight and kept across relaunches.
  - Menu-bar icons sized to sit naturally beside the native system glyphs; the
    refresh interval is adjustable.

## [1.0.0] — 2026-06-11

First stable release. Five independent tweaks — close-to-quit, Aero Snap,
snap-to-grid, Dock hover previews, and the new Dynamic notch — each toggleable
from the menu bar, each asking for a permission only when you turn it on.

### Added
- **Dynamic notch** module (off by default) — a Dynamic-Island-style hub around
  the MacBook camera notch:
  - **Music live activity**: while something plays, the closed notch grows two
    wings — album art on one side, an audio visualizer on the other.
  - **Real-time audio visualizer** *(macOS 14.2+)*: the bars react to the actual
    sound. A Core Audio system-audio tap feeds a 1024-point FFT split into
    bass / low-mid / high-mid / treble bands with per-band auto-gain and
    attack/release smoothing. It runs only while music plays and tears down a
    few seconds after it stops — no idle recording. Asks once for system-audio
    access; decline it (or toggle it off in Settings) and the bars fall back to
    smooth choreographed motion.
  - **Hover (or click) to expand** into a full player: artwork, title/artist, a
    live knobless scrubber with seek, and previous/play-pause/next controls.
  - **Shelf**: drop files, links, or text onto the notch to stash them; drag
    items back out anywhere, double-click to open, AirDrop everything in one
    click. Tiles show real QuickLook thumbnails. Items persist across launches,
    and dragging something toward the notch pops the shelf open automatically.
  - Works on screens **without** a notch too, rendering as a menu-bar-height
    pill on the main display.
  - Now-playing data flows through the vendored
    [MediaRemoteAdapter](https://github.com/ungive/mediaremote-adapter)
    (BSD-3-Clause, see `THIRD_PARTY_LICENSES`) — the post-macOS-15.4 way to read
    MediaRemote state. The notch window is fully click-through outside its
    visible shape, so the menu bar underneath stays usable.

### Design
- **Dynamic-Island language** throughout the notch: a vibrant accent color is
  extracted from the album art and tints the scrubber, the visualizer, and an
  ambient glow behind the cover; the source app's icon badges the artwork;
  continuous corners, hairline strokes, spring-driven transitions, and consistent
  margins measured from the island's visible edge.

## [0.7.0] — 2026-06-09

### Added
- **Snap got the rest of Aero Snap.** Corners snap to quarters (Windows 11 style),
  dragging a snapped window away **restores its pre-snap size** at the drop point,
  and **⌃⌥ + arrows** snap the focused window from the keyboard — ⌃⌥← / ⌃⌥→ for
  halves, ⌃⌥↑ to maximize, ⌃⌥↓ to restore.
- **Dock previews can close windows** — hover a thumbnail and click its ⊗ to close
  that window gracefully (save prompts still appear). Thumbnails also highlight on
  hover.
- **Check for Updates…** menu item — compares against the latest GitHub release and
  links the download. No background network traffic; it only runs when you ask.

### Changed
- **Much lighter at idle.** The Dock-hover poll now does a cheap geometry check and
  only talks to the Dock when the cursor is actually near it; window-snap tracking
  is driven by drag events instead of a per-click probe and a timer; and the
  permission-poll timer stops once every enabled tweak is running. Snapping no
  longer misfires on the seam between two displays, and snap previews/thumbnail
  captures got faster (thumbnails now capture concurrently).

### Fixed
- The Settings window can actually take keyboard focus when opened from the menu
  bar (WinHub becomes a regular app while it's open, accessory again on close).
- Granting a permission while the Settings window is open now clears its
  "Grant permission…" button immediately.

[0.7.0]: https://github.com/v2matosevic/WinHub/releases/tag/v0.7.0

## [0.6.0] — 2026-06-09

### Added
- **Snap icons to a grid** module (on by default) — forces macOS's "Snap to Grid"
  icon arrangement as the default everywhere: the desktop and Finder icon views,
  so files always line up to a tidy grid. Folders you've individually customised
  keep their own arrangement, and turning the tweak off restores whatever you had
  before. No permissions needed.

### Fixed
- **Close-to-quit no longer quits apps when you _minimize_ them.** Minimizing some
  apps — Lightroom Classic is the clearest case — makes their window briefly drop
  its `AXStandardWindow` subrole and the Accessibility window list churn (Lightroom
  momentarily reports *zero* windows), which the old check misread as a last-window
  close. WinHub now watches the window-minimized event directly and stands the quit
  down: minimizing keeps the app alive, Windows-style; only a real close quits it.

[0.6.0]: https://github.com/v2matosevic/WinHub/releases/tag/v0.6.0

## [0.5.1] — 2026-06-07

### Fixed
- **Close-to-quit no longer kills Chromium browsers on fullscreen-video Esc.**
  HTML5 fullscreen video opens a separate window that's destroyed when you press
  Esc; mid-transition the real browser window briefly drops out of the
  Accessibility window list, so the old single check read "no windows" and quit
  the whole browser (e.g. Brave/Chrome). The module now re-confirms the window
  list is *stably* empty (~1s) before quitting — any window that reappears stands
  the quit down.

[0.5.1]: https://github.com/v2matosevic/WinHub/releases/tag/v0.5.1

## [0.5.0] — 2026-06-03

### Added
- **Settings window** (menu → Settings…, or ⌘,) — toggle each tweak with inline
  "grant permission" buttons, manage **start at login**, and build the
  close-to-quit exclusion list with a normal app picker (no more `defaults write`).

[0.5.0]: https://github.com/v2matosevic/WinHub/releases/tag/v0.5.0

## [0.4.0] — 2026-06-03

### Added
- **Snap windows to edges** module — Aero Snap-style window tiling: drag a window
  to the left/right edge for half the screen, or the top edge to maximize, with a
  live preview overlay of the target. Accessibility only.

[0.4.0]: https://github.com/v2matosevic/WinHub/releases/tag/v0.4.0

## [0.3.0] — 2026-06-03

First public, open-source release.

### Added
- **Close button quits app** module — closing an app's last window quits it,
  Windows-style, with a built-in safe list and user-defined exclusions.
- **Dock hover previews** module — live window thumbnails on Dock hover, with
  click-to-raise, minimized-window support, and bottom/left/right Dock support.
- **Start at login** (auto-enabled on first run) and a **Relaunch WinHub** menu
  item.
- App icon, About panel, and a drag-to-install `.dmg`.
- Documentation: README, CONTRIBUTING, architecture notes, and an MIT license.

[0.3.0]: https://github.com/v2matosevic/WinHub/releases/tag/v0.3.0
