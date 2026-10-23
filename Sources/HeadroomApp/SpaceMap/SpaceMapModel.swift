import AppKit
import HeadroomCore
import Observation
import SwiftUI

/// Where the Space Map is: the whole disk by place or by kind, a place or kind gathered from
/// the snapshot, a real folder, or the offloaded list.
enum SpaceLocation: Hashable {
    case disk
    case kinds
    /// A place with no single folder (macOS, Temporary, Other), gathered from the snapshot.
    case place(SpacePlace)
    case kind(String)
    case folder(String)
    case offloaded
    /// Everything in the plan, wherever it is.
    case plan
}

enum SpaceLens: Hashable { case folders, kinds }

enum SpaceSidebarItem: Hashable {
    case place(SpacePlace)
    case kind(String)
    case offloaded
    case plan
}

enum SpaceFilter: CaseIterable, Hashable {
    case all, canGo, unused

    var title: String {
        switch self {
        case .all: "All"
        case .canGo: "Can go"
        case .unused: "Not used for 6 months"
        }
    }
}

/// What removing a row costs: one cost, or several for a folder holding different things.
enum CanGo: Hashable {
    case cost(SpaceCost)
    case mixed(CostBreakdown)
}

/// How the map moves when the location changes: into the tile that was opened, back out, or not at all.
enum SpaceZoom: Equatable {
    case none
    /// Opened from a tile; its rectangle on the map, in points.
    case into(CGRect)
    case out
}

/// One step of the path bar; `location` is nil for the step you are on.
struct Crumb: Hashable {
    var title: String
    var location: SpaceLocation?
}

/// State for the Space Map window: where you are, what is listed and what is selected.
@MainActor @Observable
final class SpaceMapModel {
    var snapshot: FolderSnapshot? = Store.snapshots().last?.existing()
    var disk: DiskStatus? = DiskStatus.current()
    var overview: SpaceOverview?
    var drives: [OffloadDestination] = []

    private(set) var location: SpaceLocation = .disk
    private(set) var lens: SpaceLens = .folders
    private var backStack: [SpaceLocation] = []
    private var forwardStack: [SpaceLocation] = []

    var nodes: [SpaceNode] = []
    var measuring = false
    var selection: Set<String> = []
    var search = ""
    var filter: SpaceFilter = .all
    /// Rows still being measured; they show "Measuring…" until their size arrives.
    var pending: Set<String> = []
    /// When the listed sizes were measured: the snapshot's date, or when this folder was measured.
    var measuredAt: Date?
    /// Costs of the measured folders inside each row, for rows the snapshot reaches into.
    var breakdowns: [String: CostBreakdown] = [:]
    /// What is inside each tile, one level down, for the impression behind its glass.
    var contents: [String: [SpaceNode]] = [:]
    /// The folder taking over a third of the map, drawn as a group with its contents inside.
    var groupPath: String?
    /// Why a row can't be touched right now: an open app or a running dev server.
    var inUse: [String: String] = [:]
    /// How much each row grew since `since`, from the daily snapshots.
    var growth: [String: Int64] = [:]
    var since: SpaceSince = .week { didSet { if since != oldValue { computeGrowth() } } }
    /// The Since choices the kept snapshots can answer.
    var sinceChoices: [SpaceSince] = []
    var zoom: SpaceZoom = .none
    /// The item shown in Quick Look, toggled with Space.
    var quickLook: URL?
    /// Free space over the Since period, for the status line.
    var freeHistory: [FreeSample] = []
    /// What you mean to free. Saved, so it survives closing the window; nothing runs until reviewed.
    var plan: CleanupPlan = Store.plan() {
        didSet { if plan != oldValue { if savesPlan { Store.savePlan(plan) }; checkPlan() } }
    }
    /// Off in previews, so a sample plan never replaces the real one.
    @ObservationIgnored var savesPlan = true
    /// What the plan checks found: what you'd lose, apps that quit, the Bin.
    var planFacts: [PlanFact] = []
    var reviewingPlan = false

    // Hooks the app sets.
    @ObservationIgnored var candidateFor: (String) -> Candidate? = { _ in nil }
    @ObservationIgnored var blockerFor: (String) -> String? = { _ in nil }
    @ObservationIgnored var offloadBlocker: (String) -> String? = { _ in nil }
    @ObservationIgnored var onClean: (Candidate) -> Void = { _ in }
    @ObservationIgnored var onOffload: (SpaceNode) -> Void = { _ in }
    @ObservationIgnored var onTrash: (SpaceNode) -> Void = { _ in }
    @ObservationIgnored var offloadedView: () -> AnyView = {
        AnyView(ContentUnavailableView("Nothing offloaded", systemImage: "externaldrive",
                                       description: Text("Things you offload to a drive or an archive appear here.")))
    }
    @ObservationIgnored var claude = ClaudeHooks()
    @ObservationIgnored var hasFullDiskAccess: () -> Bool = { true }
    @ObservationIgnored var openFullDiskAccess: () -> Void = {}
    /// The free space below which the menu warns, for the plan's meter.
    @ObservationIgnored var warningBytes: () -> Int64 = { 20_000_000_000 }
    /// Runs a reviewed plan through the app, which records history and refreshes free space.
    @ObservationIgnored var runPlan: (CleanupPlan, _ finished: @escaping @MainActor (PlanItem, CleanupOutcome) -> Void) async -> [CleanupOutcome] = { _, _ in [] }
    @ObservationIgnored var canPutBack: (CleanupOutcome) -> Bool = { _ in false }
    @ObservationIgnored var putBack: (CleanupOutcome) -> Void = { _ in }
    @ObservationIgnored var isExcluded: (String) -> Bool = { _ in false }
    @ObservationIgnored var setExcluded: (String, Bool) -> Void = { _, _ in }

    @ObservationIgnored private let data = SpaceDataSource()
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var contentsTask: Task<Void, Never>?
    @ObservationIgnored private var history: [FolderSnapshot] = Store.snapshots()
    /// Built-in and learned cleanup rules, read once per folder rather than once per row.
    @ObservationIgnored private var catalog = Catalog.all

    static let unmeasuredPath = "headroom:unmeasured"
    static let volumesPath = "headroom:volumes"
    static let placePrefix = "headroom:place:"
    static let kindPrefix = "headroom:kind:"

    init() {
        refreshDisk()
        reload()
        checkPlan()
    }

    // MARK: Derived

    /// Rule categories with what they measure; "System and other" is left to the Kinds list.
    var categories: [SpaceCategory] {
        guard let snapshot, let disk else { return [] }
        return SpaceTree.categories(snapshot: snapshot, disk: disk).filter { $0.name != SpaceTree.otherCategory }
    }

    var currentPath: String? {
        if case .folder(let path) = location { return path }
        return nil
    }

    var visibleNodes: [SpaceNode] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return nodes.filter { node in
            if !query.isEmpty && !node.name.localizedCaseInsensitiveContains(query) { return false }
            switch filter {
            case .all: return true
            case .canGo: return canGoBytes(node) > 0
            case .unused: return RelativeDate.isUnused(node.lastOpened)
            }
        }
    }

    /// The listed rows and the rows inside the group, which can be selected on the map.
    var selectableNodes: [SpaceNode] {
        guard let groupPath, let inside = contents[groupPath] else { return nodes }
        return nodes + inside
    }

    var selectedNodes: [SpaceNode] { selectableNodes.filter { selection.contains($0.path) } }

    var selectedNode: SpaceNode? {
        guard selection.count == 1 else { return nil }
        return selectableNodes.first { selection.contains($0.path) }
    }

    /// The tile that takes over a third of the map: a real folder with measured contents.
    var dominantNode: SpaceNode? {
        guard let groupPath, let node = visibleNodes.first(where: { $0.path == groupPath }) else { return nil }
        return node
    }

    var sidebarSelection: SpaceSidebarItem? {
        switch location {
        case .disk, .kinds: nil
        case .place(let place): .place(place)
        case .kind(let name): .kind(name)
        case .folder(let path): .place(SpacePlace.of(path))
        case .offloaded: .offloaded
        case .plan: .plan
        }
    }

    var title: String { crumbs.last?.title ?? "Macintosh HD" }

    /// The path bar. Folders follow their real path; folders in a gathered place start there.
    var crumbs: [Crumb] {
        let disk = Crumb(title: "Macintosh HD", location: .disk)
        var out: [Crumb]
        switch location {
        case .disk: out = [disk]
        case .kinds: out = [disk, Crumb(title: "Kinds", location: .kinds)]
        case .kind(let name):
            out = [disk, Crumb(title: "Kinds", location: .kinds), Crumb(title: Self.kindTitle(name), location: .kind(name))]
        case .place(let place): out = [disk, Crumb(title: place.title, location: .place(place))]
        case .offloaded: out = [Crumb(title: "Offloaded", location: .offloaded)]
        case .plan: out = [Crumb(title: "Plan", location: .plan)]
        case .folder(let path): out = [disk] + folderCrumbs(path)
        }
        if !out.isEmpty { out[out.count - 1].location = nil }
        return out
    }

    private func folderCrumbs(_ path: String) -> [Crumb] {
        func steps(from base: String, _ path: String) -> [Crumb] {
            var current = base
            return path.dropFirst(base.count).split(separator: "/").map { part in
                current += "/" + part
                return Crumb(title: String(part), location: .folder(current))
            }
        }
        let place = SpacePlace.of(path)
        if place.path != nil || path.hasPrefix("/Users/") || path == "/Users" {
            return steps(from: "", path)
        }
        // Inside a gathered place: start from the place and the snapshot folder that holds this.
        if let root = snapshot?.sizes.keys.filter({ path == $0 || path.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }) {
            return [Crumb(title: place.title, location: .place(place)),
                    Crumb(title: SpaceTree.displayName(root), location: .folder(root))] + steps(from: root, path)
        }
        return steps(from: "", path)
    }

    static func kindTitle(_ name: String) -> String { name == SpaceTree.otherCategory ? "Other" : name }

    /// What removing this row costs.
    func canGo(_ node: SpaceNode) -> CanGo {
        if let breakdown = breakdowns[node.path] {
            if breakdown.isMixed { return .mixed(breakdown) }
            if let top = breakdown.parts.first?.cost { return .cost(top) }
        }
        return .cost(cost(of: node))
    }

    /// What removing this row costs, from the scan, the rules, Ollie's answer and its kind.
    func cost(of node: SpaceNode) -> SpaceCost {
        switch node.path {
        // Not measured mixes macOS, purgeable space and folders Headroom couldn't read.
        case Self.unmeasuredPath: return .unknown
        case Self.volumesPath: return .system
        default: break
        }
        if node.path.hasPrefix("headroom:") { return .unknown }
        let candidate = candidateFor(node.path).flatMap { $0.paths.contains(node.path) ? $0 : nil }
        return SpaceCost.of(node.path, kind: node.kind, candidate: candidate,
                            explanation: claude.answer(node.path), catalog: catalog)
    }

    /// The part of a row that can go without losing anything.
    func canGoBytes(_ node: SpaceNode) -> Int64 {
        switch canGo(node) {
        case .cost(let cost): [.nothingLost, .slowerNext].contains(cost) ? node.allocated : 0
        case .mixed(let breakdown): breakdown.canGo >= 100_000_000 ? breakdown.canGo : 0
        }
    }

    /// The listed rows by cost, for the folder summary.
    var listedBreakdown: CostBreakdown {
        var bytes: [SpaceCost: Int64] = [:]
        for node in nodes where !pending.contains(node.path) && node.path != Self.unmeasuredPath {
            switch canGo(node) {
            case .cost(let cost): bytes[cost, default: 0] += node.allocated
            case .mixed(let breakdown): for part in breakdown.parts { bytes[part.cost, default: 0] += part.bytes }
            }
        }
        return CostBreakdown(bytes: bytes, count: nodes.count)
    }

    /// The Not measured row's size, when it is listed.
    var listedUnmeasured: Int64 { nodes.first { $0.path == Self.unmeasuredPath }?.allocated ?? 0 }

    /// The folder being listed can be measured again from the disk.
    var canMeasureAgain: Bool { currentPath != nil && !measuring }

    // MARK: Navigation

    func go(_ destination: SpaceLocation) {
        guard destination != location else { return }
        if case .into = zoom {} else { zoom = .none }
        backStack.append(location)
        forwardStack = []
        move(to: destination)
    }

    private func move(to destination: SpaceLocation) {
        location = destination
        switch destination {
        case .disk, .place: lens = .folders
        case .kinds, .kind: lens = .kinds
        case .folder, .offloaded, .plan: break
        }
        reload()
    }

    /// Opens a tile, growing it from where it is on the map.
    func open(_ node: SpaceNode, from rect: CGRect?) {
        zoom = rect.map(SpaceZoom.into) ?? .none
        open(node)
    }

    func open(_ node: SpaceNode) {
        if node.path.hasPrefix(Self.placePrefix), let place = SpacePlace(rawValue: String(node.path.dropFirst(Self.placePrefix.count))) {
            go(.place(place))
        } else if node.path.hasPrefix(Self.kindPrefix) {
            go(.kind(String(node.path.dropFirst(Self.kindPrefix.count))))
        } else if node.isDirectory, !node.path.hasPrefix("headroom:") {
            go(.folder(node.path))
        }
    }

    func select(_ item: SpaceSidebarItem) {
        switch item {
        case .place(let place): go(place.path.map(SpaceLocation.folder) ?? .place(place))
        case .kind(let name): go(.kind(name))
        case .offloaded: go(.offloaded)
        case .plan: go(.plan)
        }
    }

    func setLens(_ lens: SpaceLens) {
        guard lens != self.lens else { return }
        go(lens == .folders ? .disk : .kinds)
    }

    func back() {
        guard let previous = backStack.popLast() else { return }
        zoom = .out
        forwardStack.append(location)
        move(to: previous)
    }

    func forward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(location)
        move(to: next)
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// Opens a category, as the menu's capacity bar does.
    func show(kind name: String) {
        go(.kind(name))
    }

    /// Opens the whole disk, by place.
    func showDisk() {
        go(.disk)
    }

    // MARK: Loading

    func reload() {
        loadTask?.cancel()
        selection = []
        search = ""
        catalog = Catalog.all
        pending = []
        measuring = false
        measuredAt = snapshot?.date
        guard let snapshot else { nodes = []; return }

        switch location {
        case .disk: nodes = diskRows()
        case .kinds: nodes = kindRows()
        case .place(let place):
            var rows = SpaceTree.rows(in: place, snapshot: snapshot)
            if place == .macOS, let volumes = overview?.systemVolumes, volumes > 0 {
                rows.append(SpaceNode(path: Self.volumesPath, name: "macOS system volumes", allocated: volumes,
                                      unshared: volumes, isDirectory: false))
                rows.sort { $0.allocated > $1.allocated }
            }
            nodes = rows
        case .kind(let name): nodes = SpaceTree.topLevel(snapshot: snapshot, category: name)
        case .offloaded: nodes = []
        case .plan: nodes = planRows()
        case .folder(let path): loadFolder(path, snapshot: snapshot)
        }
        loadBreakdowns()
        afterRowsChange()
    }

    /// Everything that follows from the listed rows: the group, what is in use, growth, contents.
    private func afterRowsChange() {
        computeInUse()
        computeGrowth()
        chooseGroup()
    }

    private func diskRows() -> [SpaceNode] {
        guard let overview else { return [] }
        var rows = overview.places.map { item in
            SpaceNode(path: item.place.path ?? Self.placePrefix + item.place.rawValue, name: item.place.title,
                      allocated: item.bytes, unshared: item.bytes, isDirectory: true)
        }
        if overview.unmeasured > 0 { rows.append(unmeasuredRow(overview.unmeasured)) }
        return rows.sorted { $0.allocated > $1.allocated }
    }

    private func kindRows() -> [SpaceNode] {
        guard let overview else { return [] }
        var rows = categories.map { category in
            SpaceNode(path: Self.kindPrefix + category.name, name: category.name, allocated: category.bytes,
                      unshared: category.bytes, isDirectory: true)
        }
        let other = overview.measured - categories.reduce(0) { $0 + $1.bytes }
        if other > 0 {
            rows.append(SpaceNode(path: Self.kindPrefix + SpaceTree.otherCategory, name: "Other", allocated: other,
                                  unshared: other, isDirectory: true))
        }
        if overview.unmeasured > 0 { rows.append(unmeasuredRow(overview.unmeasured)) }
        return rows.sorted { $0.allocated > $1.allocated }
    }

    private func unmeasuredRow(_ bytes: Int64) -> SpaceNode {
        SpaceNode(path: Self.unmeasuredPath, name: "Not measured", allocated: bytes, unshared: bytes, isDirectory: false)
    }

    private func loadFolder(_ path: String, snapshot: FolderSnapshot) {
        if let rows = data.rows(in: path) {
            nodes = rows
            measuredAt = data.measuredAt(path)
            return
        }
        if SpaceTree.isCovered(path) {
            // The snapshot measured everything here; only entries made since are measured now.
            let (rows, missing) = SpaceTree.snapshotChildren(of: path, snapshot: snapshot)
            nodes = rows
            pending = Set(missing)
            guard !missing.isEmpty else { return }
            measuring = true
            loadTask = Task { [weak self, data] in
                let sizes = await data.sizes(missing)
                guard let self, !Task.isCancelled, self.currentPath == path else { return }
                self.apply(sizes)
                self.measuring = false
                self.chooseGroup()
            }
            return
        }
        // Show the names at once; sizes fill in when measuring finishes.
        nodes = data.listing(path, snapshot: snapshot)
        pending = Set(nodes.map(\.path))
        measureAll(path)
    }

    /// Measures every entry of the open folder from the disk.
    func measureAgain() {
        guard let path = currentPath else { return }
        pending = Set(nodes.map(\.path))
        measureAll(path)
    }

    private func measureAll(_ path: String) {
        measuring = true
        loadTask = Task { [weak self, data] in
            // Sizes saved from an earlier visit show while everything is measured again.
            if let waiting = self?.pending, !waiting.isEmpty {
                let saved = await data.savedSizes(Array(waiting))
                guard let self, !Task.isCancelled, self.currentPath == path else { return }
                self.apply(saved)
            }
            let measured = await data.measure(path)
            guard let self, !Task.isCancelled, self.currentPath == path else { return }
            self.nodes = measured
            self.pending = []
            self.measuring = false
            self.measuredAt = data.measuredAt(path)
            self.loadBreakdowns()
            self.afterRowsChange()
        }
    }

    private func apply(_ sizes: [String: SizeInfo]) {
        guard !sizes.isEmpty else { return }
        nodes = nodes.map { node in
            guard let size = sizes[node.path] else { return node }
            var node = node
            node.allocated = size.allocated
            node.unshared = size.unshared
            node.sharesSpace = size.sharesSpace
            return node
        }
        .sorted { $0.allocated > $1.allocated }
        pending.subtract(sizes.keys)
    }

    /// Works out the costs inside rows the snapshot reaches into, away from the main thread.
    private func loadBreakdowns() {
        guard let snapshot else { return }
        let wanted = nodes.map(\.path).filter { breakdowns[$0] == nil && $0 != Self.unmeasuredPath && $0 != Self.volumesPath }
        guard !wanted.isEmpty else { return }
        let catalog = self.catalog
        let (placePrefix, kindPrefix) = (Self.placePrefix, Self.kindPrefix)
        // The macOS volumes are measured but in no folder; they count with macOS and with Other.
        let volumes = overview?.systemVolumes ?? 0
        Task { [weak self] in
            let found = await Task.detached(priority: .utility) { () -> [String: CostBreakdown] in
                var out: [String: CostBreakdown] = [:]
                for path in wanted {
                    if path.hasPrefix(placePrefix), let place = SpacePlace(rawValue: String(path.dropFirst(placePrefix.count))) {
                        var breakdown = SpaceTree.breakdown(of: place, snapshot: snapshot, catalog: catalog)
                        if place == .macOS && volumes > 0 { breakdown.bytes[.system, default: 0] += volumes }
                        out[path] = breakdown
                    } else if path.hasPrefix(kindPrefix) {
                        let name = String(path.dropFirst(kindPrefix.count))
                        var breakdown = SpaceTree.breakdown(ofCategory: name, snapshot: snapshot, catalog: catalog)
                        if name == SpaceTree.otherCategory && volumes > 0 { breakdown.bytes[.system, default: 0] += volumes }
                        out[path] = breakdown
                    } else if let breakdown = SpaceTree.breakdown(under: path, snapshot: snapshot, catalog: catalog) {
                        out[path] = breakdown
                    }
                }
                return out
            }.value
            self?.breakdowns.merge(found) { _, new in new }
        }
    }

    /// Opens the folder holding `path` and selects it once its contents are measured.
    func reveal(_ path: String) {
        go(.folder((path as NSString).deletingLastPathComponent))
        Task {
            while measuring { try? await Task.sleep(for: .milliseconds(200)) }
            selection = [path]
        }
    }

    /// Forgets measurements, for example after something was cleaned or offloaded.
    func refresh() {
        data.forget()
        history = Store.snapshots()
        snapshot = history.last?.existing()
        breakdowns = [:]
        contents = [:]
        refreshDisk()
        reload()
    }

    private func refreshDisk() {
        disk = DiskStatus.current()
        if let snapshot, let disk {
            overview = SpaceOverview(snapshot: snapshot, disk: disk, systemVolumes: DiskStatus.otherVolumesBytes())
        }
        drives = Offloader.destinations().filter { if case .drive = $0.kind { true } else { false } }
    }

    /// Takes a row away at once, after it was moved to the Bin or offloaded.
    func removeNode(_ path: String) {
        nodes.removeAll { $0.path == path }
        data.remove(path)
        selection.remove(path)
        contents[path] = nil
    }

    // MARK: Plan

    private func planRows() -> [SpaceNode] {
        plan.items.map { item in
            let isDirectory = SpaceTree.isDirectoryPath(item.path)
            return SpaceNode(path: item.path, name: item.name, allocated: item.bytes, unshared: item.bytes,
                             isDirectory: isDirectory, lastOpened: SpaceTree.lastOpened(item.path),
                             kind: SpaceTree.kind(of: item.path, isDirectory: isDirectory))
        }
        .sorted { $0.allocated > $1.allocated }
    }

    /// Why this row can't go in the plan, or nil when it can.
    func planRefusal(_ node: SpaceNode) -> String? {
        if node.path == Self.unmeasuredPath || node.path == Self.volumesPath { return "No app can clean this." }
        return PlanRules.refusal(node.path, inUse: inUse[node.path])
    }

    func planDestinations(for path: String) -> [PlanDestination] {
        PlanRules.destinations(for: path, candidate: candidateFor(path).flatMap { $0.paths.contains(path) ? $0 : nil },
                               drives: drives, canOffload: offloadBlocker)
    }

    /// Adds rows to the plan, each going where its cost sends it. Rows that can't go are left out.
    @discardableResult
    func addToPlan(_ rows: [SpaceNode]) -> Int {
        var added = 0
        var next = plan
        for node in rows where planRefusal(node) == nil {
            let cost: SpaceCost = if case .cost(let cost) = canGo(node) { cost } else { .unknown }
            let destination = PlanRules.defaultDestination(cost: cost, among: planDestinations(for: node.path))
            if next.add(PlanItem(path: node.path, name: node.name, bytes: node.reclaimable, cost: cost, destination: destination)) {
                added += 1
            }
        }
        plan = next
        if added > 0 {
            // A light tap as the chip lands in the tray.
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        return added
    }

    func removeFromPlan(_ path: String) {
        plan.remove(path)
        if location == .plan { nodes.removeAll { $0.path == path } }
    }

    /// A on the keyboard: adds the selection, or takes it out when it is all in already.
    func togglePlanForSelection() {
        let rows = selectedNodes
        guard !rows.isEmpty else { return }
        if rows.allSatisfy({ plan.contains($0.path) }) {
            rows.forEach { removeFromPlan($0.path) }
        } else {
            addToPlan(rows.filter { !plan.contains($0.path) })
        }
    }

    /// Apps that will be quit before an item moves: its scan item's list, else the app that owns it.
    func quits(for path: String) -> [AppRef] {
        if let candidate = candidateFor(path), candidate.paths.contains(path) { return candidate.quit }
        guard let app = AppOwner.app(for: path, hint: claude.answer(path)?.ownerBundleID),
              let id = Bundle(url: app)?.bundleIdentifier else { return [] }
        return [AppRef(app.deletingPathExtension().lastPathComponent, id)]
    }

    private func checkPlan() {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        var quitting: [String: [AppRef]] = [:]
        for item in plan.items { quitting[item.path] = quits(for: item.path).filter { running.contains($0.bundleID) } }
        planFacts = PlanCheck.facts(for: plan) { quitting[$0] ?? [] }
    }

    /// Free space once the plan has run and the Bin is emptied.
    var freeAfterPlan: Int64 { (disk?.available ?? 0) + plan.total }

    // MARK: Map

    func toggleQuickLook() {
        if quickLook != nil { quickLook = nil; return }
        guard let node = selectedNode ?? selectedNodes.first, !node.path.hasPrefix("headroom:") else { return }
        quickLook = URL(fileURLWithPath: node.path)
    }

    /// The largest folder becomes a group when it takes over a third of what is listed.
    private func chooseGroup() {
        let rows = visibleNodes.filter { !pending.contains($0.path) }
        let total = rows.reduce(Int64(0)) { $0 + $1.allocated }
        guard let first = rows.first, total > 0, Double(first.allocated) / Double(total) > 1.0 / 3,
              first.isDirectory, !first.path.hasPrefix("headroom:") else { groupPath = nil; return }
        groupPath = first.path
        requestContents([first.path])
    }

    /// Measures what is inside tiles big enough to show it, one tile at a time, so the
    /// impressions behind the glass never compete with the folder being listed.
    func requestContents(_ paths: [String]) {
        let wanted = paths.filter { contents[$0] == nil && !$0.hasPrefix("headroom:") }
        guard !wanted.isEmpty else { return }
        let previous = contentsTask
        let snapshot = self.snapshot
        contentsTask = Task { [weak self, data] in
            await previous?.value
            for path in wanted {
                guard !Task.isCancelled else { return }
                if self?.contents[path] != nil { continue }
                let found = await data.contents(of: path, snapshot: snapshot)
                guard let self, !Task.isCancelled else { return }
                self.contents[path] = found
                if path == self.groupPath { self.computeInUse() }
            }
        }
    }

    /// Open apps and running dev servers, for the tiles' pause badges. Folders Headroom never
    /// moves are left out: a process somewhere inside your Library doesn't make it "in use".
    private func computeInUse() {
        let running = NSWorkspace.shared.runningApplications
        let openApps = Set(running.compactMap { $0.bundleURL?.path })
        let openIDs = Set(running.compactMap(\.bundleIdentifier))
        var out: [String: String] = [:]
        for node in selectableNodes where !node.path.hasPrefix("headroom:") && PathSafety.isDeletable(node.path) {
            if node.path.hasSuffix(".app") {
                if openApps.contains(node.path) { out[node.path] = "\((node.name as NSString).deletingPathExtension) is open." }
            } else if let blocker = blockerFor(node.path) {
                out[node.path] = blocker
            } else if let app = AppOwner.app(for: node.path, hint: nil), let id = Bundle(url: app)?.bundleIdentifier,
                      openIDs.contains(id) {
                out[node.path] = "\(app.deletingPathExtension().lastPathComponent) is open."
            }
        }
        inUse = out
    }

    /// Growth since `since`, from the daily snapshots. Rows the snapshots don't reach get none.
    private func computeGrowth() {
        guard let current = snapshot else { growth = [:]; sinceChoices = []; return }
        sinceChoices = SpaceSince.allCases.filter { $0.previous(in: history, current: current) != nil }
        if !sinceChoices.isEmpty && !sinceChoices.contains(since) { since = sinceChoices.last ?? .day }
        let start = current.date.addingTimeInterval(-Double(since.rawValue) * 86400)
        freeHistory = Store.freeSamples().filter { $0.date >= start }
        guard let previous = since.previous(in: history, current: current) else { growth = [:]; return }

        func total(_ node: SpaceNode, in snapshot: FolderSnapshot) -> Int64 {
            if node.path.hasPrefix(Self.placePrefix), let place = SpacePlace(rawValue: String(node.path.dropFirst(Self.placePrefix.count))) {
                return SpaceTree.total(in: snapshot) { SpacePlace.of($0) == place }
            }
            if node.path.hasPrefix(Self.kindPrefix) {
                let name = String(node.path.dropFirst(Self.kindPrefix.count))
                return SpaceTree.total(in: snapshot) { path in
                    let own = SpaceTree.category(of: path)
                    return name == SpaceTree.otherCategory ? own == nil : own == name
                }
            }
            return SpaceTree.total(under: node.path, in: snapshot)
        }
        var out: [String: Int64] = [:]
        for node in selectableNodes where node.path != Self.unmeasuredPath && node.path != Self.volumesPath {
            let before = total(node, in: previous)
            guard before > 0 else { continue }
            let delta = total(node, in: current) - before
            if delta >= Self.growthBadgeBytes { out[node.path] = delta }
        }
        growth = out
    }

    /// Growth smaller than this isn't badged.
    static let growthBadgeBytes: Int64 = 250_000_000

    func icon(for node: SpaceNode) -> NSImage {
        data.icon(for: node.path, owner: claude.answer(node.path)?.ownerBundleID ?? candidateFor(node.path)?.quit.first?.bundleID)
    }

    func icon(path: String) -> NSImage {
        data.icon(for: path, owner: claude.answer(path)?.ownerBundleID ?? candidateFor(path)?.quit.first?.bundleID)
    }

    func sizeText(_ node: SpaceNode) -> String {
        if pending.contains(node.path) { return "Measuring…" }
        let text = ByteFormat.string(node.allocated)
        return node.sharesSpace ? "up to " + text : text
    }
}
