import AppKit
import HeadroomCore
import SwiftUI

/// The selected row, or a summary of the folder when nothing is selected.
struct SpaceInspector: View {
    let model: SpaceMapModel
    @State private var confirmTrash = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                content
            }
            // What the inspector shows changes with a soft cross-fade and a small rise.
            .id(model.selection)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 6)), removal: .opacity))
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(Motion.respond, value: model.selection)
    }

    @ViewBuilder private var content: some View {
                if let node = model.selectedNode {
                    switch node.path {
                    case SpaceMapModel.unmeasuredPath: unmeasured(node)
                    case SpaceMapModel.volumesPath: volumes(node)
                    case let path where path.hasPrefix("headroom:"): group(node)
                    default: details(node)
                    }
                } else if model.selection.count > 1 {
                    several(model.selectedNodes)
                } else {
                    summary
                }
    }

    // MARK: Selected row

    @ViewBuilder private func details(_ node: SpaceNode) -> some View {
        let candidate = model.candidateFor(node.path)
        let value = model.canGo(node)
        Header(icon: model.icon(for: node), title: node.name, subtitle: Paths.display(node.path), size: model.sizeText(node))

        VStack(alignment: .leading, spacing: 10) {
            switch value {
            case .cost(let cost):
                if cost != .unknown { CostChip(cost: cost) }
                Text(candidate?.cost ?? node.kind.map(Self.knowledge) ?? cost.note)
            case .mixed(let breakdown):
                CostLegend(breakdown: breakdown, title: "\(breakdown.count) measured folders inside")
            }
            if node.sharesSpace {
                Text("Deleting this gives back about \(ByteFormat.string(node.reclaimable)); the rest is shared with copies elsewhere.")
                    .foregroundStyle(.secondary)
            }
            if let line = facts(node) {
                Text(line).foregroundStyle(.secondary)
            }
            if let delta = model.growth[node.path] {
                Label("Grew \(ByteFormat.string(delta)) since \(model.since.title.lowercased())", systemImage: "arrow.up.right")
                    .foregroundStyle(.secondary)
            }
            if let reason = model.inUse[node.path], reason != model.blockerFor(node.path) {
                Label(reason, systemImage: "pause.circle").foregroundStyle(.secondary)
            }
            if let candidate, candidate.id.hasPrefix("learned:") {
                HStack {
                    Text("Added from \(Helper.name)'s answer.").foregroundStyle(.secondary)
                    Button("Take Off the List") { model.claude.setOnList(node.path, false) }
                        .buttonStyle(.link)
                }
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)

        actions(node, candidate: candidate, value: value)

        if candidate == nil {
            ClaudeAnswerView(node: node, hooks: model.claude)
        }
    }

    private func facts(_ node: SpaceNode) -> String? {
        var parts: [String] = []
        if let date = node.lastOpened { parts.append("Last used " + RelativeDate.ago(date).lowercased()) }
        if let candidate = model.candidateFor(node.path), candidate.paths.contains(node.path) { parts.append(candidate.name) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private enum Action { case addToPlan, clean(Candidate), open, offload, trash }

    /// One main action, Show in Finder, and the rest in a menu. Nothing is shown greyed out.
    @ViewBuilder private func actions(_ node: SpaceNode, candidate: Candidate?, value: CanGo) -> some View {
        // Folders Headroom never moves can't be blocked by anything; a process somewhere inside
        // your Library would only confuse.
        let blocker = PathSafety.isDeletable(node.path) ? model.blockerFor(node.path) : nil
        let available = availableActions(node, candidate: candidate, value: value, blocker: blocker)

        VStack(alignment: .leading, spacing: 8) {
            if let blocker { Reason(text: blocker) }
            if let item = model.plan.item(node.path) {
                whereItGoes(item)
                Button("Remove from Plan") { withAnimation(PlanTray.travel) { model.removeFromPlan(node.path) } }
                    .buttonStyle(.glass)
            } else if let first = available.first {
                button(first, node: node).buttonStyle(.glassProminent).tint(Color.headroomTeal)
            } else if blocker == nil && !PathSafety.isDeletable(node.path) {
                Reason(text: "Headroom never moves this folder.")
            }
            HStack(spacing: 8) {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
                }
                .buttonStyle(.glass)
                let more = model.plan.contains(node.path) ? available.filter { if case .addToPlan = $0 { false } else { true } }
                                                          : Array(available.dropFirst())
                if !more.isEmpty {
                    Menu {
                        ForEach(Array(more.enumerated()), id: \.offset) { _, action in
                            button(action, node: node)
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                    .menuIndicator(.hidden)
                    .buttonStyle(.glass)
                    .fixedSize()
                }
            }
        }
        .controlSize(.large)
        .confirmationDialog("Move \(node.name) to the Bin?", isPresented: $confirmTrash) {
            Button("Move to Bin") { model.onTrash(node) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Empty the Bin to free \(ByteFormat.string(node.reclaimable)). Until then you can put it back.")
        }
    }

    /// Cheap things go to the Bin first; anything that loses something is offered for a drive first.
    private func availableActions(_ node: SpaceNode, candidate: Candidate?, value: CanGo, blocker: String?) -> [Action] {
        guard blocker == nil else { return [] }
        var out: [Action] = []
        if model.planRefusal(node) == nil { out.append(.addToPlan) }
        let canOffload = model.offloadBlocker(node.path) == nil
        let canTrash = PathSafety.isDeletable(node.path)
        let cheap: Bool = if case .cost(let cost) = value { [.nothingLost, .slowerNext].contains(cost) } else { false }
        if let candidate { out.append(.clean(candidate)) }
        if case .mixed = value, node.isDirectory { out.append(.open) }
        if cheap && canTrash { out.append(.trash) }
        if canOffload { out.append(.offload) }
        if !cheap && canTrash { out.append(.trash) }
        return out
    }

    private func button(_ action: Action, node: SpaceNode) -> Button<Text> {
        switch action {
        case .addToPlan: Button("Add to Plan") { withAnimation(PlanTray.travel) { _ = model.addToPlan([node]) } }
        case .clean(let candidate): Button("Clean…") { model.onClean(candidate) }
        case .open: Button("Open") { model.open(node) }
        case .offload: Button("Offload…") { model.onOffload(node) }
        case .trash: Button("Move to Bin…") { confirmTrash = true }
        }
    }

    /// The places a planned item can go, as cards; the chosen one is lit.
    @ViewBuilder private func whereItGoes(_ item: PlanItem) -> some View {
        Text("Where it goes").font(.callout.weight(.semibold)).padding(.top, 4)
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(model.planDestinations(for: item.path), id: \.self) { destination in
                let chosen = destination == item.destination
                Button { withAnimation(Motion.respond) { model.plan.setDestination(destination, for: item.path) } } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Image(systemName: TileLabels.symbol(destination)).font(.title3)
                            .foregroundStyle(chosen ? Color.headroomMint : .secondary)
                        Text(destination.title).font(.callout.weight(.semibold)).lineLimit(1)
                        Text(destination.note).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
                    .background(chosen ? Color.headroomMint.opacity(0.14) : Color.primary.opacity(0.05), in: .rect(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(chosen ? Color.headroomMint : .clear, lineWidth: 1.5))
                    .contentShape(.rect(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        if let reason = item.reason {
            Text(reason).font(.callout).foregroundStyle(.secondary)
        }
    }

    /// A place or kind row: what it holds, and the way in.
    @ViewBuilder private func group(_ node: SpaceNode) -> some View {
        Header(icon: model.icon(for: node), title: node.name, subtitle: nil, size: model.sizeText(node))
        if let breakdown = model.breakdowns[node.path] {
            CostLegend(breakdown: breakdown, title: "\(breakdown.count) measured folders").font(.callout)
        }
        Button("Open") { model.open(node) }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
    }

    @ViewBuilder private func unmeasured(_ node: SpaceNode) -> some View {
        Header(icon: model.icon(for: node), title: "Not measured", subtitle: nil, size: model.sizeText(node))
        VStack(alignment: .leading, spacing: 8) {
            Text("Space in use that no measured folder accounts for:")
            Label("System data Headroom can't read, such as macOS's own caches and logs.", systemImage: "gearshape")
            Label("Purgeable space, such as Time Machine snapshots, which macOS frees on its own when the disk runs low.",
                  systemImage: "clock.arrow.circlepath")
            if !model.hasFullDiskAccess() {
                Label("Folders skipped without Full Disk Access.", systemImage: "lock")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        if !model.hasFullDiskAccess() {
            Button("Open Privacy Settings…") { model.openFullDiskAccess() }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
        }
    }

    @ViewBuilder private func volumes(_ node: SpaceNode) -> some View {
        Header(icon: model.icon(for: node), title: node.name, subtitle: nil, size: model.sizeText(node))
        CostChip(cost: .system)
        Text("macOS keeps its system, startup and recovery volumes beside your data. No app can clean them.")
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Several selected

    @ViewBuilder private func several(_ nodes: [SpaceNode]) -> some View {
        let total = nodes.reduce(Int64(0)) { $0 + $1.allocated }
        Header(icon: NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil) ?? NSImage(),
               title: "\(nodes.count) items", subtitle: nil, size: ByteFormat.string(total))
        let breakdown = Self.breakdown(nodes, model: model)
        if breakdown.total > 0 {
            CostLegend(breakdown: breakdown, title: "What removing them costs").font(.callout)
        }
        let busy = nodes.filter { model.inUse[$0.path] != nil }
        if !busy.isEmpty {
            Label("\(busy.map(\.name).joined(separator: ", ")) \(busy.count == 1 ? "is" : "are") in use.",
                  systemImage: "pause.circle")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        let real = nodes.filter { !$0.path.hasPrefix("headroom:") }
        if !real.isEmpty {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(real.map { URL(fileURLWithPath: $0.path) })
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        }
    }

    static func breakdown(_ nodes: [SpaceNode], model: SpaceMapModel) -> CostBreakdown {
        var bytes: [SpaceCost: Int64] = [:]
        for node in nodes {
            switch model.canGo(node) {
            case .cost(let cost): bytes[cost, default: 0] += node.allocated
            case .mixed(let breakdown): for part in breakdown.parts { bytes[part.cost, default: 0] += part.bytes }
            }
        }
        return CostBreakdown(bytes: bytes, count: nodes.count)
    }

    // MARK: Nothing selected

    @ViewBuilder private var summary: some View {
        let total = model.nodes.reduce(Int64(0)) { $0 + $1.allocated }
        Header(icon: locationIcon, title: model.title, subtitle: model.currentPath.map(Paths.display),
               size: ByteFormat.string(total))

        let breakdown = model.listedBreakdown
        if breakdown.total > 0 {
            CostLegend(breakdown: breakdown, title: "\(model.nodes.count) items", unmeasured: model.listedUnmeasured)
                .font(.callout)
        }

        if model.location == .disk, !model.hasFullDiskAccess() {
            VStack(alignment: .leading, spacing: 8) {
                Text("Without Full Disk Access, some folders can't be measured.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Open Privacy Settings…") { model.openFullDiskAccess() }.buttonStyle(.glass)
            }
        }

        HStack(spacing: 10) {
            if model.measuring {
                ProgressView().controlSize(.small)
                Text("Measuring…")
            } else if let date = model.measuredAt {
                Text("Measured " + RelativeDate.string(date))
            }
            Spacer()
            if model.canMeasureAgain {
                Button("Measure Again") { model.measureAgain() }.buttonStyle(.glass)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)

        Text("Select an item to see what removing it costs.")
            .font(.callout)
            .foregroundStyle(.tertiary)
    }

    private var locationIcon: NSImage {
        if let path = model.currentPath { return NSWorkspace.shared.icon(forFile: path) }
        let symbol = switch model.location {
        case .place(let place): place == .macOS ? "apple.logo" : place == .temporary ? "clock.arrow.circlepath" : "shippingbox"
        case .kind(let name): SpaceSidebar.symbol(for: name)
        case .kinds: "square.grid.2x2"
        default: "internaldrive"
        }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage()
    }

    static func knowledge(_ kind: SpaceKind) -> String {
        switch kind {
        case .cache: "A cache Headroom knows. Its contents come back when needed."
        case .buildOutput: "Build output. Rebuilt on the next build."
        case .dependencies: "Installed packages. The package manager installs them again when needed."
        case .project: "A code project. Its dependencies and build output can go when you aren't working on it."
        case .appData: "Data an app keeps. Quit the app before moving it."
        case .app: "An application."
        case .emulator: "An Android emulator, with its apps, data and snapshots."
        case .simulator: "An iOS simulator and the test apps installed in it."
        case .forgotten: "Not opened for 6 months."
        }
    }
}

/// Icon, name, where it is, and its size, large.
private struct Header: View {
    let icon: NSImage
    let title: String
    let subtitle: String?
    let size: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(nsImage: icon)
                .resizable().scaledToFit()
                .frame(width: 56, height: 56)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title2.weight(.bold)).lineLimit(3)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(size)
                .font(.system(size: 30, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(Motion.arrive, value: size)
        }
    }
}

/// The cost of removing something, as a tinted capsule.
struct CostChip: View {
    let cost: SpaceCost

    var body: some View {
        Text(cost.title)
            .font(.callout.weight(.semibold))
            .foregroundStyle(cost.tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(cost.tint.opacity(0.16), in: .capsule)
    }
}

/// A bar of the costs inside, then each cost with its size.
struct CostLegend: View {
    let breakdown: CostBreakdown
    let title: String
    /// Space no folder accounts for, listed apart so it isn't mistaken for folders Headroom doesn't know.
    var unmeasured: Int64 = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).foregroundStyle(.secondary)
            CostBar(breakdown: breakdown).frame(height: 8)
            ForEach(SpaceCost.allCases.filter { (breakdown.bytes[$0] ?? 0) > 0 }, id: \.self) { cost in
                HStack(spacing: 7) {
                    Circle().fill(cost.tint).frame(width: 7, height: 7).accessibilityHidden(true)
                    Text(cost.title)
                    Spacer()
                    Text(ByteFormat.string(breakdown.bytes[cost] ?? 0)).monospacedDigit().foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            if unmeasured > 0 {
                HStack(spacing: 7) {
                    HatchedFill().frame(width: 7, height: 7).clipShape(.circle).accessibilityHidden(true)
                    Text("Not measured")
                    Spacer()
                    Text(ByteFormat.string(unmeasured)).monospacedDigit().foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private struct Reason: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "info.circle")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
