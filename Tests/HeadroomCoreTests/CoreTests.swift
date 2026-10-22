import Foundation
import Testing
@testable import HeadroomCore

@Suite struct FormatTests {
    @Test func decimalUnits() {
        #expect(ByteFormat.string(29_000_000_000) == "29 GB")
        #expect(ByteFormat.string(2_345_000_000) == "2.3 GB")
        #expect(ByteFormat.string(9_960_000_000) == "10 GB")
        #expect(ByteFormat.string(512_000_000) == "512 MB")
        #expect(ByteFormat.string(-5) == "0 KB")
    }

    @Test func dockerSizes() {
        #expect(DockerProbe.parseSize("2.345GB (45%)") == 2_345_000_000)
        #expect(DockerProbe.parseSize("512.5MB") == 512_500_000)
        #expect(DockerProbe.parseSize("0B") == 0)
    }

    @Test func levels() {
        let gb: Int64 = 1_000_000_000
        #expect(HeadroomLevel(available: 29 * gb, warnBytes: 20 * gb, criticalBytes: 10 * gb) == .ok)
        #expect(HeadroomLevel(available: 14 * gb, warnBytes: 20 * gb, criticalBytes: 10 * gb) == .low)
        #expect(HeadroomLevel(available: 6 * gb, warnBytes: 20 * gb, criticalBytes: 10 * gb) == .critical)
    }
}

@Suite struct SafetyTests {
    @Test func refusesImportantFolders() {
        let home = Paths.home
        for path in ["/", "/Users", home, home + "/Library", home + "/Documents", "/Applications",
                     "/var/folders", "relative/path", home + "/Library/../Documents"] {
            #expect(!PathSafety.isDeletable(path), "\(path) must be protected")
        }
        #expect(PathSafety.isDeletable(home + "/.npm/_cacache"))
        #expect(PathSafety.isDeletable(home + "/Library/Caches/com.spotify.client"))
    }

    @Test func expandsPrefixes() {
        #expect(Paths.expand("~/x") == Paths.home + "/x")
        #expect(Paths.expand("$TMP/metro-cache").hasSuffix("/T/metro-cache"))
        #expect(Paths.expand("$FOLDERS/X/a").hasSuffix("/X/a"))
        #expect(Paths.display(Paths.home + "/a") == "~/a")
    }
}

@Suite struct SizerTests {
    func tempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "headroom-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func clonesAreNotCountedAsUnshared() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let original = dir + "/original"
        let data = Data((0..<(20 * 1_000_000)).map { _ in UInt8.random(in: 0...255) })
        try data.write(to: URL(fileURLWithPath: original))
        #expect(clonefile(original, dir + "/clone", 0) == 0)

        let clone = Sizer.measure(dir + "/clone")
        #expect(clone.allocated >= 20_000_000)
        #expect(clone.unshared < 1_000_000, "a fresh clone owns almost none of its blocks")

        let plain = dir + "/plain"
        try data.write(to: URL(fileURLWithPath: plain))
        let single = Sizer.measure(plain)
        #expect(single.unshared == single.allocated)
    }

    @Test func missingPathIsZero() {
        #expect(Sizer.measure("/nonexistent/headroom") == .zero)
    }
}

@Suite struct ResolveTests {
    @Test func oldChildrenOnly() throws {
        let dir = NSTemporaryDirectory() + "headroom-old-" + UUID().uuidString
        let fm = FileManager.default
        try fm.createDirectory(atPath: dir + "/old", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: dir + "/new", withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: dir) }
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-90 * 86400)], ofItemAtPath: dir + "/old")
        let found = Scanner.resolve(.oldChildren(dir, days: 60))
        #expect(found == [dir + "/old"])
    }
}

@Suite struct ProjectTests {
    @Test func findsArtifactsAndActivity() throws {
        let root = NSTemporaryDirectory() + "headroom-proj-" + UUID().uuidString
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/app/node_modules/x", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/app/apps/web/.next", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/api/vendor", withIntermediateDirectories: true)
        fm.createFile(atPath: root + "/app/package.json", contents: Data("{}".utf8))
        fm.createFile(atPath: root + "/api/composer.json", contents: Data("{}".utf8))
        defer { try? fm.removeItem(atPath: root) }

        let projects = ProjectFinder.find(roots: [root]).sorted { $0.path < $1.path }
        #expect(projects.count == 2)
        let app = try #require(projects.first { $0.path.hasSuffix("/app") })
        #expect(Set(app.artifacts.map(\.folderName)) == ["node_modules", ".next"])
        #expect(app.artifacts.first { $0.folderName == ".next" }?.kind == .buildCache)
        let api = try #require(projects.first { $0.path.hasSuffix("/api") })
        #expect(api.artifacts.map(\.folderName) == ["vendor"])
        #expect(app.lastActivity != nil)
        #expect(!app.isDormant(days: 90))
    }
}

@Suite struct CandidateTests {
    func candidate(quit: [AppRef] = [], project: String? = nil, rules: [BlockRule] = []) -> Candidate {
        Candidate(id: "x", name: "X", detail: "", group: .ready, size: .zero, isEstimate: false, cost: "",
                  quit: quit, blockRules: rules, projectPath: project, action: .delete([]), fixedBlocker: nil)
    }

    @Test func runningDevServerBlocks() {
        let processes = ProcessSnapshot(commandLines: ["node /Users/t/site/node_modules/.bin/next dev"], runningBundleIDs: [])
        let status = candidate(project: "/Users/t/site").status(with: processes)
        #expect(status.isBlocked)
        #expect(!candidate(project: "/Users/t/other").status(with: processes).isBlocked)
    }

    @Test func editorsStartUnticked() {
        let processes = ProcessSnapshot(commandLines: [], runningBundleIDs: [Apps.spotify.bundleID, Apps.vscode.bundleID])
        #expect(candidate(quit: [Apps.spotify]).status(with: processes).selectedByDefault)
        #expect(!candidate(quit: [Apps.vscode]).status(with: processes).selectedByDefault)
        #expect(candidate(quit: [Apps.spotify]).status(with: processes).note == "Spotify is open. Headroom will quit it first.")
    }

    @Test func blockRules() {
        let processes = ProcessSnapshot(commandLines: ["java … GradleDaemon 8.13"], runningBundleIDs: [])
        let status = candidate(rules: [BlockRule(match: "GradleDaemon", reason: "A Gradle build is running.")]).status(with: processes)
        #expect(status.blocker == "A Gradle build is running.")
    }
}

@Suite struct CleanerTests {
    @Test func deletesAndMeasures() async throws {
        let dir = NSTemporaryDirectory() + "headroom-clean-" + UUID().uuidString
        let fm = FileManager.default
        try fm.createDirectory(atPath: dir + "/cache/ro", withIntermediateDirectories: true)
        try Data(count: 5_000_000).write(to: URL(fileURLWithPath: dir + "/cache/ro/file"))
        // Read-only folder, like dotslash's cache.
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir + "/cache/ro")
        defer { try? fm.removeItem(atPath: dir) }

        let item = Candidate(id: "t", name: "Test cache", detail: "", group: .ready, size: .zero, isEstimate: false,
                             cost: "", quit: [], blockRules: [], projectPath: nil,
                             action: .delete([dir + "/cache"]), fixedBlocker: nil)
        let outcome = await Cleaner().clean(item)
        #expect(outcome.state == .done)
        #expect(!fm.fileExists(atPath: dir + "/cache"))
    }

    @Test func refusesProtectedPath() async {
        let item = Candidate(id: "t", name: "Home", detail: "", group: .ready, size: .zero, isEstimate: false,
                             cost: "", quit: [], blockRules: [], projectPath: nil,
                             action: .delete([Paths.home]), fixedBlocker: nil)
        let outcome = await Cleaner().clean(item)
        #expect(outcome.state == .failed)
        #expect(FileManager.default.fileExists(atPath: Paths.home))
    }
}
