import AppKit
import HeadroomCore
import SwiftUI

/// Moves an item to a drive or a compressed archive: choose, confirm, watch the steps, see the measured result.
struct OffloadSheet: View {
    let item: OffloadItem
    let onFinish: (OffloadRecord?) -> Void

    init(item: OffloadItem, onFinish: @escaping (OffloadRecord?) -> Void) {
        self.item = item
        self.onFinish = onFinish
    }

    private enum Phase { case choose, running, finished }

    @State private var phase: Phase = .choose
    @State private var destinations: [OffloadDestination] = []
    @State private var selectedID: String?
    @State private var compresses = true
    @State private var saving: Double?
    @State private var current: OffloadStep?
    @State private var finishedSteps: Set<OffloadStep> = []
    @State private var record: OffloadRecord?
    @State private var failure: String?
    @State private var freed: Int64 = 0
    @State private var stopping = false
    @State private var stopFlag = StopFlag()

    private var selected: OffloadDestination? { destinations.first { $0.id == selectedID } }
    private var drives: [OffloadDestination] { destinations.filter { !$0.isArchive } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch phase {
            case .choose: chooseView
            case .running: runningView
            case .finished: finishedView
            }
        }
        .padding(20)
        .frame(width: 460)
        .task { await load() }
    }

    // MARK: - Choose

    private var chooseView: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Offload \(item.name)").font(.title3.weight(.semibold))
                Text("Moves it off this Mac and keeps it safe, so you can bring it back with one click.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if drives.isEmpty {
                Label("Connect a drive to offload to it.", systemImage: "externaldrive.badge.plus")
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 2) {
                ForEach(destinations) { destination in
                    DestinationRow(destination: destination, selected: selectedID == destination.id,
                                   disabledReason: disabledReason(destination), detail: detail(destination)) {
                        selectedID = destination.id
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                if Offloader.leavesAlias(item.path) {
                    note("An alias named “\((item.path as NSString).lastPathComponent) (offloaded)” stays where it was, so you can find it.",
                         symbol: "arrow.turn.up.right")
                } else {
                    note("No alias is left, because \(item.quit.first?.name ?? "an app") could follow it to the drive.",
                         symbol: "info.circle")
                }
                if !item.quit.isEmpty {
                    note("Headroom will quit \(item.quit.map(\.name).joined(separator: " and ")) first.", symbol: "xmark.app")
                }
                note("The original is removed only after every file is copied and checked.", symbol: "checkmark.shield")
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { onFinish(nil) }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle) { start() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.map { disabledReason($0) != nil } ?? true)
            }
        }
    }

    private func note(_ text: String, symbol: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    private var confirmTitle: String {
        let size = ByteFormat.string(item.bytes)
        guard let selected else { return "Offload" }
        return selected.isArchive
            ? "Compress, freeing \(size)"
            : "Move \(size) to \(selected.name)"
    }

    private func detail(_ destination: OffloadDestination) -> String {
        guard destination.isArchive else {
            if case .drive(_, false) = destination.kind { return destination.detail + " · stored as one archive file" }
            return destination.detail
        }
        if let saving, compresses {
            return "About \(Int((saving * 100).rounded()))% smaller, measured after · \(destination.detail)"
        }
        return destination.detail
    }

    private func disabledReason(_ destination: OffloadDestination) -> String? {
        if destination.isArchive {
            if !compresses { return "Little to gain: this is mostly data that is already compressed." }
            if let saving, saving < 0.1 { return "Little to gain: it compresses by less than 10%." }
            return nil
        }
        let needs = Int64(Double(item.bytes) * 1.05)
        if destination.available < needs {
            return "Needs \(ByteFormat.string(needs)); \(ByteFormat.string(destination.available)) free."
        }
        return nil
    }

    private func load() async {
        let path = item.path
        let found = await Task.detached(priority: .userInitiated) { Offloader.destinations() }.value
        let compressible = await Task.detached(priority: .utility) { Offloader.compresses(path) }.value
        destinations = found
        compresses = compressible
        selectedID = found.first { disabledReason($0) == nil }?.id
        if compressible {
            saving = await Offloader.estimateSaving(path)
            if selected == nil || selected.map({ disabledReason($0) != nil }) == true {
                selectedID = found.first { disabledReason($0) == nil }?.id
            }
        }
    }

    // MARK: - Running

    private var steps: [(OffloadStep, String)] {
        var out: [(OffloadStep, String)] = []
        if !item.quit.isEmpty { out.append((.quitting, "Quit \(item.quit.map(\.name).joined(separator: " and "))")) }
        out.append((.copying, selected?.isArchive == true ? "Compress into an archive" : "Copy to \(selected?.name ?? "the drive")"))
        out.append((.verifying, "Verify every file"))
        out.append((.removing, "Remove from this Mac"))
        return out
    }

    private var runningView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Offloading \(item.name)…").font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 10) {
                ForEach(steps, id: \.0) { step, title in
                    HStack(spacing: 10) {
                        OffloadStepDot(state: finishedSteps.contains(step) ? .done : current == step ? .current : .waiting)
                        Text(title)
                    }
                }
            }
            HStack {
                Spacer()
                Button(stopping ? "Stopping…" : "Stop") {
                    stopping = true
                    stopFlag.set(true)
                }
                .buttonStyle(.glass)
                .disabled(stopping || current == .removing)
            }
        }
    }

    private func start() {
        guard let destination = selected else { return }
        phase = .running
        let flag = stopFlag
        let order = steps.map(\.0)
        let before = DiskStatus.current()?.available ?? 0
        let item = item
        Task {
            do {
                let result = try await Offloader.offload(item, to: destination, progress: { step in
                    Task { @MainActor in
                        if let index = order.firstIndex(of: step) { finishedSteps.formUnion(order[..<index]) }
                        if step == .done { finishedSteps.formUnion(order) }
                        current = step
                    }
                }, shouldStop: { flag.get() })
                try? await Task.sleep(for: .milliseconds(400))
                freed = max(0, (DiskStatus.current()?.available ?? before) - before)
                record = result
            } catch {
                failure = error.localizedDescription
                freed = max(0, (DiskStatus.current()?.available ?? before) - before)
            }
            phase = .finished
        }
    }

    // MARK: - Finished

    private var finishedView: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let record {
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.isOnThisMac ? "Compressed on this Mac" : "Offloaded to \(record.volumeName ?? "the drive")")
                        .font(.title3.weight(.semibold))
                    Text("\(ByteFormat.string(freed)) freed, measured from free space before and after.")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text("Restore it from Offloaded in the Space Map.").foregroundStyle(.secondary)
                }
            } else {
                Label {
                    Text(failure ?? "The offload didn't finish.").fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            HStack {
                Spacer()
                Button("Done") { onFinish(record) }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct DestinationRow: View {
    let destination: OffloadDestination
    let selected: Bool
    let disabledReason: String?
    let detail: String
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .font(.system(size: 14))
                    .padding(.top, 1)
                Image(systemName: destination.isArchive ? "archivebox" : "externaldrive")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(destination.name)
                    Text(disabledReason ?? detail)
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(.rect)
            .background(selected ? Color.accentColor.opacity(0.1) : .clear, in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(disabledReason != nil)
        .opacity(disabledReason != nil ? 0.6 : 1)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct OffloadStepDot: View {
    enum State { case waiting, current, done }
    let state: State

    var body: some View {
        ZStack {
            Circle().fill(fill).frame(width: 16, height: 16)
            switch state {
            case .done: Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
            case .current: ProgressView().controlSize(.mini)
            case .waiting: EmptyView()
            }
        }
    }

    private var fill: Color {
        switch state {
        case .waiting: Color.primary.opacity(0.1)
        case .current: .clear
        case .done: .green
        }
    }
}

// MARK: - Offloaded list

/// Items Headroom has moved off this disk, each with Restore when its drive is connected.
struct OffloadedList: View {
    @State private var records: [OffloadRecord] = []
    @State private var confirming: OffloadRecord?
    @State private var restoring: UUID?
    @State private var restoreStep: OffloadStep?
    @State private var askKeep: OffloadRecord?
    @State private var failure: String?

    var body: some View {
        Group {
            if records.isEmpty {
                ContentUnavailableView("Nothing offloaded", systemImage: "externaldrive",
                                       description: Text("Items you offload to a drive or an archive appear here, ready to restore."))
            } else {
                List(records) { record in row(record) }
            }
        }
        .onAppear { reload() }
        .alert("Restore \(confirming?.name ?? "")?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
               presenting: confirming) { record in
            Button("Restore") { restore(record) }
            Button("Cancel", role: .cancel) {}
        } message: { record in
            Text("Needs \(ByteFormat.string(record.bytes)); \(ByteFormat.string(DiskStatus.current()?.available ?? 0)) free. It goes back to \(Paths.display(record.originalPath)).")
        }
        .alert(keepTitle, isPresented: Binding(get: { askKeep != nil }, set: { if !$0 { askKeep = nil } }),
               presenting: askKeep) { record in
            Button("Keep") {}
            Button("Delete Copy", role: .destructive) {
                do { try Offloader.deleteCopy(record) } catch { failure = error.localizedDescription }
            }
        } message: { _ in
            Text("The restored copy is verified. Keeping the other copy is a backup; deleting it frees space there.")
        }
        .alert("Couldn't restore", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private var keepTitle: String {
        guard let askKeep else { return "" }
        return askKeep.isOnThisMac ? "Keep the archive on this Mac?" : "Keep the copy on \(askKeep.volumeName ?? "the drive")?"
    }

    private func row(_ record: OffloadRecord) -> some View {
        let reachable = Offloader.isReachable(record)
        return HStack(spacing: 10) {
            Image(systemName: record.isOnThisMac ? "archivebox" : "externaldrive")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.name)
                Text(restoring == record.id ? stepTitle : reachable ? record.whereLabel
                     : "Connect \(record.volumeName ?? "the drive") to restore this.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(ByteFormat.string(record.bytes)).monospacedDigit().foregroundStyle(.secondary)
            if restoring == record.id {
                ProgressView().controlSize(.small)
            } else if reachable {
                Button("Restore…") { confirming = record }
                    .buttonStyle(.glass)
                    .disabled(restoring != nil)
            }
        }
        .padding(.vertical, 4)
    }

    private var stepTitle: String {
        switch restoreStep {
        case .copying: "Copying back…"
        case .verifying: "Verifying every file…"
        case .removing: "Removing the copy…"
        default: "Restoring…"
        }
    }

    private func restore(_ record: OffloadRecord) {
        restoring = record.id
        restoreStep = nil
        Task {
            do {
                try await Offloader.restore(record, keepCopy: true) { step in
                    Task { @MainActor in restoreStep = step }
                }
                askKeep = record
            } catch {
                failure = error.localizedDescription
            }
            restoring = nil
            reload()
        }
    }

    private func reload() { records = Offloader.records().sorted { $0.date > $1.date } }
}
