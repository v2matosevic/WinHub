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
  Modules/
    Module.swift          the HubModule protocol
    ModuleManager.swift    registry + persisted on/off state + start logic
    CloseToQuitModule.swift
    DockPreviewModule.swift
  DockPreview/            Dock hit-testing, ScreenCaptureKit, the preview panel
Scripts/                  build helpers (icon, dmg, dev identity)
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the design in depth.

## Adding a module

A module is one tweak. To add one:

1. Create a class conforming to `HubModule` (`id`, `title`, `summary`,
   `requiredPermissions`, `start()`, `stop()`).
2. Register it in `ModuleManager.init`.

That's it — the menu toggle, persisted enabled-state, permission prompts, and
the "start once permissions are granted" logic are all handled for you. Set
`isAvailable = false` while a module is still a work in progress; it shows in the
menu as "coming next" with a disabled toggle.

## Code style

- Match the surrounding code: clear names, comments that explain *why* (the AX /
  ScreenCaptureKit / TCC corners are where this matters most).
- Keep modules independent — no cross-module dependencies.
- Swift 5 language mode (set in `Package.swift`) keeps the AppKit + C-API interop
  ergonomic; please don't switch the package to strict Swift 6 concurrency.

## Submitting changes

1. Fork and branch from `main`.
2. Make sure `swift build` is clean.
3. For anything touching Accessibility or Screen Recording, **verify the real
   behavior** (grant the permission and try it) — a clean build isn't proof.
4. Open a pull request describing what changed and why.

## Reporting bugs

[Open an issue](https://github.com/v2matosevic/WinHub/issues) with your macOS
version, which module is involved, and steps to reproduce.
