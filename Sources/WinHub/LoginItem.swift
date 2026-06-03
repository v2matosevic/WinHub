import Foundation
import ServiceManagement

/// Launch-at-login, backed by `SMAppService` (macOS 13+). Registers the running
/// app bundle as a login item so WinHub starts automatically with the Mac.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            NSLog("[WinHub] login item \(enabled ? "register" : "unregister") failed: \(error)")
            return false
        }
    }
}
