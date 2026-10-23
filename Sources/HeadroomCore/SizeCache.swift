import Foundation

/// Measured sizes by path, kept on disk so going back to a folder shows its sizes at once.
///
/// An entry stays valid while the path's modification date is unchanged and it is younger
/// than `maxAge`. A folder's date only changes when entries are added or removed directly
/// inside it, so callers that must be current (the folder you open) pass `refresh: true`
/// and use the cached sizes only until the new ones arrive.
public actor SizeCache {
    public struct Entry: Codable, Sendable, Hashable {
        public var size: SizeInfo
        public var measuredAt: Date
        /// The path's modification date when it was measured.
        public var modified: Date?
    }

    public static let shared = SizeCache(file: URL(fileURLWithPath: Paths.appSupport).appendingPathComponent("sizes.json"))

    private var entries: [String: Entry]
    private let file: URL?
    private let measure: @Sendable (String) -> SizeInfo
    private let maxAge: TimeInterval
    /// Oldest entries are dropped beyond this, so the file stays small.
    private let capacity: Int

    /// - Parameter file: where entries are saved; nil keeps them in memory only.
    public init(file: URL?, maxAge: TimeInterval = 7 * 86400, capacity: Int = 5000,
                measure: @escaping @Sendable (String) -> SizeInfo = { Sizer.measure($0, unshared: true) }) {
        self.file = file
        self.maxAge = maxAge
        self.capacity = capacity
        self.measure = measure
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? decoder.decode([String: Entry].self, from: $0) } ?? [:]
    }

    /// The saved entry for `path` while it is still valid.
    public func cached(_ path: String, now: Date = Date()) -> Entry? {
        guard let entry = entries[path], now.timeIntervalSince(entry.measuredAt) < maxAge,
              entry.modified == SpaceTree.modificationDate(path) else { return nil }
        return entry
    }

    /// The valid saved sizes among `paths`, without measuring anything.
    public func cached(_ paths: [String]) -> [String: SizeInfo] {
        var out: [String: SizeInfo] = [:]
        for path in paths { if let entry = cached(path) { out[path] = entry.size } }
        return out
    }

    /// Sizes for `paths`, measuring only those without a valid entry (or all of them with
    /// `refresh`), at most `limit` at a time.
    public func sizes(of paths: [String], refresh: Bool = false, limit: Int = 4) async -> [String: SizeInfo] {
        var out: [String: SizeInfo] = [:]
        var missing: [String] = []
        for path in Set(paths) {
            if !refresh, let entry = cached(path) { out[path] = entry.size } else { missing.append(path) }
        }
        guard !missing.isEmpty else { return out }

        let measure = self.measure
        let measured = await withTaskGroup(of: (String, SizeInfo, Date?).self) { group in
            var queue = missing.sorted()[...]
            func next() {
                guard let path = queue.popFirst() else { return }
                group.addTask(priority: .utility) {
                    // Read the date first, so a change during measuring makes the entry stale.
                    let modified = SpaceTree.modificationDate(path)
                    return (path, measure(path), modified)
                }
            }
            for _ in 0..<max(1, limit) { next() }
            var results: [(String, SizeInfo, Date?)] = []
            for await result in group {
                results.append(result)
                next()
            }
            return results
        }
        if Task.isCancelled { return out }

        let now = Date()
        for (path, size, modified) in measured {
            entries[path] = Entry(size: size, measuredAt: now, modified: modified)
            out[path] = size
        }
        trim()
        save()
        return out
    }

    /// Forgets `path`, everything inside it, and the folders holding it, whose sizes changed with it.
    public func invalidate(_ path: String) {
        for key in entries.keys where key == path || key.hasPrefix(path + "/") || path.hasPrefix(key + "/") {
            entries[key] = nil
        }
        save()
    }

    public func clear() {
        entries = [:]
        save()
    }

    private func trim() {
        guard entries.count > capacity else { return }
        let keep = entries.sorted { $0.value.measuredAt > $1.value.measuredAt }.prefix(capacity)
        entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }

    private func save() {
        guard let file else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
