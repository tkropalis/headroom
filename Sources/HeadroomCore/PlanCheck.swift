import Foundation

/// Something to know about a plan before it runs, in words.
public struct PlanFact: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable {
        /// Two planned items depend on each other.
        case needs
        /// A planned folder holds saved data, such as game worlds.
        case savedData
        /// Apps quit before their data moves.
        case quitsApps
        /// Space that only comes back when the Bin is emptied.
        case bin
        /// Items kept on a drive.
        case kept
    }

    public var id: String { kind.rawValue + text }
    public var kind: Kind
    public var text: String
    public var paths: [String]

    public init(kind: Kind, text: String, paths: [String]) {
        self.kind = kind
        self.text = text
        self.paths = paths
    }

    /// Facts that warn of a loss come before facts that only explain.
    public var isWarning: Bool { kind == .needs || kind == .savedData }
}

/// Facts about a plan, from rules declared here, never guessed. Ollie may put them into
/// friendlier words; without him they show as they are.
public enum PlanCheck {
    /// One planned thing needing another: when both are in the plan, say so.
    public struct Dependency: Sendable {
        public var item: String
        public var needs: String
        public var text: String

        public init(item: String, needs: String, text: String) {
            self.item = item
            self.needs = needs
            self.text = text
        }
    }

    /// A folder that keeps something you can't download again.
    public struct SavedData: Sendable {
        public var path: String
        public var text: String

        public init(path: String, text: String) {
            self.path = path
            self.text = text
        }
    }

    public static let dependencies: [Dependency] = [
        Dependency(item: "~/.android/avd", needs: "~/Library/Android/sdk",
                   text: "Your Android emulators need the Android SDK. With both gone, they can't start until Android Studio downloads the SDK again."),
        Dependency(item: "~/Library/Developer/CoreSimulator/Devices", needs: "/Library/Developer/CoreSimulator/Volumes",
                   text: "Your iOS simulators need their runtimes. With both gone, Xcode downloads the runtimes again before they start."),
    ]

    public static let savedData: [SavedData] = [
        SavedData(path: "~/Library/Application Support/minecraft/saves", text: "Minecraft worlds are saved inside it."),
        SavedData(path: "~/Library/Application Support/Paradox Interactive", text: "Paradox game saves are kept inside it."),
        SavedData(path: "~/Library/Application Support/Steam/userdata", text: "Steam keeps game settings and some saves inside it."),
        SavedData(path: "~/.android/avd", text: "Emulators keep their apps' data and snapshots inside it."),
    ]

    /// - Parameter quits: apps that will be quit for an item, by path.
    public static func facts(for plan: CleanupPlan, quits: (String) -> [AppRef] = { _ in [] }) -> [PlanFact] {
        var out: [PlanFact] = []
        func touches(_ item: PlanItem, _ path: String) -> Bool {
            // The item is the place, inside it, or holds it.
            item.path == path || item.path.hasPrefix(path + "/") || path.hasPrefix(item.path + "/")
        }
        for rule in dependencies {
            let (item, needs) = (Paths.expand(rule.item), Paths.expand(rule.needs))
            let a = plan.items.filter { touches($0, item) && !$0.destination.isKept }
            let b = plan.items.filter { touches($0, needs) && !$0.destination.isKept }
            if !a.isEmpty && !b.isEmpty { out.append(PlanFact(kind: .needs, text: rule.text, paths: (a + b).map(\.path))) }
        }
        for rule in savedData {
            let path = Paths.expand(rule.path)
            // Kept on a drive, the saves are kept too.
            for item in plan.items where (item.path == path || path.hasPrefix(item.path + "/")) && !item.destination.isKept {
                out.append(PlanFact(kind: .savedData, text: "\(item.name): \(rule.text)", paths: [item.path]))
            }
        }
        let quitting = plan.items.flatMap { item in quits(item.path).map { (app: $0, path: item.path) } }
        if !quitting.isEmpty {
            let names = Array(Set(quitting.map(\.app.name))).sorted()
            out.append(PlanFact(kind: .quitsApps, text: "\(list(names)) \(names.count == 1 ? "is" : "are") quit first.",
                                paths: quitting.map(\.path)))
        }
        let binned = plan.items.filter(\.destination.isBin)
        if !binned.isEmpty {
            out.append(PlanFact(kind: .bin, text: "\(ByteFormat.string(plan.binBytes)) comes back when you empty the Bin.",
                                paths: binned.map(\.path)))
        }
        for (drive, items) in Dictionary(grouping: plan.items.filter(\.destination.isKept), by: \.destination.title)
            .sorted(by: { $0.key < $1.key }) {
            out.append(PlanFact(kind: .kept, text: "\(drive) keeps \(list(items.map(\.name))), so you can copy \(items.count == 1 ? "it" : "them") back.",
                                paths: items.map(\.path)))
        }
        return out.sorted { $0.isWarning && !$1.isWarning }
    }

    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        case 2: names[0] + " and " + names[1]
        default: names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }
}

extension PlanDestination {
    /// Kept somewhere, so nothing is lost.
    public var isKept: Bool {
        switch self {
        case .drive, .shared: true
        case .bin: false
        }
    }
}

/// Runs a reviewed plan, one item at a time, each through Headroom's existing path for its
/// destination: `Cleaner` for the Bin (with Put Back), `Offloader` for drives, identical-file
/// sharing for shared space. The steps are swappable so tests can check what is called.
public struct PlanRunner: Sendable {
    public var toBin: @Sendable (PlanItem, Candidate) async -> CleanupOutcome
    public var toDrive: @Sendable (PlanItem, OffloadDestination, [AppRef]) async -> CleanupOutcome
    public var share: @Sendable (Candidate) async -> CleanupOutcome
    /// The same check the offload sheet uses; nil when the item may go to a drive.
    public var canOffload: @Sendable (String) -> String?

    public init(toBin: @escaping @Sendable (PlanItem, Candidate) async -> CleanupOutcome = { _, candidate in await Cleaner().clean(candidate) },
                toDrive: @escaping @Sendable (PlanItem, OffloadDestination, [AppRef]) async -> CleanupOutcome = PlanRunner.offload,
                share: @escaping @Sendable (Candidate) async -> CleanupOutcome = { await Cleaner().clean($0) },
                canOffload: @escaping @Sendable (String) -> String? = { Offloader.canOffload($0) }) {
        self.toBin = toBin
        self.toDrive = toDrive
        self.share = share
        self.canOffload = canOffload
    }

    /// - Parameters:
    ///   - candidate: the scan's item for a path, if any, for its quit list and block rules.
    ///   - quits: apps to quit before moving an item that no scan item covers.
    public func run(_ plan: CleanupPlan, drives: [OffloadDestination],
                    candidate: @Sendable (String) -> Candidate? = { _ in nil },
                    quits: @Sendable (String) -> [AppRef] = { _ in [] },
                    onStart: (@Sendable (PlanItem) -> Void)? = nil,
                    onFinish: (@Sendable (PlanItem, CleanupOutcome) -> Void)? = nil) async -> [CleanupOutcome] {
        var outcomes: [CleanupOutcome] = []
        for item in plan.items {
            onStart?(item)
            let outcome = await run(item, drives: drives, known: candidate(item.path), quits: quits(item.path))
            outcomes.append(outcome)
            onFinish?(item, outcome)
        }
        return outcomes
    }

    func run(_ item: PlanItem, drives: [OffloadDestination], known: Candidate?, quits: [AppRef]) async -> CleanupOutcome {
        func skipped(_ message: String) -> CleanupOutcome {
            CleanupOutcome(id: item.path, name: item.name, state: .skipped, freed: 0, message: message, expected: item.bytes)
        }
        guard FileManager.default.fileExists(atPath: item.path) || item.destination == .shared else {
            return skipped("It's no longer there.")
        }
        let apps = known?.quit ?? quits
        switch item.destination {
        case .bin:
            guard PathSafety.isDeletable(item.path) else { return skipped("Headroom never moves this folder.") }
            let candidate = Candidate(id: item.path, name: item.name, detail: Paths.display(item.path), group: .yourCall,
                                      size: SizeInfo(allocated: item.bytes, unshared: item.bytes), isEstimate: false, cost: "",
                                      quit: apps, blockRules: known?.blockRules ?? [], projectPath: known?.projectPath,
                                      action: .trash([item.path]), fixedBlocker: nil)
            return await toBin(item, candidate)
        case .drive(let id, let name):
            guard let drive = drives.first(where: { $0.id == id }) else { return skipped("\(name) isn't connected.") }
            if let reason = canOffload(item.path) { return skipped(reason) }
            return await toDrive(item, drive, apps)
        case .shared:
            guard let known, case .share = known.action else { return skipped("There are no identical copies to share any more.") }
            return await share(known)
        }
    }

    /// Copies to the drive, checks the copy, removes the original, and measures what that freed.
    public static let offload: @Sendable (PlanItem, OffloadDestination, [AppRef]) async -> CleanupOutcome = { item, drive, apps in
        let before = DiskStatus.current()?.available ?? 0
        do {
            _ = try await Offloader.offload(OffloadItem(path: item.path, name: item.name, bytes: item.bytes, quit: apps), to: drive,
                                            progress: { _ in }, shouldStop: { false })
            try? await Task.sleep(for: .milliseconds(400))
            let freed = max(0, (DiskStatus.current()?.available ?? before) - before)
            return CleanupOutcome(id: item.path, name: item.name, state: .done, freed: freed,
                                  message: "Kept on \(drive.name).", expected: item.bytes)
        } catch {
            return CleanupOutcome(id: item.path, name: item.name, state: .failed, freed: 0,
                                  message: error.localizedDescription, expected: item.bytes)
        }
    }
}
