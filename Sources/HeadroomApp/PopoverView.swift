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
            case .helper: HelperScreen()
            case .ask(let path): AskScreen(path: path)
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

            if model.notesOn, let note = model.summaryNote {
                HelperNote(text: note)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }

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
                Spacer(minLength: 0)
                if let disk = model.disk {
                    FreeGauge(free: Double(disk.available) / Double(max(disk.total, 1)),
                              warning: Double(model.warnGB) * 1e9 / Double(max(disk.total, 1)),
                              level: model.level)
                        .frame(width: 54, height: 30)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                }
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
        model.spaceMap.show(kind: category)
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
                    .fixedSize(horizontal: false, vertical: true)
                Text("Since \(RelativeDate.dateTime(alert.since)).").font(.callout).foregroundStyle(.secondary)
                if let note = model.growthNotes[alert.path] {
                    Text(note).font(.callout).foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(note)
                }
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
        HStack(spacing: 10) {
            if model.scan != nil, ready.isEmpty {
                Graphic(name: .allClean, size: 40)
            } else {
                GroupIcon(group: .ready, dimmed: model.scan == nil)
            }
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
                    HStack(spacing: 10) {
                        GroupIcon(group: group)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(group.title)
                            Text(group.hint).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Text(summary(items)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(.rect)
                    .background(rowFill(open: open), in: .rect(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .focusable()
                .focusEffectDisabled()
                .focused(focus, equals: group)
                .accessibilityAddTraits(open ? .isSelected : [])

                if open {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.note).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(items.prefix(6)) { item in
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.name)
                                    Text(item.cost).font(.callout).foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .help(item.cost)
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
                    .padding(EdgeInsets(top: 4, leading: 40, bottom: 8, trailing: 10))
                    .transition(.opacity)
                }
            }
        }
    }

    /// Keyboard focus shows as a soft accent fill, in place of the system's square ring.
    private func rowFill(open: Bool) -> Color {
        if focus.wrappedValue == group { return Color.accentColor.opacity(0.16) }
        return open ? Color.primary.opacity(0.06) : .clear
    }

    private func summary(_ items: [Candidate]) -> String {
        let size = ByteFormat.string(model.total(items))
        let uncertain = items.contains { $0.size.sharesSpace || $0.isEstimate }
        let text = uncertain ? "up to \(size)" : size
        switch group {
        case .dormant, .forgotten: return "\(text) · \(items.count)"
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

            MenuRow(title: "Ask \(Helper.name)…", symbol: "text.bubble", shortcut: "") { model.screen = .helper }
            MenuRow(title: "Space Map…", symbol: "square.grid.3x3.square", shortcut: "") {
                model.spaceMap.showDisk()
                openWindow(id: "spacemap")
            }
            MenuRow(title: "Settings…", symbol: "gearshape", shortcut: "⌘,") {
                NSApp.activate()
                openSettings()
            }
            .keyboardShortcut(",")
            MenuRow(title: "Quit Headroom", symbol: "power", shortcut: "⌘Q") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

struct MenuRow: View {
    let title: String
    var symbol: String? = nil
    let shortcut: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol)
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                }
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

// MARK: - Groups

extension CandidateGroup {
    var symbol: String {
        switch self {
        case .ready: "checkmark.circle.fill"
        case .rebuilds: "arrow.clockwise.circle.fill"
        case .yourCall: "hand.raised.circle.fill"
        case .identical: "equal.circle.fill"
        case .forgotten: "clock.circle.fill"
        case .dormant: "moon.circle.fill"
        }
    }

    /// Green costs nothing, blue a slower start, orange something you may want.
    var tint: Color {
        switch self {
        case .ready: .green
        case .rebuilds: .blue
        case .yourCall: .orange
        case .identical: .purple
        case .forgotten: .brown
        case .dormant: .indigo
        }
    }

    /// What it costs, short enough for one line under the group's name.
    var hint: String {
        switch self {
        case .ready: "Nothing lost"
        case .rebuilds: "Nothing lost · next build is slower"
        case .yourCall: "Each loses something · you decide"
        case .identical: "Copies share space · nothing deleted"
        case .forgotten: "Big files not opened for 6 months"
        case .dormant: "Idle for 90 days · the code stays"
        }
    }
}

struct GroupIcon: View {
    let group: CandidateGroup
    var dimmed = false

    var body: some View {
        Image(systemName: group.symbol)
            .font(.system(size: 17))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(dimmed ? Color.secondary : group.tint)
            .frame(width: 22)
            .accessibilityHidden(true)
    }
}

/// The app's small drawings, made of shapes and symbols so they stay sharp and follow light and dark mode.
struct Graphic: View {
    enum Name { case ollie, allClean, access, scan }
    let name: Name
    let size: CGFloat

    var body: some View {
        Group {
            switch name {
            case .ollie: OllieMark()
            case .allClean: SymbolMark(symbol: "externaldrive.fill", badge: "checkmark")
            case .access: SymbolMark(symbol: "lock.open.fill", badge: nil)
            case .scan: SymbolMark(symbol: "externaldrive.fill", badge: "magnifyingglass")
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension Color {
    /// Headroom's teal, lighter in dark mode so it reads on a dark menu.
    static let headroomTeal = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.31, green: 0.70, blue: 0.66, alpha: 1)
            : NSColor(srgbRed: 0.06, green: 0.37, blue: 0.39, alpha: 1)
    })
    static let headroomMint = Color(red: 0.37, green: 0.83, blue: 0.71)
}

/// A symbol on a soft teal disc, with an optional mint badge at the lower right.
private struct SymbolMark: View {
    let symbol: String
    let badge: String?

    var body: some View {
        GeometryReader { geo in
            let side = geo.size.width
            ZStack {
                Circle().fill(Color.headroomTeal.opacity(0.16))
                Image(systemName: symbol)
                    .font(.system(size: side * 0.42, weight: .medium))
                    .foregroundStyle(Color.headroomTeal)
                if let badge {
                    ZStack {
                        Circle().fill(Color.headroomMint)
                        Image(systemName: badge)
                            .font(.system(size: side * 0.17, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: side * 0.38, height: side * 0.38)
                    .offset(x: side * 0.3, y: side * 0.3)
                }
            }
        }
    }
}

/// Ollie: a round owl drawn from circles.
private struct OllieMark: View {
    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width
            ZStack {
                // Ear tufts behind the head.
                HStack(spacing: s * 0.34) {
                    Triangle().fill(Color.headroomTeal).frame(width: s * 0.2, height: s * 0.24).rotationEffect(.degrees(-14))
                    Triangle().fill(Color.headroomTeal).frame(width: s * 0.2, height: s * 0.24).rotationEffect(.degrees(14))
                }
                .offset(y: -s * 0.33)
                Circle().fill(Color.headroomTeal).frame(width: s * 0.86)
                HStack(spacing: s * 0.04) {
                    eye(s)
                    eye(s)
                }
                .offset(y: -s * 0.05)
                Triangle().fill(Color.headroomMint)
                    .frame(width: s * 0.13, height: s * 0.11)
                    .rotationEffect(.degrees(180))
                    .offset(y: s * 0.17)
            }
            .frame(width: s, height: s)
        }
    }

    private func eye(_ s: CGFloat) -> some View {
        ZStack {
            Circle().fill(.white)
            Circle().fill(Color(white: 0.12)).frame(width: s * 0.14)
        }
        .frame(width: s * 0.32, height: s * 0.32)
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.closeSubpath()
        }
    }
}

/// The app icon's gauge, live: the needle shows the share of the disk that is free, and the left end of the arc
/// is the warning zone.
struct FreeGauge: View {
    let free: Double
    let warning: Double
    let level: HeadroomLevel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var needleColor: Color {
        switch level {
        case .ok: .headroomMint
        case .low: .orange
        case .critical: .red
        }
    }

    var body: some View {
        GeometryReader { geo in
            let line = geo.size.width * 0.09
            ZStack {
                GaugeArc(start: 0, end: 1)
                    .stroke(Color.headroomTeal.opacity(0.35), style: StrokeStyle(lineWidth: line, lineCap: .round))
                GaugeArc(start: 0, end: min(max(warning, 0), 1))
                    .stroke(Color.orange.opacity(0.75), style: StrokeStyle(lineWidth: line, lineCap: .round))
                Needle(fraction: min(max(free, 0), 1))
                    .stroke(needleColor, style: StrokeStyle(lineWidth: line * 0.8, lineCap: .round))
                Circle().fill(needleColor)
                    .frame(width: line * 1.6, height: line * 1.6)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .offset(y: line * 0.8)
            }
            .padding(line / 2)
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.6, bounce: 0.15), value: free)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Gauge: \(Int((free * 100).rounded())) percent of the disk is free")
    }
}

/// The upper half of a circle whose centre is the middle of the bottom edge; 0 is the left end, 1 the right.
private struct GaugeArc: Shape {
    var start: Double
    var end: Double

    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width / 2, rect.height)
        return Path { p in
            p.addArc(center: CGPoint(x: rect.midX, y: rect.maxY), radius: radius,
                     startAngle: .degrees(180 + 180 * start), endAngle: .degrees(180 + 180 * end), clockwise: false)
        }
    }
}

private struct Needle: Shape {
    var fraction: Double
    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width / 2, rect.height)
        let centre = CGPoint(x: rect.midX, y: rect.maxY)
        let angle = Angle.degrees(180 + 180 * fraction).radians
        return Path { p in
            p.move(to: centre)
            p.addLine(to: CGPoint(x: centre.x + cos(angle) * radius * 0.72, y: centre.y + sin(angle) * radius * 0.72))
        }
    }
}
