import AppKit
import HeadroomCore
import SwiftUI

/// The glass map of what is listed: tiles sized by space and tinted by what removing them costs.
struct TileMap: View {
    @Bindable var model: SpaceMapModel
    let planSpace: Namespace.ID
    @FocusState private var focused: Bool
    @State private var size: CGSize = .zero
    @State private var marquee: CGRect?
    @State private var marqueeBase: Set<String> = []
    /// The tile under the pointer and where on it, so its rim can catch the light there.
    @State private var hover: (id: String, point: CGPoint)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Opening and going back: a spring with no overshoot, as nothing was thrown.
    static let zoomSpring = Animation.spring(response: 0.42, dampingFraction: 1)

    var body: some View {
        ZStack {
            canvas
                .id(model.location)
                .transition(transition)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .contentShape(.rect)
        .gesture(dragSelect)
        .simultaneousGesture(pinch)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .return, .space, .escape, "a"]) { press in
            handle(press.key)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Space map")
    }

    // MARK: Layers

    private var canvas: some View {
        let tiles = MapTile.layout(model, in: size)
        return ZStack(alignment: .topLeading) {
            if tiles.isEmpty && model.measuring {
                MeasuringPlaceholder(size: size)
                    .transition(.opacity)
            }
            // Under the glass: contents, group plates, flat small tiles. Flat tiles take clicks here.
            ForEach(tiles) { tile in
                TileUnderlay(tile: tile, model: model, selected: isSelected(tile))
                    .frame(width: tile.rect.width, height: tile.rect.height)
                    .modifier(TileInteraction(tile: tile, map: self, active: !hasGlass(tile)))
                    .offset(x: tile.rect.minX, y: tile.rect.minY)
            }
            // The glass, all in one container so it renders together. Spacing 0 keeps tiles from merging.
            GlassEffectContainer(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    ForEach(tiles.filter(hasGlass)) { tile in
                        let lifted = isPlanned(tile)
                        TileGlass(tile: tile, tint: tileTint(tile, model: model), selected: isSelected(tile), lifted: lifted)
                            .frame(width: tile.rect.width, height: tile.rect.height)
                            .modifier(TileInteraction(tile: tile, map: self, active: true))
                            .modifier(Lift(lifted: lifted))
                            .offset(x: tile.rect.minX, y: tile.rect.minY)
                    }
                }
            }
            ForEach(tiles) { tile in
                TileLabels(tile: tile, model: model, selected: isSelected(tile), lifted: isPlanned(tile),
                           hoverPoint: hover?.id == tile.id ? hover?.point : nil)
                    .allowsHitTesting(false)
                    .modifier(Lift(lifted: isPlanned(tile) && hasGlass(tile)))
                    .offset(x: tile.rect.minX, y: tile.rect.minY)
            }
            // Where each tile's chip starts when it is added to the plan. Placed by position, not
            // offset, so the shared geometry sees where the tile really is.
            ForEach(tiles.filter { $0.node != nil && !$0.isGroup && !isPlanned($0) }) { tile in
                Color.clear
                    .frame(width: tile.rect.width, height: tile.rect.height)
                    .matchedGeometryEffect(id: "chip:" + tile.id, in: planSpace)
                    .position(x: tile.rect.midX, y: tile.rect.midY)
                    .allowsHitTesting(false)
            }
            if let marquee {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(0.12))
                    .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1)
                    .frame(width: marquee.width, height: marquee.height)
                    .offset(x: marquee.minX, y: marquee.minY)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        // Tiles glide to their new places when sizes arrive, filters change or things leave.
        .animation(Motion.layout(reduced: reduceMotion), value: tiles.map(\.rect))
        .animation(Motion.fade, value: tiles.isEmpty)
        .onAppear { requestContents(tiles) }
        .onChange(of: tiles.map(\.id)) { requestContents(tiles) }
    }

    /// Opening grows the tile into the map while its contents sharpen; going back recedes.
    private var transition: AnyTransition {
        if reduceMotion { return .opacity }
        switch model.zoom {
        case .into(let rect):
            return .asymmetric(insertion: .modifier(active: ZoomFrom(rect: rect, size: size, progress: 0),
                                                    identity: ZoomFrom(rect: rect, size: size, progress: 1)),
                               removal: .opacity)
        case .out:
            return .asymmetric(insertion: .modifier(active: Recede(amount: 1), identity: Recede(amount: 0)),
                               removal: .modifier(active: Recede(amount: -1), identity: Recede(amount: 0)))
        case .none:
            return .opacity
        }
    }

    /// Small tiles, group plates and space no app can measure have no glass of their own.
    private func hasGlass(_ tile: MapTile) -> Bool {
        !tile.isFlat && !tile.isGroup && tile.node?.path != SpaceMapModel.unmeasuredPath
    }

    private func isSelected(_ tile: MapTile) -> Bool { model.selection.contains(tile.id) }

    private func isPlanned(_ tile: MapTile) -> Bool { tile.node != nil && model.plan.contains(tile.id) }

    private func requestContents(_ tiles: [MapTile]) {
        // Only tiles big enough to show what is inside them.
        let wanted = tiles.filter { $0.rect.width >= 90 && $0.rect.height >= 70 && !$0.isGroup }
            .sorted { $0.rect.width * $0.rect.height > $1.rect.width * $1.rect.height }
            .compactMap { $0.node?.isDirectory == true ? $0.node?.path : nil }
        model.requestContents(Array(wanted.prefix(16)))
    }

    // MARK: Selecting and opening

    func tap(_ tile: MapTile) {
        focused = true
        guard tile.node != nil else { return }
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if model.selection.contains(tile.id) { model.selection.remove(tile.id) } else { model.selection.insert(tile.id) }
        } else if flags.contains(.shift) {
            model.selection.insert(tile.id)
        } else {
            model.selection = [tile.id]
        }
    }

    func setHover(_ tile: MapTile, _ phase: HoverPhase) {
        switch phase {
        case .active(let point): hover = (tile.id, point)
        case .ended: if hover?.id == tile.id { hover = nil }
        }
    }

    func open(_ tile: MapTile) {
        guard let node = tile.node else { return }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : Self.zoomSpring) { model.open(node, from: tile.rect) }
    }

    private var dragSelect: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if marquee == nil { marqueeBase = NSEvent.modifierFlags.contains(.command) ? model.selection : [] }
                let rect = CGRect(x: min(value.startLocation.x, value.location.x), y: min(value.startLocation.y, value.location.y),
                                  width: abs(value.location.x - value.startLocation.x), height: abs(value.location.y - value.startLocation.y))
                marquee = rect
                let hits = MapTile.layout(model, in: size).filter { $0.node != nil && !$0.isGroup && $0.rect.intersects(rect) }
                model.selection = marqueeBase.union(hits.map(\.id))
                focused = true
            }
            .onEnded { _ in marquee = nil }
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onEnded { value in
                if value.magnification > 1.2, let node = model.selectedNode, node.isDirectory,
                   let tile = MapTile.layout(model, in: size).first(where: { $0.id == node.path }) {
                    open(tile)
                } else if value.magnification < 0.83, model.canGoBack {
                    withAnimation(Self.zoomSpring) { model.back() }
                }
            }
    }

    // MARK: Keyboard

    private func handle(_ key: KeyEquivalent) -> KeyPress.Result {
        let tiles = MapTile.layout(model, in: size).filter { $0.node != nil && !$0.isGroup }
        let current = tiles.first { model.selection.contains($0.id) }
        switch key {
        case .return:
            guard let current else { return .ignored }
            open(current)
        case .space:
            model.toggleQuickLook()
        case "a":
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : PlanTray.travel) { model.togglePlanForSelection() }
        case .escape:
            model.selection = []
        default:
            guard let current else {
                if let first = tiles.first { model.selection = [first.id] }
                return .handled
            }
            let direction: Treemap.Direction = switch key {
            case .leftArrow: .left
            case .rightArrow: .right
            case .upArrow: .up
            default: .down
            }
            let rects = tiles.map { Treemap.Tile(id: $0.id, rect: $0.rect) }
            if let next = Treemap.neighbour(of: current.id, in: rects, toward: direction) { model.selection = [next] }
        }
        return .handled
    }
}

/// Click to select (⌘ to add or remove), double-click to open, and the item's menu.
private struct TileInteraction: ViewModifier {
    let tile: MapTile
    let map: TileMap
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content
                .modifier(DragToPlan(tile: tile, model: map.model))
                .onContinuousHover { map.setHover(tile, $0) }
                .onTapGesture { map.tap(tile) }
                .simultaneousGesture(TapGesture(count: 2).onEnded { map.open(tile) })
                .contextMenu {
                    if let node = tile.node { SpaceItemMenu(model: map.model, node: node) }
                }
                .help(help)
                .accessibilityElement()
                .accessibilityLabel(accessibility)
                .accessibilityAddTraits(.isButton)
        } else {
            content
        }
    }

    private var help: String {
        switch tile.role {
        case .rest(let count, let bytes): "\(count) smaller items, \(ByteFormat.string(bytes)). They are listed below."
        case .node(let node), .group(let node): "\(node.name), \(map.model.sizeText(node))"
        }
    }

    private var accessibility: String {
        guard let node = tile.node else { return help }
        let cost: String = switch map.model.canGo(node) {
        case .cost(let cost): cost.title
        case .mixed: "mixed"
        }
        return "\(node.name), \(map.model.sizeText(node)), \(cost)"
    }
}

/// Grows from a tile's rectangle to the whole map, sharpening as it goes.
private struct ZoomFrom: ViewModifier, Animatable {
    let rect: CGRect
    let size: CGSize
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let width = max(1, size.width), height = max(1, size.height)
        let scaleX = rect.width / width + (1 - rect.width / width) * progress
        let scaleY = rect.height / height + (1 - rect.height / height) * progress
        content
            .scaleEffect(x: scaleX, y: scaleY, anchor: .topLeading)
            .offset(x: rect.minX * (1 - progress), y: rect.minY * (1 - progress))
            .blur(radius: 10 * (1 - progress))
            .opacity(0.35 + 0.65 * progress)
    }
}

/// Going back: the level you leave shrinks away and frosts; the one you return to settles in.
private struct Recede: ViewModifier {
    /// 1 is the returning level before it arrives, -1 the leaving level as it goes.
    let amount: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(amount > 0 ? 1.06 : amount < 0 ? 0.92 : 1)
            .blur(radius: abs(amount) * 8)
            .opacity(1 - abs(amount))
    }
}

/// The menu for a row or tile, shared by the map and the list.
struct SpaceItemMenu: View {
    let model: SpaceMapModel
    let node: SpaceNode

    var body: some View {
        let real = !node.path.hasPrefix("headroom:")
        if real {
            if model.plan.contains(node.path) {
                Button("Remove from Plan") { withAnimation(PlanTray.travel) { model.removeFromPlan(node.path) } }
            } else if model.planRefusal(node) == nil {
                Button("Add to Plan") { withAnimation(PlanTray.travel) { _ = model.addToPlan([node]) } }
            }
            Divider()
        }
        if node.isDirectory || !real {
            Button("Open") { model.open(node) }
        }
        if real {
            Button("Quick Look") { model.quickLook = URL(fileURLWithPath: node.path) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)]) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.path, forType: .string)
            }
            if model.candidateFor(node.path) == nil, Explainer.privacyBlocker(node.path) == nil, model.claude.ready() {
                Divider()
                Button("Ask \(Helper.name)") {
                    model.selection = [node.path]
                    model.claude.ask(node, false)
                }
            }
            Divider()
            if model.isExcluded(node.path) {
                Button("Scan This Again") { model.setExcluded(node.path, false) }
            } else {
                Button("Never Scan This") { model.setExcluded(node.path, true) }
            }
        }
    }
}

/// A tile in the plan rises off the map as clear glass, leaving its footprint behind.
private struct Lift: ViewModifier {
    let lifted: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .offset(x: lifted && !reduceMotion ? -3 : 0, y: lifted && !reduceMotion ? -4 : 0)
            .shadow(color: .black.opacity(lifted ? 0.35 : 0), radius: lifted ? 10 : 0, y: lifted ? 6 : 0)
            // However it was added (key, menu, drop, inspector), it rises the same way.
            .animation(Motion.travel(reduced: reduceMotion), value: lifted)
    }
}

/// While a folder is measured for the first time, soft tiles breathe where the map will be.
private struct MeasuringPlaceholder: View {
    let size: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bright = false

    var body: some View {
        let shapes = Treemap.mapLayout([(id: 0, value: 40), (id: 1, value: 24), (id: 2, value: 14), (id: 3, value: 10),
                                        (id: 4, value: 7), (id: 5, value: 5)],
                                       in: CGRect(origin: .zero, size: size), gap: MapTile.gap)
        ZStack(alignment: .topLeading) {
            ForEach(shapes, id: \.self) { shape in
                RoundedRectangle(cornerRadius: MapTile.tileRadius, style: .continuous)
                    .fill(Color.primary.opacity(bright ? 0.09 : 0.04))
                    .frame(width: shape.rect.width, height: shape.rect.height)
                    .offset(x: shape.rect.minX, y: shape.rect.minY)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { bright = true }
        }
        .accessibilityLabel("Measuring")
    }
}

/// Selected tiles can be dragged into the plan tray. Unselected ones drag a selection
/// rectangle instead, since tiles fill nearly all of the map.
private struct DragToPlan: ViewModifier {
    let tile: MapTile
    let model: SpaceMapModel

    func body(content: Content) -> some View {
        if let node = tile.node, model.selection.contains(node.path), model.planRefusal(node) == nil {
            content.draggable(model.selection.sorted().joined(separator: "\n")) {
                Label("\(model.selection.count == 1 ? node.name : "\(model.selection.count) items")", systemImage: "plus.circle.fill")
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.regularMaterial, in: .capsule)
            }
        } else {
            content
        }
    }
}
