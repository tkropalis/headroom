import AppKit
import HeadroomCore
import SwiftUI

struct ScreenTitle: View {
    @Environment(AppModel.self) private var model
    let title: String
    var back = true

    var body: some View {
        HStack(spacing: 6) {
            if back {
                Button { model.screen = .main } label: {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                .keyboardShortcut(.cancelAction)
            }
            Text(title).font(.headline)
        }
        .padding(.horizontal, back ? 10 : 16)
        .padding(.bottom, 8)
    }
}

// MARK: - Review

struct ReviewScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenTitle(title: "Review: \(model.reviewGroup.title)")
            Text(model.reviewGroup == .yourCall
                 ? "Ticked items go to the Bin. Nothing moves until you confirm."
                 : "Nothing is removed until you confirm below.")
                .font(.callout).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.bottom, 6)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.reviewItems) { item in ReviewRow(item: item) }
                }
                .padding(.horizontal, 6)
            }
            .frame(maxHeight: 420)
            .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.horizontal, 16).padding(.top, 6)
            VStack(alignment: .trailing, spacing: 10) {
                Text(selectionLine)
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Button("Cancel") { model.screen = .main }
                        .buttonStyle(.glass)
                    Button(model.confirmTitle) { model.cleanSelection() }
                        .buttonStyle(.glassProminent)
                        .disabled(model.selectedItems.isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(EdgeInsets(top: 10, leading: 16, bottom: 4, trailing: 16))
        }
    }

    private var selectionLine: String {
        let items = model.selectedItems
        guard !items.isEmpty else { return "Nothing selected" }
        return "\(ByteFormat.string(model.total(items))) selected in \(items.count) \(items.count == 1 ? "item" : "items")"
    }
}

struct ReviewRow: View {
    @Environment(AppModel.self) private var model
    let item: Candidate

    var body: some View {
        let status = model.status(of: item)
        let checked = model.selection.contains(item.id)
        Toggle(isOn: Binding(get: { checked }, set: { _ in model.toggle(item) })) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.name)
                    Spacer()
                    Text(item.sizeLabel).monospacedDigit()
                }
                Text(item.cost).font(.callout).foregroundStyle(.secondary)
                Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                if item.size.sharesSpace {
                    Text("Some of this is shared with copies elsewhere. The real gain is measured after cleaning.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let note = status.note {
                    Label(note, systemImage: status.isBlocked ? "pause.circle" : "exclamationmark.circle")
                        .font(.callout)
                        .foregroundStyle(status.isBlocked ? Color.secondary : Color.orange)
                }
            }
        }
        .toggleStyle(.checkbox)
        .disabled(status.isBlocked)
        .opacity(status.isBlocked ? 0.65 : 1)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(checked ? Color.accentColor.opacity(0.08) : .clear, in: .rect(cornerRadius: 8))
    }
}

// MARK: - Cleaning

struct CleaningScreen: View {
    @Environment(AppModel.self) private var model
    @State private var stopping = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cleaning…").font(.headline).padding(.horizontal, 16)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(model.reviewItems.enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: 10) {
                        StepDot(state: state(index))
                        Text(item.name).frame(maxWidth: .infinity, alignment: .leading)
                        Text(statusText(index, item)).font(.callout).monospacedDigit()
                            .foregroundStyle(index < model.outcomes.count ? Color.green : .secondary)
                    }
                }
            }
            .padding(.horizontal, 16)
            HStack {
                Spacer()
                Button(stopping ? "Stopping…" : "Stop after this item") {
                    stopping = true
                    model.stopCleaning()
                }
                .buttonStyle(.glass)
                .disabled(stopping)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
    }

    private func state(_ index: Int) -> StepDot.State {
        if index < model.outcomes.count { return model.outcomes[index].state == .done ? .done : .failed }
        return index == model.cleaningIndex ? .current : .waiting
    }

    private func statusText(_ index: Int, _ item: Candidate) -> String {
        if index < model.outcomes.count { return model.outcomes[index].resultLabel }
        return index == model.cleaningIndex ? "Cleaning…" : "Waiting"
    }
}

struct StepDot: View {
    enum State { case waiting, current, done, failed }
    let state: State

    var body: some View {
        ZStack {
            Circle().fill(fill).frame(width: 16, height: 16)
            switch state {
            case .done: Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
            case .failed: Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
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
        case .failed: .orange
        }
    }
}

// MARK: - Result

struct ResultScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Freed \(ByteFormat.string(model.freedTotal))")
                    .font(.system(size: 22, weight: .semibold)).monospacedDigit()
                Text("\(model.disk.map { ByteFormat.string($0.available) } ?? "–") free now · measured from free space before and after")
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.outcomes) { outcome in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(outcome.name)
                            Spacer()
                            Text(outcome.resultLabel)
                                .monospacedDigit()
                                .foregroundStyle(outcome.state != .done ? Color.orange : outcome.inBin ? .secondary : .green)
                        }
                        if let message = outcome.message {
                            Text(message).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done") { model.screen = .main }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - Growth

struct GrowthScreen: View {
    @Environment(AppModel.self) private var model
    let alert: GrowthAlert

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenTitle(title: alert.name)
            VStack(alignment: .leading, spacing: 12) {
                Text(Paths.display(alert.path)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                HStack(spacing: 10) {
                    Stat(label: RelativeDate.dateTime(alert.since), value: alert.previous == 0 ? "None" : ByteFormat.string(alert.previous))
                    Stat(label: "Now", value: ByteFormat.string(alert.current))
                }
                if alert.sharesSpace {
                    Text("Part of this is files sharing space with copies, so Finder may show more than deleting would give back. Headroom measures the real gain after cleaning.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let match = model.candidate(for: alert)
                if let match {
                    Text("\(match.name): \(match.cost)").font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Spacer()
                    Button("Ignore") { model.dismiss(alert) }.buttonStyle(.glass)
                    if let match {
                        Button("Review cleanup") { model.openReview(match.group, preselect: [match.id]) }
                            .buttonStyle(.glassProminent)
                    } else {
                        Button("Show in Finder") { model.reveal(alert.path) }.buttonStyle(.glassProminent)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

struct Stat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 10))
    }
}
