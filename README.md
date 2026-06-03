# WinHub

A menu-bar hub of small, lightweight tweaks that make macOS feel like home for
someone coming from Windows. Each tweak is a self-contained **module** you toggle
on or off from the menu bar.

> Working name — `WinHub` / `hr.version2.winhub`. Rename is a one-pass job once it
> has a vibe.

## Modules

| Module | Status | What it does | Permissions |
| --- | --- | --- | --- |
| **Close button quits app** | ✅ built | Closing an app's last window quits the app, Windows-style (graceful — unsaved-work prompts still appear). All apps, minus a safe denylist (Finder, System Settings, Dock, Control Center, ourselves) plus your own exclusions. | Accessibility |
| **Dock hover previews** | 🚧 next | Live window thumbnails when you hover a Dock icon, like the Windows taskbar. | Accessibility, Screen Recording |

## Build & run

```bash
./build.sh            # release build → WinHub.app (ad-hoc signed)
open WinHub.app       # launches as a menu-bar agent (no Dock icon)
swift build -c debug  # fast compile check, no .app bundle
```

After launching, click the menu-bar icon (a 2×2 grid), flip a module **on**, and
grant the permission it asks for in System Settings → Privacy & Security. The app
polls every ~2s, so the module activates within a couple seconds of being granted —
no relaunch needed.

## Keep your permission grants across rebuilds

Ad-hoc signing changes the app's code hash on every build, which makes macOS forget
your Accessibility/Screen-Recording grants. Set up a stable self-signed identity
**once** and `build.sh` uses it automatically thereafter:

```bash
Scripts/dev_identity.sh        # prompts for your login password (to trust the cert)
```

Teardown: `Scripts/dev_identity.sh --remove`.

## Excluding an app from "close button quits app"

Until there's UI for it, add bundle IDs to a `UserDefaults` array:

```bash
defaults write hr.version2.winhub closeToQuit.userExclusions -array com.example.app
```

## Layout

```
Sources/WinHub/
  main.swift              # entry point; menu-bar agent (LSUIElement)
  AppDelegate.swift       # status item + menu, permission rows, reconcile timer
  Permissions.swift       # Accessibility / Screen Recording checks + prompts
  Modules/
    Module.swift          # HubModule protocol
    ModuleManager.swift   # registry, persisted on/off state, start/stop logic
    CloseToQuitModule.swift
    DockPreviewModule.swift   # roadmap stub (isAvailable = false)
```
