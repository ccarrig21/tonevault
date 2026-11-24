import Foundation

struct ModelFile: Identifiable, Hashable {
    let url: URL
    var id: String { url.path }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

/// Models live in the shared App Group when it's available. If a sideloading tool strips the
/// group, everything still works from each target's own Documents/Models folder, and the
/// plugin can import files directly.
enum ModelStore {
    private static func make(_ u: URL?) -> URL? {
        guard let u else { return nil }
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static var groupDir: URL? {
        make(FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Config.appGroup)?
            .appendingPathComponent("Models", isDirectory: true))
    }
    static var localDir: URL {
        make(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Models", isDirectory: true))!
    }
    static var writeDir: URL { groupDir ?? localDir }

    static func list() -> [ModelFile] {
        var out: [ModelFile] = []
        for d in [groupDir, localDir].compactMap({ $0 }) {
            let items = (try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []
            out += items.filter { $0.pathExtension.lowercased() == "nam" }.map(ModelFile.init)
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    static func url(named n: String) -> URL? { list().first { $0.name == n }?.url }
    static func delete(_ f: ModelFile) { try? FileManager.default.removeItem(at: f.url) }
    static func sanitize(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?*\"<>|")
        return s.components(separatedBy: bad).joined(separator: "_").trimmingCharacters(in: .whitespaces)
    }
    /// Move anything dropped into the app's Documents/Models (via Files) into the shared group.
    static func syncLocalToGroup() {
        guard let g = groupDir else { return }
        let items = (try? FileManager.default.contentsOfDirectory(at: localDir, includingPropertiesForKeys: nil)) ?? []
        for u in items where u.pathExtension.lowercased() == "nam" {
            let dest = g.appendingPathComponent(u.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: u, to: dest)
        }
    }
}
