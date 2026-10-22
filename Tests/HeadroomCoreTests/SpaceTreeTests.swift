import Foundation
import Testing
@testable import HeadroomCore

@Suite struct SpaceTreeTests {
    let home = Paths.home

    @Test func categoryRules() {
        #expect(SpaceTree.category(of: home + "/Library/Developer") == "Developer")
        #expect(SpaceTree.category(of: home + "/.gradle") == "Developer")
        #expect(SpaceTree.category(of: home + "/Library/Containers/com.docker.docker") == "Docker")
        #expect(SpaceTree.category(of: home + "/.claude") == "Claude")
        #expect(SpaceTree.category(of: home + "/Library/Caches/com.spotify.client") == "Caches")
        #expect(SpaceTree.category(of: "/Applications/Figma.app") == "Apps")
        #expect(SpaceTree.category(of: home + "/oikos") == "Projects")
        #expect(SpaceTree.category(of: home + "/.zshrc") == nil)
    }

    @Test func categoriesAndUnmeasured() {
        let gb: Int64 = 1_000_000_000
        let snapshot = FolderSnapshot(date: Date(), sizes: [
            home + "/Library/Developer": 30 * gb,
            "/Applications/Figma.app": 1 * gb,
            home + "/.zshrc": 1 * gb,
        ])
        let disk = DiskStatus(total: 245 * gb, available: 18 * gb)
        let categories = SpaceTree.categories(snapshot: snapshot, disk: disk)
        #expect(categories.map(\.name) == ["Developer", "Apps", SpaceTree.otherCategory])
        #expect(categories.last?.bytes == 227 * gb - 31 * gb)
        #expect(SpaceTree.unmeasured(snapshot: snapshot, disk: disk) == 227 * gb - 32 * gb)

        let other = SpaceTree.topLevel(snapshot: snapshot, category: SpaceTree.otherCategory)
        #expect(other.map(\.path) == [home + "/.zshrc"])
        #expect(SpaceTree.topLevel(snapshot: snapshot, category: nil).first?.path == home + "/Library/Developer")
    }

    @Test func childrenSortedBySize() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spacetree-\(UUID().uuidString)").path
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/big", withIntermediateDirectories: true)
        try Data(count: 2_000_000).write(to: URL(fileURLWithPath: root + "/big/a.bin"))
        try Data(count: 300_000).write(to: URL(fileURLWithPath: root + "/small.bin"))
        defer { try? fm.removeItem(atPath: root) }

        let rows = await SpaceTree.children(of: root)
        #expect(rows.map(\.name) == ["big", "small.bin"])
        #expect(rows[0].isDirectory && !rows[1].isDirectory)
        #expect(rows[0].allocated > rows[1].allocated)
    }

    @Test func kinds() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spacekind-\(UUID().uuidString)").path
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/web/node_modules", withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: URL(fileURLWithPath: root + "/web/package.json"))
        try fm.createDirectory(atPath: root + "/Pixel_7.avd", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/plain", withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: root) }

        #expect(SpaceTree.kind(of: root + "/web/node_modules", isDirectory: true) == .dependencies)
        #expect(SpaceTree.kind(of: root + "/web", isDirectory: true) == .project)
        #expect(SpaceTree.kind(of: root + "/Pixel_7.avd", isDirectory: true) == .emulator)
        #expect(SpaceTree.kind(of: root + "/plain", isDirectory: true) == nil)
        #expect(SpaceTree.kind(of: home + "/Library/Developer/Xcode/DerivedData", isDirectory: true) == .buildOutput)
        #expect(SpaceTree.kind(of: home + "/.npm/_cacache", isDirectory: true) == .cache)
    }
}
