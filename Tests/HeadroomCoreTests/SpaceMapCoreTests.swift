import CoreGraphics
import Foundation
import Testing
@testable import HeadroomCore

@Suite struct TreemapTests {
    let sizes: [Double] = [26, 18, 9.4, 7.1, 6, 4.2, 3.3, 2.5, 1.2, 0.9, 0.4, 0.1]
    let rect = CGRect(x: 0, y: 0, width: 900, height: 520)

    var items: [(id: Int, value: Double)] { sizes.enumerated().map { (id: $0.offset, value: $0.element) } }

    @Test func areasFollowSizes() {
        let tiles = Treemap.layout(items, in: rect)
        #expect(tiles.count == sizes.count)
        let total = sizes.reduce(0, +)
        for tile in tiles {
            let expected = Double(rect.width * rect.height) * sizes[tile.id] / total
            #expect(abs(Double(tile.rect.width * tile.rect.height) - expected) < 1)
        }
    }

    @Test func tilesStayInsideAndDontOverlap() {
        let tiles = Treemap.layout(items, in: rect)
        for (index, tile) in tiles.enumerated() {
            #expect(rect.insetBy(dx: -0.001, dy: -0.001).contains(tile.rect))
            for other in tiles[(index + 1)...] {
                let overlap = tile.rect.intersection(other.rect)
                #expect(overlap.isNull || overlap.width * overlap.height < 0.001)
            }
        }
    }

    @Test func sameInputSameOutput() {
        let ties: [(id: String, value: Double)] = [("a", 5), ("b", 5), ("c", 5), ("d", 2)]
        let first = Treemap.layout(ties, in: rect)
        #expect(Treemap.layout(ties, in: rect) == first)
        #expect(first.map(\.id) == ["a", "b", "c", "d"])
    }

    @Test func emptyAndZeroValues() {
        #expect(Treemap.layout([(id: 1, value: 0), (id: 2, value: -3)], in: rect).isEmpty)
        #expect(Treemap.layout(items, in: .zero).isEmpty)
        let one = Treemap.layout([(id: 1, value: 4)], in: rect)
        #expect(one.first?.rect == rect)
    }

    @Test func squarerThanSlices() {
        // Squarified rows keep tiles far from the thin slivers a plain slice layout gives.
        let tiles = Treemap.layout(items.prefix(6).map { $0 }, in: rect)
        let worst = tiles.map { max($0.rect.width / $0.rect.height, $0.rect.height / $0.rect.width) }.max() ?? 0
        #expect(worst < 4)
    }
}

@Suite struct SpaceCostTests {
    let home = Paths.home

    func cost(_ path: String, kind: SpaceKind? = nil) -> SpaceCost {
        SpaceCost.of(Paths.expand(path), kind: kind, catalog: Catalog.builtIn)
    }

    @Test func knownPaths() {
        #expect(cost("~/Library/Developer/Xcode/DerivedData") == .nothingLost)
        #expect(cost("~/Library/Caches/com.spotify.client") == .nothingLost)
        #expect(cost("~/.npm/_cacache") == .nothingLost)
        #expect(cost("~/.gradle/caches") == .slowerNext)
        #expect(cost("~/.gradle/caches/modules-2") == .slowerNext)
        #expect(cost("~/Library/Containers/com.docker.docker") == .yourCall)
        #expect(cost("~/Library/Application Support/minecraft") == .yourCall)
        #expect(cost("~/Documents") == .yourFiles)
        #expect(cost("~/Documents/Taxes/2025.pdf") == .yourFiles)
        #expect(cost("~") == .yourFiles)
        #expect(cost("/System/Library") == .system)
    }

    @Test func kindsWhenNoRule() {
        #expect(cost("~/code/web/node_modules", kind: .dependencies) == .slowerNext)
        #expect(cost("~/code/web/.next", kind: .buildOutput) == .nothingLost)
        #expect(cost("~/code/web", kind: .project) == .yourFiles)
        #expect(cost("~/.android/avd/Pixel_7.avd", kind: .emulator) == .yourCall)
        #expect(cost("~/somewhere/odd") == .unknown)
    }

    @Test func scanItemAndAnswerDecide() {
        let path = home + "/.somecache"
        let item = Candidate(id: "x", name: "x", detail: "", group: .ready, size: .zero, isEstimate: false, cost: "",
                             quit: [], blockRules: [], projectPath: nil, action: .delete([path]), fixedBlocker: nil)
        #expect(SpaceCost.of(path, kind: nil, candidate: item, catalog: []) == .nothingLost)

        let answer = Explanation(path: path, name: "x", what: "", owner: "", ownerBundleID: "", verdict: .keep, cost: "",
                                 howToRemove: "", confidence: .high, bytes: 0, askedAt: Date(), model: "",
                                 appInstalled: nil, confirmed: false)
        #expect(SpaceCost.of(path, kind: nil, explanation: answer, catalog: []) == .yourCall)

        // Your own folders win over anything a rule or an answer says.
        let documents = home + "/Documents/cache"
        #expect(SpaceCost.of(documents, kind: .cache, candidate: item, catalog: []) == .yourFiles)
    }
}

@Suite struct SizeCacheTests {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func add(_ path: String) { lock.withLock { paths.append(path) } }
        var count: Int { lock.withLock { paths.count } }
    }

    func folder() throws -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sizecache-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root + "/a", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/b", withIntermediateDirectories: true)
        return root
    }

    @Test func returnsCachedSizesWithoutMeasuringAgain() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let counter = Counter()
        let cache = SizeCache(file: nil) { path in counter.add(path); return SizeInfo(allocated: 42, unshared: 42) }

        let first = await cache.sizes(of: [root + "/a", root + "/b"])
        #expect(first[root + "/a"]?.allocated == 42)
        #expect(counter.count == 2)

        let second = await cache.sizes(of: [root + "/a", root + "/b"])
        #expect(second.count == 2)
        #expect(counter.count == 2)

        _ = await cache.sizes(of: [root + "/a"], refresh: true)
        #expect(counter.count == 3)
    }

    @Test func newerModificationDateMeasuresAgain() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let counter = Counter()
        let cache = SizeCache(file: nil) { path in counter.add(path); return SizeInfo(allocated: 1) }

        _ = await cache.sizes(of: [root + "/a"])
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: root + "/a")
        #expect(await cache.cached(root + "/a") == nil)
        _ = await cache.sizes(of: [root + "/a"])
        #expect(counter.count == 2)
    }

    @Test func oldEntriesExpireAndInvalidateReachesParents() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let cache = SizeCache(file: nil, maxAge: 3600) { _ in SizeInfo(allocated: 1) }
        _ = await cache.sizes(of: [root, root + "/a", root + "/b"])
        #expect(await cache.cached(root + "/a", now: Date().addingTimeInterval(7200)) == nil)

        await cache.invalidate(root + "/a")
        #expect(await cache.cached(root + "/a") == nil)
        #expect(await cache.cached(root) == nil)
        #expect(await cache.cached(root + "/b") != nil)
    }

    @Test func savesToDisk() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let file = URL(fileURLWithPath: root + "/sizes.json")
        _ = await SizeCache(file: file) { _ in SizeInfo(allocated: 7) }.sizes(of: [root + "/a"])

        let counter = Counter()
        let reopened = SizeCache(file: file) { path in counter.add(path); return .zero }
        #expect(await reopened.sizes(of: [root + "/a"])[root + "/a"]?.allocated == 7)
        #expect(counter.count == 0)
    }
}

@Suite struct SpacePlacesTests {
    let home = Paths.home
    let gb: Int64 = 1_000_000_000

    @Test func everyFolderHasOnePlace() {
        #expect(SpacePlace.of(home + "/Library/Containers/com.docker.docker") == .home)
        #expect(SpacePlace.of("/Applications/Xcode.app") == .applications)
        #expect(SpacePlace.of("/Library/Developer") == .library)
        #expect(SpacePlace.of("/System/Volumes/Data/System/Library/AssetsV2") == .macOS)
        #expect(SpacePlace.of("/private/var/vm") == .macOS)
        #expect(SpacePlace.of(Paths.userFolders + "/T/metro-cache") == .temporary)
        #expect(SpacePlace.of("/opt") == .other)
    }

    @Test func overviewAddsUp() {
        let snapshot = FolderSnapshot(date: Date(), sizes: [
            home + "/Library/Containers/com.docker.docker": 26 * gb,
            "/Applications/Xcode.app": 4 * gb,
            "/private/var/vm": 2 * gb,
            "/opt": 5 * gb,
        ])
        let disk = DiskStatus(total: 245 * gb, available: 33 * gb)
        let overview = SpaceOverview(snapshot: snapshot, disk: disk, systemVolumes: 12 * gb)
        #expect(overview.bytes(.macOS) == 14 * gb)
        #expect(overview.measured == 49 * gb)
        #expect(overview.measured + overview.unmeasured == disk.used)
        #expect(overview.measured + overview.unmeasured + overview.free == disk.total)
        #expect(overview.places.first?.place == .home)

        // Volumes never push the total past what is in use.
        let tight = SpaceOverview(snapshot: snapshot, disk: DiskStatus(total: 50 * gb, available: 10 * gb), systemVolumes: 12 * gb)
        #expect(tight.measured + tight.unmeasured == 40 * gb)
        #expect(tight.unmeasured == 0)
    }

    @Test func childrenSummedFromSnapshot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("places-\(UUID().uuidString)").path
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/Library/Caches", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/web", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/new", withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: root) }

        let snapshot = FolderSnapshot(date: Date(), sizes: [
            root + "/Library/Caches/a": 3 * gb, root + "/Library/Caches/b": 1 * gb, root + "/Library/Mail": 2 * gb,
            root + "/web": 5 * gb,
        ])
        let (rows, missing) = SpaceTree.snapshotChildren(of: root, snapshot: snapshot)
        #expect(rows.map(\.name) == ["Library", "web", "new"])
        #expect(rows[0].allocated == 6 * gb)
        #expect(missing == [root + "/new"])

        let breakdown = SpaceTree.breakdown(under: root + "/Library", snapshot: snapshot, index: CatalogIndex([]))
        #expect(breakdown?.count == 3)
        #expect(breakdown?.total == 6 * gb)
        #expect(SpaceTree.breakdown(under: root + "/web", snapshot: snapshot, index: CatalogIndex([])) == nil)
    }

    @Test func mixedNeedsVisibleShares() {
        #expect(CostBreakdown(bytes: [.nothingLost: 50, .yourCall: 50], count: 2).isMixed)
        #expect(!CostBreakdown(bytes: [.nothingLost: 99, .yourCall: 1], count: 2).isMixed)
        #expect(CostBreakdown(bytes: [.nothingLost: 5, .slowerNext: 3, .yourCall: 2], count: 3).canGo == 8)
    }

    @Test func relativeDates() {
        let now = Date()
        #expect(RelativeDate.ago(now, now: now) == "Today")
        #expect(RelativeDate.ago(now.addingTimeInterval(-86400 * 3), now: now) == "3 days ago")
        #expect(RelativeDate.ago(now.addingTimeInterval(-86400 * 21), now: now) == "3 weeks ago")
        #expect(RelativeDate.ago(now.addingTimeInterval(-86400 * 150), now: now) == "5 months ago")
        #expect(RelativeDate.isUnused(now.addingTimeInterval(-86400 * 200), now: now))
        #expect(!RelativeDate.isUnused(nil, now: now))
    }
}

@Suite struct ProcessNameTests {
    @Test func names() {
        #expect(ProcessSnapshot.displayName("/Applications/Claude.app/Contents/Frameworks/Electron Framework.framework/Helpers/chrome_crashpad_handler --annotation=x") == "Claude")
        #expect(ProcessSnapshot.displayName("/opt/homebrew/bin/node /Users/me/web/node_modules/.bin/next dev") == "next")
        #expect(ProcessSnapshot.displayName("/usr/bin/java -Xmx2g GradleDaemon") == "java")
    }
}

@Suite struct MapLayoutTests {
    let rect = CGRect(x: 0, y: 0, width: 800, height: 400)

    @Test func smallItemsFoldIntoMore() {
        let items: [(id: Int, value: Double)] = [(1, 500), (2, 300), (3, 150)] + (4...60).map { ($0, 0.5) }
        let tiles = Treemap.mapLayout(items, in: rect)
        let rest = tiles.compactMap { tile -> Int? in if case .rest(let count, _) = tile.id { count } else { nil } }
        #expect(rest == [57])
        #expect(tiles.count == 4)
    }

    @Test func gapsBetweenTilesAndFlushEdges() {
        let tiles = Treemap.mapLayout([(id: "a", value: 1), (id: "b", value: 1)], in: rect, gap: 6)
        #expect(tiles.count == 2)
        let left = tiles.map(\.rect).sorted { $0.minX < $1.minX }
        #expect(abs(left[0].minX - rect.minX) < 0.001)
        #expect(abs(left[1].maxX - rect.maxX) < 0.001)
        #expect(abs((left[1].minX - left[0].maxX) - 6) < 0.001)
    }

    @Test func oneLeftoverStaysItself() {
        let tiles = Treemap.mapLayout([(id: 1, value: 1000), (id: 2, value: 0.01)], in: rect, minArea: 1600)
        #expect(tiles.allSatisfy { if case .item = $0.id { true } else { false } })
    }
}

@Suite struct GrowthTests {
    let gb: Int64 = 1_000_000_000

    @Test func sinceFindsTheRightSnapshot() {
        let now = Date()
        let history = [0, 1, 3, 7, 8].map { FolderSnapshot(date: now.addingTimeInterval(-Double($0) * 86400), sizes: [:]) }
        let current = history[0]
        #expect(SpaceSince.day.previous(in: history.reversed(), current: current)?.date == history[1].date)
        #expect(SpaceSince.week.previous(in: history.reversed(), current: current)?.date == history[3].date)
        #expect(SpaceSince.twoWeeks.previous(in: history.reversed(), current: current) == nil)
    }

    @Test func totalsAndContents() {
        let snapshot = FolderSnapshot(date: Date(), sizes: ["/a/b/c": 2 * gb, "/a/b/d": 1 * gb, "/a/e": 4 * gb, "/ab": 9 * gb])
        #expect(SpaceTree.total(under: "/a", in: snapshot) == 7 * gb)
        #expect(SpaceTree.total(under: "/a/b", in: snapshot) == 3 * gb)
        #expect(SpaceTree.snapshotContents(of: "/a", in: snapshot).map(\.name) == ["e", "b"])
        #expect(SpaceTree.snapshotContents(of: "/a/e", in: snapshot).isEmpty)
    }
}

@Suite struct NeighbourTests {
    // A big tile on the left, two stacked on the right, and a wide one along the bottom right.
    let tiles: [Treemap.Tile<String>] = [
        .init(id: "big", rect: CGRect(x: 0, y: 0, width: 400, height: 300)),
        .init(id: "topRight", rect: CGRect(x: 400, y: 0, width: 200, height: 150)),
        .init(id: "midRight", rect: CGRect(x: 400, y: 150, width: 200, height: 150)),
        .init(id: "bottom", rect: CGRect(x: 0, y: 300, width: 600, height: 100)),
    ]

    @Test func movesByPosition() {
        #expect(Treemap.neighbour(of: "big", in: tiles, toward: .right) == "topRight")
        #expect(Treemap.neighbour(of: "topRight", in: tiles, toward: .down) == "midRight")
        #expect(Treemap.neighbour(of: "midRight", in: tiles, toward: .left) == "big")
        #expect(Treemap.neighbour(of: "big", in: tiles, toward: .down) == "bottom")
        #expect(Treemap.neighbour(of: "big", in: tiles, toward: .left) == nil)
        #expect(Treemap.neighbour(of: "missing", in: tiles, toward: .up) == nil)
    }
}
