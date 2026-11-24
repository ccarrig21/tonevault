import Foundation

struct ModelFile: Identifiable, Hashable {
    let url: URL
    var id: String { url.path }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

private enum StoreHelper {
    static func make(_ u: URL?) -> URL? {
        guard let u else { return nil }
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static func groupDir(_ folder: String) -> URL? {
        make(FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Config.appGroup)?
            .appendingPathComponent(folder, isDirectory: true))
    }
    static func localDir(_ folder: String) -> URL {
        make(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(folder, isDirectory: true))!
    }
    static func list(folder: String, exts: Set<String>) -> [ModelFile] {
        var seen = Set<String>()
        var out: [ModelFile] = []
        for d in [groupDir(folder), localDir(folder)].compactMap({ $0 }) {
            let items = (try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []
            for u in items where exts.contains(u.pathExtension.lowercased()) {
                let f = ModelFile(url: u)
                if seen.insert(f.name.lowercased()).inserted { out.append(f) }
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    static func sync(folder: String, exts: Set<String>) {
        guard let g = groupDir(folder) else { return }
        let local = localDir(folder)
        let items = (try? FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: nil)) ?? []
        for u in items where exts.contains(u.pathExtension.lowercased()) {
            let dest = g.appendingPathComponent(u.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: u, to: dest)
        }
    }
}

/// NAM models (.nam) shared through the App Group with local Documents fallback.
enum ModelStore {
    static let exts: Set<String> = ["nam"]
    static var groupDir: URL? { StoreHelper.groupDir("Models") }
    static var localDir: URL { StoreHelper.localDir("Models") }
    static var writeDir: URL { groupDir ?? localDir }

    static func list() -> [ModelFile] { StoreHelper.list(folder: "Models", exts: exts) }
    static func url(named n: String) -> URL? { list().first { $0.name == n }?.url }
    static func delete(_ f: ModelFile) { try? FileManager.default.removeItem(at: f.url) }
    static func sanitize(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?*\"<>|")
        return s.components(separatedBy: bad).joined(separator: "_").trimmingCharacters(in: .whitespaces)
    }
    static func syncLocalToGroup() { StoreHelper.sync(folder: "Models", exts: exts) }
}

/// Cabinet Impulse Responses (.wav / .aif / .aiff) mirroring ModelStore.
enum IRStore {
    static let exts: Set<String> = ["wav", "aif", "aiff"]
    static var groupDir: URL? { StoreHelper.groupDir("IRs") }
    static var localDir: URL { StoreHelper.localDir("IRs") }
    static var writeDir: URL { groupDir ?? localDir }

    static func list() -> [ModelFile] { StoreHelper.list(folder: "IRs", exts: exts) }
    static func url(named n: String) -> URL? { list().first { $0.name == n }?.url }
    static func delete(_ f: ModelFile) { try? FileManager.default.removeItem(at: f.url) }
    static func syncLocalToGroup() { StoreHelper.sync(folder: "IRs", exts: exts) }
}

/// Full pedalboard rig presets (order, params, optional amp & IR references).
struct RigPreset: Identifiable, Codable, Hashable {
    var id: String { name }
    let name: String
    let isFactory: Bool
    let chainOrder: [Int]
    let params: [Int: Float]
    let modelName: String?
    let irName: String?
}

enum PresetStore {
    static var dir: URL { StoreHelper.groupDir("Presets") ?? StoreHelper.localDir("Presets") }

    static let factory: [RigPreset] = [
        RigPreset(
            name: "Clean Studio", isFactory: true,
            chainOrder: [0, 1, 2, 3, 4, 5, 6, 7],
            params: [6: 1, 7: 1, 8: 0, 9: 1, 10: 1, 11: 1, 12: 0, 13: 1,
                     15: -24, 16: 3.5, 19: 3, 20: 70, 28: 0, 29: 0.9, 30: 40, 31: 30,
                     37: 1, 38: 2.0, 39: 22, 40: 7500, 41: 22],
            modelName: nil, irName: nil
        ),
        RigPreset(
            name: "Edge of Breakup", isFactory: true,
            chainOrder: [0, 1, 2, 3, 4, 5, 6, 7],
            params: [6: 1, 7: 0, 8: 1, 9: 1, 10: 1, 11: 0, 12: 1, 13: 1,
                     21: 35, 22: 60, 23: 2, 24: 1,
                     32: 1, 33: 380, 34: 32, 35: 3600, 36: 22,
                     37: 0, 38: 1.4, 39: 15, 40: 6200, 41: 18],
            modelName: nil, irName: nil
        ),
        RigPreset(
            name: "Tight High-Gain", isFactory: true,
            chainOrder: [0, 2, 3, 4, 1, 5, 6, 7],
            params: [1: -55, 6: 1, 7: 0, 8: 1, 9: 1, 10: 1, 11: 0, 12: 0, 13: 0,
                     14: 45, 21: 18, 22: 68, 23: 4, 24: 0,
                     25: 100, 26: 8200, 27: 0],
            modelName: nil, irName: nil
        ),
        RigPreset(
            name: "Ambient Wash", isFactory: true,
            chainOrder: [0, 1, 3, 4, 5, 6, 7, 2],
            params: [6: 0, 7: 1, 8: 0, 9: 1, 10: 1, 11: 1, 12: 1, 13: 1,
                     15: -26, 16: 4, 19: 4, 20: 85,
                     28: 0, 29: 0.6, 30: 65, 31: 42,
                     32: 2, 33: 440, 34: 55, 35: 3200, 36: 38,
                     37: 2, 38: 5.5, 39: 35, 40: 5200, 41: 48],
            modelName: nil, irName: nil
        ),
    ]

    static func listUser() -> [RigPreset] {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension.lowercased() == "json" }.compactMap { u in
            guard let d = try? Data(contentsOf: u) else { return nil }
            return try? JSONDecoder().decode(RigPreset.self, from: d)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func save(_ p: RigPreset) {
        let safe = ModelStore.sanitize(p.name)
        guard !safe.isEmpty, let d = try? JSONEncoder().encode(p) else { return }
        try? d.write(to: dir.appendingPathComponent(safe + ".json"))
    }

    static func delete(named name: String) {
        let safe = ModelStore.sanitize(name)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(safe + ".json"))
    }
}