import Foundation
import Testing
@testable import HeadroomCore

@Suite struct PlanTests {
    let home = Paths.home
    let gb: Int64 = 1_000_000_000
    let drive = OffloadDestination(id: "uuid-1", name: "ilo-external", root: "/Volumes/ilo-external",
                                   kind: .drive(format: "APFS", keepsMetadata: true), available: 900_000_000_000)

    func item(_ path: String, _ destination: PlanDestination = .bin, cost: SpaceCost = .yourCall) -> PlanItem {
        PlanItem(path: Paths.expand(path), name: (path as NSString).lastPathComponent, bytes: 2 * gb, cost: cost, destination: destination)
    }

    @Test func savesAndLoads() throws {
        var plan = CleanupPlan()
        plan.add(item("~/.android", .drive(id: "uuid-1", name: "ilo-external")))
        plan.add(item("~/Library/Android/sdk", .bin, cost: .slowerNext))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = try decoder.decode(CleanupPlan.self, from: encoder.encode(plan))
        #expect(loaded.items.map(\.path) == plan.items.map(\.path))
        #expect(loaded.items[0].destination == .drive(id: "uuid-1", name: "ilo-external"))
        #expect(loaded.binBytes == 2 * gb)
    }

    @Test func noDoubleCounting() {
        var plan = CleanupPlan()
        let inside = plan.add(item("~/.android/avd/Pixel_7.avd"))
        let folder = plan.add(item("~/.android"))
        #expect(inside && folder)
        #expect(plan.items.map(\.name) == [".android"])
        let again = plan.add(item("~/.android/cache"))
        let twice = plan.add(item("~/.android"))
        #expect(!again && !twice)
    }

    @Test func destinationsDefaultByCost() {
        let withDrive: [PlanDestination] = [.drive(id: "uuid-1", name: "ilo-external"), .bin]
        #expect(PlanRules.defaultDestination(cost: .nothingLost, among: withDrive) == .bin)
        #expect(PlanRules.defaultDestination(cost: .slowerNext, among: withDrive) == .bin)
        #expect(PlanRules.defaultDestination(cost: .yourCall, among: withDrive) == .drive(id: "uuid-1", name: "ilo-external"))
        #expect(PlanRules.defaultDestination(cost: .yourCall, among: [.bin]) == .bin)
        #expect(PlanRules.defaultDestination(cost: .yourFiles, among: [.shared, .bin]) == .shared)
    }

    @Test func onlyBinOrDriveOutsideTheCatalogue() {
        let choices = PlanRules.destinations(for: home + "/somewhere", candidate: nil, drives: [drive], canOffload: { _ in nil })
        #expect(choices == [.drive(id: "uuid-1", name: "ilo-external"), .bin])
        let noDrive = PlanRules.destinations(for: home + "/Library/Containers/x", candidate: nil, drives: [drive],
                                             canOffload: { _ in "Headroom doesn't move app data it doesn't know." })
        #expect(noDrive == [.bin])
    }

    @Test func refusals() {
        #expect(PlanRules.refusal(home + "/Documents", inUse: nil) != nil)
        #expect(PlanRules.refusal(home + "/Library", inUse: nil) != nil)
        #expect(PlanRules.refusal("headroom:unmeasured", inUse: nil) != nil)
        #expect(PlanRules.refusal(home + "/.android", inUse: "Android Studio is open.")?.contains("in use") == true)
        #expect(PlanRules.refusal(home + "/.android", inUse: nil) == nil)
    }

    @Test func checkFindsEmulatorAndSDK() {
        var plan = CleanupPlan()
        plan.add(item("~/.android"))
        plan.add(item("~/Library/Android/sdk", cost: .slowerNext))
        let facts = PlanCheck.facts(for: plan)
        #expect(facts.first?.kind == .needs)
        #expect(facts.contains { $0.kind == .savedData && $0.text.contains("snapshots") })

        // Kept on a drive, the emulators lose nothing.
        plan.setDestination(.drive(id: "uuid-1", name: "ilo-external"), for: home + "/.android")
        let kept = PlanCheck.facts(for: plan)
        #expect(!kept.contains { $0.kind == .needs })
        #expect(kept.contains { $0.kind == .kept && $0.text.contains("ilo-external keeps .android") })
    }

    @Test func checkFindsGameSaves() {
        var plan = CleanupPlan()
        plan.add(item("~/Library/Application Support/minecraft"))
        let facts = PlanCheck.facts(for: plan, quits: { _ in [AppRef("Minecraft", "com.mojang.minecraftlauncher")] })
        #expect(facts.contains { $0.kind == .savedData && $0.text.contains("Minecraft worlds") })
        #expect(facts.contains { $0.kind == .quitsApps && $0.text == "Minecraft is quit first." })
        #expect(facts.contains { $0.kind == .bin })
    }

    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        func add(_ call: String) { lock.withLock { list.append(call) } }
        var all: [String] { lock.withLock { list } }
    }

    @Test func runsEachDestinationThroughItsPath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plan-\(UUID().uuidString)").path
        let fm = FileManager.default
        for name in ["a", "b", "c"] { try fm.createDirectory(atPath: root + "/" + name, withIntermediateDirectories: true) }
        defer { try? fm.removeItem(atPath: root) }

        let calls = Calls()
        let done = { (item: PlanItem) in CleanupOutcome(id: item.path, name: item.name, state: .done, freed: item.bytes, message: nil) }
        let runner = PlanRunner(
            toBin: { item, candidate in
                if case .trash(let paths) = candidate.action, paths == [item.path] { calls.add("bin:" + item.name) }
                return done(item)
            },
            toDrive: { item, drive, apps in calls.add("drive:\(item.name):\(drive.name):\(apps.map(\.name))"); return done(item) },
            share: { candidate in calls.add("share:" + candidate.id); return CleanupOutcome(id: candidate.id, name: "", state: .done, freed: 0, message: nil) },
            canOffload: { _ in nil })

        let group = IdenticalGroup(id: "g", name: "x", detail: "", sets: [], projectPaths: [], reclaimable: 0)
        let sharing = Candidate(id: "identical", name: "Copies", detail: "", group: .identical, size: .zero, isEstimate: false,
                                cost: "", quit: [], blockRules: [], projectPath: nil, action: .share(group), fixedBlocker: nil)
        var plan = CleanupPlan()
        plan.add(PlanItem(path: root + "/a", name: "a", bytes: 1, cost: .nothingLost, destination: .bin))
        plan.add(PlanItem(path: root + "/b", name: "b", bytes: 1, cost: .yourCall, destination: .drive(id: "uuid-1", name: "ilo-external")))
        plan.add(PlanItem(path: root + "/c", name: "c", bytes: 1, cost: .yourFiles, destination: .shared))
        plan.add(PlanItem(path: root + "/gone", name: "gone", bytes: 1, cost: .nothingLost, destination: .bin))
        plan.add(PlanItem(path: root + "/a2", name: "a2", bytes: 1, cost: .yourCall, destination: .drive(id: "other", name: "Other drive")))

        let outcomes = await runner.run(plan, drives: [drive],
                                        candidate: { $0.hasSuffix("/c") ? sharing : nil },
                                        quits: { $0.hasSuffix("/b") ? [AppRef("Android Studio", "com.google.android.studio")] : [] })
        #expect(calls.all == ["bin:a", "drive:b:ilo-external:[\"Android Studio\"]", "share:identical"])
        #expect(outcomes.map(\.state) == [.done, .done, .done, .skipped, .skipped])
        #expect(outcomes[4].message == "It's no longer there.")
    }
}
