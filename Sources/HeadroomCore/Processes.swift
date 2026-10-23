import AppKit
import Foundation

/// What is running right now: GUI apps and every process's command line.
public struct ProcessSnapshot: Sendable {
    public var commandLines: [String]
    public var runningBundleIDs: Set<String>

    public init(commandLines: [String], runningBundleIDs: Set<String>) {
        self.commandLines = commandLines
        self.runningBundleIDs = runningBundleIDs
    }

    public static func capture() -> ProcessSnapshot {
        let ids = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let output = Shell.run("/bin/ps", ["-axww", "-o", "command="])?.output ?? ""
        let lines = output.split(separator: "\n").map(String.init)
        return ProcessSnapshot(commandLines: lines, runningBundleIDs: ids)
    }

    public func isRunning(_ app: AppRef) -> Bool { runningBundleIDs.contains(app.bundleID) }

    public func anyProcess(containing needle: String) -> Bool {
        commandLines.contains { $0.contains(needle) }
    }

    /// A short name for a command line: the app it belongs to, else the program's own name.
    /// "/Applications/Claude.app/…/chrome_crashpad_handler --database=…" is "Claude".
    public static func displayName(_ commandLine: String) -> String {
        if let range = commandLine.range(of: ".app/") {
            let bundle = commandLine[..<range.lowerBound]
            return (String(bundle) as NSString).lastPathComponent
        }
        // Paths may hold spaces, so the program ends where the first option starts.
        let program = commandLine.components(separatedBy: " -").first ?? commandLine
        let name = (program.trimmingCharacters(in: .whitespaces) as NSString).lastPathComponent
        return name.split(separator: " ").first.map(String.init) ?? name
    }

    /// A dev server or build tool running inside a project folder.
    public func processUsing(folder: String) -> String? {
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        return commandLines.first { line in
            line.contains(prefix) && !line.contains("/Contents/MacOS/") && !line.hasPrefix("/bin/ps")
        }
    }
}

public enum Shell {
    public struct Result: Sendable {
        public var status: Int32
        public var output: String
        public var error: String
    }

    /// Runs a command and waits for it. Returns nil when it can't be started.
    @discardableResult
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 120) -> Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return nil }

        // Read before waiting so a full pipe can't block the child.
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        group.wait()
        return Result(status: process.terminationStatus,
                      output: String(decoding: outData, as: UTF8.self),
                      error: String(decoding: errData, as: UTF8.self))
    }

    public static func which(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
