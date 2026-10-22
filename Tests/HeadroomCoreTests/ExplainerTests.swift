import Foundation
import Testing
@testable import HeadroomCore

@Suite struct ExplainerTests {
    func answer(_ path: String, verdict: Explanation.Verdict, confirmed: Bool, bundleID: String = "") -> Explanation {
        Explanation(path: path, name: "Example data", what: "What it is.", owner: "Example", ownerBundleID: bundleID,
                    verdict: verdict, cost: "Nothing.", howToRemove: "", confidence: .high, bytes: 1_000_000,
                    askedAt: Date(), model: ClaudeClient.model, appInstalled: nil, confirmed: confirmed)
    }

    @Test func personalFoldersAreNeverSent() {
        let home = Paths.home
        #expect(Explainer.privacyBlocker(home) != nil)
        #expect(Explainer.privacyBlocker(home + "/Documents") != nil)
        #expect(Explainer.privacyBlocker(home + "/Desktop/notes") != nil)
        #expect(Explainer.privacyBlocker(home + "/Library/Mobile Documents/com~apple~CloudDocs") != nil)
        #expect(Explainer.privacyBlocker(home + "/Library/Messages") != nil)
        #expect(Explainer.privacyBlocker(home + "/Library/Application Support/Postman") == nil)
        #expect(Explainer.privacyBlocker(home + "/DocumentsOld") == nil)
    }

    @Test func messageShowsNamesAndSizesWithHomeShortened() {
        let facts = FolderFacts(path: Paths.home + "/Library/Application Support/Example", bytes: 2_500_000_000,
                                isDirectory: true, lastOpened: nil, modified: nil, kind: .appData,
                                children: [.init(name: "Cache", bytes: 2_000_000_000, isDirectory: true),
                                           .init(name: "prefs.json", bytes: 4_000, isDirectory: false)],
                                childCount: 30)
        let message = facts.message
        #expect(message.hasPrefix("Folder: ~/Library/Application Support/Example\n"))
        #expect(!message.contains(Paths.home))
        #expect(message.contains("Headroom's guess: App data"))
        #expect(message.contains("Inside (largest first, 2 of 30 items):"))
        #expect(message.contains("- Cache/ 2.0 GB"))
        #expect(message.contains("- prefs.json "))
    }

    @Test func onlyConfirmedRemovableAnswersBecomeCatalogEntries() {
        let base = Paths.home + "/Library/Application Support/"
        let entries = Catalog.learned(from: [
            answer(base + "A", verdict: .safe, confirmed: true, bundleID: "com.example.a"),
            answer(base + "B", verdict: .yourCall, confirmed: false),
            answer(base + "C", verdict: .keep, confirmed: true),
            answer(Paths.home + "/Library", verdict: .safe, confirmed: true),
        ])
        #expect(entries.count == 1)
        let entry = entries[0]
        #expect(entry.id == "learned:~/Library/Application Support/A")
        #expect(entry.level == .safe)
        #expect(entry.disposal == .trash)
        #expect(entry.quit.map(\.bundleID) == ["com.example.a"])
    }

    @Test func replyDecodesAndTextIsTidied() throws {
        let json = """
        {"name":"Example cache","what":"A cache.  It grows.","owner":"Example","ownerBundleID":"","ownerIsApp":false,
         "verdict":"rebuilds","cost":"Nothing;\\n it downloads again.","howToRemove":"","confidence":"medium"}
        """
        let reply = try JSONDecoder().decode(Explainer.Reply.self, from: Data(json.utf8))
        #expect(reply.verdict == .rebuilds)
        #expect(Explainer.tidy(reply.what) == "A cache. It grows.")
        #expect(Explainer.tidy(reply.cost) == "Nothing; it downloads again.")
    }

    @Test func installedAppsAreFoundByNameWhenTheBundleIDIsWrong() {
        guard FileManager.default.fileExists(atPath: "/Applications/Safari.app") else { return }
        let found = Explainer.installedApp(bundleID: "com.example.not-safari", name: "Safari")
        #expect(found.installed == true)
        #expect(found.bundleID == "com.apple.Safari")
        #expect(Explainer.installedApp(bundleID: "", name: "No Such App 9").installed == false)
        #expect(Explainer.installedApp(bundleID: "", name: "macOS").installed == nil)
    }
}

@Suite struct QuickNotesTests {
    func item(_ id: String, _ name: String, _ group: CandidateGroup, _ bytes: Int64, project: String? = nil) -> Candidate {
        Candidate(id: id, name: name, detail: "", group: group, size: SizeInfo(allocated: bytes, unshared: bytes),
                  isEstimate: false, cost: "", quit: [], blockRules: [], projectPath: project, action: .delete([]),
                  fixedBlocker: nil)
    }

    @Test func summaryNamesCachesButNotYourFilesOrProjects() {
        let home = Paths.home
        let candidates = [
            item("gradle", "Gradle caches", .rebuilds, 8_700_000_000),
            item("build", "secretproject build cache", .ready, 1_600_000_000, project: home + "/code/secretproject"),
            item("npm", "npm download cache", .ready, 70_000_000),
            item("f", "tax-return-2025.pdf", .forgotten, 900_000_000),
        ]
        let alerts = [GrowthAlert(path: home + "/Documents/Taxes", previous: 0, current: 6_000_000_000, since: Date(), sharesSpace: false)]
        let input = QuickNotes.SummaryInput.make(disk: DiskStatus(total: 245_000_000_000, available: 16_400_000_000),
                                                 candidates: candidates, snapshot: nil, warnGB: 20, runway: nil, growth: alerts)
        let message = input.message
        #expect(message.contains("Free: 16 GB of 245 GB. Warning level: 20 GB."))
        #expect(message.contains("Gradle caches 8.7 GB"))
        #expect(message.contains("npm download cache"))
        #expect(!message.contains("secretproject"))
        #expect(!message.contains("tax-return"))
        #expect(!message.contains("Taxes"))
        #expect(message.contains("a personal folder grew"))
        #expect(!message.contains(home))
    }
}
