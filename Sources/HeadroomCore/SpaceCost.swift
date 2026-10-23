import Foundation

/// What removing a folder or file costs you, in the menu's terms. One answer for any path,
/// used by the Space Map's list, inspector and tiles. It describes; it never decides what may
/// be moved, which stays with `PathSafety` and `Offloader.canOffload`.
public enum SpaceCost: String, Codable, Sendable, CaseIterable {
    /// Caches and build output: nothing is lost.
    case nothingLost
    /// Nothing is lost, but the next build or launch downloads or rebuilds it.
    case slowerNext
    /// Removing it loses something: app data, games, emulators, installed apps.
    case yourCall
    /// Your own documents and code.
    case yourFiles
    /// macOS itself, or space no app can clean.
    case system
    /// Headroom has no rule for it.
    case unknown

    public var title: String {
        switch self {
        case .nothingLost: "Nothing lost"
        case .slowerNext: "Slower next time"
        case .yourCall: "Your call"
        case .yourFiles: "Your files"
        case .system: "macOS"
        case .unknown: "Unknown"
        }
    }

    /// What you lose, in one sentence.
    public var note: String {
        switch self {
        case .nothingLost: "Nothing is lost. It comes back when needed."
        case .slowerNext: "Nothing is lost, but the next build or launch is slower."
        case .yourCall: "Removing it loses something. Check what before you do."
        case .yourFiles: "Your own files. Headroom doesn't suggest removing them."
        case .system: "Part of macOS, or space no app can clean."
        case .unknown: "Headroom has no rule for this. Look inside before removing it."
        }
    }

    /// The cost of removing `path`. Checked in order: your own folders, the scan's item for
    /// this path, the cleanup catalogue (built-in and learned), Ollie's saved answer, where
    /// the path is, and finally what kind of thing it is.
    public static func of(_ path: String, kind: SpaceKind?, candidate: Candidate? = nil,
                          explanation: Explanation? = nil, catalog: [CatalogEntry] = Catalog.all) -> SpaceCost {
        if isPersonal(path) { return .yourFiles }
        if let candidate, let cost = cost(of: candidate.group) { return cost }
        if let level = catalogLevel(path, catalog: catalog) { return cost(of: level) }
        if let explanation, explanation.path == path { return cost(of: explanation.verdict) }
        if let cost = byLocation(path) { return cost }
        if let kind { return cost(of: kind) }
        return .unknown
    }

    static func cost(of level: CleanupLevel) -> SpaceCost {
        switch level {
        case .safe: .nothingLost
        case .rebuilds: .slowerNext
        case .yourCall: .yourCall
        }
    }

    /// "Leave it" answers lose something too; they are never labelled macOS.
    static func cost(of verdict: Explanation.Verdict) -> SpaceCost {
        verdict.level.map(cost(of:)) ?? .yourCall
    }

    /// Identical copies say nothing about the cost of removing one file, so they don't decide.
    static func cost(of group: CandidateGroup) -> SpaceCost? {
        switch group {
        case .ready: .nothingLost
        case .rebuilds, .dormant: .slowerNext
        case .yourCall, .forgotten: .yourCall
        case .identical: nil
        }
    }

    static func cost(of kind: SpaceKind) -> SpaceCost {
        switch kind {
        case .cache, .buildOutput: .nothingLost
        case .dependencies: .slowerNext
        case .appData, .app, .emulator, .simulator, .forgotten: .yourCall
        case .project: .yourFiles
        }
    }

    /// The home folder and the folders whose names Headroom never sends anywhere.
    static func isPersonal(_ path: String) -> Bool {
        Explainer.privacyBlocker(path) != nil
    }

    /// The level of the catalogue entry that cleans this path or a folder holding it.
    static func catalogLevel(_ path: String, catalog: [CatalogEntry]) -> CleanupLevel? {
        func within(_ folder: String) -> Bool { path == folder || path.hasPrefix(folder + "/") }
        for entry in catalog {
            switch entry.target {
            case .paths(let list): if list.map(Paths.expand).contains(where: within) { return entry.level }
            case .adminContents(let dir): if within(dir) { return entry.level }
            case .oldChildren(let dir, _), .oldFiles(let dir, _, _): if within(Paths.expand(dir)) { return entry.level }
            case .docker, .probe: break
            }
        }
        return nil
    }

    static let systemFolders = ["/System", "/usr", "/bin", "/sbin", "/private/var/vm", "/Library/Apple",
                                "/System/Volumes/Data/System"]

    /// Places whose cost follows from where they are, whatever is inside.
    static func byLocation(_ path: String) -> SpaceCost? {
        if systemFolders.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return .system }
        let library = Paths.home + "/Library/"
        // Apps rebuild their caches; Apple's rules let macOS remove them too.
        if path.hasPrefix(library + "Caches/") || path.hasPrefix("/Library/Caches/") { return .nothingLost }
        // Sandboxed apps keep their data here, as others do in Application Support.
        for folder in ["Containers", "Group Containers", "Application Support"] {
            let parent = library + folder
            if (path as NSString).deletingLastPathComponent == parent { return .yourCall }
        }
        return nil
    }
}
