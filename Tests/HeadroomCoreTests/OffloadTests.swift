import Foundation
import Testing
@testable import HeadroomCore

/// Offload tests move real files, so they work in a folder under the home folder (offloading
/// is limited to the home folder) and point the record store and archive folder at it.
@Suite(.serialized) struct OffloadTests {
    let sandbox: String
    let source: String
    let drive: String

    init() throws {
        sandbox = Paths.home + "/HeadroomOffloadTests-" + UUID().uuidString.prefix(8)
        source = sandbox + "/Projects/demo"
        drive = sandbox + "/T7"
        let fm = FileManager.default
        try fm.createDirectory(atPath: source + "/sub/deeper", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: drive, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: URL(fileURLWithPath: source + "/a.txt"))
        try Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: URL(fileURLWithPath: source + "/sub/b.bin"))
        try Data("deep".utf8).write(to: URL(fileURLWithPath: source + "/sub/deeper/c.txt"))
        try Data("locked".utf8).write(to: URL(fileURLWithPath: source + "/readonly.txt"))
        try fm.createSymbolicLink(atPath: source + "/link", withDestinationPath: "a.txt")
        _ = "1".withCString { value in setxattr(source + "/a.txt", "com.headroom.test", value, 1, 0, 0) }
        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: source + "/readonly.txt")
        Offloader.storeURL = URL(fileURLWithPath: sandbox + "/offloaded.json")
        Offloader.archiveRoot = sandbox + "/Headroom Offload"
    }

    func cleanUp() {
        Shell.run("/bin/chmod", ["-R", "u+w", sandbox])
        try? FileManager.default.removeItem(atPath: sandbox)
    }

    var driveDestination: OffloadDestination {
        OffloadDestination(id: "t7", name: "T7", root: drive, kind: .drive(format: "apfs", keepsMetadata: true),
                           available: 100_000_000_000)
    }

    var item: OffloadItem { OffloadItem(path: source, name: "demo", bytes: 400_000) }

    func xattr(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: 8)
        let n = getxattr(path, "com.headroom.test", &buffer, buffer.count, 0, 0)
        return n > 0 ? String(decoding: buffer.prefix(n).map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
    }

    @Test func offloadsToADriveAndRestores() async throws {
        defer { cleanUp() }
        let before = try Offloader.treeEntries(source)
        let record = try await Offloader.offload(item, to: driveDestination, progress: { _ in }, shouldStop: { false })

        #expect(!FileManager.default.fileExists(atPath: source))
        #expect(record.storedPath == drive + "/Headroom Offload/demo")
        #expect(try Offloader.treeEntries(record.storedPath) == before)
        #expect(xattr(record.storedPath + "/a.txt") == "1")
        #expect(record.aliasPath == sandbox + "/Projects/demo (offloaded)")
        #expect(Offloader.isAliasFile(record.aliasPath ?? ""))
        #expect(Offloader.records() == [record])
        #expect(Offloader.isReachable(record))

        try await Offloader.restore(record, keepCopy: false, progress: { _ in })
        #expect(try Offloader.treeEntries(source) == before)
        #expect(xattr(source + "/a.txt") == "1")
        let mode = try FileManager.default.attributesOfItem(atPath: source + "/readonly.txt")[.posixPermissions] as? Int
        #expect(mode == 0o444)
        #expect(!FileManager.default.fileExists(atPath: record.storedPath))
        #expect(!FileManager.default.fileExists(atPath: record.aliasPath ?? "/nonexistent"))
        #expect(Offloader.records().isEmpty)
    }

    @Test func archiveRoundTrips() async throws {
        defer { cleanUp() }
        let before = try Offloader.treeEntries(source)
        let archive = OffloadDestination(id: "archive", name: "Compressed archive on this Mac",
                                         root: Offloader.archiveRoot, kind: .archive, available: 100_000_000_000)
        try FileManager.default.createDirectory(atPath: archive.root, withIntermediateDirectories: true)
        let record = try await Offloader.offload(item, to: archive, progress: { _ in }, shouldStop: { false })

        #expect(record.isArchive && record.isOnThisMac)
        #expect(record.storedPath.hasSuffix("/demo.aar"))
        #expect(!FileManager.default.fileExists(atPath: source))
        #expect(try Offloader.archiveEntries(record.storedPath) == before)

        try await Offloader.restore(record, keepCopy: true, progress: { _ in })
        #expect(try Offloader.treeEntries(source) == before)
        #expect(FileManager.default.fileExists(atPath: record.storedPath))
    }

    @Test func nonAppleDriveGetsAnArchive() async throws {
        defer { cleanUp() }
        let before = try Offloader.treeEntries(source)
        let exfat = OffloadDestination(id: "usb", name: "USB", root: drive, kind: .drive(format: "exfat", keepsMetadata: false),
                                       available: 100_000_000_000)
        let record = try await Offloader.offload(item, to: exfat, progress: { _ in }, shouldStop: { false })
        #expect(record.storedPath == drive + "/Headroom Offload/demo.aar")
        #expect(try Offloader.archiveEntries(record.storedPath) == before)
    }

    @Test func offloadsASingleFile() async throws {
        defer { cleanUp() }
        let file = source + "/sub/b.bin"
        let before = try Offloader.treeEntries(file)
        let record = try await Offloader.offload(OffloadItem(path: file, name: "b.bin", bytes: 300_000),
                                                 to: driveDestination, progress: { _ in }, shouldStop: { false })
        #expect(!FileManager.default.fileExists(atPath: file))
        try await Offloader.restore(record, keepCopy: false, progress: { _ in })
        #expect(try Offloader.treeEntries(file) == before)
    }

    @Test func stopLeavesTheOriginal() async throws {
        defer { cleanUp() }
        let before = try Offloader.treeEntries(source)
        await #expect(throws: OffloadError.stopped) {
            try await Offloader.offload(item, to: driveDestination, progress: { _ in }, shouldStop: { true })
        }
        #expect(try Offloader.treeEntries(source) == before)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: drive + "/Headroom Offload")) ?? []
        #expect(leftovers.isEmpty)
        #expect(Offloader.records().isEmpty)
    }

    @Test func refusesWithoutSpace() async throws {
        defer { cleanUp() }
        var small = driveDestination
        small.root = drive
        let huge = OffloadItem(path: source, name: "demo", bytes: Int64.max / 4)
        await #expect(throws: OffloadError.notEnoughSpace("T7")) {
            try await Offloader.offload(huge, to: small, progress: { _ in }, shouldStop: { false })
        }
        #expect(FileManager.default.fileExists(atPath: source))
    }

    @Test func detectsADifferentCopy() throws {
        defer { cleanUp() }
        let copy = sandbox + "/copy"
        Shell.run("/usr/bin/ditto", [source, copy])
        #expect(Offloader.countDifferences(try Offloader.treeEntries(source),
                                           try Offloader.treeEntries(copy, rootName: "demo")) == 0)
        try Data("changed".utf8).write(to: URL(fileURLWithPath: copy + "/sub/deeper/c.txt"))
        try FileManager.default.removeItem(atPath: copy + "/link")
        #expect(Offloader.countDifferences(try Offloader.treeEntries(source),
                                           try Offloader.treeEntries(copy, rootName: "demo")) == 2)
    }

    @Test func refusesProtectedPlaces() {
        defer { cleanUp() }
        #expect(Offloader.canOffload(Paths.home) != nil)
        #expect(Offloader.canOffload("/System") != nil)
        #expect(Offloader.canOffload("/Applications/Safari.app") != nil)
        #expect(Offloader.canOffload(Paths.home + "/Library/Preferences") != nil)
        #expect(Offloader.canOffload(source) == nil)
    }

    @Test func aliasesOnlyUserFolders() {
        defer { cleanUp() }
        #expect(Offloader.wantsAlias(Paths.home + "/Documents/Old project"))
        #expect(!Offloader.wantsAlias(Paths.home + "/Library/Application Support/Steam"))
        #expect(!Offloader.wantsAlias(Paths.home + "/.android/avd/Pixel_7.avd"))
    }

    @Test func listsTheArchiveLast() {
        defer { cleanUp() }
        let found = Offloader.destinations()
        #expect(found.last?.isArchive == true)
        #expect(found.dropLast().allSatisfy { $0.root.hasPrefix("/Volumes/") })
    }

    @Test func compressibility() {
        defer { cleanUp() }
        #expect(Offloader.compresses(source))
        #expect(!Offloader.compresses(Paths.home + "/.android/avd/Pixel_7.avd"))
    }
}
