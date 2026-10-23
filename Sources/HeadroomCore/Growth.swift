import Foundation

/// Sizes of the folders Headroom watches, taken once a day.
public struct FolderSnapshot: Codable, Sendable {
    public var date: Date
    public var sizes: [String: Int64]

    /// Without folders deleted since it was taken, whose space is free now.
    public func existing() -> FolderSnapshot {
        FolderSnapshot(date: date, sizes: sizes.filter { path, _ in
            var st = stat()
            return lstat(path, &st) == 0
        })
    }
}

public struct GrowthAlert: Codable, Sendable, Identifiable, Hashable {
    public var path: String
    public var previous: Int64
    public var current: Int64
    public var since: Date
    /// Part of the growth may be clones sharing space; the real gain is smaller.
    public var sharesSpace: Bool

    public init(path: String, previous: Int64, current: Int64, since: Date, sharesSpace: Bool) {
        self.path = path
        self.previous = previous
        self.current = current
        self.since = since
        self.sharesSpace = sharesSpace
    }

    public var id: String { path }
    public var delta: Int64 { current - previous }
    public var name: String { GrowthTracker.displayName(path) }

    public var headline: String {
        "\(name) grew \(sharesSpace ? "up to " : "")\(ByteFormat.string(delta))"
    }
}

public enum GrowthTracker {
    /// Folders measured by their children instead of as a whole, so alerts name something specific.
    static var expanded: Set<String> {
        let h = Paths.home
        let f = Paths.userFolders
        return [h, h + "/Library", h + "/Library/Caches", h + "/Library/Application Support",
                h + "/Library/Containers", h + "/Library/Group Containers", h + "/Library/Developer",
                f, f + "/X", f + "/C", f + "/T", "/Applications"]
    }

    public static func watchedFolders() -> [String] {
        let fm = FileManager.default
        let expanded = self.expanded
        var out: [String] = []
        func visit(_ dir: String) {
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
                let path = dir + "/" + name
                if (try? fm.destinationOfSymbolicLink(atPath: path)) != nil { continue }
                if expanded.contains(path) { visit(path) } else { out.append(path) }
            }
        }
        for root in [Paths.home, "/Applications", Paths.userFolders, "/Library"] { visit(root) }
        // Outside the home folder, a few places hold most of the rest: Homebrew, swap and
        // the simulator runtimes macOS keeps as system assets.
        out += ["/opt", "/usr/local", "/private/var/vm", "/System/Volumes/Data/System/Library/AssetsV2"]
            .filter { fm.fileExists(atPath: $0) }
        return out
    }

    public static func record() async -> FolderSnapshot {
        let sizes = await Sizer.measureAll(watchedFolders(), unshared: false)
        return FolderSnapshot(date: Date(), sizes: sizes.mapValues(\.allocated))
    }

    /// Compares with the newest snapshot at least 20 hours older than `current`.
    public static func alerts(history: [FolderSnapshot], current: FolderSnapshot, threshold: Int64) -> [GrowthAlert] {
        guard let previous = history.last(where: { current.date.timeIntervalSince($0.date) >= 20 * 3600 }) else { return [] }
        return current.sizes.compactMap { path, size in
            let before = previous.sizes[path] ?? 0
            guard size - before >= threshold else { return nil }
            let unshared = Sizer.measure(path, unshared: true)
            return GrowthAlert(path: path, previous: before, current: size, since: previous.date,
                               sharesSpace: unshared.sharesSpace)
        }.sorted { $0.delta > $1.delta }
    }

    /// A catalogue name when the folder is a known cache, else a short path.
    public static func displayName(_ path: String) -> String {
        for entry in Catalog.all {
            if case .paths(let paths) = entry.target, paths.map(Paths.expand).contains(path) { return entry.name }
        }
        return Paths.display(path)
    }
}
