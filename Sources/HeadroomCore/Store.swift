import Foundation

public struct HistoryEntry: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var date: Date
    public var items: [String]
    public var freed: Int64

    public init(date: Date = Date(), items: [String], freed: Int64) {
        self.id = UUID()
        self.date = date
        self.items = items
        self.freed = freed
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

    public static func lastScan() -> ScanResult? { load("last-scan.json", as: ScanResult.self) }
    public static func saveScan(_ scan: ScanResult) { save(scan, as: "last-scan.json") }

    public static func snapshots() -> [FolderSnapshot] { load("snapshots.json", as: [FolderSnapshot].self) ?? [] }

    public static func appendSnapshot(_ snapshot: FolderSnapshot) {
        var all = snapshots()
        all.append(snapshot)
        save(Array(all.suffix(14)), as: "snapshots.json")
    }
}
