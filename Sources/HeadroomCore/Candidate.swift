import Foundation

public enum CandidateGroup: String, Codable, Sendable, CaseIterable {
    case ready, rebuilds, yourCall, identical, forgotten, dormant

    public var title: String {
        switch self {
        case .ready: "Ready to clean"
        case .rebuilds: "Rebuilds on use"
        case .yourCall: "Your call"
        case .identical: "Identical files"
        case .forgotten: "Forgotten files"
        case .dormant: "Dormant projects"
        }
    }

    public var note: String {
        switch self {
        case .ready: "Nothing is lost."
        case .rebuilds: "Nothing is lost, but the next build or launch is slower."
        case .yourCall: "Each of these loses something. Removed items go to the Bin where they can."
        case .identical: "Copies of the same file share their disk space. Every file stays where it is and opens as before."
        case .forgotten: "Over 500 MB and not opened for 6 months, plus installers for apps you already have. They go to the Bin."
        case .dormant: "No commit or edit in 90 days. The code stays; dependencies reinstall."
        }
    }
}

public enum CleanupAction: Codable, Sendable, Hashable {
    case delete([String])
    case trash([String])
    case adminDeleteContents(String)
    case dockerPrune
    /// A tool's own cleanup command, such as `xcrun simctl delete unavailable`.
    case run([Command])
    /// Make identical copies share their blocks; nothing is deleted.
    case share(IdenticalGroup)
}

public struct Command: Codable, Sendable, Hashable {
    public var executable: String
    public var arguments: [String]

    public init(_ executable: String, _ arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    public var display: String { ([(executable as NSString).lastPathComponent] + arguments).joined(separator: " ") }
}

public struct BlockRule: Codable, Sendable, Hashable {
    public var match: String
    public var reason: String
}

/// Something Headroom can clean, measured during a scan.
public struct Candidate: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var detail: String
    public var group: CandidateGroup
    public var size: SizeInfo
    /// The size comes from a tool's own estimate (Docker), not from measuring files.
    public var isEstimate: Bool
    public var cost: String
    public var quit: [AppRef]
    public var blockRules: [BlockRule]
    /// For project items: the project folder, so a running dev server blocks cleaning.
    public var projectPath: String?
    public var action: CleanupAction
    /// Set during the scan when something outside Headroom prevents cleaning (Docker not running).
    public var fixedBlocker: String?

    public init(id: String, name: String, detail: String, group: CandidateGroup, size: SizeInfo, isEstimate: Bool,
                cost: String, quit: [AppRef], blockRules: [BlockRule], projectPath: String?, action: CleanupAction,
                fixedBlocker: String?) {
        self.id = id
        self.name = name
        self.detail = detail
        self.group = group
        self.size = size
        self.isEstimate = isEstimate
        self.cost = cost
        self.quit = quit
        self.blockRules = blockRules
        self.projectPath = projectPath
        self.action = action
        self.fixedBlocker = fixedBlocker
    }

    public var needsAdmin: Bool {
        if case .adminDeleteContents = action { return true }
        return false
    }

    public var paths: [String] {
        switch action {
        case .delete(let p), .trash(let p): p
        case .adminDeleteContents(let p): [p]
        case .dockerPrune, .run: []
        case .share(let group): group.sets.flatMap(\.copies)
        }
    }

    /// "up to" when clones or estimates make the number uncertain.
    public var sizeLabel: String {
        if isEstimate && size.allocated == 0 { return "size unknown" }
        let text = ByteFormat.string(size.allocated)
        return size.sharesSpace || isEstimate ? "up to " + text : text
    }

    /// Short phrase for when a blocked item becomes cleanable: "once the ilov2front dev server stops".
    public var unblockHint: String {
        if let projectPath { return "once the \((projectPath as NSString).lastPathComponent) dev server stops" }
        if fixedBlocker != nil, case .dockerPrune = action { return "once Docker is running" }
        return "once \(name) is no longer in use"
    }

    /// The number used for totals: unshared bytes when clones are involved.
    public var expectedBytes: Int64 { isEstimate ? size.allocated : size.reclaimable }

    public func status(with processes: ProcessSnapshot) -> CandidateStatus {
        if let fixedBlocker { return CandidateStatus(blocker: fixedBlocker, appsToQuit: []) }
        for rule in blockRules where processes.anyProcess(containing: rule.match) {
            return CandidateStatus(blocker: rule.reason, appsToQuit: [])
        }
        if case .share(let group) = action {
            // A running dev server only holds back the copies in its own project.
            let busy = group.projectPaths.filter { processes.processUsing(folder: $0) != nil }
            if !busy.isEmpty {
                let names = busy.map { ($0 as NSString).lastPathComponent }.joined(separator: " and ")
                if busy.count == group.projectPaths.count {
                    return CandidateStatus(blocker: "The \(names) dev server is running. Stop it to share these.", appsToQuit: [])
                }
                return CandidateStatus(blocker: nil, appsToQuit: [], warning: "Copies in \(names) are skipped while its dev server runs.")
            }
        }
        if let projectPath, processes.processUsing(folder: projectPath) != nil {
            let name = (projectPath as NSString).lastPathComponent
            return CandidateStatus(blocker: "A dev server or build in \(name) is running. Stop it to clean this.", appsToQuit: [])
        }
        return CandidateStatus(blocker: nil, appsToQuit: quit.filter { processes.isRunning($0) })
    }
}

public struct CandidateStatus: Sendable, Hashable {
    public var blocker: String?
    public var appsToQuit: [AppRef]
    /// Something to know that doesn't stop the item, such as copies that will be skipped.
    public var warning: String?

    public init(blocker: String?, appsToQuit: [AppRef], warning: String? = nil) {
        self.blocker = blocker
        self.appsToQuit = appsToQuit
        self.warning = warning
    }

    public var isBlocked: Bool { blocker != nil }

    /// Ticked by default: not blocked, and no app you work in has to quit.
    public var selectedByDefault: Bool {
        blocker == nil && !appsToQuit.contains { $0.disruptive }
    }

    public var note: String? {
        if let blocker { return blocker }
        guard !appsToQuit.isEmpty else { return warning }
        let names = appsToQuit.map(\.name).joined(separator: " and ")
        let verb = appsToQuit.count == 1 ? "is" : "are"
        if appsToQuit.contains(where: \.disruptive) {
            return "\(names) \(verb) open. Tick to quit \(appsToQuit.count == 1 ? "it" : "them") and clean."
        }
        return "\(names) \(verb) open. Headroom will quit \(appsToQuit.count == 1 ? "it" : "them") first."
    }
}
