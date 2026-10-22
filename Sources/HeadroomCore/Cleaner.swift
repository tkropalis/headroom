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

    public init(id: String, name: String, state: State, freed: Int64, message: String?, inBin: Bool = false) {
        self.id = id
        self.name = name
        self.state = state
        self.freed = freed
        self.message = message
        self.inBin = inBin
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
        func result(_ state: CleanupOutcome.State, _ freed: Int64 = 0, _ message: String? = nil) -> CleanupOutcome {
            CleanupOutcome(id: item.id, name: item.name, state: state, freed: freed, message: message,
                           inBin: inBin && state == .done)
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
            step = trash(paths)
            note = "Moved to the Bin. Empty the Bin to free the space."
        case .adminDeleteContents(let dir):
            step = adminDeleteContents(dir)
        case .dockerPrune:
            step = dockerPrune()
            note = "Docker Desktop returns space to the Mac gradually."
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

    func trash(_ paths: [String]) -> StepResult {
        var failed: [String] = []
        var moved = false
        for path in paths where FileManager.default.fileExists(atPath: path) {
            guard PathSafety.isDeletable(path) else { failed.append(Paths.display(path)); continue }
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                moved = true
            } catch { failed.append(Paths.display(path)) }
        }
        return StepResult(removedAnything: moved,
                          failure: failed.isEmpty ? nil : "Couldn't move " + failed.joined(separator: ", ") + " to the Bin.")
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
    func quit(_ app: AppRef) async -> Bool {
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
