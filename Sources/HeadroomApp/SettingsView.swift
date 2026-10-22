import AppKit
import HeadroomCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            // Each tab sets its own height; the window resizes as you switch, like System Settings panes.
            Tab("General", systemImage: "gearshape") { GeneralSettings().frame(width: 560, height: 230) }
            Tab("Alerts", systemImage: "bell.badge") { AlertSettings().frame(width: 560, height: 330) }
            Tab("Scanning", systemImage: "magnifyingglass") { ScanningSettings().frame(width: 560, height: 470) }
            Tab("Caches", systemImage: "list.bullet") { CacheSettings().frame(width: 560, height: 520) }
            Tab("History", systemImage: "clock.arrow.circlepath") { HistorySettings().frame(width: 560, height: 360) }
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
        VStack(alignment: .leading, spacing: 8) {
            Text("Every cleanup, with the space it actually freed.").foregroundStyle(.secondary)
            if model.history.isEmpty {
                ContentUnavailableView("No cleanups yet", systemImage: "clock",
                                       description: Text("Cleanups you run from Headroom or the headroom command appear here."))
            } else {
                Table(model.history) {
                    TableColumn("Date") { Text(RelativeDate.dateTime($0.date)) }.width(110)
                    TableColumn("What was cleaned") { Text($0.items.joined(separator: ", ")).lineLimit(2) }
                    TableColumn("Freed") { Text(ByteFormat.string($0.freed)).monospacedDigit() }.width(70)
                }
            }
        }
        .padding()
    }
}
