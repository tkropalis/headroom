import AppKit
import Foundation

public struct CleanupOutcome: Codable, Sendable, Identifiable, Hashable {
    public enum State: String, Codable, Sendable { case done, skipped, failed }

    public var id: String
    public var name: String
    public var state: State
    /// Measured from free space before and after; 0 when nothing changed.
    public var freed: Int64
    public var message: String?
    /// Moved to the Bin: the space comes back only when the Bin is emptied.
    public var inBin: Bool
    /// Where each item went in the Bin, keyed by that path, with its original path, for Put Back.
    public var restorable: [String: String]?
    /// Size shown before cleaning, so Bin items can say how much they will free.
    public var expected: Int64?

    public init(id: String, name: String, state: State, freed: Int64, message: String?, inBin: Bool = false,
                restorable: [String: String]? = nil, expected: Int64? = nil) {
        self.id = id
        self.name = name
        self.state = state
        self.freed = freed
        self.message = message
        self.inBin = inBin
        self.restorable = restorable
        self.expected = expected
    }

    /// What the result list shows on the right.
    public var resultLabel: String {
        switch state {
        case .done: inBin && freed == 0 ? "In the Bin" : ByteFormat.string(freed)
        case .skipped: "Skipped"
        case .failed: "Failed"
        }
    }
}

/// Cleans candidates one at a time and measures what each actually freed.
public struct Cleaner: Sendable {
    public init() {}

    public func run(_ items: [Candidate],
                    onStart: (@Sendable (Int) -> Void)? = nil,
                    onFinish: (@Sendable (CleanupOutcome) -> Void)? = nil,
                    shouldStop: (@Sendable () -> Bool)? = nil) async -> [CleanupOutcome] {
        var outcomes: [CleanupOutcome] = []
        for (index, item) in items.enumerated() {
            if shouldStop?() == true { break }
            onStart?(index)
            let outcome = await clean(item)
            outcomes.append(outcome)
            onFinish?(outcome)
        }
        return outcomes
    }

    public func clean(_ item: Candidate) async -> CleanupOutcome {
        let inBin: Bool = if case .trash = item.action { true } else { false }
        var restorable: [String: String] = [:]
        func result(_ state: CleanupOutcome.State, _ freed: Int64 = 0, _ message: String? = nil) -> CleanupOutcome {
            CleanupOutcome(id: item.id, name: item.name, state: state, freed: freed, message: message,
                           inBin: inBin && state == .done, restorable: restorable.isEmpty ? nil : restorable,
                           expected: item.expectedBytes)
        }

        let status = item.status(with: ProcessSnapshot.capture())
        if let blocker = status.blocker { return result(.skipped, 0, blocker) }

        for app in status.appsToQuit {
            if !(await quit(app)) {
                return result(.skipped, 0, "\(app.name) didn't quit. It may have unsaved work.")
            }
        }

        let before = DiskStatus.current()?.available ?? 0
        let step: StepResult
        var note: String?

        switch item.action {
        case .delete(let paths):
            step = delete(paths)
        case .trash(let paths):
            let moved = trash(paths)
            step = moved.step
            restorable = moved.locations
            note = "Moved to the Bin. Empty the Bin to free the space."
        case .adminDeleteContents(let dir):
            step = adminDeleteContents(dir)
        case .dockerPrune:
            step = dockerPrune()
            note = "Docker Desktop returns space to the Mac gradually."
        case .run(let commands):
            step = run(commands)
        case .share(let group):
            // Leave the copies in projects whose dev server is running; their watchers would see changes.
            let processes = ProcessSnapshot.capture()
            let busy = group.projectPaths.filter { processes.processUsing(folder: $0) != nil }
            var safe = group
            safe.sets = group.sets.map { set in
                var set = set
                set.copies = set.copies.filter { copy in !busy.contains { copy.hasPrefix($0 + "/") } }
                return set
            }.filter { !$0.copies.isEmpty }
            let shared = IdenticalFiles.share(safe)
            step = StepResult(removedAnything: shared.sharedFiles > 0,
                              failure: shared.failures.isEmpty ? nil : shared.failures.prefix(2).joined(separator: " "))
            if shared.skipped > 0 { note = "\(shared.skipped) files were skipped because they changed or are in use." }
        }

        // APFS can take a moment to account freed blocks.
        try? await Task.sleep(for: .milliseconds(400))
        let after = DiskStatus.current()?.available ?? before
        let freed = step.removedAnything ? max(0, after - before) : 0

        if let failure = step.failure {
            return result(step.removedAnything ? .done : .failed, freed, failure)
        }
        return result(.done, freed, note)
    }

    struct StepResult {
        var removedAnything: Bool
        var failure: String?
    }

    // MARK: - Actions

    func delete(_ paths: [String]) -> StepResult {
        var failed: [String] = []
        var removed = false
        for path in paths {
            guard PathSafety.isDeletable(path) else {
                failed.append(Paths.display(path) + " (protected)")
                continue
            }
            guard FileManager.default.fileExists(atPath: path) || isDanglingLink(path) else { continue }
            do {
                try FileManager.default.removeItem(atPath: path)
                removed = true
            } catch {
                // Read-only files (dotslash, Go modules) need write permission first.
                Shell.run("/usr/bin/chflags", ["-R", "nouchg", path])
                Shell.run("/bin/chmod", ["-R", "u+w", path])
                do { try FileManager.default.removeItem(atPath: path); removed = true }
                catch { failed.append(Paths.display(path)) }
            }
        }
        return StepResult(removedAnything: removed,
                          failure: failed.isEmpty ? nil : "Couldn't remove " + failed.joined(separator: ", ") + ".")
    }

    func trash(_ paths: [String]) -> (step: StepResult, locations: [String: String]) {
        var failed: [String] = []
        var locations: [String: String] = [:]
        for path in paths where FileManager.default.fileExists(atPath: path) {
            guard PathSafety.isDeletable(path) else { failed.append(Paths.display(path)); continue }
            do {
                var resulting: NSURL?
                try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
                if let trashed = resulting?.path { locations[trashed] = path }
            } catch { failed.append(Paths.display(path)) }
        }
        let step = StepResult(removedAnything: !locations.isEmpty,
                              failure: failed.isEmpty ? nil : "Couldn't move " + failed.joined(separator: ", ") + " to the Bin.")
        return (step, locations)
    }

    /// Moves items back from the Bin to where they were. Returns the originals that could not be restored.
    public static func putBack(_ locations: [String: String]) -> [String] {
        let fm = FileManager.default
        var failed: [String] = []
        for (trashed, original) in locations {
            guard fm.fileExists(atPath: trashed), !fm.fileExists(atPath: original) else { failed.append(original); continue }
            do {
                try fm.createDirectory(atPath: (original as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try fm.moveItem(atPath: trashed, toPath: original)
            } catch { failed.append(original) }
        }
        return failed
    }

    /// True while every item is still in the Bin, so Put Back can work.
    public static func canPutBack(_ locations: [String: String]) -> Bool {
        !locations.isEmpty && locations.allSatisfy { FileManager.default.fileExists(atPath: $0.key) && !FileManager.default.fileExists(atPath: $0.value) }
    }

    func run(_ commands: [Command]) -> StepResult {
        var ranAny = false
        for command in commands {
            guard let result = Shell.run(command.executable, command.arguments, timeout: 900) else {
                return StepResult(removedAnything: ranAny, failure: "Couldn't start \(command.display).")
            }
            guard result.status == 0 else {
                let reason = result.error.split(separator: "\n").first.map(String.init) ?? "exit \(result.status)"
                return StepResult(removedAnything: ranAny, failure: "\(command.display) failed: \(reason.prefix(120))")
            }
            ranAny = true
        }
        return StepResult(removedAnything: ranAny, failure: nil)
    }

    func adminDeleteContents(_ dir: String) -> StepResult {
        // Only the folders the catalogue names may be cleaned with admin rights.
        let allowed: Set<String> = ["/Library/Developer/CoreSimulator/Caches"]
        guard allowed.contains(dir), !dir.contains("'") else {
            return StepResult(removedAnything: false, failure: "This folder can't be cleaned with admin rights.")
        }
        let script = "do shell script \"/bin/rm -rf '\(dir)'/*\" with administrator privileges"
        guard let run = Shell.run("/usr/bin/osascript", ["-e", script], timeout: 300) else {
            return StepResult(removedAnything: false, failure: "Couldn't ask for your password.")
        }
        if run.status != 0 {
            return StepResult(removedAnything: false,
                              failure: run.error.contains("-128") ? "Cancelled at the password prompt." : "The admin cleanup failed.")
        }
        return StepResult(removedAnything: true, failure: nil)
    }

    func dockerPrune() -> StepResult {
        guard let docker = DockerProbe.executable else { return StepResult(removedAnything: false, failure: "Docker isn't installed.") }
        guard let run = Shell.run(docker, ["system", "prune", "-a", "-f"], timeout: 900) else {
            return StepResult(removedAnything: false, failure: "Couldn't start docker.")
        }
        return run.status == 0
            ? StepResult(removedAnything: true, failure: nil)
            : StepResult(removedAnything: false, failure: "docker system prune failed: " + run.error.prefix(120))
    }

    /// Asks an app to quit and waits up to 15 seconds.
    public func quit(_ app: AppRef) async -> Bool {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
        guard !running.isEmpty else { return true }
        let pids = running.map(\.processIdentifier)
        for instance in running { instance.terminate() }
        for _ in 0..<75 {
            if pids.allSatisfy({ kill($0, 0) != 0 }) { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    private func isDanglingLink(_ path: String) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
    }
}
