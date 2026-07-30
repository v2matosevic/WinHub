import Foundation

/// UserDefaults-backed knobs for the Finder keys module. Read live at the point
/// of use so Settings changes apply without restarting the module — and so a
/// single misbehaving translation can be switched off without losing the others.
enum FinderKeysSettings {
    static let deleteToTrashKey = "finderKeys.deleteToTrash"
    static let f2RenameKey = "finderKeys.f2Rename"
    static let enterOpensKey = "finderKeys.enterOpens"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            deleteToTrashKey: true,
            f2RenameKey: true,
            enterOpensKey: true,
        ])
    }

    static var deleteToTrash: Bool { UserDefaults.standard.bool(forKey: deleteToTrashKey) }
    static var f2Rename: Bool { UserDefaults.standard.bool(forKey: f2RenameKey) }
    static var enterOpens: Bool { UserDefaults.standard.bool(forKey: enterOpensKey) }
}
