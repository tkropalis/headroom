import Foundation

/// The top level of the Space Map's Folders view. Every folder in the daily snapshot belongs
/// to exactly one place, so the places add up to what was measured.
public enum SpacePlace: String, CaseIterable, Sendable, Hashable, Codable {
    case home, applications, library, macOS, temporary, other

    public var title: String {
        switch self {
        case .home: "Home"
        case .applications: "Applications"
        case .library: "Library"
        case .macOS: "macOS"
        case .temporary: "Temporary"
        case .other: "Other"
        }
    }

    /// The real folder, for places that are one. The others are gathered from the snapshot.
    public var path: String? {
        switch self {
        case .home: Paths.home
        case .applications: "/Applications"
        case .library: "/Library"
        case .macOS, .temporary, .other: nil
        }
    }

    /// The place a snapshot folder belongs to.
    public static func of(_ path: String) -> SpacePlace {
        func within(_ folder: String) -> Bool { path == folder || path.hasPrefix(folder + "/") }
        if within(Paths.home) { return .home }
        if within("/Applications") { return .applications }
        if within("/Library") { return .library }
        let folders = Paths.userFolders.hasSuffix("/") ? String(Paths.userFolders.dropLast()) : Paths.userFolders
        if within(folders) || within("/private" + folders) || within("/private/tmp") { return .temporary }
        if SpaceCost.systemFolders.contains(where: within) { return .macOS }
        return .other
    }
}

/// The whole disk in four numbers that add up: measured (by place), what apps can't measure, and free.
public struct SpaceOverview: Sendable, Hashable {
    public var total: Int64
    public var free: Int64
    /// Per place, largest first; macOS includes its own volumes.
    public var places: [Place]
    /// The macOS system, preboot and recovery volumes, which statfs reports but no folder holds.
    public var systemVolumes: Int64
    /// In use, but in no measured folder: system data, purgeable space, folders Headroom couldn't read.
    public var unmeasured: Int64

    public struct Place: Sendable, Hashable, Identifiable {
        public var id: SpacePlace { place }
        public var place: SpacePlace
        public var bytes: Int64
    }

    public var used: Int64 { total - free }
    public var measured: Int64 { places.reduce(0) { $0 + $1.bytes } }

    public init(snapshot: FolderSnapshot, disk: DiskStatus, systemVolumes: Int64) {
        var totals: [SpacePlace: Int64] = [:]
        for (path, size) in snapshot.sizes { totals[SpacePlace.of(path), default: 0] += size }
        // What the volumes use can't exceed what no folder accounts for.
        let measuredFolders = totals.values.reduce(0, +)
        let volumes = min(systemVolumes, max(0, disk.used - measuredFolders))
        totals[.macOS, default: 0] += volumes

        total = disk.total
        free = disk.available
        self.systemVolumes = volumes
        places = SpacePlace.allCases.compactMap { place in
            totals[place].flatMap { $0 > 0 ? Place(place: place, bytes: $0) : nil }
        }
        .sorted { $0.bytes > $1.bytes }
        unmeasured = max(0, disk.used - measuredFolders - volumes)
    }

    public func bytes(_ place: SpacePlace) -> Int64 { places.first { $0.place == place }?.bytes ?? 0 }
}

/// Bytes by what removing them costs, for a folder holding several measured folders.
public struct CostBreakdown: Sendable, Hashable {
    public var bytes: [SpaceCost: Int64]
    /// How many measured folders it is made of.
    public var count: Int

    public init(bytes: [SpaceCost: Int64], count: Int) {
        self.bytes = bytes
        self.count = count
    }

    public var total: Int64 { bytes.values.reduce(0, +) }

    /// Largest share first.
    public var parts: [(cost: SpaceCost, bytes: Int64)] {
        bytes.filter { $0.value > 0 }.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    /// More than one cost, each with a visible share.
    public var isMixed: Bool {
        let total = max(1, self.total)
        return bytes.values.filter { Double($0) / Double(total) >= 0.05 }.count >= 2
    }

    /// What can go without losing anything: nothing lost or slower next time.
    public var canGo: Int64 { (bytes[.nothingLost] ?? 0) + (bytes[.slowerNext] ?? 0) }
}

extension SpaceTree {
    /// Folders whose entries the daily snapshot measures, one by one or by summing the
    /// folders inside them. Their sizes come from the snapshot instead of measuring again.
    public static func isCovered(_ folder: String) -> Bool {
        let roots = [Paths.home, "/Applications", "/Library", trimmed(Paths.userFolders), "/Users"]
        return roots.contains(folder) || GrowthTracker.expanded.contains(folder)
    }

    /// The entries of a covered folder with sizes summed from the snapshot, largest first.
    /// `missing` are entries the snapshot has no folder for, such as ones made since.
    public static func snapshotChildren(of folder: String, snapshot: FolderSnapshot) -> (rows: [SpaceNode], missing: [String]) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        var sums: [String: Int64] = [:]
        let prefix = folder + "/"
        for (path, size) in snapshot.sizes where path.hasPrefix(prefix) {
            let rest = path.dropFirst(prefix.count)
            let child = prefix + (rest.split(separator: "/", maxSplits: 1).first.map(String.init) ?? String(rest))
            sums[child, default: 0] += size
        }
        var missing: [String] = []
        let rows = names.map { name -> SpaceNode in
            let path = prefix + name
            let isDirectory = isDirectoryPath(path)
            if sums[path] == nil { missing.append(path) }
            let size = sums[path] ?? 0
            return SpaceNode(path: path, name: name, allocated: size, unshared: size, isDirectory: isDirectory,
                             lastOpened: lastOpened(path), kind: kind(of: path, isDirectory: isDirectory))
        }
        return (rows.sorted { $0.allocated > $1.allocated }, missing)
    }

    /// The snapshot folders in a place, as rows, largest first.
    public static func rows(in place: SpacePlace, snapshot: FolderSnapshot) -> [SpaceNode] {
        snapshot.sizes.compactMap { path, size -> SpaceNode? in
            guard SpacePlace.of(path) == place else { return nil }
            let isDirectory = isDirectoryPath(path)
            return SpaceNode(path: path, name: displayName(path), allocated: size, unshared: size,
                             isDirectory: isDirectory, lastOpened: modificationDate(path),
                             kind: kind(of: path, isDirectory: isDirectory))
        }
        .sorted { $0.allocated > $1.allocated }
    }

    /// What removing the snapshot folders under `path` costs, by bytes. Nil when the
    /// snapshot holds fewer than two folders there.
    public static func breakdown(under path: String, snapshot: FolderSnapshot, catalog: [CatalogEntry]) -> CostBreakdown? {
        let prefix = path + "/"
        var bytes: [SpaceCost: Int64] = [:]
        var count = 0
        for (entry, size) in snapshot.sizes where entry.hasPrefix(prefix) {
            count += 1
            bytes[SpaceCost.of(entry, kind: kind(of: entry, isDirectory: true), catalog: catalog), default: 0] += size
        }
        return count >= 2 ? CostBreakdown(bytes: bytes, count: count) : nil
    }

    /// The snapshot folders in a place, summed by cost.
    public static func breakdown(of place: SpacePlace, snapshot: FolderSnapshot, catalog: [CatalogEntry]) -> CostBreakdown {
        var bytes: [SpaceCost: Int64] = [:]
        var count = 0
        for (entry, size) in snapshot.sizes where SpacePlace.of(entry) == place {
            count += 1
            bytes[SpaceCost.of(entry, kind: kind(of: entry, isDirectory: true), catalog: catalog), default: 0] += size
        }
        return CostBreakdown(bytes: bytes, count: count)
    }

    /// The snapshot folders of a category, summed by cost. `otherCategory` means the folders no rule claims.
    public static func breakdown(ofCategory name: String, snapshot: FolderSnapshot, catalog: [CatalogEntry]) -> CostBreakdown {
        var bytes: [SpaceCost: Int64] = [:]
        var count = 0
        for (entry, size) in snapshot.sizes {
            let own = category(of: entry)
            guard name == otherCategory ? own == nil : own == name else { continue }
            count += 1
            bytes[SpaceCost.of(entry, kind: kind(of: entry, isDirectory: true), catalog: catalog), default: 0] += size
        }
        return CostBreakdown(bytes: bytes, count: count)
    }

    static func trimmed(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

extension RelativeDate {
    /// "Today", "Yesterday", "3 days ago", "2 weeks ago", "5 months ago", "2 years ago".
    public static func ago(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1: return "Today"
        case 1: return "Yesterday"
        case ..<14: return "\(days) days ago"
        case ..<61: return "\(days / 7) weeks ago"
        case ..<365: return "\(max(2, days / 30)) months ago"
        default: return days < 730 ? "A year ago" : "\(days / 365) years ago"
        }
    }

    /// Not used for 6 months, the Space Map's filter.
    public static func isUnused(_ date: Date?, now: Date = Date()) -> Bool {
        guard let date else { return false }
        return now.timeIntervalSince(date) > 182 * 86400
    }
}

/// How far back the Space Map compares sizes. Snapshots are daily, so these are whole days.
public enum SpaceSince: Int, CaseIterable, Sendable, Hashable {
    case day = 1, week = 7, twoWeeks = 14

    public var title: String {
        switch self {
        case .day: "Yesterday"
        case .week: "Last week"
        case .twoWeeks: "Two weeks ago"
        }
    }

    /// The newest snapshot at least this old compared with `current`. A few hours of slack
    /// keep a snapshot taken a little later in the day from being skipped.
    public func previous(in history: [FolderSnapshot], current: FolderSnapshot) -> FolderSnapshot? {
        let age = Double(rawValue) * 86400 - 4 * 3600
        return history.last { current.date.timeIntervalSince($0.date) >= age }
    }
}

extension SpaceTree {
    /// What the snapshot measured at `path` and inside it.
    public static func total(under path: String, in snapshot: FolderSnapshot) -> Int64 {
        let prefix = path + "/"
        return snapshot.sizes.reduce(0) { sum, entry in
            entry.key == path || entry.key.hasPrefix(prefix) ? sum + entry.value : sum
        }
    }

    /// What the snapshot measured for the folders `matches` picks.
    public static func total(in snapshot: FolderSnapshot, where matches: (String) -> Bool) -> Int64 {
        snapshot.sizes.reduce(Int64(0)) { sum, entry in matches(entry.key) ? sum + entry.value : sum }
    }

    /// The measured folders inside `path`, one level down, summed from the snapshot without
    /// reading the disk. Empty when the snapshot holds nothing below `path`.
    public static func snapshotContents(of path: String, in snapshot: FolderSnapshot) -> [SpaceNode] {
        let prefix = path + "/"
        var sums: [String: Int64] = [:]
        for (entry, size) in snapshot.sizes where entry.hasPrefix(prefix) {
            let rest = entry.dropFirst(prefix.count)
            sums[prefix + (rest.split(separator: "/", maxSplits: 1).first.map(String.init) ?? String(rest)), default: 0] += size
        }
        return sums.map { child, size in
            SpaceNode(path: child, name: (child as NSString).lastPathComponent, allocated: size, unshared: size,
                      isDirectory: true)
        }
        .sorted { $0.allocated > $1.allocated }
    }
}
