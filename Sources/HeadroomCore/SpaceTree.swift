import CoreServices
import Foundation

/// What Headroom recognises a folder or file to be, shown as a label in the Space Map.
public enum SpaceKind: String, Codable, Sendable {
    case cache, buildOutput, dependencies, project, appData, app, emulator, simulator, forgotten

    public var title: String {
        switch self {
        case .cache: "Cache"
        case .buildOutput: "Build output"
        case .dependencies: "Dependencies"
        case .project: "Project"
        case .appData: "App data"
        case .app: "App"
        case .emulator: "Emulator"
        case .simulator: "Simulator"
        case .forgotten: "Forgotten"
        }
    }
}

/// One row of the Space Map: a folder or file with its measured size.
public struct SpaceNode: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var allocated: Int64
    public var unshared: Int64
    public var isDirectory: Bool
    public var lastOpened: Date?
    public var kind: SpaceKind?
    /// Same rule as `SizeInfo.sharesSpace`: clones make `allocated` overstate the real gain.
    public var sharesSpace: Bool

    public init(path: String, name: String, allocated: Int64, unshared: Int64, isDirectory: Bool,
                lastOpened: Date? = nil, kind: SpaceKind? = nil, sharesSpace: Bool = false) {
        self.path = path
        self.name = name
        self.allocated = allocated
        self.unshared = unshared
        self.isDirectory = isDirectory
        self.lastOpened = lastOpened
        self.kind = kind
        self.sharesSpace = sharesSpace
    }

    /// What deleting this would give back, as far as Headroom can tell before trying.
    public var reclaimable: Int64 { unshared > 0 ? unshared : allocated }
}

public struct SpaceCategory: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var bytes: Int64

    public init(name: String, bytes: Int64) {
        self.name = name
        self.bytes = bytes
    }
}

/// Accounts for the whole disk: categories from the daily snapshot, and folders measured on demand.
public enum SpaceTree {
    /// The catch-all category: folders no rule claims, plus space the snapshot didn't measure.
    public static let otherCategory = "System and other"

    private static let rules: [(name: String, matches: (String) -> Bool)] = [
        ("Developer", { p in ["/Library/Developer", "/Library/Android", "/.gradle", "/.android", "Xcode.app",
                               "Android Studio.app", "/.cocoapods", "/.swiftpm", "/.expo", "/.maestro"].contains { p.contains($0) } }),
        ("Docker", { p in p.contains("com.docker.docker") || p.hasSuffix("/.docker") || p.hasSuffix("Docker.app") }),
        ("Claude", { p in p.hasSuffix("/Application Support/Claude") || p.hasSuffix("/.claude") || p.hasSuffix("Claude.app") }),
        ("Caches", { p in p.contains("/Library/Caches/") || p.hasPrefix(Paths.userFolders) || p.hasSuffix("/.npm") || p.hasSuffix("/.cache") }),
        ("Apps", { p in p.hasPrefix("/Applications/") }),
        ("Projects", { p in
            let home = Paths.home
            return p.hasPrefix(home + "/") && !p.dropFirst(home.count + 1).contains("/")
                && !p.dropFirst(home.count + 1).hasPrefix(".")
        }),
    ]

    /// Category of a top-level folder from the growth snapshot, or nil for Other.
    public static func category(of path: String) -> String? {
        rules.first { $0.matches(path) }?.name
    }

    /// Categories with totals, then everything else as "System and other".
    public static func categories(snapshot: FolderSnapshot, disk: DiskStatus) -> [SpaceCategory] {
        var totals: [String: Int64] = [:]
        for (path, size) in snapshot.sizes {
            if let name = category(of: path) { totals[name, default: 0] += size }
        }
        var out = rules.map { SpaceCategory(name: $0.name, bytes: totals[$0.name] ?? 0) }.filter { $0.bytes > 0 }
        let measured = out.reduce(Int64(0)) { $0 + $1.bytes }
        out.append(SpaceCategory(name: otherCategory, bytes: max(0, disk.used - measured)))
        return out
    }

    /// Top-level rows from the snapshot, largest first. `category` nil means every row;
    /// `otherCategory` means the rows no rule claims. Nothing is measured again.
    public static func topLevel(snapshot: FolderSnapshot, category: String?) -> [SpaceNode] {
        snapshot.sizes.compactMap { path, size -> SpaceNode? in
            if let category {
                let own = self.category(of: path)
                if category == otherCategory ? own != nil : own != category { return nil }
            }
            let isDirectory = isDirectoryPath(path)
            return SpaceNode(path: path, name: displayName(path), allocated: size, unshared: size,
                             isDirectory: isDirectory, lastOpened: modificationDate(path),
                             kind: kind(of: path, isDirectory: isDirectory))
        }
        .sorted { $0.allocated > $1.allocated }
    }

    /// The entries of a folder, each measured (clone-aware), largest first.
    public static func children(of path: String) async -> [SpaceNode] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        let paths = names.map { path == "/" ? "/" + $0 : path + "/" + $0 }
        let sizes = await Sizer.measureAll(paths, unshared: true)
        return paths.map { child in
            let size = sizes[child] ?? .zero
            let isDirectory = isDirectoryPath(child)
            return SpaceNode(path: child, name: (child as NSString).lastPathComponent,
                             allocated: size.allocated, unshared: size.unshared, isDirectory: isDirectory,
                             lastOpened: lastOpened(child), kind: kind(of: child, isDirectory: isDirectory),
                             sharesSpace: size.sharesSpace)
        }
        .sorted { $0.allocated > $1.allocated }
    }

    static let dependencyNames: Set<String> = ProjectFinder.dependencyFolders.union(["vendor"])

    /// Top-level folders outside the home folder get a name that says what they are.
    public static func displayName(_ path: String) -> String {
        switch path {
        case "/opt": "Homebrew and other tools (/opt)"
        case "/usr/local": "Local tools (/usr/local)"
        case "/private/var/vm": "Swap and sleep image"
        case "/System/Volumes/Data/System/Library/AssetsV2": "System assets, including simulator runtimes"
        default:
            path.hasPrefix("/Library/") ? "/Library/" + (path as NSString).lastPathComponent : (path as NSString).lastPathComponent
        }
    }

    public static func kind(of path: String, isDirectory: Bool) -> SpaceKind? {
        let name = (path as NSString).lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent

        if dependencyNames.contains(name) { return .dependencies }
        if ProjectFinder.buildCaches.contains(name) || path.hasSuffix("/Xcode/DerivedData") { return .buildOutput }
        if isCatalogued(path) { return .cache }
        if name.hasSuffix(".avd") { return .emulator }
        if parent.hasSuffix("/CoreSimulator/Devices"), UUID(uuidString: name) != nil { return .simulator }
        if name.hasSuffix(".app") { return .app }
        if parent == Paths.home + "/Library/Application Support" { return .appData }
        if isDirectory, let names = try? FileManager.default.contentsOfDirectory(atPath: path),
           !ProjectFinder.markers.isDisjoint(with: names) || names.contains(".git") {
            return .project
        }
        return nil
    }

    /// The folder is a cache the catalogue cleans, or holds what it cleans. "Your call"
    /// entries (games, VM images) aren't caches, so they keep their own kind.
    static func isCatalogued(_ path: String) -> Bool {
        for entry in Catalog.builtIn where entry.level != .yourCall {
            switch entry.target {
            case .paths(let list): if list.map(Paths.expand).contains(path) { return true }
            case .adminContents(let dir): if dir == path { return true }
            case .oldChildren(let dir, _), .oldFiles(let dir, _, _): if Paths.expand(dir) == path { return true }
            case .docker, .probe: break
            }
        }
        return false
    }

    /// Spotlight's last-opened date, else the last modification.
    public static func lastOpened(_ path: String) -> Date? {
        if let item = MDItemCreate(kCFAllocatorDefault, path as CFString),
           let date = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date {
            return date
        }
        return modificationDate(path)
    }

    /// Space in use that no folder in the snapshot accounts for: system data, purgeable space,
    /// and folders Headroom couldn't read.
    public static func unmeasured(snapshot: FolderSnapshot, disk: DiskStatus) -> Int64 {
        max(0, disk.used - snapshot.sizes.values.reduce(0, +))
    }

    static func modificationDate(_ path: String) -> Date? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
    }

    static func isDirectoryPath(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }
}
