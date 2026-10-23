import Foundation

/// Where a planned item goes when the plan runs.
public enum PlanDestination: Codable, Hashable, Sendable {
    /// The Bin, where Put Back works until it is emptied.
    case bin
    /// A connected drive, by its offload destination's id and name. The item is kept there.
    case drive(id: String, name: String)
    /// Identical copies made to share their disk space; nothing is deleted.
    case shared

    public var title: String {
        switch self {
        case .bin: "Bin"
        case .drive(_, let name): name
        case .shared: "Shared space"
        }
    }

    /// What happens to it, in a few words.
    public var note: String {
        switch self {
        case .bin: "Gone once the Bin is emptied."
        case .drive: "Kept. Copy it back any time."
        case .shared: "Every copy stays and opens as before."
        }
    }

    public var isBin: Bool { self == .bin }
}

/// One thing in the plan.
public struct PlanItem: Codable, Hashable, Sendable, Identifiable {
    public enum Source: String, Codable, Sendable { case you, target }

    public var id: String { path }
    public var path: String
    public var name: String
    public var bytes: Int64
    public var cost: SpaceCost
    public var destination: PlanDestination
    /// Why a target picked it; nil for things you added.
    public var reason: String?
    public var addedBy: Source
    public var addedAt: Date

    public init(path: String, name: String, bytes: Int64, cost: SpaceCost, destination: PlanDestination,
                reason: String? = nil, addedBy: Source = .you, addedAt: Date = Date()) {
        self.path = path
        self.name = name
        self.bytes = bytes
        self.cost = cost
        self.destination = destination
        self.reason = reason
        self.addedBy = addedBy
        self.addedAt = addedAt
    }
}

/// What you mean to free, built on the Space Map. Nothing happens until it is reviewed and run.
public struct CleanupPlan: Codable, Sendable, Hashable {
    public var items: [PlanItem]

    public init(items: [PlanItem] = []) {
        self.items = items
    }

    public var isEmpty: Bool { items.isEmpty }
    public var total: Int64 { items.reduce(0) { $0 + $1.bytes } }
    /// What comes back only once the Bin is emptied.
    public var binBytes: Int64 { items.filter(\.destination.isBin).reduce(0) { $0 + $1.bytes } }

    public func contains(_ path: String) -> Bool { items.contains { $0.path == path } }
    public func item(_ path: String) -> PlanItem? { items.first { $0.path == path } }

    /// Adds an item, unless it or a folder holding it is already in. Adding a folder takes
    /// out the things inside it that were added before, so nothing is counted twice.
    @discardableResult
    public mutating func add(_ item: PlanItem) -> Bool {
        if items.contains(where: { $0.path == item.path || item.path.hasPrefix($0.path + "/") }) { return false }
        items.removeAll { $0.path.hasPrefix(item.path + "/") }
        items.append(item)
        return true
    }

    public mutating func remove(_ path: String) {
        items.removeAll { $0.path == path }
    }

    public mutating func setDestination(_ destination: PlanDestination, for path: String) {
        guard let index = items.firstIndex(where: { $0.path == path }) else { return }
        items[index].destination = destination
    }
}

extension Store {
    public static func plan() -> CleanupPlan { load("plan.json", as: CleanupPlan.self) ?? CleanupPlan() }
    public static func savePlan(_ plan: CleanupPlan) { save(plan, as: "plan.json") }
}

/// What may go in a plan and where it may go. Moving anything is still checked again by
/// `PathSafety` and `Offloader.canOffload` when the plan runs.
public enum PlanRules {
    /// Why this can't be planned, or nil when it can.
    public static func refusal(_ path: String, inUse: String?) -> String? {
        if path.hasPrefix("headroom:") { return "Open it to plan what is inside." }
        guard PathSafety.isDeletable(path) else { return "Headroom never moves this folder." }
        if let inUse { return inUse + " It can go in a plan once it isn't in use." }
        return nil
    }

    /// The places this can go. Folders outside the cleanup catalogue only ever get the Bin or a drive.
    public static func destinations(for path: String, candidate: Candidate?, drives: [OffloadDestination],
                                    canOffload: (String) -> String? = Offloader.canOffload) -> [PlanDestination] {
        var out: [PlanDestination] = []
        if let candidate, case .share = candidate.action { out.append(.shared) }
        if canOffload(path) == nil {
            out += drives.filter { !$0.isArchive }.map { .drive(id: $0.id, name: $0.name) }
        }
        out.append(.bin)
        return out
    }

    /// Where it goes unless you choose otherwise: what loses nothing goes to the Bin; what
    /// loses something is kept on a drive when one is connected, else the Bin.
    public static func defaultDestination(cost: SpaceCost, among choices: [PlanDestination]) -> PlanDestination {
        if choices.contains(.shared) { return .shared }
        switch cost {
        case .nothingLost, .slowerNext: return .bin
        case .yourCall, .yourFiles, .unknown, .system:
            return choices.first { if case .drive = $0 { true } else { false } } ?? .bin
        }
    }
}
