# Security & Privacy

WinHub is a menu-bar utility that asks for some of the most sensitive
permissions macOS has. This document says exactly what it does with them, and
how to report a problem.

## Reporting a vulnerability

Please **don't** open a public issue for a security problem. Use GitHub's
[private vulnerability reporting](https://github.com/v2matosevic/WinHub/security/advisories/new)
instead. Include the macOS version, which module is involved, and how to
reproduce it. It's a one-maintainer project, so expect a first reply within a
week rather than within hours.

## What WinHub collects

Nothing. There is no analytics, no telemetry, no crash reporting, and no account.

The only network request the app ever makes is to
`api.github.com/repos/v2matosevic/WinHub/releases/latest`, and only when you
pick **Check for Updates…** from the menu. Nothing is sent with it, and no check
runs in the background.

Everything WinHub stores stays on your Mac:

- `~/Library/Preferences/hr.version2.winhub.plist` — which tweaks are on, their
  options, and the system monitor's daily high/low/average figures.
- `~/Library/Application Support/WinHub/Shelf/items.json` — the notch shelf's
  contents (security-scoped bookmarks for files, plus any links or text you
  dropped there).

## What each permission is used for

WinHub asks for a permission only when you enable a tweak that needs it, and
each one is used for exactly one thing.

| Permission | Module | What it does with it |
| --- | --- | --- |
| **Accessibility** | Close-to-quit, Snap, Dock previews, Finder keys | Observe window open/close events, read and set window position and size, raise and close windows, and read Finder's keyboard focus. |
| **Screen Recording** | Dock previews, Snap Assist | Capture a still thumbnail of a window, at the moment you hover a Dock tile or a Snap Assist picker opens. Images are held in memory to draw the panel and are never written to disk or transmitted. |
| **System Audio Recording** *(optional)* | Notch visualizer | Read the level of the system audio mix to animate four equalizer bars. The tap exists only while music is playing and is torn down a few seconds after it stops. No audio is buffered beyond the FFT window, recorded, or transmitted. |

Declining any of them disables that tweak and nothing else. The notch and the
system monitor need no permissions at all.

## The input event tap

The **Windows keys in Finder** module installs a `CGEventTap` on key events,
which is the most invasive thing in this codebase. It ships **off by default**.
What it does:

- It reads key codes and modifier flags. It does not read, log, buffer or
  transmit typed text, and it never inspects events outside the small set of
  keys it translates.
- It acts only while **Finder** is the frontmost application, only on a bare
  keypress with no modifier held, and only when Finder's keyboard focus is the
  file view — never in a rename field, a search field, a dialog or a menu.
- It never touches a file itself. Each key is rewritten into the macOS shortcut
  that already does the job (⌘⌫, ↩, ⌘↓) and Finder performs the action, so its
  own confirmations and undo apply.

macOS will not let an event tap see keystrokes in a secure input field (password
fields), and WinHub does not attempt to work around that.

## Code signing

Releases are signed with a self-signed identity and are **not notarized by
Apple**, so the first launch has to be cleared manually — see the README. That
means macOS has not vetted these builds, and you are trusting the source. If
that trade-off isn't one you want to make, [build from
source](README.md#building-from-source); it's a single script and no full Xcode
install is required.

## Third-party code

The Dynamic notch bundles [MediaRemoteAdapter](https://github.com/ungive/mediaremote-adapter)
(BSD-3-Clause) to read now-playing information, which runs as a `/usr/bin/perl`
subprocess. Its license is reproduced in `THIRD_PARTY_LICENSES` and shipped
inside the app bundle. There are no other dependencies.
