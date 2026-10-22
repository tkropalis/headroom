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
                ForEach([CandidateGroup.rebuilds, .yourCall, .dormant], id: \.self) { group in
                    GroupDisclosure(group: group)
                }
            }
            .padding(6)

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
            Text(subLine)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(subColor)
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
                                    .help("\(category.name): \(ByteFormat.string(category.bytes))")
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
                     "\(c.name) \(ByteFormat.string(c.bytes))")
                })
            }
        }
        .padding(.top, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Int(disk.usedFraction * 100)) percent used")
    }
}

struct FlowLegend: View {
    let items: [(Color, String)]

    var body: some View {
        // Two columns keep the legend compact and aligned.
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                  alignment: .leading, spacing: 3) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(item.0).frame(width: 8, height: 8)
                    Text(item.1).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
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
        return group == .dormant ? "\(text) · \(items.count)" : text
    }
}

struct Footer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

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
