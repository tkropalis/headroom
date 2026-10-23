import AppKit
import HeadroomCore
import SwiftUI

/// The plan: what you picked and where each goes, free space now and after, and what you'd
/// lose. Things can be dropped on it. Nothing happens until Review Plan.
struct PlanTray: View {
    @Bindable var model: SpaceMapModel
    let namespace: Namespace.ID
    @State private var targeted = false
    @State private var chipsHeight: CGFloat = 30

    var body: some View {
        let plan = model.plan
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Plan").font(.headline)
                Text(plan.isEmpty ? "Press A or drag items here" : "\(plan.items.count) \(plan.items.count == 1 ? "item" : "items") · nothing happens until you review")
                    .foregroundStyle(.secondary)
                Spacer()
                if !plan.isEmpty {
                    Button("Review Plan…") { model.reviewingPlan = true }
                        .buttonStyle(.glassProminent)
                        .tint(Color.headroomTeal)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
            if !plan.isEmpty {
                ScrollView {
                    FlowLayout(spacing: 8) {
                        ForEach(plan.items) { item in
                            PlanChip(model: model, item: item)
                                .matchedGeometryEffect(id: "chip:" + item.path, in: namespace)
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { chipsHeight = $0 }
                }
                // Two rows show; more scroll.
                .frame(height: min(max(chipsHeight, 28), 70))
                .scrollBounceBehavior(.basedOnSize)

                FreeMeter(now: model.disk?.available ?? 0, plan: plan, warning: model.warningBytes())
                if let first = model.planFacts.first {
                    // The most important fact; the review lists them all.
                    Label(first.text, systemImage: first.isWarning ? "exclamationmark.triangle" : "info.circle")
                        .font(.callout)
                        .foregroundStyle(first.isWarning ? Color.orange : .secondary)
                        .lineLimit(2)
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassEffect(.regular.tint(Color(nsColor: .windowBackgroundColor).opacity(0.5)), in: .rect(cornerRadius: 20))
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 20).strokeBorder(Color.headroomMint, lineWidth: 2)
            }
        }
        .dropDestination(for: String.self) { drops, _ in
            // A dragged selection arrives as one string, a path per line.
            let paths = Set(drops.flatMap { $0.split(separator: "\n").map(String.init) })
            let rows = model.selectableNodes.filter { paths.contains($0.path) }
            withAnimation(PlanTray.travel) { model.addToPlan(rows) }
            return !rows.isEmpty
        } isTargeted: { targeted = $0 }
        .animation(PlanTray.travel, value: plan.items.map(\.path))
        .animation(PlanTray.travel, value: plan.isEmpty)
        .animation(Motion.respond, value: targeted)
    }

    /// Picking something up and putting it in the tray: a little bounce, since it was moved by hand.
    static let travel = Animation.spring(response: 0.35, dampingFraction: 0.8)
}

/// One planned item: its icon, name, size and where it goes. Click to change where, or take it out.
struct PlanChip: View {
    let model: SpaceMapModel
    let item: PlanItem

    var body: some View {
        Menu {
            Picker("Where it goes", selection: Binding(get: { item.destination },
                                                     set: { value in withAnimation(Motion.respond) { model.plan.setDestination(value, for: item.path) } })) {
                ForEach(model.planDestinations(for: item.path), id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Show in Map") { model.reveal(item.path) }
            Button("Remove from Plan") { withAnimation(PlanTray.travel) { model.removeFromPlan(item.path) } }
        } label: {
            HStack(spacing: 6) {
                Image(nsImage: model.icon(path: item.path)).resizable().scaledToFit().frame(width: 16, height: 16)
                Text(item.name).lineLimit(1)
                Text(ByteFormat.string(item.bytes)).fontWeight(.semibold).monospacedDigit()
                Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                Text(item.destination.title).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.08), in: .capsule)
            .contentShape(.capsule)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("\(item.name) goes to \(item.destination.title). \(item.destination.note)")
    }
}

/// Free now to free after, with the warning level marked. The Bin's share is striped: it comes
/// back only when the Bin is emptied.
struct FreeMeter: View {
    let now: Int64
    let plan: CleanupPlan
    let warning: Int64

    var body: some View {
        let after = now + plan.total
        HStack(alignment: .bottom, spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Free now").font(.caption).foregroundStyle(.secondary)
                Text(ByteFormat.string(now)).font(.title2.weight(.semibold)).monospacedDigit()
                    .contentTransition(.numericText())
            }
            GeometryReader { geo in
                let scale = Double(max(after, warning) ) * 1.15
                let x = { (bytes: Int64) in geo.size.width * Double(bytes) / max(scale, 1) }
                let kept = plan.total - plan.binBytes
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    HStack(spacing: 0) {
                        Rectangle().fill(DiskSwatch.free).frame(width: x(now))
                        Rectangle().fill(Color.headroomMint).frame(width: x(kept))
                        HatchedFill().foregroundStyle(Color.headroomMint).frame(width: x(plan.binBytes))
                            .overlay(Rectangle().fill(Color.headroomMint.opacity(0.35)))
                    }
                    .clipShape(.capsule)
                    // The warning level.
                    Rectangle().fill(Color.orange).frame(width: 2, height: 14).offset(x: x(warning) - 1)
                    Text("\(ByteFormat.string(warning)) warning")
                        .font(.caption2).foregroundStyle(.orange)
                        .fixedSize()
                        .offset(x: x(warning) - 30, y: 16)
                }
                .frame(height: 8)
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 36)
            VStack(alignment: .trailing, spacing: 0) {
                Text("Free after").font(.caption).foregroundStyle(.secondary)
                Text(ByteFormat.string(after)).font(.title2.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(Color.headroomMint)
                    .contentTransition(.numericText())
            }
        }
        // The bar fills and the numbers roll as things are added or taken out.
        .animation(PlanTray.travel, value: plan.total)
        .animation(PlanTray.travel, value: plan.binBytes)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Free now \(ByteFormat.string(now)), free after the plan \(ByteFormat.string(after))")
    }
}

/// Lays chips out in rows, wrapping when a row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, width: width)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: width.isFinite ? width : rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty && rows[rows.count - 1].width + spacing + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
