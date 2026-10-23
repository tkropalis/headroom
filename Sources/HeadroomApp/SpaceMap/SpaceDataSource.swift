import AppKit
import HeadroomCore

/// Where the Space Map's rows come from: folders measured through the size cache, kept in
/// memory for this session so going back is instant, and their icons.
@MainActor
final class SpaceDataSource {
    private let sizes: SizeCache
    private var measured: [String: (rows: [SpaceNode], at: Date)] = [:]
    private var icons: [String: NSImage] = [:]

    init(sizes: SizeCache = .shared) {
        self.sizes = sizes
    }

    /// Rows measured earlier in this session.
    func rows(in path: String) -> [SpaceNode]? { measured[path]?.rows }

    func measuredAt(_ path: String) -> Date? { measured[path]?.at }

    /// The folder's entries at once, with sizes from the snapshot where it has them.
    func listing(_ path: String, snapshot: FolderSnapshot?) -> [SpaceNode] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return names.map { name in
            let child = path + "/" + name
            let known = snapshot?.sizes[child] ?? 0
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: child, isDirectory: &isDir)
            return SpaceNode(path: child, name: name, allocated: known, unshared: known, isDirectory: isDir.boolValue)
        }
        .sorted { $0.allocated > $1.allocated }
    }

    /// Sizes saved from an earlier measurement that are still valid, without measuring.
    func savedSizes(_ paths: [String]) async -> [String: SizeInfo] {
        await sizes.cached(paths)
    }

    /// Sizes for a few entries, from the cache where it has them.
    func sizes(_ paths: [String]) async -> [String: SizeInfo] {
        await sizes.sizes(of: paths)
    }

    /// Measures every entry of the folder again and remembers the rows for this session.
    func measure(_ path: String) async -> [SpaceNode] {
        let sizes = self.sizes
        let limit = ProcessInfo.processInfo.activeProcessorCount
        let rows = await SpaceTree.children(of: path) { await sizes.sizes(of: $0, refresh: true, limit: limit) }
        if !Task.isCancelled { measured[path] = (rows, Date()) }
        return rows
    }

    /// What is inside a folder, one level down: from the snapshot when it measured folders
    /// there, else measured through the size cache, at most 4 at a time. Folders with very
    /// many entries get none; an impression of thousands of slivers says nothing.
    func contents(of path: String, snapshot: FolderSnapshot?) async -> [SpaceNode] {
        if let snapshot {
            let known = SpaceTree.snapshotContents(of: path, in: snapshot)
            if known.count >= 2 { return known }
        }
        guard SpaceTree.isDirectoryPath(path),
              let names = try? FileManager.default.contentsOfDirectory(atPath: path), names.count <= Self.contentsLimit
        else { return [] }
        let paths = names.map { path + "/" + $0 }
        let found = await sizes.sizes(of: paths, limit: 4)
        return paths.compactMap { child in
            guard let size = found[child], size.allocated > 0 else { return nil }
            return SpaceNode(path: child, name: (child as NSString).lastPathComponent, allocated: size.allocated,
                             unshared: size.unshared, isDirectory: SpaceTree.isDirectoryPath(child),
                             kind: SpaceTree.kind(of: child, isDirectory: SpaceTree.isDirectoryPath(child)))
        }
        .sorted { $0.allocated > $1.allocated }
    }

    static let contentsLimit = 80

    /// Forgets this session's rows, for example after something was cleaned or offloaded.
    func forget() {
        measured = [:]
    }

    /// Takes away a row that was moved to the Bin or offloaded, and the saved sizes it changed.
    func remove(_ path: String) {
        for key in measured.keys { measured[key]?.rows.removeAll { $0.path == path } }
        let sizes = self.sizes
        Task { await sizes.invalidate(path) }
    }

    /// The app's own icon for folders an app owns, else the Finder icon.
    /// `owner` is a bundle identifier Headroom already knows, from a rule or Ollie's answer.
    func icon(for path: String, owner: String? = nil) -> NSImage {
        if let cached = icons[path] { return cached }
        let image: NSImage
        if path.hasPrefix(SpaceMapModel.kindPrefix) {
            image = Self.kindIcon(String(path.dropFirst(SpaceMapModel.kindPrefix.count)))
        } else if let symbol = Self.symbol(for: path) {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage()
        } else if let app = AppOwner.app(for: path, hint: owner) {
            image = NSWorkspace.shared.icon(forFile: app.path)
        } else {
            image = NSWorkspace.shared.icon(forFile: path)
        }
        icons[path] = image
        return image
    }

    /// Symbols for rows that are no single folder.
    static func symbol(for path: String) -> String? {
        switch path {
        case SpaceMapModel.unmeasuredPath: return "questionmark.folder"
        case SpaceMapModel.volumesPath: return "apple.logo"
        default: break
        }
        if path.hasPrefix(SpaceMapModel.placePrefix) {
            switch SpacePlace(rawValue: String(path.dropFirst(SpaceMapModel.placePrefix.count))) {
            case .macOS: return "apple.logo"
            case .temporary: return "clock.arrow.circlepath"
            default: return "shippingbox"
            }
        }
        return nil
    }

    /// The app a kind is mostly about when it is installed, else a symbol. Shared with the sidebar.
    static func kindIcon(_ name: String) -> NSImage {
        let apps = ["Developer": "com.apple.dt.Xcode", "Docker": "com.docker.docker", "Claude": "com.anthropic.claudefordesktop"]
        if let id = apps[name], let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: SpaceSidebar.symbol(for: name), accessibilityDescription: nil) ?? NSImage()
    }
}

/// Finds the app a folder belongs to, for its icon. Only installed apps are used.
enum AppOwner {
    /// Folders named for a tool rather than its app.
    static let known: [String: String] = [
        ".android": "com.google.android.studio", "Android": "com.google.android.studio",
        ".gradle": "com.google.android.studio", ".claude": "com.anthropic.claudefordesktop",
        "Claude": "com.anthropic.claudefordesktop", ".vscode": "com.microsoft.VSCode",
        "Code": "com.microsoft.VSCode", ".docker": "com.docker.docker", "Steam": "com.valvesoftware.steam",
        "minecraft": "com.mojang.minecraftlauncher", "Xcode": "com.apple.dt.Xcode",
        "CoreSimulator": "com.apple.iphonesimulator", "DerivedData": "com.apple.dt.Xcode",
    ]

    /// Answers so far, by hint and path: Launch Services lookups are slow, and the map asks for
    /// every row's owner each time it lists a folder. Forgotten when the window opens.
    @MainActor private static var found: [String: URL?] = [:]

    @MainActor static func app(for path: String, hint: String?) -> URL? {
        let key = (hint ?? "") + "|" + path
        if let known = found[key] { return known }
        let url = lookUp(path, hint: hint)
        found[key] = url
        return url
    }

    @MainActor static func forget() { found = [:] }

    private static func lookUp(_ path: String, hint: String?) -> URL? {
        let workspace = NSWorkspace.shared
        if let hint, !hint.isEmpty, let url = workspace.urlForApplication(withBundleIdentifier: hint) { return url }
        let name = (path as NSString).lastPathComponent
        // Apps and the folders inside a bundle show the bundle's own icon already.
        if name.hasSuffix(".app") { return nil }
        if let id = known[name], let url = workspace.urlForApplication(withBundleIdentifier: id) { return url }

        let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        guard ["Containers", "Group Containers", "Application Support", "Caches", "Preferences"].contains(parent) else { return nil }
        // Bundle identifiers, with a group or team prefix taken off.
        var id = name.hasPrefix("group.") ? String(name.dropFirst(6)) : name
        if let dot = id.firstIndex(of: "."), id[..<dot].count == 10, id[..<dot].allSatisfy({ $0.isUppercase || $0.isNumber }) {
            id = String(id[id.index(after: dot)...])
        }
        if id.contains("."), let url = workspace.urlForApplication(withBundleIdentifier: id) { return url }
        // Folders named after the app.
        for folder in ["/Applications", Paths.home + "/Applications"] {
            let url = URL(fileURLWithPath: folder + "/" + name + ".app")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
}
