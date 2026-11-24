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
    let category: String? // "electric", "acoustic", or "user"
    let summary: String?
    let chainOrder: [Int]
    let params: [Int: Float]
    let modelName: String?
    let irName: String?

    init(name: String,
         isFactory: Bool,
         category: String? = nil,
         summary: String? = nil,
         chainOrder: [Int],
         params: [Int: Float],
         modelName: String? = nil,
         irName: String? = nil) {
        self.name = name
        self.isFactory = isFactory
        self.category = category
        self.summary = summary
        self.chainOrder = chainOrder
        self.params = params
        self.modelName = modelName
        self.irName = irName
    }
}

enum PresetStore {
    static var dir: URL { StoreHelper.groupDir("Presets") ?? StoreHelper.localDir("Presets") }

    private static let stdOrder = [8, 0, 1, 2, 3, 4, 5, 6, 7]

    static let factory: [RigPreset] = [
        // =====================================================================
        // ELECTRIC GUITAR (11)
        // =====================================================================
        RigPreset(
            name: "Clean Studio", isFactory: true, category: "electric",
            summary: "Parallel Comp · Subtle Chorus · Plate",
            chainOrder: stdOrder,
            params: [6: 1, 7: 1, 8: 0, 9: 1, 10: 1, 11: 1, 12: 0, 13: 1,
                     15: -24, 16: 3.5, 17: 14, 18: 130, 19: 3, 20: 70,
                     28: 0, 29: 0.9, 30: 40, 31: 28,
                     37: 1, 38: 2.0, 39: 22, 40: 7500, 41: 22]
        ),
        RigPreset(
            name: "Funk Spank", isFactory: true, category: "electric",
            summary: "Snappy Comp · Bright EQ · Tight Room",
            chainOrder: stdOrder,
            params: [2: -1.5, 3: 1.0, 4: 2.5,
                     6: 1, 7: 1, 8: 0, 9: 1, 10: 1, 11: 0, 12: 0, 13: 1,
                     15: -28, 16: 6.0, 17: 4, 18: 75, 19: 5.5, 20: 85,
                     25: 100, 26: 11500,
                     37: 0, 38: 0.6, 39: 10, 40: 8500, 41: 12]
        ),
        RigPreset(
            name: "Edge of Breakup", isFactory: true, category: "electric",
            summary: "Klone Boost · Warm Tape · Room",
            chainOrder: stdOrder,
            params: [6: 1, 7: 0, 8: 1, 9: 1, 10: 1, 11: 0, 12: 1, 13: 1,
                     21: 32, 22: 60, 23: 2.5, 24: 1,
                     32: 1, 33: 370, 34: 30, 35: 3600, 36: 22,
                     37: 0, 38: 1.4, 39: 15, 40: 6200, 41: 18]
        ),
        RigPreset(
            name: "Indie Pop Sparkle", isFactory: true, category: "electric",
            summary: "Comp · Klone · Wide Chorus · Digital Dly · Plate",
            chainOrder: stdOrder,
            params: [2: -1.0, 4: 2.0,
                     6: 1, 7: 1, 8: 1, 9: 1, 10: 1, 11: 1, 12: 1, 13: 1,
                     15: -24, 16: 4.0, 17: 12, 18: 110, 19: 3.5, 20: 75,
                     21: 22, 22: 68, 23: 1.5, 24: 1,
                     28: 0, 29: 1.1, 30: 55, 31: 38,
                     32: 0, 33: 330, 34: 34, 35: 6800, 36: 24,
                     37: 1, 38: 2.4, 39: 28, 40: 8200, 41: 26]
        ),
        RigPreset(
            name: "Blues Lead", isFactory: true, category: "electric",
            summary: "Tube OD · Warm Tape Delay · Hall",
            chainOrder: stdOrder,
            params: [3: 2.0, 4: -0.5,
                     6: 1, 7: 0, 8: 1, 9: 1, 10: 1, 11: 0, 12: 1, 13: 1,
                     21: 52, 22: 52, 23: 2.0, 24: 0,
                     32: 1, 33: 410, 34: 36, 35: 2900, 36: 26,
                     37: 2, 38: 2.1, 39: 24, 40: 5400, 41: 22]
        ),
        RigPreset(
            name: "Vintage Tremolo", isFactory: true, category: "electric",
            summary: "Amp · Pulsing Tremolo · Tape Slap · Room",
            chainOrder: stdOrder,
            params: [2: 1.0, 4: 1.5,
                     6: 1, 7: 0, 8: 0, 9: 1, 10: 1, 11: 1, 12: 1, 13: 1,
                     28: 2, 29: 3.8, 30: 68, 31: 85,
                     32: 1, 33: 135, 34: 18, 35: 3400, 36: 20,
                     37: 0, 38: 1.7, 39: 12, 40: 5800, 41: 26]
        ),
        RigPreset(
            name: "Crunch Rhythm", isFactory: true, category: "electric",
            summary: "Gate · Klone Drive · Punchy Mid EQ · Room",
            chainOrder: [8, 0, 2, 3, 4, 1, 5, 6, 7],
            params: [1: -62, 2: 0.5, 3: 2.0, 4: 1.5,
                     6: 1, 7: 0, 8: 1, 9: 1, 10: 1, 11: 0, 12: 0, 13: 1,
                     14: 55,
                     21: 42, 22: 64, 23: 3.0, 24: 1,
                     25: 90, 26: 9000,
                     37: 0, 38: 0.8, 39: 10, 40: 6000, 41: 12]
        ),
        RigPreset(
            name: "Tight High-Gain", isFactory: true, category: "electric",
            summary: "Fast Gate · Tube Boost · Tight Cab Cuts",
            chainOrder: [8, 0, 2, 3, 4, 1, 5, 6, 7],
            params: [1: -54, 2: -1.0, 3: 1.5, 4: 1.5,
                     6: 1, 7: 0, 8: 1, 9: 1, 10: 1, 11: 0, 12: 0, 13: 0,
                     14: 40,
                     21: 16, 22: 70, 23: 4.5, 24: 0,
                     25: 105, 26: 8000]
        ),
        RigPreset(
            name: "Liquid Solo", isFactory: true, category: "electric",
            summary: "Gate · Tube OD · Ping-Pong Dly · Hall",
            chainOrder: [8, 0, 2, 3, 4, 1, 5, 6, 7],
            params: [1: -60, 3: 2.5, 4: 0.5,
                     6: 1, 7: 0, 8: 1, 9: 1, 10: 1, 11: 0, 12: 1, 13: 1,
                     14: 75,
                     21: 58, 22: 58, 23: 3.5, 24: 0,
                     25: 95, 26: 8800,
                     32: 2, 33: 420, 34: 42, 35: 3800, 36: 30,
                     37: 2, 38: 2.8, 39: 30, 40: 5600, 41: 26]
        ),
        RigPreset(
            name: "Fuzz Shoegaze", isFactory: true, category: "electric",
            summary: "Hall Reverb → Fuzz → Flanger → Tape Dly",
            chainOrder: [8, 0, 1, 7, 2, 3, 4, 5, 6],
            params: [6: 0, 7: 0, 8: 1, 9: 1, 10: 1, 11: 1, 12: 1, 13: 1,
                     21: 78, 22: 48, 23: -1.0, 24: 2,
                     28: 1, 29: 0.35, 30: 55, 31: 35,
                     32: 1, 33: 480, 34: 48, 35: 2800, 36: 32,
                     37: 2, 38: 4.2, 39: 15, 40: 4800, 41: 42]
        ),
        RigPreset(
            name: "Ambient Wash", isFactory: true, category: "electric",
            summary: "Comp · Slow Chorus · Ping-Pong · Huge Hall",
            chainOrder: stdOrder,
            params: [6: 0, 7: 1, 8: 0, 9: 1, 10: 1, 11: 1, 12: 1, 13: 1,
                     15: -26, 16: 4.0, 17: 18, 18: 160, 19: 4.0, 20: 85,
                     28: 0, 29: 0.55, 30: 68, 31: 42,
                     32: 2, 33: 440, 34: 58, 35: 3200, 36: 38,
                     37: 2, 38: 6.0, 39: 38, 40: 5000, 41: 50]
        ),

        // =====================================================================
        // ACOUSTIC GUITAR (8) — Amp & Cab bypassed by default (except Body IR)
        // =====================================================================
        RigPreset(
            name: "Acoustic Natural", isFactory: true, category: "acoustic",
            summary: "Gentle Parallel Comp · Warm Room",
            chainOrder: stdOrder,
            params: [6: 0, 7: 1, 8: 0, 9: 0, 10: 0, 11: 0, 12: 0, 13: 1,
                     15: -24, 16: 2.5, 17: 20, 18: 150, 19: 2.5, 20: 55,
                     37: 0, 38: 1.1, 39: 16, 40: 7800, 41: 18]
        ),
        RigPreset(
            name: "Fingerstyle Intimate", isFactory: true, category: "acoustic",
            summary: "Soft Comp (Transient Safe) · Plate · Subtle Dly",
            chainOrder: stdOrder,
            params: [6: 0, 7: 1, 8: 0, 9: 0, 10: 0, 11: 0, 12: 1, 13: 1,
                     15: -28, 16: 3.0, 17: 26, 18: 180, 19: 4.5, 20: 70,
                     32: 1, 33: 320, 34: 22, 35: 4400, 36: 12,
                     37: 1, 38: 2.3, 39: 26, 40: 7200, 41: 24]
        ),
        RigPreset(
            name: "Strummer Studio", isFactory: true, category: "acoustic",
            summary: "Peak-Taming Fast Comp · Tight Room",
            chainOrder: stdOrder,
            params: [6: 0, 7: 1, 8: 0, 9: 0, 10: 0, 11: 0, 12: 0, 13: 1,
                     15: -22, 16: 4.5, 17: 6, 18: 95, 19: 3.5, 20: 80,
                     37: 0, 38: 0.8, 39: 12, 40: 8200, 41: 14]
        ),
        RigPreset(
            name: "Acoustic Chorus", isFactory: true, category: "acoustic",
            summary: "Comp · Lush Stereo Chorus · Plate",
            chainOrder: stdOrder,
            params: [6: 0, 7: 1, 8: 0, 9: 0, 10: 0, 11: 1, 12: 0, 13: 1,
                     15: -24, 16: 3.0, 17: 18, 18: 140, 19: 3.0, 20: 65,
                     28: 0, 29: 0.75, 30: 52, 31: 32,
                     37: 1, 38: 2.2, 39: 24, 40: 7600, 41: 24]
        ),
        RigPreset(
            name: "Acoustic Slapback", isFactory: true, category: "acoustic",
            summary: "Comp · Short Tape Slap · Warm Room",
            chainOrder: stdOrder,
            params: [6: 0, 7: 1, 8: 0, 9: 0, 10: 0, 11: 0, 12: 1, 13: 1,
                     15: -24, 16: 3.2, 17: 14, 18: 120, 19: 3.0, 20: 65,
                     32: 1, 33: 115, 34: 18, 35: 3800, 36: 22,
                     37: 0, 38: 1.0, 39: 10, 40: 6800, 41: 15]
        ),
        RigPreset(
            name: "Acoustic Ambient", isFactory: true, category: "acoustic",
            summary: "Comp · Slow Chorus · Ping-Pong · Deep Hall",
            chainOrder: stdOrder,
            params: [6: 0, 7: 1, 8: 0, 9: 0, 10: 0, 11: 1, 12: 1, 13: 1,
                     15: -26, 16: 3.2, 17: 22, 18: 170, 19: 3.5, 20: 70,
                     28: 0, 29: 0.5, 30: 50, 31: 28,
                     32: 2, 33: 410, 34: 48, 35: 4200, 36: 32,
                     37: 2, 38: 4.8, 39: 36, 40: 6400, 41: 42]
        ),
        RigPreset(
            name: "Acoustic Mic Clean", isFactory: true, category: "acoustic",
            summary: "Denoiser (Tap Learn) · Gentle Comp · Room",
            chainOrder: stdOrder,
            params: [6: 0, 7: 1, 8: 0, 9: 0, 10: 0, 11: 0, 12: 0, 13: 1,
                     15: -26, 16: 2.8, 17: 20, 18: 150, 19: 3.0, 20: 60,
                     37: 0, 38: 1.2, 39: 18, 40: 7500, 41: 20,
                     42: 1, 43: 18, 44: 2, 45: 55, 46: 100]
        ),
        RigPreset(
            name: "Acoustic Body IR", isFactory: true, category: "acoustic",
            summary: "Comp · Wide-Band Cab IR Slot · Plate",
            chainOrder: stdOrder,
            params: [6: 0, 7: 1, 8: 0, 9: 0, 10: 1, 11: 0, 12: 0, 13: 1,
                     15: -24, 16: 3.0, 17: 18, 18: 140, 19: 3.0, 20: 65,
                     25: 75, 26: 16500, 27: 0,
                     37: 1, 38: 2.0, 39: 22, 40: 8000, 41: 22]
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