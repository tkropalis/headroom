import AppKit
import HeadroomCore
import QuickLook
import SwiftUI

/// The Space Map, plus the sheets it starts: offloading, and reviews opened from the inspector.
struct SpaceMapWindow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        SpaceMapView(model: model.spaceMap)
            .frame(minWidth: 860, minHeight: 500)
            .sheet(isPresented: Binding(get: { model.offloadRequest != nil }, set: { if !$0 { model.offloadRequest = nil } })) {
                if let item = model.offloadRequest {
                    OffloadSheet(item: item) { record in model.offloadFinished(record) }
                }
            }
            .sheet(isPresented: Binding(get: { model.flowInWindow && model.screen != .main },
                                        set: { if !$0 { model.flowInWindow = false; model.screen = .main } })) {
                FlowSheet().environment(model)
            }
            // Headroom is a menu bar app; while this window is open it behaves like a normal app.
            .onAppear {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate()
                model.refreshProcesses()
                model.spaceMap.refresh()
            }
            .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }
}

/// The window's content: a floating glass sidebar and inspector, 8 pt inside the window with
/// corners concentric to it, and the folder's rows resting on the window between them.
struct SpaceMapView: View {
    @Bindable var model: SpaceMapModel
    @State private var showInspector = true
    @FocusState private var searchFocused: Bool
    /// Tiles and their chips in the tray share this, so a chip travels from its tile.
    @Namespace private var planSpace

    init(model: SpaceMapModel) { self.model = model }

    static let inset: CGFloat = 8

    var body: some View {
        // The panels float over everything; the rows lay out between them, and the map is
        // reflected beneath them, blurred, so the glass has something to show.
        let leading = Self.inset + Self.sidebarWidth
        let trailing = showInspector ? Self.inset + Self.inspectorWidth : 0
        ZStack {
            VStack(spacing: 0) {
                SpaceHeaderBar(model: model, showInspector: $showInspector, searchFocused: $searchFocused)
                    .padding(.leading, leading)
                    .padding(.trailing, trailing)
                if model.location == .offloaded {
                    model.offloadedView()
                        .padding(.leading, leading)
                        .padding(.trailing, trailing)
                } else {
                    SpaceFilterBar(model: model)
                        .padding(.leading, leading)
                        .padding(.trailing, trailing)
                    GeometryReader { geo in
                        VStack(spacing: 6) {
                            TileMap(model: model, planSpace: planSpace)
                                .background { MapReflection(model: model, sidebar: leading + Self.margin, inspector: showInspector ? trailing + Self.margin : 0) }
                                .padding(.leading, leading + Self.margin)
                                .padding(.trailing, trailing + Self.margin)
                                .frame(height: min(max(geo.size.height * 0.5, 220), 560))
                            SpaceTable(model: model)
                                .padding(.leading, leading)
                                .padding(.trailing, trailing)
                            PlanTray(model: model, namespace: planSpace)
                                .padding(.leading, leading + Self.margin)
                                .padding(.trailing, trailing + Self.margin)
                                .padding(.bottom, 4)
                        }
                    }
                }
                SpaceStatusBar(model: model)
                    .padding(.leading, leading)
                    .padding(.trailing, trailing)
            }

            HStack(spacing: 0) {
                SpaceSidebar(model: model)
                    // Room for the window's buttons, which sit on the panel.
                    .padding(.top, 34)
                    .frame(width: Self.sidebarWidth - Self.inset)
                    .glassPanel()
                    .padding([.leading, .vertical], Self.inset)
                Spacer(minLength: 0)
                if showInspector {
                    SpaceInspector(model: model)
                        .frame(width: Self.inspectorWidth - Self.inset)
                        .glassPanel()
                        .padding([.trailing, .vertical], Self.inset)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .ignoresSafeArea()
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(model.title)
        .quickLookPreview($model.quickLook)
        .sheet(isPresented: $model.reviewingPlan) { PlanReviewSheet(model: model) }
        .animation(.spring(response: 0.35, dampingFraction: 1), value: showInspector)
    }

    static let sidebarWidth: CGFloat = 244
    static let inspectorWidth: CGFloat = 308
    /// Space between the panels and the map.
    static let margin: CGFloat = 10
}

extension View {
    /// A floating Liquid Glass panel whose corners stay concentric with the window's.
    func glassPanel() -> some View {
        let shape = ConcentricRectangle(corners: .concentric(minimum: .fixed(12)), isUniform: true)
        // Structural panels are a heavier material than the tiles: a wash of the window's own
        // colour keeps their text legible over the map beneath.
        return self
            .clipShape(shape)
            .glassEffect(.regular.tint(Color(nsColor: .windowBackgroundColor).opacity(0.55)), in: shape)
    }
}

/// Back and forward, where you are, Folders or Kinds, search, and the inspector button.
/// The window has no title bar, so this row also drags the window.
struct SpaceHeaderBar: View {
    @Bindable var model: SpaceMapModel
    @Binding var showInspector: Bool
    var searchFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 0) {
                Button { withAnimation(TileMap.zoomSpring) { model.back() } } label: { Image(systemName: "chevron.left").frame(width: 30, height: 30) }
                    .disabled(!model.canGoBack)
                    .keyboardShortcut("[", modifiers: .command)
                    .help("Back")
                Button { withAnimation(TileMap.zoomSpring) { model.forward() } } label: { Image(systemName: "chevron.right").frame(width: 30, height: 30) }
                    .disabled(!model.canGoForward)
                    .keyboardShortcut("]", modifiers: .command)
                    .help("Forward")
            }
            .buttonStyle(.plain)
            .fontWeight(.semibold)
            .padding(.horizontal, 4)
            .glassEffect(.regular.interactive(), in: .capsule)

            SpacePathBar(model: model)
                .layoutPriority(1)
            Spacer(minLength: 8)

            Picker("View", selection: Binding(get: { model.lens }, set: { model.setLens($0) })) {
                Text("Folders").tag(SpaceLens.folders)
                Text("Kinds").tag(SpaceLens.kinds)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Show the disk by folder or by kind")

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $model.search)
                    .textFieldStyle(.plain)
                    .focused(searchFocused)
                if !model.search.isEmpty {
                    Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Clear the search")
                }
            }
            .padding(.horizontal, 12)
            .frame(width: 160, height: 32)
            .glassEffect(.regular, in: .capsule)
            .background {
                // ⌘F puts the cursor in the search field, as in Finder.
                Button("Find") { searchFocused.wrappedValue = true }
                    .keyboardShortcut("f", modifiers: .command)
                    .hidden()
            }

            Button { showInspector.toggle() } label: { Image(systemName: "sidebar.right").frame(width: 32, height: 32) }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help(showInspector ? "Hide details" : "Show details")
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .frame(height: 52)
        .background {
            Color.clear.contentShape(.rect).gesture(WindowDragGesture())
        }
    }
}

// MARK: - Sidebar

struct SpaceSidebar: View {
    @Bindable var model: SpaceMapModel

    var body: some View {
        let selection = Binding<SpaceSidebarItem?>(get: { model.sidebarSelection }, set: { if let item = $0 { model.select(item) } })
        List(selection: selection) {
            DiskHeader(model: model)
                .selectionDisabled()
                .listRowSeparator(.hidden)
                .padding(.bottom, 6)

            if let overview = model.overview {
                Section("Places") {
                    ForEach(overview.places) { item in
                        SidebarRow(title: item.place.title, icon: Self.icon(for: item.place), bytes: item.bytes)
                            .tag(SpaceSidebarItem.place(item.place))
                    }
                }
            }
            Section("Kinds") {
                ForEach(model.categories) { category in
                    SidebarRow(title: category.name, icon: Self.icon(forKind: category.name), bytes: category.bytes)
                        .tag(SpaceSidebarItem.kind(category.name))
                }
            }
            if !model.plan.isEmpty {
                Section("Plan") {
                    HStack {
                        Label { Text("\(model.plan.items.count) \(model.plan.items.count == 1 ? "item" : "items")") } icon: {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.headroomMint)
                        }
                        Spacer()
                        Text(ByteFormat.string(model.plan.total)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                    .tag(SpaceSidebarItem.plan)
                    .animation(PlanTray.travel, value: model.plan.total)
                }
            }
            Section("Drives") {
                SidebarRow(title: "Offloaded", icon: Image(systemName: "externaldrive.badge.checkmark"), bytes: nil)
                    .tag(SpaceSidebarItem.offloaded)
                ForEach(model.drives) { drive in
                    HStack {
                        Label { Text(drive.name) } icon: { Image(nsImage: NSWorkspace.shared.icon(forFile: drive.root)).resizable().frame(width: 16, height: 16) }
                        Spacer()
                        Text("\(ByteFormat.string(drive.available)) free")
                            .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .selectionDisabled()
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    static func icon(for place: SpacePlace) -> Image {
        if let path = place.path {
            return Image(nsImage: NSWorkspace.shared.icon(forFile: path))
        }
        switch place {
        case .macOS: return Image(systemName: "apple.logo")
        case .temporary: return Image(systemName: "clock.arrow.circlepath")
        default: return Image(systemName: "shippingbox")
        }
    }

    /// The app a kind is mostly about, when it is installed.
    static func icon(forKind name: String) -> Image {
        Image(nsImage: SpaceDataSource.kindIcon(name))
    }

    static func symbol(for category: String) -> String {
        switch category {
        case "Developer": "hammer"
        case "Docker": "shippingbox"
        case "Claude": "bubble.left"
        case "Caches": "archivebox"
        case "Apps": "app"
        case "Projects": "folder"
        default: "gearshape"
        }
    }
}

private struct SidebarRow: View {
    let title: String
    let icon: Image
    let bytes: Int64?

    var body: some View {
        HStack {
            Label { Text(title) } icon: { icon.resizable().scaledToFit().frame(width: 16, height: 16) }
            Spacer()
            if let bytes {
                Text(ByteFormat.string(bytes)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
}

/// The disk's name, how full it is, and a bar of measured, unmeasured and free space.
private struct DiskHeader: View {
    let model: SpaceMapModel

    var body: some View {
        Button { model.showDisk() } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Macintosh HD").font(.headline)
                if let overview = model.overview {
                    Text("\(ByteFormat.string(overview.used)) used of \(ByteFormat.string(overview.total))")
                        .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    DiskBar(overview: overview)
                        .frame(height: 6)
                        .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Show the whole disk")
    }
}

/// Measured, not measurable, and free, side by side in proportion.
struct DiskBar: View {
    let overview: SpaceOverview

    var body: some View {
        GeometryReader { geo in
            let total = max(1, Double(overview.total))
            let gap: CGFloat = 2
            let width = max(0, geo.size.width - gap * 2)
            HStack(spacing: gap) {
                Capsule().fill(DiskSwatch.measured)
                    .frame(width: width * Double(overview.measured) / total)
                HatchedFill()
                    .clipShape(.capsule)
                    .frame(width: width * Double(overview.unmeasured) / total)
                Capsule().fill(DiskSwatch.free)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(ByteFormat.string(overview.measured)) measured, \(ByteFormat.string(overview.unmeasured)) not measured, \(ByteFormat.string(overview.free)) free")
    }
}

enum DiskSwatch {
    static let measured = Color.primary.opacity(0.38)
    static let free = Color.primary.opacity(0.85)
}

/// Diagonal stripes for space no app can measure.
struct HatchedFill: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.primary.opacity(0.12)))
            var path = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 4
            }
            context.stroke(path, with: .color(.primary.opacity(0.4)), lineWidth: 1.2)
        }
    }
}

// MARK: - Toolbar and bars

/// Breadcrumbs for where you are; each one is a button that goes back to it. When the
/// header is narrow, the first steps fold into an ellipsis that still goes back one step.
struct SpacePathBar: View {
    let model: SpaceMapModel

    var body: some View {
        let crumbs = model.crumbs
        ViewThatFits(in: .horizontal) {
            row(crumbs, from: 0)
            ForEach(Array(stride(from: 1, to: crumbs.count, by: 1)), id: \.self) { start in
                row(crumbs, from: start)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 6)
        .animation(Motion.respond, value: crumbs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Path")
    }

    private func row(_ crumbs: [Crumb], from start: Int) -> some View {
        HStack(spacing: 4) {
            if start > 0, let hidden = crumbs[start - 1].location {
                Button { model.go(hidden) } label: { Image(systemName: "ellipsis") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(crumbs[..<start].map(\.title).joined(separator: " › "))
                separator
            }
            ForEach(Array(crumbs.enumerated().dropFirst(start)), id: \.offset) { index, crumb in
                if index > start { separator }
                if let location = crumb.location {
                    Button(crumb.title) { model.go(location) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                } else {
                    Text(crumb.title).fontWeight(.semibold)
                }
            }
        }
        .fixedSize()
    }

    private var separator: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

/// All, Can go and Not used for 6 months, with what is listed.
struct SpaceFilterBar: View {
    @Bindable var model: SpaceMapModel
    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            ForEach(SpaceFilter.allCases, id: \.self) { filter in
                FilterChip(title: filter.title, selected: model.filter == filter, pill: pill) {
                    withAnimation(Motion.layout(reduced: reduceMotion)) { model.filter = filter }
                }
            }
            Spacer(minLength: 12)
            if !model.sinceChoices.isEmpty {
                Menu {
                    Picker("Growth since", selection: $model.since) {
                        ForEach(model.sinceChoices, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Since \(model.since.title.lowercased())", systemImage: "arrow.up.right")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .fixedSize()
                .help("Badges on the map show what grew since then")
            }
            if model.measuring {
                ProgressView().controlSize(.small)
                Text("Measuring…").foregroundStyle(.secondary)
            }
            let rows = model.visibleNodes
            Text("\(rows.count) \(rows.count == 1 ? "item" : "items") · \(ByteFormat.string(rows.reduce(0) { $0 + $1.allocated }))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .animation(Motion.arrive, value: rows.count)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }
}

private struct FilterChip: View {
    let title: String
    let selected: Bool
    let pill: Namespace.ID
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .fontWeight(selected ? .semibold : .regular)
                .foregroundStyle(selected ? Color.primary : .secondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .background {
                    // One pill that slides to the chosen filter.
                    if selected {
                        Capsule().fill(Color.primary.opacity(0.14)).matchedGeometryEffect(id: "pill", in: pill)
                    } else {
                        Capsule().fill(Color.primary.opacity(0.05))
                    }
                }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Measured, not measurable by apps, and free: together they are the whole disk.
struct SpaceStatusBar: View {
    let model: SpaceMapModel

    var body: some View {
        HStack(spacing: 16) {
            if let overview = model.overview {
                item(Capsule().fill(DiskSwatch.measured), overview.measured, "measured")
                item(HatchedFill().clipShape(.rect(cornerRadius: 2)), overview.unmeasured,
                     model.hasFullDiskAccess() ? "not measurable" : "not measured")
                    .help(model.hasFullDiskAccess()
                          ? "macOS doesn't let apps measure its system data and purgeable space."
                          : "Without Full Disk Access, some folders can't be measured.")
                item(Capsule().fill(DiskSwatch.free), overview.free, "free")
            }
            Spacer()
            if model.freeHistory.count >= 3 {
                HStack(spacing: 6) {
                    Text("Free").foregroundStyle(.secondary)
                    Sparkline(samples: model.freeHistory)
                        .frame(width: 90, height: 16)
                }
                .help("Free space since \(model.since.title.lowercased())")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(sparklineLabel)
            }
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sparklineLabel: String {
        guard let first = model.freeHistory.first, let last = model.freeHistory.last else { return "" }
        return "Free space went from \(ByteFormat.string(first.available)) to \(ByteFormat.string(last.available))"
    }

    private func item(_ swatch: some View, _ bytes: Int64, _ label: String) -> some View {
        HStack(spacing: 6) {
            swatch.frame(width: 10, height: 10).accessibilityHidden(true)
            Text(ByteFormat.string(bytes)).fontWeight(.semibold).monospacedDigit()
                .contentTransition(.numericText())
                .animation(Motion.arrive, value: bytes)
            Text(label).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Free space over time, as a line scaled to its own range.
struct Sparkline: View {
    let samples: [FreeSample]

    var body: some View {
        Canvas { context, size in
            let values = samples.map { Double($0.available) }
            guard let low = values.min(), let high = values.max(), values.count >= 2 else { return }
            let range = max(high - low, 1)
            var path = Path()
            for (index, value) in values.enumerated() {
                let point = CGPoint(x: size.width * Double(index) / Double(values.count - 1),
                                    y: size.height - 1 - (size.height - 2) * (value - low) / range)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .color(.secondary), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
        }
    }
}

/// The map's colours mirrored past its edges and heavily blurred, under the sidebar and the
/// inspector. Like the system's background extension, but faded out at the top and bottom
/// so it never shows as a band.
struct MapReflection: View {
    let model: SpaceMapModel
    /// How far the reflection reaches past the map's leading and trailing edges.
    let sidebar: CGFloat
    let inspector: CGFloat

    var body: some View {
        GeometryReader { geo in
            let tiles = MapTile.layout(model, in: geo.size).filter { !$0.isGroup }
            let colours = tiles.map { (rect: $0.rect, tint: tileTint($0, model: model)) }
            Canvas { context, size in
                for item in colours {
                    // Mirrored across the left edge, then across the right edge.
                    let left = CGRect(x: sidebar - item.rect.maxX, y: item.rect.minY, width: item.rect.width, height: item.rect.height)
                    let right = CGRect(x: sidebar + 2 * geo.size.width - item.rect.maxX, y: item.rect.minY,
                                       width: item.rect.width, height: item.rect.height)
                    for rect in [left, right] {
                        context.fill(Path(roundedRect: rect, cornerRadius: 16), with: .color(item.tint.opacity(0.75)))
                    }
                }
            }
            .frame(width: sidebar + geo.size.width + inspector, height: geo.size.height)
            .blur(radius: 34)
            .mask {
                // Only the parts under the panels, fading towards the top and bottom of the map.
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: sidebar)
                    Color.clear.frame(width: geo.size.width)
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: inspector)
                }
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.3),
                                             .init(color: .black, location: 0.7), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
            }
            .offset(x: -sidebar)
            .opacity(0.8)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
