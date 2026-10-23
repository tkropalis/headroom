import AppKit
import HeadroomCore
import SwiftUI

/// One tile on the map, already placed.
struct MapTile: Identifiable, Hashable {
    enum Role: Hashable {
        /// A listed row, or a row inside the group.
        case node(SpaceNode)
        /// The dominant folder: a plate with its contents laid out inside.
        case group(SpaceNode)
        /// Small rows folded together; they are named in the list below.
        case rest(count: Int, bytes: Int64)
    }

    var id: String
    var role: Role
    var rect: CGRect

    var node: SpaceNode? {
        switch role {
        case .node(let node), .group(let node): node
        case .rest: nil
        }
    }

    var isGroup: Bool { if case .group = role { true } else { false } }

    /// Glass needs room to read as glass, and many small glass views cost frames.
    var isFlat: Bool { rect.width < Self.glassMinimum || rect.height < Self.glassMinimum }

    var cornerRadius: CGFloat {
        isGroup ? Self.groupRadius : min(Self.tileRadius, min(rect.width, rect.height) / 2)
    }

    static let glassMinimum: CGFloat = 40
    /// Concentric: the group is the tiles' 16 plus the 5 pt gap around them.
    static let tileRadius: CGFloat = 16
    static let groupRadius: CGFloat = 21
    static let contentsRadius: CGFloat = 9
    static let gap: CGFloat = 6
    static let groupGap: CGFloat = 5
    static let groupHeader: CGFloat = 28

    var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }
}

extension MapTile {
    /// Lays out the listed rows in `size`; the dominant folder becomes a group of its contents.
    @MainActor static func layout(_ model: SpaceMapModel, in size: CGSize) -> [MapTile] {
        let rows = model.visibleNodes.filter { $0.allocated > 0 }
        let byPath = Dictionary(rows.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let rect = CGRect(origin: .zero, size: size)
        var out: [MapTile] = []
        for tile in Treemap.mapLayout(rows.map { (id: $0.path, value: Double($0.allocated)) }, in: rect,
                                      gap: gap, maxTiles: 36, minArea: 1400) {
            switch tile.id {
            case .rest(let count, let value):
                out.append(MapTile(id: "rest", role: .rest(count: count, bytes: Int64(value)), rect: tile.rect))
            case .item(let path):
                guard let node = byPath[path] else { continue }
                if path == model.groupPath, let inside = model.contents[path], inside.count >= 2,
                   tile.rect.width >= 220, tile.rect.height >= 150 {
                    out.append(MapTile(id: path, role: .group(node), rect: tile.rect))
                    let inner = CGRect(x: tile.rect.minX + groupGap, y: tile.rect.minY + groupHeader,
                                       width: tile.rect.width - groupGap * 2, height: tile.rect.height - groupHeader - groupGap)
                    let children = Dictionary(inside.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
                    for child in Treemap.mapLayout(inside.map { (id: $0.path, value: Double($0.allocated)) }, in: inner,
                                                   gap: groupGap, maxTiles: 14, minArea: 1600) {
                        switch child.id {
                        case .rest(let count, let value):
                            out.append(MapTile(id: path + "/:rest", role: .rest(count: count, bytes: Int64(value)), rect: child.rect))
                        case .item(let childPath):
                            if let node = children[childPath] { out.append(MapTile(id: childPath, role: .node(node), rect: child.rect)) }
                        }
                    }
                } else {
                    out.append(MapTile(id: path, role: .node(node), rect: tile.rect))
                }
            }
        }
        return out
    }
}

/// The tint of a tile's glass: its cost, or grey for folders that hold several.
@MainActor func tileTint(_ tile: MapTile, model: SpaceMapModel) -> Color {
    guard let node = tile.node else { return .gray }
    if node.path == SpaceMapModel.unmeasuredPath { return .gray }
    switch model.canGo(node) {
    case .cost(let cost): return cost.tint
    case .mixed: return .gray
    }
}

// MARK: - Under the glass

/// What sits under a tile's glass: its contents, softly; a plate for the group; a flat tint for
/// tiles too small for glass; stripes for space no app can measure.
struct TileUnderlay: View {
    let tile: MapTile
    let model: SpaceMapModel
    let selected: Bool

    var body: some View {
        let tint = tileTint(tile, model: model)
        if tile.node?.path == SpaceMapModel.unmeasuredPath {
            HatchedFill().clipShape(tile.shape)
        } else if tile.isGroup {
            tile.shape.fill(Color.primary.opacity(0.045))
                .overlay(tile.shape.strokeBorder(Color.primary.opacity(0.08)))
        } else if tile.isFlat {
            tile.shape.fill(tint.opacity(0.5))
                .overlay(tile.shape.strokeBorder(Color.white.opacity(0.12)))
        } else {
            ZStack(alignment: .topLeading) {
                // A soft wash of the tile's colour, brighter at the top left where light catches it.
                tile.shape.fill(LinearGradient(colors: [tint.opacity(0.55), tint.opacity(0.22)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing))
                if let parts = impression {
                    // Contents arrive after the tile; they fade in under the frost.
                    ForEach(parts, id: \.path) { part in
                        RoundedRectangle(cornerRadius: MapTile.contentsRadius, style: .continuous)
                            .fill(part.tint.opacity(0.9))
                            .frame(width: part.rect.width, height: part.rect.height)
                            .offset(x: part.rect.minX, y: part.rect.minY)
                    }
                    .blur(radius: selected ? 1.5 : 9)
                    .transition(.opacity)
                }
            }
            .clipShape(tile.shape)
            .animation(Motion.arrive, value: impression?.count)
            .animation(Motion.respond, value: selected)
            .overlay {
                // The footprint a planned tile leaves as it lifts.
                if let node = tile.node, model.plan.contains(node.path) {
                    tile.shape.strokeBorder(Color.headroomMint.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                }
            }
        }
    }

    struct Part { var path: String; var rect: CGRect; var tint: Color }

    /// The tile's contents as a small map inside it, 7 pt in from its edge.
    private var impression: [Part]? {
        guard let node = tile.node, tile.rect.width >= 90, tile.rect.height >= 70,
              let inside = model.contents[node.path], inside.count >= 2 else { return nil }
        let inner = CGRect(origin: .zero, size: tile.rect.size).insetBy(dx: 7, dy: 7)
        let byPath = Dictionary(inside.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        return Treemap.mapLayout(inside.prefix(10).map { (id: $0.path, value: Double($0.allocated)) }, in: inner,
                                 gap: 4, maxTiles: 10, minArea: 60)
            .compactMap { part in
                guard case .item(let path) = part.id, let child = byPath[path] else { return nil }
                return Part(path: path, rect: part.rect, tint: model.cost(of: child).tint)
            }
    }
}

// MARK: - Glass

/// The glass itself. Resting tiles are frosted; a selected tile clears.
struct TileGlass: View {
    let tile: MapTile
    let tint: Color
    let selected: Bool
    /// In the plan: clear, bright glass lifted off the map.
    var lifted = false

    var body: some View {
        Color.clear
            .contentShape(tile.shape)
            .glassEffect(glass, in: tile.shape)
            // Frost clears when selected or lifted, and frosts again, rather than switching.
            .animation(Motion.respond, value: selected)
            .animation(PlanTray.travel, value: lifted)
    }

    private var glass: Glass {
        if lifted { return .clear.tint(Color.headroomMint.opacity(0.14)).interactive() }
        return selected ? .clear.tint(tint.opacity(0.16)).interactive() : .regular.tint(tint.opacity(0.38)).interactive()
    }
}

// MARK: - On the glass

/// Name, size and icon, sized to the tile; badges for in use and growth; the selection rim.
/// The highlight that follows the pointer is drawn by `HoverRim`.
struct TileLabels: View {
    let tile: MapTile
    let model: SpaceMapModel
    let selected: Bool
    var lifted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        let size = tile.rect.size
        ZStack(alignment: .topLeading) {
            labels(size)
            badges(size)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .overlay {
            if lifted {
                tile.shape.strokeBorder(Color.headroomMint.opacity(selected ? 1 : 0.85), lineWidth: selected ? 2.5 : 2)
            } else if selected {
                tile.shape.strokeBorder(Color.white.opacity(0.9), lineWidth: 2)
            } else if inUseReason != nil {
                tile.shape.strokeBorder(Color.white.opacity(pulse ? 0.55 : 0.15), lineWidth: 1.5)
            } else if !tile.isFlat && !tile.isGroup {
                // The rim catches light at the top left, as glass does.
                tile.shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.42), .white.opacity(0.04), .white.opacity(0.12)],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            }
        }
        .animation(Motion.respond, value: selected)
        .animation(Motion.arrive, value: model.growth[tile.id])
        .animation(Motion.arrive, value: inUseReason)
        .onAppear {
            guard inUseReason != nil, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    private var inUseReason: String? { tile.node.flatMap { model.inUse[$0.path] } }

    @ViewBuilder private func labels(_ size: CGSize) -> some View {
        switch tile.role {
        case .group(let node):
            HStack(spacing: 6) {
                Text(node.name).font(.callout.weight(.semibold))
                Text(model.sizeText(node)).font(.callout).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .padding(.leading, 12)
            .padding(.top, 6)
        case .rest(let count, let bytes):
            if size.width >= 56 && size.height >= 40 {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(count) more").font(.callout.weight(.semibold))
                    Text(ByteFormat.string(bytes)).font(.caption).foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .padding(10)
            }
        case .node(let node):
            nodeLabels(node, size)
        }
    }

    @ViewBuilder private func nodeLabels(_ node: SpaceNode, _ size: CGSize) -> some View {
        let icon = Image(nsImage: model.icon(for: node)).resizable().scaledToFit()
        if size.height >= (lifted ? 128 : 96) && size.width >= 84 {
            VStack(alignment: .leading, spacing: 6) {
                icon.frame(width: 30, height: 30).shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                // Names with spaces wrap to two lines; bundle-style names truncate rather than hyphenate.
                Text(node.name).font(.headline)
                    .lineLimit(node.name.contains(" ") ? 2 : 1)
                    .truncationMode(.middle)
                Text(model.sizeText(node)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if lifted {
                    destinationChip(node)
                } else if selected, let top = model.contents[node.path]?.first, size.height >= 150 {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(top.name).font(.caption).lineLimit(1)
                        Text(ByteFormat.string(top.allocated)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
        } else if size.height >= 46 && size.width >= 70 {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    icon.frame(width: 16, height: 16)
                    Text(node.name).font(.callout.weight(.semibold)).lineLimit(1)
                }
                if lifted, let item = model.plan.item(node.path) {
                    // Narrow tiles keep only where it goes; wider ones show the size too.
                    HStack(spacing: 4) {
                        if size.width >= 150 {
                            Text(model.sizeText(node)).monospacedDigit().foregroundStyle(.secondary)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        }
                        Label(item.destination.title, systemImage: Self.symbol(item.destination)).fontWeight(.semibold)
                    }
                    .font(.caption)
                    .lineLimit(1)
                } else {
                    Text(model.sizeText(node)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .padding(9)
        } else if size.width >= 44 && size.height >= 30 {
            Text(node.name).font(.caption.weight(.semibold)).lineLimit(1)
                .padding(.horizontal, 7).padding(.top, 6)
        }
    }

    /// Where a planned tile goes, as a small capsule.
    @ViewBuilder private func destinationChip(_ node: SpaceNode) -> some View {
        if let item = model.plan.item(node.path) {
            HStack(spacing: 4) {
                Image(systemName: Self.symbol(item.destination))
                Text(item.destination.title).lineLimit(1)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.black.opacity(0.32), in: .capsule)
            .transition(.pop)
            .contentTransition(.interpolate)
        }
    }

    static func symbol(_ destination: PlanDestination) -> String {
        switch destination {
        case .bin: "trash"
        case .drive: "externaldrive"
        case .shared: "square.on.square"
        }
    }

    @ViewBuilder private func badges(_ size: CGSize) -> some View {
        if let node = tile.node, size.width >= 70, size.height >= 46 {
            HStack(spacing: 4) {
                if let delta = model.growth[node.path], size.width >= 130 {
                    Label(ByteFormat.string(delta), systemImage: "arrow.up")
                        .font(.caption2.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.28), in: .capsule)
                        .transition(.pop)
                }
                if inUseReason != nil {
                    Image(systemName: "pause.circle.fill")
                        .font(.callout)
                        .symbolRenderingMode(.hierarchical)
                        .transition(.pop)
                }
            }
            .padding(8)
            .frame(width: size.width, alignment: .topTrailing)
        }
    }
}
