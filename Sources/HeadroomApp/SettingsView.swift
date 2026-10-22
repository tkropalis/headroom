import AppKit
import Charts
import HeadroomCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            // Each tab sets its own height; the window resizes as you switch, like System Settings panes.
            Tab("General", systemImage: "gearshape") { GeneralSettings().frame(width: 560, height: 230) }
            Tab("Alerts", systemImage: "bell.badge") { AlertSettings().frame(width: 560, height: 420) }
            Tab("Scanning", systemImage: "magnifyingglass") { ScanningSettings().frame(width: 560, height: 600) }
            Tab("Caches", systemImage: "list.bullet") { CacheSettings().frame(width: 560, height: 560) }
            Tab("History", systemImage: "clock.arrow.circlepath") { HistorySettings().frame(width: 620, height: 600) }
            Tab(Helper.name, systemImage: "text.bubble") { ClaudeSettings().frame(width: 560, height: 680) }
        }
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var login = false

    var body: some View {
        @Bindable var model = model
        Form {
            Toggle("Open Headroom at login", isOn: $login)
                .onChange(of: login) { _, value in model.launchAtLogin = value }
            Picker("Menu bar shows", selection: $model.menuDisplay) {
                ForEach(MenuDisplay.allCases) { Text($0.title).tag($0) }
            }
            LabeledContent("Sizes") {
                Text("Decimal (1 GB = 1,000 MB)")
            }
            Text("The same units as Finder and About This Mac.").font(.callout).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .onAppear { login = model.launchAtLogin }
    }
}

struct AlertSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Stepper(value: $model.warnGB, in: 5...100, step: 5) {
                    LabeledContent("Warn below", value: "\(model.warnGB) GB")
                }
                Stepper(value: $model.criticalGB, in: 2...50) {
                    LabeledContent("Critical below", value: "\(model.criticalGB) GB")
                }
            } footer: {
                Text("Below the warning level the menu bar icon gets an orange dot and you get one notification. Builds and Docker start failing around 10 GB.")
            }
            Section {
                Stepper(value: $model.growthGB, in: 1...50) {
                    LabeledContent("Alert when a folder grows", value: "\(model.growthGB) GB a day")
                }
            } footer: {
                Text("Compared with the snapshot from the day before.")
            }
            Section {
                Stepper(value: $model.runwayDays, in: 1...30) {
                    LabeledContent("Warn when the disk would be full within", value: "\(model.runwayDays) days")
                }
            } footer: {
                Text("Based on the last 7 days. The popover shows the trend from 30 days out.")
            }
        }
        .formStyle(.grouped)
    }
}

struct ScanningSettings: View {
    @Environment(AppModel.self) private var model
    @State private var newExclusion = ""

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                LabeledContent("Scans", value: "Macintosh HD (internal disk)")
                Toggle("Check folder growth once a day when the Mac is idle", isOn: $model.dailyScan)
                LabeledContent("Last growth check") {
                    HStack {
                        Text(model.lastSnapshotDate.map { RelativeDate.string($0) } ?? "Never")
                        Button(model.recordingGrowth ? "Checking…" : "Check Now") { model.recordGrowth() }
                            .disabled(model.recordingGrowth)
                    }
                }
            } footer: {
                Text("Scans only measure. Nothing is cleaned without you.")
            }
            Section {
                Toggle("Look for forgotten files", isOn: entryToggle("forgotten"))
                Stepper(value: $model.forgottenMB, in: 100...5000, step: 100) {
                    LabeledContent("Larger than", value: "\(model.forgottenMB) MB")
                }
                Picker("Not opened for", selection: $model.forgottenMonths) {
                    ForEach([3, 6, 12, 24], id: \.self) { Text($0 == 12 ? "1 year" : $0 == 24 ? "2 years" : "\($0) months").tag($0) }
                }
            } header: {
                Text("Forgotten files")
            } footer: {
                Text("Plus installers in Downloads for apps that are already installed.")
            }
            Section {
                Toggle("Look for identical files", isOn: entryToggle("identical"))
                Stepper(value: $model.identicalMinKB, in: 16...4096, step: 16) {
                    LabeledContent("Skip files smaller than", value: "\(model.identicalMinKB) KB")
                }
                LabeledContent("Last checked") {
                    HStack {
                        Text(model.identicalDate.map { RelativeDate.string($0) } ?? "Never")
                        Button(model.scanningIdentical ? "Checking…" : "Check Now") { model.startIdenticalScan() }
                            .disabled(model.scanningIdentical)
                    }
                }
            } header: {
                Text("Identical files")
            } footer: {
                Text("Every file stays where it is. Copies share their disk space until one is edited. Checked once a day.")
            }
            Section("Full Disk Access") {
                if model.hasFullDiskAccess {
                    Label("Granted. Every folder can be measured.", systemImage: "checkmark.circle")
                } else {
                    LabeledContent {
                        Button("Open Privacy Settings…") { model.openFullDiskAccessSettings() }
                    } label: {
                        Label("Off. Mail, Safari and some app data are skipped.", systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            Section("Don't scan") {
                ForEach(model.excludedPaths, id: \.self) { path in
                    HStack {
                        Text(Paths.display(path))
                        Spacer()
                        Button("Remove") { model.excludedPaths.removeAll { $0 == path } }.buttonStyle(.borderless)
                    }
                }
                HStack {
                    Button("Add Folder…") { chooseFolder() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func entryToggle(_ id: String) -> Binding<Bool> {
        Binding(get: { !model.disabledEntries.contains(id) },
                set: { on in if on { model.disabledEntries.remove(id) } else { model.disabledEntries.insert(id) } })
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url, !model.excludedPaths.contains(url.path) {
            model.excludedPaths.append(url.path)
        }
    }
}

struct CacheSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                ForEach(Catalog.builtIn) { entry in
                    Toggle(isOn: Binding(
                        get: { !model.disabledEntries.contains(entry.id) },
                        set: { on in
                            if on { model.disabledEntries.remove(entry.id) } else { model.disabledEntries.insert(entry.id) }
                        })) {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.name)
                                Text(entry.cost).font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            LevelBadge(level: entry.level)
                        }
                    }
                }
            } footer: {
                Text("Folders Headroom knows how to clean. Turn one off to stop suggesting it. Project build caches and dormant projects are found by scanning your home folder.")
            }
        }
        .formStyle(.grouped)
    }
}

struct LevelBadge: View {
    let level: CleanupLevel

    var body: some View {
        Text(level.title)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: .capsule)
    }

    private var color: Color {
        switch level {
        case .safe: .green
        case .rebuilds: .orange
        case .yourCall: .red
        }
    }
}

struct HistorySettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Free space, last 30 days").font(.headline)
                if let runway = model.runway {
                    Text(runway.line).foregroundStyle(runway.daysLeft <= model.runwayDays ? Color.orange : Color.secondary)
                }
                FreeSpaceChart()
                    .frame(height: 200)

                Text("Every cleanup, with the space it actually freed.").foregroundStyle(.secondary).padding(.top, 8)
                if model.history.isEmpty {
                    ContentUnavailableView("No cleanups yet", systemImage: "clock",
                                           description: Text("Cleanups you run from Headroom or the headroom command appear here."))
                } else {
                    VStack(spacing: 0) {
                        ForEach(model.history) { entry in
                            HistoryRow(entry: entry)
                            Divider()
                        }
                    }
                    .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 8))
                }
            }
            .padding()
        }
    }
}

struct HistoryRow: View {
    @Environment(AppModel.self) private var model
    let entry: HistoryEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(RelativeDate.dateTime(entry.date)).frame(width: 110, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.items.joined(separator: ", ")).lineLimit(2)
                if entry.putBack == true {
                    Text("Put back").font(.callout).foregroundStyle(.secondary)
                } else if model.canPutBack(entry) {
                    Text("In the Bin until it is emptied").font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.canPutBack(entry) {
                Button("Put Back") { model.putBack(entry) }.controlSize(.small)
            }
            Text(ByteFormat.string(entry.freed)).monospacedDigit().frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

/// Hourly free space with the warning levels, each cleanup, and the projection when space is falling.
struct FreeSpaceChart: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let now = Date()
        let start = now.addingTimeInterval(-30 * 86400)
        let samples = model.freeSamples.filter { $0.date >= start }
        let cleanups = model.history.filter { $0.date >= start && $0.freed > 0 }
        let runway = model.runway
        let last = samples.last

        if samples.count < 24 {
            ContentUnavailableView("Not enough history yet", systemImage: "chart.xyaxis.line",
                                   description: Text("Free space is recorded hourly. The trend appears after 3 days."))
        } else {
            Chart {
                ForEach(samples, id: \.date) { sample in
                    AreaMark(x: .value("Date", sample.date), y: .value("Free", gb(sample.available)))
                        .foregroundStyle(Color.accentColor.opacity(0.18))
                    LineMark(x: .value("Date", sample.date), y: .value("Free", gb(sample.available)))
                        .foregroundStyle(Color.accentColor)
                }
                RuleMark(y: .value("Warning", model.warnGB))
                    .foregroundStyle(.orange)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("Warning \(model.warnGB) GB").font(.caption2).foregroundStyle(.orange)
                    }
                RuleMark(y: .value("Critical", model.criticalGB))
                    .foregroundStyle(.red)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("Critical \(model.criticalGB) GB").font(.caption2).foregroundStyle(.red)
                    }
                ForEach(cleanups) { entry in
                    PointMark(x: .value("Date", entry.date), y: .value("Free", gb(nearest(entry.date, in: samples))))
                        .foregroundStyle(.green)
                        .annotation(position: .top) {
                            Text("+\(ByteFormat.string(entry.freed))").font(.caption2).foregroundStyle(.green)
                        }
                }
                if let runway, let last {
                    let end = last.date.addingTimeInterval(Double(runway.daysLeft) * 86400)
                    LineMark(x: .value("Date", last.date), y: .value("Projection", gb(last.available)), series: .value("Series", "Projection"))
                        .foregroundStyle(.orange)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    LineMark(x: .value("Date", end), y: .value("Projection", 0), series: .value("Series", "Projection"))
                        .foregroundStyle(.orange)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                }
            }
            .chartYAxisLabel("GB free")
            .chartYScale(domain: 0...max(Double(model.warnGB) * 1.4, (samples.map { gb($0.available) }.max() ?? 0) * 1.1))
            .accessibilityLabel(runway?.line ?? "Free space over the last 30 days")
        }
    }

    private func gb(_ bytes: Int64) -> Double { Double(bytes) / 1e9 }

    private func nearest(_ date: Date, in samples: [FreeSample]) -> Int64 {
        samples.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }?.available ?? 0
    }
}
