import AppKit
import HeadroomCore
import SwiftUI

/// Every planned item and where it goes, what the plan costs, and one button that names the
/// total. Running it goes through Headroom's usual paths; the results are measured on the disk.
struct PlanReviewSheet: View {
    @Bindable var model: SpaceMapModel
    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .review
    @State private var outcomes: [String: CleanupOutcome] = [:]
    @State private var running: String?
    /// The plan as it was when it started running.
    @State private var ran: CleanupPlan?

    enum Phase { case review, running, done }

    var body: some View {
        let plan = ran ?? model.plan
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.weight(.bold))
                Text(subtitle(plan)).foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(Motion.arrive, value: outcomes.count)
            }

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(plan.items) { item in
                        row(item)
                        if item.id != plan.items.last?.id { Divider() }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 12)
            .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 14))

            if phase != .done && !model.planFacts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.planFacts) { fact in
                        Label(fact.text, systemImage: fact.isWarning ? "exclamationmark.triangle.fill" : "info.circle")
                            .foregroundStyle(fact.isWarning ? Color.orange : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.callout)
            }

            HStack {
                if phase == .done, let putBack = putBackOutcomes, !putBack.isEmpty {
                    Button("Put Back from Bin") { putBack.forEach(model.putBack); dismiss() }
                        .help("Moves what went to the Bin back where it was.")
                }
                Spacer()
                switch phase {
                case .review:
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Move \(plan.items.count) \(plan.items.count == 1 ? "Item" : "Items") · \(ByteFormat.string(plan.total))") { run() }
                        .buttonStyle(.glassProminent)
                        .tint(Color.headroomTeal)
                        .keyboardShortcut(.defaultAction)
                case .running:
                    ProgressView().controlSize(.small)
                    Text("Working…").foregroundStyle(.secondary)
                case .done:
                    Button("Done") { dismiss() }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 600, height: 560)
        .interactiveDismissDisabled(phase == .running)
        .animation(Motion.arrive, value: outcomes.count)
        .animation(Motion.respond, value: phase)
    }

    private var title: String {
        switch phase {
        case .review: "Review Plan"
        case .running: "Running the Plan"
        case .done: "Plan Done"
        }
    }

    private func subtitle(_ plan: CleanupPlan) -> String {
        switch phase {
        case .review:
            return "\(plan.items.count) \(plan.items.count == 1 ? "item" : "items") · \(ByteFormat.string(plan.total)). Nothing has happened yet."
        case .running:
            return "\(outcomes.count) of \(plan.items.count) done."
        case .done:
            let freed = outcomes.values.reduce(Int64(0)) { $0 + $1.freed }
            let inBin = outcomes.values.filter { $0.inBin && $0.freed == 0 }.reduce(Int64(0)) { $0 + ($1.expected ?? 0) }
            var text = "Freed \(ByteFormat.string(freed)), measured on the disk."
            if inBin > 0 { text += " \(ByteFormat.string(inBin)) more when you empty the Bin." }
            return text
        }
    }

    @ViewBuilder private func row(_ item: PlanItem) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: model.icon(path: item.path)).resizable().scaledToFit().frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).lineLimit(1)
                Text(detail(item)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(ByteFormat.string(item.bytes)).monospacedDigit()
            Group {
                switch phase {
                case .review:
                    Picker("Where it goes", selection: Binding(get: { model.plan.item(item.path)?.destination ?? item.destination },
                                                             set: { model.plan.setDestination($0, for: item.path) })) {
                        ForEach(model.planDestinations(for: item.path), id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                case .running, .done:
                    status(item)
                }
            }
            .frame(width: 150, alignment: .trailing)
        }
        .padding(.vertical, 8)
    }

    private func detail(_ item: PlanItem) -> String {
        if let outcome = outcomes[item.path], let message = outcome.message { return message }
        let quits = model.quits(for: item.path).filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleID).isEmpty }
        if !quits.isEmpty { return "Quits \(quits.map(\.name).joined(separator: " and ")) first · " + Paths.display(item.path) }
        return Paths.display(item.path)
    }

    @ViewBuilder private func status(_ item: PlanItem) -> some View {
        if let outcome = outcomes[item.path] {
            StatusLabel(outcome: outcome, item: item)
                .transition(.pop)
        } else if running == item.path {
            ProgressView().controlSize(.small).transition(.opacity)
        } else {
            Text("Waiting").foregroundStyle(.tertiary)
        }
    }

    private var putBackOutcomes: [CleanupOutcome]? {
        let list = outcomes.values.filter { $0.restorable != nil && model.canPutBack($0) }
        return list.isEmpty ? nil : list
    }

    private func run() {
        let plan = model.plan
        ran = plan
        phase = .running
        running = plan.items.first?.path
        Task {
            _ = await model.runPlan(plan) { item, outcome in
                withAnimation(Motion.arrive) {
                    outcomes[item.path] = outcome
                    let index = plan.items.firstIndex { $0.path == item.path } ?? 0
                    running = index + 1 < plan.items.count ? plan.items[index + 1].path : nil
                }
                // Done items leave the plan; skipped and failed ones stay for another try.
                if outcome.state == .done { withAnimation(PlanTray.travel) { model.plan.remove(item.path) } }
            }
            withAnimation(Motion.respond) {
                running = nil
                phase = .done
            }
            model.refresh()
        }
    }
}

/// How one item ended: where it went or what it freed, with a tick that bounces as it lands.
private struct StatusLabel: View {
    let outcome: CleanupOutcome
    let item: PlanItem
    @State private var landed = false

    var body: some View {
        Label(text, systemImage: outcome.state == .done ? "checkmark.circle.fill" : "xmark.circle")
            .foregroundStyle(outcome.state == .done ? Color.headroomMint : .secondary)
            .symbolEffect(.bounce, value: landed)
            .onAppear { landed = true }
    }

    private var text: String {
        guard outcome.state == .done else { return outcome.resultLabel }
        if outcome.inBin && outcome.freed == 0 { return "In the Bin" }
        return item.destination.isBin ? ByteFormat.string(outcome.freed) : "On \(item.destination.title)"
    }
}
