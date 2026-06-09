import Foundation

/// Forces macOS's "Snap to Grid" icon arrangement as the default everywhere — the
/// desktop and Finder icon views — so files line up to a tidy grid instead of
/// landing wherever they're dropped. It's the Windows habit of icons that always
/// keep to a grid.
///
/// Finder stores icon-view arrangement in a handful of *view-settings* dictionaries
/// inside `com.apple.finder`; we set each one's `IconViewSettings.arrangeBy` to
/// `grid` and restart Finder so it takes effect. Folders a user has *individually*
/// customised keep their own setting (that lives in the folder's `.DS_Store`) —
/// exactly how "Use as Defaults" behaves in Finder. Disabling the tweak restores
/// whatever arrangement was in place before WinHub touched it.
final class SnapToGridModule: HubModule {
    let id = "snap-to-grid"
    let title = "Snap icons to a grid"
    let summary = "Lines up desktop and Finder icons to a tidy grid, everywhere."
    let requiredPermissions: [Permission] = []
    private(set) var isRunning = false

    private let finderDomain = "com.apple.finder"
    private let gridValue = "grid"
    /// Where the pre-change arrangement is stashed so `stop()` can restore it.
    private let backupKey = "snapToGrid.previousArrangeBy"
    /// The icon-view-settings dictionaries whose arrangement we drive. Covers the
    /// desktop, standard Finder folders (current + factory defaults), and Computer.
    private let viewSettingsKeys = [
        "DesktopViewSettings",
        "StandardViewSettings",
        "FK_StandardViewSettings",
        "ComputerViewSettings",
    ]

    func start() {
        guard !isRunning else { return }
        applyGrid()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        restorePrevious()
        isRunning = false
    }

    // MARK: - Apply / restore

    private func applyGrid() {
        guard let finder = UserDefaults(suiteName: finderDomain) else { return }

        // Snapshot the prior arrangement once (empty string == was unset / "none"),
        // so disabling the tweak can put it back.
        if UserDefaults.standard.dictionary(forKey: backupKey) == nil {
            var backup: [String: String] = [:]
            for key in viewSettingsKeys { backup[key] = arrangeBy(finder, key) ?? "" }
            UserDefaults.standard.set(backup, forKey: backupKey)
        }

        var changed = false
        for key in viewSettingsKeys where arrangeBy(finder, key) != gridValue {
            setArrangeBy(finder, key, gridValue)
            changed = true
        }
        if changed { restartFinder() }   // only when we actually moved something
    }

    private func restorePrevious() {
        guard let finder = UserDefaults(suiteName: finderDomain) else { return }
        let backup = UserDefaults.standard.dictionary(forKey: backupKey) as? [String: String] ?? [:]

        var changed = false
        for key in viewSettingsKeys {
            // Empty / missing backup means it was unset before — remove the key to
            // return to Finder's own default rather than pinning it to "none".
            let previous = backup[key]
            let target = (previous?.isEmpty ?? true) ? nil : previous
            if arrangeBy(finder, key) != target {
                setArrangeBy(finder, key, target)
                changed = true
            }
        }
        UserDefaults.standard.removeObject(forKey: backupKey)
        if changed { restartFinder() }
    }

    // MARK: - Nested-dictionary plumbing

    /// The `IconViewSettings.arrangeBy` currently stored under a view-settings key.
    private func arrangeBy(_ finder: UserDefaults, _ key: String) -> String? {
        let icon = finder.dictionary(forKey: key)?["IconViewSettings"] as? [String: Any]
        return icon?["arrangeBy"] as? String
    }

    /// Set (or, with `nil`, remove) `IconViewSettings.arrangeBy` without disturbing
    /// the rest of the view-settings dictionary.
    private func setArrangeBy(_ finder: UserDefaults, _ key: String, _ value: String?) {
        var top = finder.dictionary(forKey: key) ?? [:]
        var icon = (top["IconViewSettings"] as? [String: Any]) ?? [:]
        if let value { icon["arrangeBy"] = value } else { icon.removeValue(forKey: "arrangeBy") }
        top["IconViewSettings"] = icon
        finder.set(top, forKey: key)
    }

    private func restartFinder() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["Finder"]
        try? task.run()
    }
}
