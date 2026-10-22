import AppKit
import HeadroomCore
import SwiftUI

struct PopoverView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.screen {
            case .main: MainScreen()
            case .review: ReviewScreen()
            case .cleaning: CleaningScreen()
            case .result: ResultScreen()
            case .growth(let alert): GrowthScreen(alert: alert)
            case .onboarding(let step): OnboardingScreen(step: step)
            }
        }
        .padding(.vertical, 12)
        .frame(width: 352)
        .onAppear { model.popoverOpened() }
        .animation(.spring(duration: 0.3, bounce: 0), value: model.screen)
    }
}

// MARK: - Main

struct MainScreen: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: CandidateGroup?

    static let groups: [CandidateGroup] = [.rebuilds, .yourCall, .identical, .forgotten, .dormant]

    /// Groups that have a row right now, in the order shown.
    private var visibleGroups: [CandidateGroup] { Self.groups.filter { !model.candidates(in: $0).isEmpty } }

    /// ↑ and ↓ move between group rows, → opens one and ← closes it.
    private func move(_ step: Int) -> KeyPress.Result {
        let rows = visibleGroups
        guard !rows.isEmpty else { return .ignored }
        let index = focused.flatMap { rows.firstIndex(of: $0) } ?? (step > 0 ? -1 : rows.count)
        focused = rows[max(0, min(rows.count - 1, index + step))]
        return .handled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeadroomHeader()
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

            ForEach(model.visibleAlerts.prefix(2)) { alert in
                GrowthRow(alert: alert)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }

            Divider().padding(.horizontal, 16)
            ReadyRow()
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            Divider().padding(.horizontal, 16)

            VStack(spacing: 0) {
                ForEach(Self.groups, id: \.self) { group in
                    GroupDisclosure(group: group, focus: $focused)
                }
            }
            .padding(6)
            .onKeyPress(.downArrow) { move(1) }
            .onKeyPress(.upArrow) { move(-1) }
            .onKeyPress(.rightArrow) {
                guard let focused else { return .ignored }
                model.expandedGroup = focused
                return .handled
            }
            .onKeyPress(.leftArrow) {
                guard focused != nil else { return .ignored }
                model.expandedGroup = nil
                return .handled
            }

            Divider().padding(.horizontal, 16)
            Footer()
        }
    }
}

struct HeadroomHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(model.disk.map { ByteFormat.string($0.available) } ?? "–")
                    .font(.system(size: 26, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(model.level == .critical ? Color.red : Color.primary)
                Text("free").font(.title3).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(subLine)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(subColor)
                // Purgeable space only matters once space is short.
                if model.level != .ok, model.purgeable >= 500_000_000 {
                    Text("Plus \(ByteFormat.string(model.purgeable)) that macOS can free on its own.")
                        .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
                if let runway = model.runway {
                    Label(runway.line, systemImage: "chart.line.downtrend.xyaxis")
                        .font(.callout).monospacedDigit()
                        .foregroundStyle(runway.daysLeft <= model.runwayDays ? Color.orange : Color.secondary)
                }
            }
            CapacityBar()
        }
    }

    private var subLine: String {
        guard let disk = model.disk else { return "" }
        let total = "of \(ByteFormat.string(disk.total))"
        let warn = Int64(model.warnGB) * 1_000_000_000
        let gap = ByteFormat.wholeGB(abs(disk.available - warn))
        return disk.available >= warn
            ? "\(total) · \(gap) above your \(model.warnGB) GB warning"
            : "\(total) · \(gap) below your \(model.warnGB) GB warning"
    }

    private var subColor: Color {
        switch model.level {
        case .ok: .secondary
        case .low: .orange
        case .critical: .red
        }
    }
}

struct CapacityBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private func open(_ category: String) {
        model.spaceMap.sidebar = .category(category)
        openWindow(id: "spacemap")
    }

    static let palette: [Color] = [.blue, .purple, .orange, .teal, .yellow, .green, .gray]

    var body: some View {
        let disk = model.disk ?? DiskStatus(total: 1, available: 1)
        let categories = model.categories
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    HStack(spacing: 1) {
                        if categories.isEmpty {
                            Rectangle().fill(Color.secondary)
                                .frame(width: width * disk.usedFraction)
                        } else {
                            ForEach(Array(categories.enumerated()), id: \.offset) { index, category in
                                Rectangle()
                                    .fill(Self.palette[index % Self.palette.count].opacity(index == categories.count - 1 ? 0.45 : 0.9))
                                    .frame(width: max(1, width * Double(category.bytes) / Double(disk.total)))
                                    .help("\(category.name): \(ByteFormat.string(category.bytes)). Click to open in Space Map.")
                                    .contentShape(.rect)
                                    .onTapGesture { open(category.name) }
                            }
                        }
                    }
                    .clipShape(Capsule())
                    Rectangle()
                        .fill(Color.primary.opacity(0.55))
                        .frame(width: 2, height: 14)
                        .offset(x: width * (1 - Double(model.warnGB) * 1e9 / Double(disk.total)) - 1)
                        .help("Warning level: \(model.warnGB) GB free")
                }
            }
            .frame(height: 10)
            .animation(.spring(duration: 0.35, bounce: 0), value: disk.available)

            if !categories.isEmpty {
                FlowLegend(items: categories.enumerated().map { index, c in
                    (Self.palette[index % Self.palette.count].opacity(index == categories.count - 1 ? 0.45 : 0.9),
                     "\(c.name) \(ByteFormat.string(c.bytes))", { open(c.name) })
                })
            }
        }
        .padding(.top, 4)
    }
}

struct FlowLegend: View {
    let items: [(Color, String, () -> Void)]

    var body: some View {
        // Two columns keep the legend compact and aligned. Each entry opens the Space Map there.
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                  alignment: .leading, spacing: 1) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Button(action: item.2) {
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(item.0).frame(width: 8, height: 8)
                        Text(item.1).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .padding(.vertical, 2)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Open in Space Map")
                .accessibilityLabel("\(item.1), open in Space Map")
            }
        }
    }
}

struct GrowthRow: View {
    @Environment(AppModel.self) private var model
    let alert: GrowthAlert

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.up")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(alert.headline).fontWeight(.semibold)
                Text("Since \(RelativeDate.dateTime(alert.since)).").font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("Review") { model.openGrowth(alert) }
                .buttonStyle(.glass)
                .controlSize(.small)
        }
        .padding(10)
        .background(Color.orange.opacity(0.14), in: .rect(cornerRadius: 12))
    }
}

struct ReadyRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let ready = model.readyNow
        let blocked = model.readyBlocked
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if model.scan == nil {
                    Text("Scanning…").fontWeight(.semibold)
                    Text("Measuring caches and projects.").font(.callout).foregroundStyle(.secondary)
                } else if ready.isEmpty {
                    Text("Caches are clean").fontWeight(.semibold)
                    Text("Nothing left that can go without a cost.").font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Ready to clean").fontWeight(.semibold)
                    Text("\(ByteFormat.string(model.total(ready))) in \(ready.count) \(ready.count == 1 ? "item" : "items") · nothing lost")
                        .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
                if let first = blocked.first {
                    Text(blocked.count == 1
                         ? "\(ByteFormat.string(first.expectedBytes)) more \(first.unblockHint)."
                         : "\(ByteFormat.string(model.total(blocked))) more once \(blocked.count) items in use are free.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            if !model.candidates(in: .ready).isEmpty {
                if model.level == .ok {
                    Button("Review…") { model.openReview(.ready) }.buttonStyle(.glass)
                } else {
                    Button("Review…") { model.openReview(.ready) }.buttonStyle(.glassProminent)
                }
            }
        }
    }
}

struct GroupDisclosure: View {
    @Environment(AppModel.self) private var model
    let group: CandidateGroup
    var focus: FocusState<CandidateGroup?>.Binding

    var body: some View {
        let items = model.candidates(in: group)
        let open = model.expandedGroup == group
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    model.expandedGroup = open ? nil : group
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(open ? 90 : 0))
                        Text(group.title)
                        Spacer()
                        Text(summary(items)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .contentShape(.rect)
                    .background(open ? Color.primary.opacity(0.06) : .clear, in: .rect(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .focusable()
                .focused(focus, equals: group)
                .accessibilityAddTraits(open ? .isSelected : [])

                if open {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.note).font(.callout).foregroundStyle(.secondary)
                        ForEach(items.prefix(6)) { item in
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.name)
                                    Text(item.cost).font(.callout).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(item.sizeLabel).font(.callout).monospacedDigit()
                            }
                        }
                        if items.count > 6 {
                            Text("and \(items.count - 6) more").font(.callout).foregroundStyle(.secondary)
                        }
                        HStack {
                            Spacer()
                            Button("Review…") { model.openReview(group) }
                                .buttonStyle(.glass).controlSize(.small)
                        }
                    }
                    .padding(EdgeInsets(top: 4, leading: 28, bottom: 8, trailing: 10))
                    .transition(.opacity)
                }
            }
        }
    }

    private func summary(_ items: [Candidate]) -> String {
        let size = ByteFormat.string(model.total(items))
        let uncertain = items.contains { $0.size.sharesSpace || $0.isEstimate }
        let text = uncertain ? "up to \(size)" : size
        switch group {
        case .dormant, .forgotten: return "\(text) · \(items.count)"
        case .identical: return "\(text) · nothing deleted"
        default: return text
        }
    }
}

struct Footer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(model.scanning ? "Scanning…" : model.scan.map { "Scanned " + RelativeDate.string($0.date) } ?? "Not scanned yet")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Scan Now") { model.startScan() }
                    .buttonStyle(.glass).controlSize(.small)
                    .disabled(model.scanning)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            MenuRow(title: "Space Map…", shortcut: "") {
                model.spaceMap.sidebar = .all
                openWindow(id: "spacemap")
            }
            MenuRow(title: "Settings…", shortcut: "⌘,") {
                NSApp.activate()
                openSettings()
            }
            .keyboardShortcut(",")
            MenuRow(title: "Quit Headroom", shortcut: "⌘Q") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

struct MenuRow: View {
    let title: String
    let shortcut: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Text(shortcut).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .contentShape(.rect)
            .background(hovering ? Color.primary.opacity(0.08) : .clear, in: .rect(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, 6)
    }
}
