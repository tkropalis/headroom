import AppKit
import HeadroomCore
import Observation
import ServiceManagement
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
    var scan: ScanResult? = Store.lastScan()
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
    @ObservationIgnored private var lastNotifiedLevel: HeadroomLevel = .ok

    init() {
        defaults.register(defaults: ["warnGB": 20, "criticalGB": 10, "growthGB": 5, "dailyScan": true,
                                     "menuDisplay": MenuDisplay.gigabytes.rawValue])
        warnGB = defaults.integer(forKey: "warnGB")
        criticalGB = defaults.integer(forKey: "criticalGB")
        growthGB = defaults.integer(forKey: "growthGB")
        menuDisplay = MenuDisplay(rawValue: defaults.string(forKey: "menuDisplay") ?? "") ?? .gigabytes
        dailyScan = defaults.bool(forKey: "dailyScan")
        disabledEntries = Set(defaults.stringArray(forKey: "disabledEntries") ?? [])
        excludedPaths = defaults.stringArray(forKey: "excludedPaths") ?? []
        dismissedAlerts = Set(defaults.stringArray(forKey: "dismissedAlerts") ?? [])
        lastNotifiedLevel = level
        loadGrowthAlerts()
        requestNotificationPermission()
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

    func candidates(in group: CandidateGroup) -> [Candidate] { scan?.candidates(in: group) ?? [] }

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
        let verb = trashOnly ? "Move \(size) to Bin" : "Clean \(size)"
        let quits = appsToQuitForSelection.map(\.name)
        return quits.isEmpty ? verb : "Quit \(quits.joined(separator: " and ")) and \(verb.prefix(1).lowercased() + verb.dropFirst())"
    }

    // MARK: - Disk and scanning

    func refreshDisk() {
        disk = DiskStatus.current()
        checkThresholds()
    }

    func refreshProcesses() { processes = ProcessSnapshot.capture() }

    func startScan() {
        guard !scanning else { return }
        scanning = true
        let options = ScanOptions(disabledEntries: disabledEntries, excludedPaths: excludedPaths)
        Task {
            let result = await Task.detached(priority: .utility) { await Scanner.scan(options) }.value
            Store.saveScan(result)
            scan = result
            refreshProcesses()
            refreshDisk()
            scanning = false
        }
    }

    func popoverOpened() {
        // An accessory app isn't active by default, which draws its controls as inactive.
        NSApp.activate()
        refreshDisk()
        refreshProcesses()
        if scan == nil || Date().timeIntervalSince(scan!.date) > 3600 { startScan() }
    }

    // MARK: - Review and clean

    func openReview(_ group: CandidateGroup, preselect: Set<String>? = nil) {
        refreshProcesses()
        reviewGroup = group
        reviewItems = candidates(in: group)
        selection = preselect ?? Set(reviewItems.filter { group == .ready && status(of: $0).selectedByDefault }.map(\.id))
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
                let entry = HistoryEntry(items: done.map(\.name), freed: freed)
                Store.appendHistory(entry)
                history.insert(entry, at: 0)
            }
            refreshDisk()
            screen = .result
            startScan()
        }
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
    var categories: [(name: String, bytes: Int64)] {
        guard let disk, let snapshot = Store.snapshots().last else { return [] }
        let home = Paths.home
        let rules: [(String, (String) -> Bool)] = [
            ("Developer", { p in ["/Library/Developer", "/Library/Android", "/.gradle", "/.android", "Xcode.app",
                                   "Android Studio.app", "/.cocoapods", "/.swiftpm", "/.expo", "/.maestro"].contains { p.contains($0) } }),
            ("Docker", { p in p.contains("com.docker.docker") || p.hasSuffix("/.docker") || p.hasSuffix("Docker.app") }),
            ("Claude", { p in p.hasSuffix("/Application Support/Claude") || p.hasSuffix("/.claude") || p.hasSuffix("Claude.app") }),
            ("Caches", { p in p.contains("/Library/Caches/") || p.hasPrefix(Paths.userFolders) || p.hasSuffix("/.npm") || p.hasSuffix("/.cache") }),
            ("Apps", { p in p.hasPrefix("/Applications/") }),
            ("Projects", { p in p.hasPrefix(home + "/") && !p.dropFirst(home.count + 1).contains("/")
                             && !p.dropFirst(home.count + 1).hasPrefix(".") }),
        ]
        var totals: [String: Int64] = [:]
        for (path, size) in snapshot.sizes {
            if let rule = rules.first(where: { $0.1(path) }) { totals[rule.0, default: 0] += size }
        }
        var out = rules.map { ($0.0, totals[$0.0] ?? 0) }.filter { $0.1 > 0 }
        let measured = out.reduce(Int64(0)) { $0 + $1.1 }
        out.append(("System and other", max(0, disk.used - measured)))
        return out.map { (name: $0.0, bytes: $0.1) }
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
