import Foundation

public struct HistoryEntry: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var date: Date
    public var items: [String]
    public var freed: Int64
    /// Items moved to the Bin: Bin path to original path, for Put Back.
    public var restorable: [String: String]?
    /// Set once the Bin items were put back.
    public var putBack: Bool?

    public init(date: Date = Date(), items: [String], freed: Int64, restorable: [String: String]? = nil) {
        self.id = UUID()
        self.date = date
        self.items = items
        self.freed = freed
        self.restorable = restorable
    }

    public var summary: String {
        items.count <= 2 ? items.joined(separator: " and ") : "\(items[0]) and \(items.count - 1) more"
    }
}

/// JSON files in ~/Library/Application Support/Headroom.
public enum Store {
    static var directory: URL {
        let url = URL(fileURLWithPath: Paths.appSupport)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func load<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, as name: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    public static func history() -> [HistoryEntry] { load("history.json", as: [HistoryEntry].self) ?? [] }

    public static func appendHistory(_ entry: HistoryEntry) {
        var all = history()
        all.insert(entry, at: 0)
        save(Array(all.prefix(200)), as: "history.json")
    }

    public static func saveHistory(_ entries: [HistoryEntry]) { save(Array(entries.prefix(200)), as: "history.json") }

    public static func freeSamples() -> [FreeSample] { load("free-space.json", as: [FreeSample].self) ?? [] }
    public static func saveFreeSamples(_ samples: [FreeSample]) { save(samples, as: "free-space.json") }

    public static func identicalGroups() -> (date: Date, groups: [IdenticalGroup])? {
        load("identical.json", as: IdenticalScan.self).map { ($0.date, $0.groups) }
    }
    public static func saveIdentical(_ groups: [IdenticalGroup], date: Date = Date()) {
        save(IdenticalScan(date: date, groups: groups), as: "identical.json")
    }

    struct IdenticalScan: Codable { var date: Date; var groups: [IdenticalGroup] }

    public static func lastScan() -> ScanResult? { load("last-scan.json", as: ScanResult.self) }
    public static func saveScan(_ scan: ScanResult) { save(scan, as: "last-scan.json") }

    public static func snapshots() -> [FolderSnapshot] { load("snapshots.json", as: [FolderSnapshot].self) ?? [] }

    public static func appendSnapshot(_ snapshot: FolderSnapshot) {
        var all = snapshots()
        all.append(snapshot)
        save(Array(all.suffix(14)), as: "snapshots.json")
    }
}
