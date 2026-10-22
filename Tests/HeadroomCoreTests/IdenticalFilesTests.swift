import Foundation
import Testing
@testable import HeadroomCore

@Suite(.serialized) struct IdenticalFilesTests {
    let dir: String

    init() throws {
        dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("headroom-identical-" + UUID().uuidString)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    static func randomData(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    func write(_ name: String, _ data: Data) throws -> String {
        let path = dir + "/" + name
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    @Test func findsIdenticalPairOnly() async throws {
        let data = Self.randomData(1_500_000)
        let a = try write("one/video.mov", data)
        let b = try write("two/video.mov", data)
        var other = data
        other[700_000] ^= 0xFF
        _ = try write("three/video.mov", other)

        let groups = await IdenticalFiles.find(roots: [dir])
        #expect(groups.count == 1)
        let set = try #require(groups.first?.sets.first)
        #expect(Set([set.keeper] + set.copies) == [a, b])
        #expect(set.freeableCopies == 1)
        #expect(groups[0].reclaimable >= 1_400_000)
        try? FileManager.default.removeItem(atPath: dir)
    }

    @Test func ignoresFilesUnderMinimum() async throws {
        let data = Self.randomData(1_500_000)
        _ = try write("a.bin", data)
        _ = try write("b.bin", data)
        #expect(await IdenticalFiles.find(roots: [dir], minimumBytes: 2_000_000).isEmpty)
        try? FileManager.default.removeItem(atPath: dir)
    }

    @Test func sharesAndKeepsMetadata() async throws {
        let fm = FileManager.default
        let data = Self.randomData(1_500_000)
        let keeper = try write("keeper.bin", data)
        let copy = try write("copy.bin", data)
        let old = Date(timeIntervalSince1970: 1_500_000_000)
        try fm.setAttributes([.creationDate: Date(timeIntervalSince1970: 1_400_000_000)], ofItemAtPath: keeper)
        try fm.setAttributes([.modificationDate: old, .posixPermissions: 0o600], ofItemAtPath: copy)

        let groups = await IdenticalFiles.find(roots: [dir])
        let group = try #require(groups.first)
        #expect(group.sets[0].keeper == keeper)
        let outcome = IdenticalFiles.share(group)
        #expect(outcome.sharedFiles == 1)
        #expect(outcome.failures.isEmpty)

        #expect(try Data(contentsOf: URL(fileURLWithPath: copy)) == data)
        #expect(try Data(contentsOf: URL(fileURLWithPath: keeper)) == data)
        let attributes = try fm.attributesOfItem(atPath: copy)
        #expect((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 == old.timeIntervalSince1970)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        #expect(IdenticalFiles.cloneID(copy) == IdenticalFiles.cloneID(keeper))
        let leftovers = try fm.contentsOfDirectory(atPath: dir).filter { $0.hasPrefix(".headroom-share-") }
        #expect(leftovers.isEmpty)

        // Already shared: nothing more to offer.
        #expect(await IdenticalFiles.find(roots: [dir]).isEmpty)
        try? fm.removeItem(atPath: dir)
    }

    @Test func leavesChangedFileAlone() async throws {
        let data = Self.randomData(1_500_000)
        _ = try write("a.bin", data)
        let copy = try write("b.bin", data)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1_400_000_000)],
                                              ofItemAtPath: dir + "/a.bin")
        let group = try #require(await IdenticalFiles.find(roots: [dir]).first)
        #expect(group.sets[0].copies == [copy])

        var edited = data
        edited[10] ^= 0xFF
        try edited.write(to: URL(fileURLWithPath: copy))
        let outcome = IdenticalFiles.share(group)
        #expect(outcome.sharedFiles == 0)
        #expect(outcome.skipped == 1)
        #expect(try Data(contentsOf: URL(fileURLWithPath: copy)) == edited)
        try? FileManager.default.removeItem(atPath: dir)
    }

    @Test func groupsPackagesAcrossProjects() async throws {
        let data = Self.randomData(1_200_000)
        for project in ["alpha", "beta", "gamma"] {
            _ = try write("\(project)/package.json", Data("{}".utf8))
            _ = try write("\(project)/node_modules/@scope/lib/package.json", Data(#"{"version":"1.2.3"}"#.utf8))
            _ = try write("\(project)/node_modules/@scope/lib/dist/index.js", data)
        }
        let group = try #require(await IdenticalFiles.find(roots: [dir]).first)
        #expect(group.name == "@scope/lib 1.2.3")
        #expect(group.detail == "3 identical copies across projects")
        #expect(group.projectPaths.count == 3)
        #expect(group.sets[0].copies.count == 2)
        try? FileManager.default.removeItem(atPath: dir)
    }

    @Test func describesPlaces() {
        let home = Paths.home
        #expect(IdenticalFiles.place(home + "/Desktop") == "on the Desktop")
        #expect(IdenticalFiles.place(home + "/Downloads") == "in Downloads")
        let set = IdenticalSet(id: "x", keeper: home + "/Downloads/a.mov", copies: [home + "/Desktop/a.mov"],
                               fileSize: 2_000_000, freeableCopies: 1, stamps: [:])
        #expect(IdenticalFiles.fileGroup(set).detail == "In Downloads and on the Desktop")
    }
}
