import AppKit
import HeadroomCore
import Observation
import ServiceManagement
import SwiftUI
import UserNotifications

enum MenuDisplay: String, CaseIterable, Identifiable {
    case gigabytes, percentage, iconOnly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .gigabytes: "Free space in GB"
        case .percentage: "Percentage free"
        case .iconOnly: "Icon only"
        }
    }
}

enum Screen: Equatable {
    case main, review, cleaning, result
    case growth(GrowthAlert)
    /// Folders Headroom doesn't know, to ask Ollie about.
    case helper
    /// Ollie's answer about one folder.
    case ask(String)
    /// First run, steps 1 to 3.
    case onboarding(Int)
}

/// Thread-safe flag the cleaner checks between items.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor @Observable
final class AppModel {
    // Disk and scan
    var disk: DiskStatus? = DiskStatus.current()
    var scan: ScanResult? = Store.lastScan() { didSet { candidatesChanged() } }
    var scanning = false
    var processes = ProcessSnapshot(commandLines: [], runningBundleIDs: [])
    var expandedGroup: CandidateGroup?

    // Review and cleaning
    var screen: Screen = .main
    var reviewGroup: CandidateGroup = .ready
    var reviewItems: [Candidate] = []
    var selection: Set<String> = []
    var cleaningIndex = 0
    var outcomes: [CleanupOutcome] = []
    private let stopFlag = StopFlag()

    // Identical files: a slower scan of its own, at most once a day.
    var identicalGroups: [IdenticalGroup] = Store.identicalGroups()?.groups ?? [] { didSet { candidatesChanged() } }
    var identicalDate: Date? = Store.identicalGroups()?.date
    var scanningIdentical = false

    // Trend
    var freeSamples: [FreeSample] = Store.freeSamples()
    var purgeable: Int64 = Purgeable.bytes()
    @ObservationIgnored private var runwayNotified = false

    // Space Map and offload
    let spaceMap = SpaceMapModel()
    var offloadRequest: OffloadItem?
    var offloadedCount = Offloader.records().count

    // Growth and history
    var growthAlerts: [GrowthAlert] = []
    var dismissedAlerts: Set<String> = []
    var history: [HistoryEntry] = Store.history()
    var lastSnapshotDate: Date? = Store.snapshots().last?.date
    var recordingGrowth = false

    // Settings
    @ObservationIgnored private let defaults = UserDefaults.standard
    var warnGB: Int { didSet { defaults.set(warnGB, forKey: "warnGB"); checkThresholds() } }
    var criticalGB: Int { didSet { defaults.set(criticalGB, forKey: "criticalGB"); checkThresholds() } }
    var growthGB: Int { didSet { defaults.set(growthGB, forKey: "growthGB") } }
    var menuDisplay: MenuDisplay { didSet { defaults.set(menuDisplay.rawValue, forKey: "menuDisplay") } }
    var dailyScan: Bool { didSet { defaults.set(dailyScan, forKey: "dailyScan") } }
    var disabledEntries: Set<String> { didSet { defaults.set(Array(disabledEntries), forKey: "disabledEntries") } }
    var excludedPaths: [String] { didSet { defaults.set(excludedPaths, forKey: "excludedPaths") } }
    var runwayDays: Int { didSet { defaults.set(runwayDays, forKey: "runwayDays") } }
    var forgottenMB: Int { didSet { defaults.set(forgottenMB, forKey: "forgottenMB") } }
    var forgottenMonths: Int { didSet { defaults.set(forgottenMonths, forKey: "forgottenMonths") } }
    var identicalMinKB: Int { didSet { defaults.set(identicalMinKB, forKey: "identicalMinKB") } }
    var hasOnboarded: Bool { didSet { defaults.set(hasOnboarded, forKey: "hasOnboarded") } }
    var claudeEnabled: Bool { didSet { defaults.set(claudeEnabled, forKey: "claudeEnabled"); refreshNotes() } }
    var claudeAutoNotes: Bool { didSet { defaults.set(claudeAutoNotes, forKey: "claudeAutoNotes"); refreshNotes() } }
    @ObservationIgnored private var lastNotifiedLevel: HeadroomLevel = .ok

    init() {
        defaults.register(defaults: ["warnGB": 20, "criticalGB": 10, "growthGB": 5, "dailyScan": true,
                                     "menuDisplay": MenuDisplay.gigabytes.rawValue, "runwayDays": 7,
                                     "forgottenMB": 500, "forgottenMonths": 6, "identicalMinKB": 100,
                                     "claudeAutoNotes": true])
        warnGB = defaults.integer(forKey: "warnGB")
        criticalGB = defaults.integer(forKey: "criticalGB")
        growthGB = defaults.integer(forKey: "growthGB")
        menuDisplay = MenuDisplay(rawValue: defaults.string(forKey: "menuDisplay") ?? "") ?? .gigabytes
        dailyScan = defaults.bool(forKey: "dailyScan")
        disabledEntries = Set(defaults.stringArray(forKey: "disabledEntries") ?? [])
        excludedPaths = defaults.stringArray(forKey: "excludedPaths") ?? []
        runwayDays = defaults.integer(forKey: "runwayDays")
        forgottenMB = defaults.integer(forKey: "forgottenMB")
        forgottenMonths = defaults.integer(forKey: "forgottenMonths")
        identicalMinKB = defaults.integer(forKey: "identicalMinKB")
        // Someone who used v1 already has a scan; they don't need the welcome.
        hasOnboarded = defaults.bool(forKey: "hasOnboarded") || Store.lastScan() != nil
        claudeEnabled = defaults.bool(forKey: "claudeEnabled")
        claudeAutoNotes = defaults.bool(forKey: "claudeAutoNotes")
        dismissedAlerts = Set(defaults.stringArray(forKey: "dismissedAlerts") ?? [])
        lastNotifiedLevel = level
        loadGrowthAlerts()
        requestNotificationPermission()
        configureSpaceMap()
        startTimers()
    }

    // MARK: - Derived

    var level: HeadroomLevel {
        guard let disk else { return .ok }
        return HeadroomLevel(available: disk.available, warnBytes: ByteFormat.gigabytes(Double(warnGB)),
                             criticalBytes: ByteFormat.gigabytes(Double(criticalGB)))
    }

    var menuTitle: String {
        guard let disk else { return "–" }
        switch menuDisplay {
        case .gigabytes: return ByteFormat.wholeGB(disk.available)
        case .percentage: return "\(Int((Double(disk.available) / Double(max(disk.total, 1)) * 100).rounded()))%"
        case .iconOnly: return ""
        }
    }

    var visibleAlerts: [GrowthAlert] { growthAlerts.filter { !dismissedAlerts.contains(alertKey($0)) } }

    func candidates(in group: CandidateGroup) -> [Candidate] {
        if group == .identical {
            return Scanner.identicalCandidates(identicalGroups).sorted { $0.expectedBytes > $1.expectedBytes }
        }
        return scan?.candidates(in: group) ?? []
    }

    var allCandidates: [Candidate] { (scan?.candidates ?? []) + Scanner.identicalCandidates(identicalGroups) }

    /// Scan items by the paths they clean, and by those or their project. The Space Map asks for
    /// every tile; built once per scan rather than searched each time.
    @ObservationIgnored private var candidateIndex: (cleans: [String: Candidate], cleansOrProject: [String: Candidate])?

    /// The first scan item that cleans `path`, or, with `orProject`, whose project it is.
    func candidate(for path: String, orProject: Bool) -> Candidate? {
        // Read so that views asking this redraw when a scan finishes.
        _ = scan
        _ = identicalGroups
        let index = candidateIndex ?? buildCandidateIndex()
        return orProject ? index.cleansOrProject[path] : index.cleans[path]
    }

    private func buildCandidateIndex() -> (cleans: [String: Candidate], cleansOrProject: [String: Candidate]) {
        var cleans: [String: Candidate] = [:]
        var cleansOrProject: [String: Candidate] = [:]
        // Earlier items win, as a search from the start would find them.
        for item in allCandidates {
            for path in item.paths {
                if cleans[path] == nil { cleans[path] = item }
                if cleansOrProject[path] == nil { cleansOrProject[path] = item }
            }
            if let project = item.projectPath, cleansOrProject[project] == nil { cleansOrProject[project] = item }
        }
        candidateIndex = (cleans, cleansOrProject)
        return (cleans, cleansOrProject)
    }

    private func candidatesChanged() {
        candidateIndex = nil
        spaceMap.costsChanged()
    }

    /// Shown under the headroom line when free space is falling and would run out within 30 days.
    var runway: Runway? {
        guard let runway = Trend.runway(freeSamples), runway.daysLeft <= 30 else { return nil }
        return runway
    }

    func status(of item: Candidate) -> CandidateStatus { item.status(with: processes) }

    /// Ready items that can be cleaned right now without quitting an app you work in.
    var readyNow: [Candidate] { candidates(in: .ready).filter { status(of: $0).selectedByDefault } }
    var readyBlocked: [Candidate] { candidates(in: .ready).filter { status(of: $0).isBlocked } }

    func total(_ items: [Candidate]) -> Int64 { items.reduce(0) { $0 + $1.expectedBytes } }

    var selectedItems: [Candidate] { reviewItems.filter { selection.contains($0.id) } }

    var appsToQuitForSelection: [AppRef] {
        var seen = Set<String>()
        return selectedItems.flatMap { status(of: $0).appsToQuit }.filter { seen.insert($0.bundleID).inserted }
    }

    var confirmTitle: String {
        let items = selectedItems
        guard !items.isEmpty else { return "Clean" }
        let size = ByteFormat.string(total(items))
        let trashOnly = items.allSatisfy { if case .trash = $0.action { true } else { false } }
        let shareOnly = items.allSatisfy { if case .share = $0.action { true } else { false } }
        let verb = shareOnly ? "Share space, \(size)" : trashOnly ? "Move \(size) to the Bin" : "Clean \(size)"
        let quits = appsToQuitForSelection.map(\.name)
        return quits.isEmpty ? verb : "Quit \(quits.joined(separator: " and ")) and \(verb.prefix(1).lowercased() + verb.dropFirst())"
    }

    // MARK: - Disk and scanning

    func refreshDisk() {
        disk = DiskStatus.current()
        purgeable = Purgeable.bytes()
        if let disk {
            let updated = Trend.record(disk.available, into: freeSamples)
            if updated != freeSamples {
                freeSamples = updated
                Store.saveFreeSamples(updated)
            }
        }
        checkThresholds()
        checkRunway()
    }

    func refreshProcesses() { processes = ProcessSnapshot.capture() }

    func startScan() {
        guard !scanning else { return }
        scanning = true
        let options = ScanOptions(disabledEntries: disabledEntries, excludedPaths: excludedPaths,
                                  forgottenBytes: Int64(forgottenMB) * 1_000_000, forgottenDays: forgottenMonths * 30)
        Task {
            let result = await Task.detached(priority: .utility) { await Scanner.scan(options) }.value
            Store.saveScan(result)
            scan = result
            refreshProcesses()
            refreshDisk()
            scanning = false
            refreshNotes()
            if Date().timeIntervalSince(identicalDate ?? .distantPast) > 24 * 3600 { startIdenticalScan() }
        }
    }

    /// Walks the home folder for identical files. Slow, so it runs in the background at most daily.
    func startIdenticalScan() {
        guard !scanningIdentical, !disabledEntries.contains("identical") else { return }
        scanningIdentical = true
        let minimum = Int64(identicalMinKB) * 1000
        let excluded = excludedPaths
        Task {
            let groups = await IdenticalFiles.find(roots: IdenticalFiles.defaultRoots(), minimumBytes: minimum, excluded: excluded)
            Store.saveIdentical(groups)
            identicalGroups = groups
            identicalDate = Date()
            scanningIdentical = false
        }
    }

    func popoverOpened() {
        // An accessory app isn't active by default, which draws its controls as inactive.
        NSApp.activate()
        refreshDisk()
        refreshProcesses()
        if !hasOnboarded {
            if case .onboarding = screen {} else { screen = .onboarding(1) }
            return
        }
        if scan == nil || Date().timeIntervalSince(scan!.date) > 3600 { startScan() }
        refreshNotes()
    }

    func finishOnboarding() {
        hasOnboarded = true
        screen = .main
        startScan()
    }

    // MARK: - Review and clean

    func openReview(_ group: CandidateGroup, preselect: Set<String>? = nil) {
        refreshProcesses()
        reviewGroup = group
        reviewItems = candidates(in: group)
        // Groups where nothing is lost, or where ticking is the point, start ticked.
        let ticked: Set<CandidateGroup> = [.ready, .identical, .forgotten]
        selection = preselect ?? Set(reviewItems.filter { ticked.contains(group) && status(of: $0).selectedByDefault }.map(\.id))
        screen = .review
    }

    func toggle(_ item: Candidate) {
        guard !status(of: item).isBlocked else { return }
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
    }

    func cleanSelection() {
        let items = selectedItems.filter { !status(of: $0).isBlocked }
        guard !items.isEmpty else { return }
        reviewItems = items
        outcomes = []
        cleaningIndex = 0
        stopFlag.set(false)
        screen = .cleaning
        let flag = stopFlag
        Task {
            let results = await Cleaner().run(
                items,
                onStart: { index in Task { @MainActor in self.cleaningIndex = index } },
                onFinish: { outcome in Task { @MainActor in self.outcomes.append(outcome) } },
                shouldStop: { flag.get() })
            outcomes = results
            let freed = results.reduce(Int64(0)) { $0 + $1.freed }
            let done = results.filter { $0.state == .done }
            if !done.isEmpty {
                let restorable = done.compactMap(\.restorable).reduce(into: [String: String]()) { $0.merge($1) { a, _ in a } }
                let entry = HistoryEntry(items: done.map(\.name), freed: freed, restorable: restorable.isEmpty ? nil : restorable)
                Store.appendHistory(entry)
                history.insert(entry, at: 0)
            }
            if items.contains(where: { $0.group == .identical }) {
                let shared = Set(items.filter { $0.group == .identical }.map(\.id))
                identicalGroups.removeAll { shared.contains("identical:" + $0.id) }
                Store.saveIdentical(identicalGroups, date: identicalDate ?? Date())
            }
            refreshDisk()
            screen = .result
            startScan()
        }
    }

    // MARK: - Put Back

    /// Outcomes already put back on the result screen.
    var putBackIDs: Set<String> = []

    func canPutBack(_ outcome: CleanupOutcome) -> Bool {
        guard !putBackIDs.contains(outcome.id), let map = outcome.restorable else { return false }
        return Cleaner.canPutBack(map)
    }

    func putBack(_ outcome: CleanupOutcome) {
        guard let map = outcome.restorable else { return }
        let failed = Cleaner.putBack(map)
        if failed.isEmpty { putBackIDs.insert(outcome.id) }
        markHistoryPutBack(map)
        startScan()
    }

    func canPutBack(_ entry: HistoryEntry) -> Bool {
        guard entry.putBack != true, let map = entry.restorable else { return false }
        return Cleaner.canPutBack(map)
    }

    func putBack(_ entry: HistoryEntry) {
        guard let map = entry.restorable else { return }
        _ = Cleaner.putBack(map)
        markHistoryPutBack(map)
        startScan()
    }

    private func markHistoryPutBack(_ map: [String: String]) {
        for index in history.indices {
            guard let entryMap = history[index].restorable, !Set(entryMap.keys).isDisjoint(with: map.keys) else { continue }
            if !Cleaner.canPutBack(entryMap) { history[index].putBack = true }
        }
        Store.saveHistory(history)
    }

    func stopCleaning() { stopFlag.set(true) }

    var freedTotal: Int64 { outcomes.reduce(0) { $0 + $1.freed } }

    // MARK: - Growth

    func openGrowth(_ alert: GrowthAlert) { screen = .growth(alert) }

    func dismiss(_ alert: GrowthAlert) {
        dismissedAlerts.insert(alertKey(alert))
        defaults.set(Array(dismissedAlerts), forKey: "dismissedAlerts")
        screen = .main
    }

    /// A catalogue item that covers the folder that grew, if any.
    func candidate(for alert: GrowthAlert) -> Candidate? {
        scan?.candidates.first { item in
            item.paths.contains { $0 == alert.path || $0.hasPrefix(alert.path + "/") || alert.path.hasPrefix($0 + "/") }
        }
    }

    func recordGrowth() {
        guard !recordingGrowth else { return }
        recordingGrowth = true
        let threshold = ByteFormat.gigabytes(Double(growthGB))
        Task {
            let history = Store.snapshots()
            let snapshot = await Task.detached(priority: .background) { await GrowthTracker.record() }.value
            let alerts = await Task.detached(priority: .background) {
                GrowthTracker.alerts(history: history, current: snapshot, threshold: threshold)
            }.value
            Store.appendSnapshot(snapshot)
            lastSnapshotDate = snapshot.date
            growthAlerts = alerts
            for alert in alerts where !dismissedAlerts.contains(alertKey(alert)) {
                notify(title: "A folder grew fast", body: alert.headline + " since " + RelativeDate.dateTime(alert.since) + ".")
            }
            recordingGrowth = false
        }
    }

    private func loadGrowthAlerts() {
        let all = Store.snapshots()
        guard let latest = all.last else { return }
        growthAlerts = GrowthTracker.alerts(history: Array(all.dropLast()), current: latest,
                                            threshold: ByteFormat.gigabytes(Double(growthGB)))
    }

    private func alertKey(_ alert: GrowthAlert) -> String { alert.path + "@" + String(alert.current) }

    /// Space used by each kind of folder, from the latest snapshot.
    var categories: [SpaceCategory] {
        guard let disk, let snapshot = Store.snapshots().last else { return [] }
        return SpaceTree.categories(snapshot: snapshot, disk: disk)
    }

    // MARK: - Claude

    var claudeKeyStored = ClaudeKey.isStored
    var explanations: [Explanation] = Store.explanations() { didSet { spaceMap.costsChanged() } }
    var explaining: Set<String> = []
    var explainErrors: [String: String] = [:]

    var claudeReady: Bool { claudeEnabled && claudeKeyStored }
    /// Ollie may send short notes without being asked.
    var notesOn: Bool { claudeReady && claudeAutoNotes }

    // Notes Ollie writes on its own, with Haiku.
    var summaryNote: String?
    var growthNotes: [String: String] = [:]
    var guesses: [String: String] = [:]
    @ObservationIgnored private var notesInFlight: Set<String> = []

    /// Writes the summary and the growth notes if what they describe changed. Saved notes come back
    /// without a request, so this is cheap to call whenever the popover opens or a scan ends.
    func refreshNotes() {
        guard notesOn else { summaryNote = nil; return }
        if let disk, scan != nil, !notesInFlight.contains("summary") {
            let input = QuickNotes.SummaryInput.make(disk: disk, candidates: allCandidates, snapshot: Store.snapshots().last,
                                                     warnGB: warnGB, runway: runway, growth: visibleAlerts)
            notesInFlight.insert("summary")
            Task {
                if let note = try? await QuickNotes.summary(input) { summaryNote = note }
                notesInFlight.remove("summary")
            }
        }
        for alert in visibleAlerts where growthNotes[alert.path] == nil && Explainer.privacyBlocker(alert.path) == nil {
            let key = "growth:" + alert.path
            guard !notesInFlight.contains(key) else { continue }
            notesInFlight.insert(key)
            Task {
                let facts = await FolderFacts.gather(path: alert.path, bytes: alert.current)
                if let note = try? await QuickNotes.growthReason(alert, children: facts.children) { growthNotes[alert.path] = note }
                notesInFlight.remove(key)
            }
        }
    }

    /// First guesses for folders without a cleanup rule or an answer, asked together.
    func requestGuesses(_ nodes: [SpaceNode]) {
        let wanted = nodes.filter { node in
            guesses[node.path] == nil && explanation(for: node.path) == nil && !notesInFlight.contains("guess:" + node.path)
                && Explainer.privacyBlocker(node.path) == nil && node.path != SpaceMapModel.unmeasuredPath
        }
        for node in wanted { if let saved = QuickNotes.savedGuess(node.path) { guesses[node.path] = saved } }
        let missing = wanted.filter { guesses[$0.path] == nil }
        guard notesOn, !missing.isEmpty else { return }
        missing.forEach { notesInFlight.insert("guess:" + $0.path) }
        Task {
            var facts: [FolderFacts] = []
            for node in missing.prefix(8) { facts.append(await FolderFacts.gather(path: node.path, bytes: node.allocated)) }
            if let found = try? await QuickNotes.guesses(facts) { guesses.merge(found) { _, new in new } }
            missing.forEach { notesInFlight.remove("guess:" + $0.path) }
        }
    }

    /// The largest folders from the last snapshot that Headroom has no cleanup rule for.
    var unknownFolders: [SpaceNode] {
        guard let snapshot = Store.snapshots().last else { return [] }
        // Only "System and other": the named categories are folders Headroom already knows, and so
        // are the system places it gives a descriptive name.
        return SpaceTree.topLevel(snapshot: snapshot, category: SpaceTree.otherCategory).filter { node in
            node.allocated >= 100_000_000 && (node.kind == nil || node.kind == .appData)
                && (node.name == (node.path as NSString).lastPathComponent || node.path.hasPrefix("/Library/"))
                && Explainer.privacyBlocker(node.path) == nil
                && !allCandidates.contains { $0.paths.contains(node.path) || $0.projectPath == node.path }
        }
        .prefix(8).map { $0 }
    }

    /// Asks for any folder, picked in an Open panel.
    func chooseFolderToAsk() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: Paths.home + "/Library")
        panel.prompt = "Ask \(Helper.name)"
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { screen = .ask(url.path) }
    }

    var claudeHooks: ClaudeHooks {
        ClaudeHooks(
            ready: { [weak self] in self?.claudeReady ?? false },
            answer: { [weak self] path in self?.explanation(for: path) },
            asking: { [weak self] path in self?.explaining.contains(path) ?? false },
            error: { [weak self] path in self?.explainErrors[path] },
            ask: { [weak self] node, refresh in self?.explain(node, refresh: refresh) },
            setOnList: { [weak self] path, on in self?.setOnList(path, on) },
            guess: { [weak self] path in self?.guesses[path] },
            requestGuess: { [weak self] node in self?.requestGuesses([node]) })
    }

    func explanation(for path: String) -> Explanation? { explanations.first { $0.path == path } }

    /// Asks Claude about a Space Map row. Only runs when the person chooses Ask Claude.
    func explain(_ node: SpaceNode, refresh: Bool = false) {
        guard claudeReady, !explaining.contains(node.path) else { return }
        explaining.insert(node.path)
        explainErrors[node.path] = nil
        Task {
            do {
                _ = try await Explainer.explain(path: node.path, bytes: node.allocated, refresh: refresh)
            } catch {
                explainErrors[node.path] = error.localizedDescription
                if (error as? ClaudeError) == .noKey { claudeKeyStored = false }
            }
            explanations = Store.explanations()
            explaining.remove(node.path)
        }
    }

    /// Puts the folder on the cleanup list. Cleaning it still goes through the usual review.
    func setOnList(_ path: String, _ on: Bool) {
        guard var item = explanation(for: path), item.confirmed != on, !on || item.canConfirm else { return }
        item.confirmed = on
        Store.saveExplanation(item)
        explanations = Store.explanations()
        startScan()
    }

    func forgetExplanation(_ path: String) {
        let wasOnList = explanation(for: path)?.confirmed == true
        Store.removeExplanation(path)
        explanations = Store.explanations()
        if wasOnList { startScan() }
    }

    @discardableResult
    func saveClaudeKey(_ key: String) -> Bool {
        claudeKeyStored = ClaudeKey.save(key)
        if claudeKeyStored { claudeEnabled = true }
        return claudeKeyStored
    }

    func removeClaudeKey() {
        ClaudeKey.delete()
        claudeKeyStored = ClaudeKey.isStored
    }

    // MARK: - Space Map

    private func configureSpaceMap() {
        let map = spaceMap
        map.candidateFor = { [weak self] path in
            self?.candidate(for: path, orProject: true)
        }
        map.blockerFor = { [weak self] path in
            guard let self else { return nil }
            if let item = self.candidate(for: path, orProject: false), let blocker = self.status(of: item).blocker {
                return blocker
            }
            if let process = self.processes.processUsing(folder: path) {
                return "\(ProcessSnapshot.displayName(process)) is using this folder."
            }
            return nil
        }
        map.offloadBlocker = { path in Offloader.canOffload(path) }
        map.onClean = { [weak self] item in
            guard let self else { return }
            self.openReview(item.group, preselect: [item.id])
            self.reviewItems = [item]
            self.flowInWindow = true
        }
        map.onOffload = { [weak self] node in
            guard let self else { return }
            let quit = self.allCandidates.first { $0.paths.contains(node.path) }?.quit ?? []
            self.offloadRequest = OffloadItem(path: node.path, name: node.name, bytes: node.reclaimable, quit: quit)
        }
        map.onTrash = { [weak self] node in
            guard let self else { return }
            Task {
                let item = Candidate(id: "map:" + node.path, name: node.name, detail: Paths.display(node.path), group: .yourCall,
                                     size: SizeInfo(allocated: node.allocated, unshared: node.unshared), isEstimate: false,
                                     cost: "", quit: [], blockRules: [], projectPath: nil, action: .trash([node.path]), fixedBlocker: nil)
                let outcome = await Cleaner().clean(item)
                if outcome.state == .done {
                    let entry = HistoryEntry(items: [node.name], freed: outcome.freed, restorable: outcome.restorable)
                    Store.appendHistory(entry)
                    self.history.insert(entry, at: 0)
                    map.removeNode(node.path)
                }
            }
        }
        map.offloadedView = { AnyView(OffloadedList()) }
        map.claude = claudeHooks
        map.hasFullDiskAccess = { [weak self] in self?.hasFullDiskAccess ?? true }
        map.openFullDiskAccess = { [weak self] in self?.openFullDiskAccessSettings() }
        map.warningBytes = { [weak self] in ByteFormat.gigabytes(Double(self?.warnGB ?? 20)) }
        map.runPlan = { [weak self] plan, finished in
            guard let self else { return [] }
            let candidates = self.allCandidates
            var quits: [String: [AppRef]] = [:]
            for item in plan.items { quits[item.path] = map.quits(for: item.path) }
            let known = quits
            let outcomes = await PlanRunner().run(
                plan, drives: Offloader.destinations(),
                candidate: { path in candidates.first { $0.paths.contains(path) } },
                quits: { known[$0] ?? [] },
                onFinish: { item, outcome in Task { @MainActor in finished(item, outcome) } })
            let done = outcomes.filter { $0.state == .done }
            if !done.isEmpty {
                var restorable: [String: String] = [:]
                for outcome in done { restorable.merge(outcome.restorable ?? [:]) { first, _ in first } }
                let entry = HistoryEntry(items: done.map(\.name), freed: done.reduce(0) { $0 + $1.freed },
                                         restorable: restorable.isEmpty ? nil : restorable)
                Store.appendHistory(entry)
                self.history.insert(entry, at: 0)
            }
            self.offloadedCount = Offloader.records().count
            self.refreshDisk()
            return outcomes
        }
        map.canPutBack = { [weak self] outcome in self?.canPutBack(outcome) ?? false }
        map.putBack = { [weak self] outcome in
            self?.putBack(outcome)
            self?.spaceMap.refresh()
        }
        map.isExcluded = { [weak self] path in self?.excludedPaths.contains(path) ?? false }
        map.setExcluded = { [weak self] path, excluded in
            guard let self else { return }
            if excluded { if !self.excludedPaths.contains(path) { self.excludedPaths.append(path) } }
            else { self.excludedPaths.removeAll { $0 == path } }
        }
    }

    /// A review started from the Space Map runs in a sheet on that window.
    var flowInWindow = false

    func offloadFinished(_ record: OffloadRecord?) {
        offloadRequest = nil
        offloadedCount = Offloader.records().count
        if let record {
            spaceMap.removeNode(record.originalPath)
            refreshDisk()
            let entry = HistoryEntry(items: ["\(record.name), offloaded"], freed: record.bytes)
            Store.appendHistory(entry)
            history.insert(entry, at: 0)
        }
    }

    // MARK: - Notifications and timers

    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    private func requestNotificationPermission() {
        guard canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(title: String, body: String) {
        guard canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private func checkThresholds() {
        let current = level
        defer { lastNotifiedLevel = current }
        guard current > lastNotifiedLevel, let disk else { return }
        let ready = total(readyNow)
        let extra = ready > 0 ? " \(ByteFormat.string(ready)) of caches can be cleaned without losing anything." : ""
        notify(title: current == .critical ? "Headroom is critical" : "Headroom is low",
               body: "\(ByteFormat.string(disk.available)) free.\(extra)")
    }

    /// One notification each time the runway drops inside the warning window.
    private func checkRunway() {
        guard let runway = Trend.runway(freeSamples) else { runwayNotified = false; return }
        if runway.daysLeft > runwayDays { runwayNotified = false; return }
        guard !runwayNotified else { return }
        runwayNotified = true
        let ready = total(readyNow)
        let extra = ready > 0 ? " \(ByteFormat.string(ready)) can be cleaned without losing anything." : ""
        notify(title: "Running out in about \(runway.daysLeft) \(runway.daysLeft == 1 ? "day" : "days")",
               body: "At this rate the disk is full in about \(runway.daysLeft) \(runway.daysLeft == 1 ? "day" : "days").\(extra)")
    }

    private func startTimers() {
        Task { [weak self] in
            var tick = 0
            while let self {
                try? await Task.sleep(for: .seconds(60))
                self.refreshDisk()
                tick += 1
                if tick % 30 == 0, let scan = self.scan, Date().timeIntervalSince(scan.date) > 6 * 3600 { self.startScan() }
                if self.dailyScan, tick % 15 == 0, self.isIdle,
                   Date().timeIntervalSince(self.lastSnapshotDate ?? .distantPast) > 22 * 3600 {
                    self.recordGrowth()
                }
            }
        }
        if scan == nil { startScan() }
    }

    /// No keyboard or mouse input for five minutes.
    private var isIdle: Bool {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!) > 300
    }

    // MARK: - System

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
            catch { NSLog("Headroom: login item change failed: \(error)") }
        }
    }

    var hasFullDiskAccess: Bool {
        let probe = Paths.home + "/Library/Safari"
        return (try? FileManager.default.contentsOfDirectory(atPath: probe)) != nil
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
