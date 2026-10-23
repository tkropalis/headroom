import CoreGraphics
import Foundation

/// Squarified treemap layout (Bruls, Huizing and van Wijk): each item gets a rectangle whose
/// area is proportional to its value, kept as close to square as the row allows.
public enum Treemap {
    public struct Tile<ID: Hashable & Sendable>: Hashable, Sendable {
        public var id: ID
        public var rect: CGRect

        public init(id: ID, rect: CGRect) {
            self.id = id
            self.rect = rect
        }
    }

    /// Lays out `items` inside `rect`, largest first. Items with no value get no tile.
    /// The same input always gives the same output: equal values keep their input order.
    public static func layout<ID: Hashable & Sendable>(_ items: [(id: ID, value: Double)], in rect: CGRect) -> [Tile<ID>] {
        let sorted = items.enumerated()
            .filter { $0.element.value > 0 && $0.element.value.isFinite }
            .sorted { $0.element.value != $1.element.value ? $0.element.value > $1.element.value : $0.offset < $1.offset }
            .map(\.element)
        let total = sorted.reduce(0) { $0 + $1.value }
        guard total > 0, rect.width > 0, rect.height > 0 else { return [] }

        // Work in areas, so the rows can be laid out directly in points.
        let scale = Double(rect.width * rect.height) / total
        var remaining = sorted.map { (id: $0.id, area: $0.value * scale) }[...]
        var free = rect
        var tiles: [Tile<ID>] = []

        while !remaining.isEmpty {
            let side = Double(min(free.width, free.height))
            var row = [remaining.removeFirst()]
            while let next = remaining.first, worst(row + [next], side: side) <= worst(row, side: side) {
                row.append(remaining.removeFirst())
            }
            tiles += place(row, in: &free, isLast: remaining.isEmpty)
        }
        return tiles
    }

    /// The worst aspect ratio in a row laid along a side of length `side`.
    static func worst<ID>(_ row: [(id: ID, area: Double)], side: Double) -> Double {
        let sum = row.reduce(0) { $0 + $1.area }
        guard sum > 0, side > 0, let largest = row.map(\.area).max(), let smallest = row.map(\.area).min(), smallest > 0 else {
            return .infinity
        }
        let sideSquared = side * side
        return max(sideSquared * largest / (sum * sum), (sum * sum) / (sideSquared * smallest))
    }

    /// Places a row along the shorter side of `free` and shrinks `free` by the strip it used.
    private static func place<ID>(_ row: [(id: ID, area: Double)], in free: inout CGRect, isLast: Bool) -> [Tile<ID>] {
        let sum = row.reduce(0) { $0 + $1.area }
        var tiles: [Tile<ID>] = []
        if free.width >= free.height {
            // A column on the left, items stacked top to bottom.
            let width = isLast ? free.width : CGFloat(sum) / free.height
            var y = free.minY
            for (index, item) in row.enumerated() {
                let height = index == row.count - 1 ? free.maxY - y : CGFloat(item.area) / width
                tiles.append(Tile(id: item.id, rect: CGRect(x: free.minX, y: y, width: width, height: height)))
                y += height
            }
            free = CGRect(x: free.minX + width, y: free.minY, width: max(0, free.width - width), height: free.height)
        } else {
            // A row along the top, items left to right.
            let height = isLast ? free.height : CGFloat(sum) / free.width
            var x = free.minX
            for (index, item) in row.enumerated() {
                let width = index == row.count - 1 ? free.maxX - x : CGFloat(item.area) / height
                tiles.append(Tile(id: item.id, rect: CGRect(x: x, y: free.minY, width: width, height: height)))
                x += width
            }
            free = CGRect(x: free.minX, y: free.minY + height, width: free.width, height: max(0, free.height - height))
        }
        return tiles
    }
}

extension Treemap {
    /// A tile on the Space Map: one item, or the tail of small items folded into "N more".
    public enum MapItem<ID: Hashable & Sendable>: Hashable, Sendable {
        case item(ID)
        case rest(count: Int, value: Double)
    }

    /// Lays out items for the map: at most `maxTiles`, each at least `minArea` square points,
    /// the rest folded into one tile. Tiles are inset by half of `gap` so neighbours keep a
    /// `gap` between them, and the outer ones stay flush with `rect`.
    public static func mapLayout<ID: Hashable & Sendable>(_ items: [(id: ID, value: Double)], in rect: CGRect,
                                                         gap: CGFloat = 5, maxTiles: Int = 40,
                                                         minArea: CGFloat = 1600) -> [Tile<MapItem<ID>>] {
        let sorted = items.enumerated()
            .filter { $0.element.value > 0 && $0.element.value.isFinite }
            .sorted { $0.element.value != $1.element.value ? $0.element.value > $1.element.value : $0.offset < $1.offset }
            .map(\.element)
        let total = sorted.reduce(0) { $0 + $1.value }
        guard total > 0, rect.width > gap, rect.height > gap else { return [] }

        let area = Double(rect.width * rect.height)
        var kept = sorted.prefix { area * $0.value / total >= Double(minArea) }.prefix(maxTiles).map { $0 }
        var restItems = Array(sorted.dropFirst(kept.count))
        // A single leftover reads better as itself than as "1 more".
        if restItems.count == 1 { kept.append(restItems.removeFirst()) }

        var mapItems: [(id: MapItem<ID>, value: Double)] = kept.map { (.item($0.id), $0.value) }
        let restValue = restItems.reduce(0) { $0 + $1.value }
        if !restItems.isEmpty { mapItems.append((.rest(count: restItems.count, value: restValue), restValue)) }

        let outer = rect.insetBy(dx: -gap / 2, dy: -gap / 2)
        return layout(mapItems, in: outer).map { tile in
            Tile(id: tile.id, rect: tile.rect.insetBy(dx: gap / 2, dy: gap / 2))
        }
    }
}

extension Treemap {
    public enum Direction: Sendable { case left, right, up, down }

    /// The nearest rectangle in a direction, by position: distance along the direction, with
    /// drifting sideways counted double, so a move stays in the row or column you expect.
    public static func neighbour<ID: Hashable & Sendable>(of id: ID, in tiles: [Tile<ID>], toward direction: Direction) -> ID? {
        guard let tile = tiles.first(where: { $0.id == id }) else { return nil }
        let from = CGPoint(x: tile.rect.midX, y: tile.rect.midY)
        func score(_ other: Tile<ID>) -> CGFloat? {
            let to = CGPoint(x: other.rect.midX, y: other.rect.midY)
            let (along, across): (CGFloat, CGFloat) = switch direction {
            case .right: (to.x - from.x, abs(to.y - from.y))
            case .left: (from.x - to.x, abs(to.y - from.y))
            case .down: (to.y - from.y, abs(to.x - from.x))
            case .up: (from.y - to.y, abs(to.x - from.x))
            }
            return along > 1 ? along + across * 2 : nil
        }
        return tiles.filter { $0.id != id }.compactMap { other in score(other).map { (other.id, $0) } }
            .min { $0.1 < $1.1 }?.0
    }
}
