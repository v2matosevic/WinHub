import AppKit

/// Manual update check against the GitHub releases API — zero dependencies and no
/// background network traffic: it runs only when the user picks "Check for
/// Updates…" from the menu.
enum UpdateChecker {
    private static let releasesAPI =
        URL(string: "https://api.github.com/repos/v2matosevic/WinHub/releases/latest")!
    private static let releasesPage =
        URL(string: "https://github.com/v2matosevic/WinHub/releases/latest")!

    static func checkInteractively() {
        URLSession.shared.dataTask(with: releasesAPI) { data, _, _ in
            let latest = data.flatMap(latestVersion)
            DispatchQueue.main.async { present(latest: latest) }
        }.resume()
    }

    /// The release's version, from its git tag ("v0.7.0" → "0.7.0").
    private static func latestVersion(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any],
              let tag = json["tag_name"] as? String else { return nil }
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    private static func present(latest: String?) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()

        guard let latest else {
            alert.messageText = "Couldn't check for updates"
            alert.informativeText = "GitHub didn't answer. Try again later, or open the releases page directly."
            alert.addButton(withTitle: "Open Releases Page")
            alert.addButton(withTitle: "OK")
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(releasesPage) }
            return
        }

        if isNewer(latest, than: AppInfo.version) {
            alert.messageText = "WinHub \(latest) is available"
            alert.informativeText = "You have \(AppInfo.version). Download the new version from GitHub, then drag it over the old one."
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(releasesPage) }
        } else {
            alert.messageText = "You're up to date"
            alert.informativeText = "WinHub \(AppInfo.version) is the latest version."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    /// Numeric dotted-version compare, so "0.10.0" beats "0.9.1".
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
