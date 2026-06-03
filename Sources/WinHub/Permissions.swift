import AppKit
import ApplicationServices
import CoreGraphics

/// A macOS privacy permission a module may depend on.
enum Permission {
    case accessibility
    case screenRecording

    var displayName: String {
        switch self {
        case .accessibility:   return "Accessibility"
        case .screenRecording: return "Screen Recording"
        }
    }

    /// Whether the permission is currently granted to this process.
    var isGranted: Bool {
        switch self {
        case .accessibility:   return AXIsProcessTrusted()
        case .screenRecording: return CGPreflightScreenCaptureAccess()
        }
    }
}

enum Permissions {
    /// Trigger the system Accessibility prompt (only shows once per code identity;
    /// thereafter the user must toggle it in System Settings).
    static func requestAccessibility() {
        // We pass the prompt-option key as its literal string value rather than the
        // `kAXTrustedCheckOptionPrompt` constant: the AX headers are unaudited, so
        // that constant bridges to Swift differently across SDKs (Unmanaged<CFString>
        // vs CFString). The string value is stable and documented.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
    }

    /// Open the relevant pane in System Settings → Privacy & Security.
    static func openSettings(for permission: Permission) {
        let anchor: String
        switch permission {
        case .accessibility:   anchor = "Privacy_Accessibility"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
