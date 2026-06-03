import AppKit

// WinHub is a menu-bar agent (LSUIElement). No Dock icon, no main window —
// it lives in the status bar and hosts a set of toggleable "modules", each a
// small quality-of-life tweak for ex-Windows users on macOS.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
