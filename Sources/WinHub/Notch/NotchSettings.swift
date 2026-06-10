import Foundation

/// UserDefaults-backed knobs for the Dynamic notch module. Read live at the
/// point of use so Settings changes apply without restarting the module.
enum NotchSettings {
    static let openOnHoverKey = "notch.openOnHover"
    static let hoverDelayKey = "notch.hoverDelay"
    static let liveActivityKey = "notch.liveActivity"
    static let shelfKey = "notch.shelf"
    static let hapticsKey = "notch.haptics"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            openOnHoverKey: true,
            hoverDelayKey: 0.3,
            liveActivityKey: true,
            shelfKey: true,
            hapticsKey: true,
        ])
    }

    static var openOnHover: Bool { UserDefaults.standard.bool(forKey: openOnHoverKey) }
    static var hoverDelay: Double { UserDefaults.standard.double(forKey: hoverDelayKey) }
    static var liveActivity: Bool { UserDefaults.standard.bool(forKey: liveActivityKey) }
    static var shelfEnabled: Bool { UserDefaults.standard.bool(forKey: shelfKey) }
    static var haptics: Bool { UserDefaults.standard.bool(forKey: hapticsKey) }
}
