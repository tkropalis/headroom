import Foundation

/// Developer leftovers that need a tool to find them: simulators, runtimes, emulators, archives.
public enum Probe: String, Sendable {
    case unavailableSimulators, idleSimulators, unusedRuntimes
    case idleEmulators, unusedSystemImages, oldArchives
    case pnpmStore, homebrew
}

/// What a probe found: the folders to measure (if any) and how to clean them.
public struct ProbeResult: Sendable {
    public var paths: [String]
    public var action: CleanupAction
    public var detail: String
    /// The tool's own size when the files can't be measured directly.
    public var estimate: Int64?
}

public enum DevLeftovers {
    static let day: TimeInterval = 86400

    public static func run(_ probe: Probe, now: Date = Date()) -> ProbeResult? {
        switch probe {
        case .unavailableSimulators: unavailableSimulators()
        case .idleSimulators: idleSimulators(days: 90, now: now)
        case .unusedRuntimes: unusedRuntimes()
        case .idleEmulators: idleEmulators(days: 60, now: now)
        case .unusedSystemImages: unusedSystemImages()
        case .oldArchives: oldArchives(days: 365, now: now)
        case .pnpmStore: pnpmStore()
        case .homebrew: homebrew()
        }
    }

    // MARK: - Simulators

    struct SimDevice {
        var udid: String
        var name: String
        var runtime: String
        var state: String
        var available: Bool
        var lastBooted: Date?
        var folder: String
    }

    static var xcrun: String? { FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") ? "/usr/bin/xcrun" : nil }

    static func simDevices(_ filter: String? = nil) -> [SimDevice] {
        guard let xcrun else { return [] }
        var args = ["simctl", "list", "devices"]
        if let filter { args.append(filter) }
        args.append("-j")
        guard let run = Shell.run(xcrun, args, timeout: 30), run.status == 0,
              let json = try? JSONSerialization.jsonObject(with: Data(run.output.utf8)) as? [String: Any],
              let devices = json["devices"] as? [String: [[String: Any]]] else { return [] }
        let iso = ISO8601DateFormatter()
        return devices.flatMap { runtime, list in
            list.compactMap { d -> SimDevice? in
                guard let udid = d["udid"] as? String, let data = d["dataPath"] as? String else { return nil }
                return SimDevice(udid: udid, name: d["name"] as? String ?? udid, runtime: runtime,
                                 state: d["state"] as? String ?? "", available: d["isAvailable"] as? Bool ?? true,
                                 lastBooted: (d["lastBootedAt"] as? String).flatMap(iso.date(from:)),
                                 folder: (data as NSString).deletingLastPathComponent)
            }
        }
    }

    static func unavailableSimulators() -> ProbeResult? {
        guard let xcrun else { return nil }
        let gone = simDevices("unavailable").filter { !$0.available }
        guard !gone.isEmpty else { return nil }
        return ProbeResult(paths: gone.map(\.folder), action: .run([Command(xcrun, ["simctl", "delete", "unavailable"])]),
                           detail: "\(gone.count) simulators whose iOS version is no longer installed", estimate: nil)
    }

    static func idleSimulators(days: Int, now: Date) -> ProbeResult? {
        guard let xcrun else { return nil }
        let cutoff = now.addingTimeInterval(-Double(days) * day)
        let idle = simDevices("available").filter { device in
            guard device.state == "Shutdown" else { return false }
            if let booted = device.lastBooted { return booted < cutoff }
            let created = (try? FileManager.default.attributesOfItem(atPath: device.folder))?[.creationDate] as? Date
            return (created ?? now) < cutoff
        }
        guard !idle.isEmpty else { return nil }
        return ProbeResult(paths: idle.map(\.folder), action: .run([Command(xcrun, ["simctl", "delete"] + idle.map(\.udid))]),
                           detail: idle.count == 1 ? idle[0].name : "\(idle.count) simulators, including \(idle[0].name)",
                           estimate: nil)
    }

    static func unusedRuntimes() -> ProbeResult? {
        guard let xcrun, let run = Shell.run(xcrun, ["simctl", "runtime", "list", "-j"], timeout: 30), run.status == 0,
              let json = try? JSONSerialization.jsonObject(with: Data(run.output.utf8)) as? [String: [String: Any]]
        else { return nil }
        let used = Set(simDevices().map(\.runtime))
        let unused = json.values.filter { r in
            (r["deletable"] as? Bool ?? false) && !used.contains(r["runtimeIdentifier"] as? String ?? "")
        }
        guard !unused.isEmpty else { return nil }
        let bytes = unused.reduce(Int64(0)) { $0 + ((($1["sizeBytes"] as? NSNumber)?.int64Value) ?? 0) }
        let names = unused.compactMap { r in (r["version"] as? String).map { "iOS " + $0 } }.sorted()
        return ProbeResult(paths: [], action: .run(unused.compactMap { r in
            (r["identifier"] as? String).map { Command(xcrun, ["simctl", "runtime", "delete", $0]) }
        }), detail: names.joined(separator: ", "), estimate: bytes)
    }

    // MARK: - Android

    static var avdHome: String { Paths.home + "/.android/avd" }
    static var sdkHome: String { Paths.home + "/Library/Android/sdk" }

    /// Last time an emulator wrote to its own folder, which happens on every start.
    static func lastUsed(_ folder: String) -> Date? {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: folder)) ?? []
        return names.compactMap { (try? fm.attributesOfItem(atPath: folder + "/" + $0))?[.modificationDate] as? Date }.max()
    }

    static func idleEmulators(days: Int, now: Date) -> ProbeResult? {
        let fm = FileManager.default
        let cutoff = now.addingTimeInterval(-Double(days) * day)
        let avds = ((try? fm.contentsOfDirectory(atPath: avdHome)) ?? []).filter { $0.hasSuffix(".avd") }
        let idle = avds.filter { (lastUsed(avdHome + "/" + $0) ?? now) < cutoff }
        guard !idle.isEmpty else { return nil }
        let paths = idle.flatMap { name -> [String] in
            let ini = avdHome + "/" + name.replacingOccurrences(of: ".avd", with: ".ini")
            return [avdHome + "/" + name] + (fm.fileExists(atPath: ini) ? [ini] : [])
        }
        return ProbeResult(paths: paths, action: .delete(paths),
                           detail: idle.map { $0.replacingOccurrences(of: ".avd", with: "") }.joined(separator: ", "),
                           estimate: nil)
    }

    static func unusedSystemImages() -> ProbeResult? {
        let fm = FileManager.default
        let root = sdkHome + "/system-images"
        // image.sysdir.1=system-images/android-36/google_apis_playstore/arm64-v8a/
        var used = Set<String>()
        for name in (try? fm.contentsOfDirectory(atPath: avdHome)) ?? [] where name.hasSuffix(".avd") {
            let config = (try? String(contentsOfFile: avdHome + "/" + name + "/config.ini", encoding: .utf8)) ?? ""
            for line in config.split(separator: "\n") where line.hasPrefix("image.sysdir") {
                let value = line.split(separator: "=", maxSplits: 1).last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
                used.insert((sdkHome + "/" + value as NSString).standardizingPath)
            }
        }
        var unused: [String] = []
        for api in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where !api.hasPrefix(".") {
            for tag in (try? fm.contentsOfDirectory(atPath: root + "/" + api)) ?? [] where !tag.hasPrefix(".") {
                for abi in (try? fm.contentsOfDirectory(atPath: root + "/" + api + "/" + tag)) ?? [] where !abi.hasPrefix(".") {
                    let path = [root, api, tag, abi].joined(separator: "/")
                    if !used.contains(path) { unused.append(path) }
                }
            }
        }
        guard !unused.isEmpty else { return nil }
        return ProbeResult(paths: unused, action: .delete(unused),
                           detail: unused.map { $0.dropFirst(root.count + 1).replacingOccurrences(of: "/", with: " ") }.joined(separator: ", "),
                           estimate: nil)
    }

    // MARK: - Xcode archives

    static func oldArchives(days: Int, now: Date) -> ProbeResult? {
        let fm = FileManager.default
        let root = Paths.home + "/Library/Developer/Xcode/Archives"
        let cutoff = now.addingTimeInterval(-Double(days) * day)
        var byApp: [String: [(path: String, date: Date)]] = [:]
        for folder in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            for name in (try? fm.contentsOfDirectory(atPath: root + "/" + folder)) ?? [] where name.hasSuffix(".xcarchive") {
                let path = root + "/" + folder + "/" + name
                let info = NSDictionary(contentsOfFile: path + "/Info.plist")
                let app = (info?["Name"] as? String) ?? String(name.split(separator: " ").first ?? "")
                let date = (info?["CreationDate"] as? Date)
                    ?? ((try? fm.attributesOfItem(atPath: path))?[.creationDate] as? Date) ?? now
                byApp[app, default: []].append((path, date))
            }
        }
        // Keep the newest archive of every app, whatever its age.
        let old = byApp.values.flatMap { list in
            list.sorted { $0.date > $1.date }.dropFirst().filter { $0.date < cutoff }.map(\.path)
        }
        guard !old.isEmpty else { return nil }
        return ProbeResult(paths: old, action: .trash(old), detail: "\(old.count) archives in \(Paths.display(root))", estimate: nil)
    }

    // MARK: - Package managers

    static func pnpmStore() -> ProbeResult? {
        let store = Paths.home + "/Library/pnpm/store"
        guard FileManager.default.fileExists(atPath: store) else { return nil }
        if let pnpm = Shell.which(["/opt/homebrew/bin/pnpm", "/usr/local/bin/pnpm", Paths.home + "/Library/pnpm/pnpm",
                                   Paths.home + "/.local/share/pnpm/pnpm"]) {
            return ProbeResult(paths: [store], action: .run([Command(pnpm, ["store", "prune"])]),
                               detail: "pnpm store prune", estimate: nil)
        }
        // pnpm itself is gone, so nothing uses its store any more.
        return ProbeResult(paths: [store], action: .delete([store]),
                           detail: "\(Paths.display(store)), left over after pnpm was removed", estimate: nil)
    }

    static func homebrew() -> ProbeResult? {
        let cache = Paths.home + "/Library/Caches/Homebrew"
        guard let brew = Shell.which(["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]) else {
            return FileManager.default.fileExists(atPath: cache)
                ? ProbeResult(paths: [cache], action: .delete([cache]), detail: Paths.display(cache), estimate: nil) : nil
        }
        guard let dry = Shell.run(brew, ["cleanup", "--prune=all", "-s", "-n"], timeout: 60), dry.status == 0 else { return nil }
        let bytes = parseBrewEstimate(dry.output)
        guard bytes > 0 else { return nil }
        return ProbeResult(paths: [], action: .run([Command(brew, ["cleanup", "--prune=all", "-s"])]),
                           detail: "brew cleanup", estimate: bytes)
    }

    /// "This operation would free approximately 34.6MB of disk space."
    public static func parseBrewEstimate(_ output: String) -> Int64 {
        guard let range = output.range(of: "approximately ") else { return 0 }
        let rest = output[range.upperBound...].prefix { $0 != " " }
        return DockerProbe.parseSize(String(rest))
    }
}
