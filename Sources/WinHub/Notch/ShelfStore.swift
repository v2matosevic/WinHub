import AppKit
import Combine
import UniformTypeIdentifiers

/// One stashed item. Files are kept as bookmarks so they survive moves; the
/// last known path doubles as display name and dedupe identity.
struct ShelfItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case file, link, text }
    let id: UUID
    let kind: Kind
    var bookmark: Data?
    var path: String?
    var text: String?

    static func == (lhs: ShelfItem, rhs: ShelfItem) -> Bool { lhs.id == rhs.id }
}

/// The drop shelf: a staging tray for files/links/text dropped on the notch.
/// Persisted to Application Support so a relaunch keeps the stash.
@MainActor
final class ShelfStore: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []
    /// True while AirDrop/share is using shelf items — the notch must not auto-close.
    @Published var isSharing = false

    private nonisolated static let storeURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("WinHub/Shelf/items.json")

    private let sharingDelegate = SharingDelegate()

    init() {
        load()
    }

    // MARK: - Items

    func url(for item: ShelfItem) -> URL? {
        switch item.kind {
        case .file:
            if let bookmark = item.bookmark {
                var stale = false
                if let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) {
                    return url
                }
            }
            return item.path.map { URL(fileURLWithPath: $0) }
        case .link:
            return item.text.flatMap(URL.init(string:))
        case .text:
            return nil
        }
    }

    func displayName(for item: ShelfItem) -> String {
        switch item.kind {
        case .file: return url(for: item)?.lastPathComponent ?? "File"
        case .link: return text(for: item)
        case .text: return text(for: item)
        }
    }

    private func text(for item: ShelfItem) -> String { item.text ?? "" }

    func add(fileURL: URL) {
        let path = fileURL.path
        guard !items.contains(where: { $0.kind == .file && $0.path == path }) else { return }
        let bookmark = try? fileURL.bookmarkData()
        items.append(ShelfItem(id: UUID(), kind: .file, bookmark: bookmark, path: path, text: nil))
        save()
    }

    func add(link: URL) {
        let s = link.absoluteString
        guard !items.contains(where: { $0.kind == .link && $0.text == s }) else { return }
        items.append(ShelfItem(id: UUID(), kind: .link, bookmark: nil, path: nil, text: s))
        save()
    }

    func add(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !items.contains(where: { $0.kind == .text && $0.text == trimmed }) else { return }
        items.append(ShelfItem(id: UUID(), kind: .text, bookmark: nil, path: nil, text: trimmed))
        save()
    }

    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear() {
        items = []
        save()
    }

    // MARK: - Drop handling

    @discardableResult
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let url = Self.fileURL(from: item) else { return }
                    Task { @MainActor [weak self] in self?.add(fileURL: url) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                    guard let url = Self.fileURL(from: item) else { return }
                    Task { @MainActor [weak self] in self?.add(link: url) }
                }
            } else if provider.canLoadObject(ofClass: NSString.self) {
                handled = true
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                    guard let s = object as? String else { return }
                    Task { @MainActor [weak self] in self?.add(text: s) }
                }
            }
        }
        return handled
    }

    private nonisolated static func fileURL(from item: NSSecureCoding?) -> URL? {
        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        if let url = item as? URL { return url }
        if let s = item as? String { return URL(string: s) }
        return nil
    }

    // MARK: - AirDrop

    func airDrop() {
        let urls = items.compactMap { url(for: $0) }
        guard !urls.isEmpty,
              let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: urls) else { return }
        isSharing = true
        sharingDelegate.onDone = { [weak self] in
            Task { @MainActor in self?.isSharing = false }
        }
        service.delegate = sharingDelegate
        service.perform(withItems: urls)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let decoded = try? JSONDecoder().decode([ShelfItem].self, from: data) else { return }
        // Drop file entries whose target no longer exists anywhere.
        items = decoded.filter { item in
            guard item.kind == .file else { return true }
            guard let url = url(for: item) else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }
    }

    private func save() {
        do {
            let dir = Self.storeURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(items)
            try data.write(to: Self.storeURL, options: .atomic)
        } catch {
            NSLog("[WinHub.notch] shelf save failed: \(error)")
        }
    }
}

/// Clears the share-in-progress hold when AirDrop finishes either way.
private final class SharingDelegate: NSObject, NSSharingServiceDelegate {
    var onDone: (() -> Void)?
    func sharingService(_ service: NSSharingService, didShareItems items: [Any]) { onDone?() }
    func sharingService(_ service: NSSharingService, didFailToShareItems items: [Any], error: Error) { onDone?() }
}
