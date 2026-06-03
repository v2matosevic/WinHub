import Foundation

enum AppInfo {
    static let name = "WinHub"

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.0"
    }
}
