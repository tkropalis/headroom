import AppKit
import HeadroomCore
import SwiftUI

struct SpaceTable: View {
    @Bindable var model: SpaceMapModel

    var body: some View {
        Table(model.visibleNodes, selection: $model.selection) {
            TableColumn("Name") { node in
                HStack(spacing: 7) {
                    Image(nsImage: model.icon(for: node))
                        .resizable().scaledToFit().frame(width: 18, height: 18)
                    Text(node.name).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(node.path == SpaceMapModel.unmeasuredPath ? .secondary : .primary)
                    if model.plan.contains(node.path) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.headroomMint)
                            .help("In the plan")
                            .accessibilityLabel("In the plan")
                            .transition(.pop)
                    }
                }
            }
            TableColumn("Can go") { node in
                CanGoLabel(value: model.canGo(node))
                    .animation(Motion.arrive, value: model.canGo(node))
            }
            .width(min: 130, ideal: 160, max: 200)
            TableColumn("Last used") { node in
                if let date = node.lastOpened {
                    Text(RelativeDate.ago(date))
                        .foregroundStyle(RelativeDate.isUnused(date) ? Color.orange : .secondary)
                        .help(RelativeDate.shortDate(date))
                } else {
                    Text("–").foregroundStyle(.tertiary)
                }
            }
            .width(min: 90, ideal: 110, max: 140)
            TableColumn("Size") { node in
                Text(model.sizeText(node))
                    .monospacedDigit()
                    .foregroundStyle(model.pending.contains(node.path) ? .secondary : .primary)
                    .contentTransition(.numericText())
                    .animation(Motion.arrive, value: model.sizeText(node))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 80, ideal: 90, max: 120)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .onKeyPress(.space) {
            model.toggleQuickLook()
            return .handled
        }
        .onKeyPress("a") {
            withAnimation(PlanTray.travel) { model.togglePlanForSelection() }
            return .handled
        }
        .contextMenu(forSelectionType: String.self) { paths in
            if paths.count == 1, let path = paths.first, let node = model.selectableNodes.first(where: { $0.path == path }) {
                SpaceItemMenu(model: model, node: node)
            }
        } primaryAction: { paths in
            // Double-click or Return opens a folder.
            if let path = paths.first, let node = model.nodes.first(where: { $0.path == path }) { model.open(node) }
        }
        .overlay {
            if model.visibleNodes.isEmpty && !model.measuring {
                if !model.search.isEmpty {
                    ContentUnavailableView.search(text: model.search)
                } else if model.filter != .all && !model.nodes.isEmpty {
                    ContentUnavailableView("Nothing here \(model.filter == .canGo ? "can go" : "is unused")",
                                           systemImage: "line.3.horizontal.decrease.circle",
                                           description: Text("Choose All to see everything in this folder."))
                } else {
                    ContentUnavailableView("Empty folder", systemImage: "folder")
                }
            }
        }
    }
}

/// What removing a row costs: a dot and its name, or a small bar of the costs inside.
struct CanGoLabel: View {
    let value: CanGo

    var body: some View {
        switch value {
        case .cost(.unknown):
            Text("–").foregroundStyle(.tertiary).accessibilityLabel(SpaceCost.unknown.title)
        case .cost(let cost):
            HStack(spacing: 6) {
                Circle().fill(cost.tint).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(cost.title)
            }
            .help(cost.note)
        case .mixed(let breakdown):
            HStack(spacing: 6) {
                CostBar(breakdown: breakdown).frame(width: 34, height: 6)
                Text(breakdown.canGo >= 1_000_000 ? "\(ByteFormat.string(breakdown.canGo)) can go" : "Mixed")
                    .foregroundStyle(.secondary)
            }
            .help(breakdown.parts.map { "\($0.cost.title): \(ByteFormat.string($0.bytes))" }.joined(separator: "\n"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Mixed: "
                                + breakdown.parts.map { "\(ByteFormat.string($0.bytes)) \($0.cost.title)" }.joined(separator: ", "))
        }
    }
}

/// The costs inside a folder, in proportion, largest first.
struct CostBar: View {
    let breakdown: CostBreakdown

    var body: some View {
        GeometryReader { geo in
            let total = max(1, Double(breakdown.total))
            let parts = breakdown.parts
            HStack(spacing: 1) {
                ForEach(parts, id: \.cost) { part in
                    Rectangle().fill(part.cost.tint)
                        .frame(width: max(1, (geo.size.width - CGFloat(parts.count - 1)) * Double(part.bytes) / total))
                }
            }
        }
        .clipShape(.capsule)
        .accessibilityHidden(true)
    }
}

extension SpaceCost {
    /// The menu's colours: green loses nothing, blue makes the next build slower, orange is
    /// your call, sand is your own files.
    var tint: Color {
        switch self {
        case .nothingLost: .green
        case .slowerNext: .blue
        case .yourCall: .orange
        case .yourFiles: Color(red: 0.80, green: 0.69, blue: 0.52)
        case .system, .unknown: .gray
        }
    }
}
