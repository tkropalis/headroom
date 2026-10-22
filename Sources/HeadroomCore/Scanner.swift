import Foundation

public struct ScanOptions: Sendable {
    public var projectRoots: [String]
    public var dormantDays: Int
    public var disabledEntries: Set<String>
    public var excludedPaths: [String]
    /// Items smaller than this are not worth showing.
    public var minimumBytes: Int64

    public init(projectRoots: [String] = [Paths.home], dormantDays: Int = 90,
                disabledEntries: Set<String> = [], excludedPaths: [String] = [],
                minimumBytes: Int64 = 20_000_000) {
        self.projectRoots = projectRoots
        self.dormantDays = dormantDays
        self.disabledEntries = disabledEntries
        self.excludedPaths = excludedPaths
        self.minimumBytes = minimumBytes
    }
}

public struct ScanResult: Codable, Sendable {
    public var date: Date
    public var disk: DiskStatus
    public var candidates: [Candidate]
    public var projects: [Project]
    public var unreadableFiles: Int

    public func candidates(in group: CandidateGroup) -> [Candidate] {
        candidates.filter { $0.group == group }.sorted { $0.expectedBytes > $1.expectedBytes }
    }

    public func total(in group: CandidateGroup) -> Int64 {
        candidates(in: group).reduce(0) { $0 + $1.expectedBytes }
    }
}

public enum Scanner {
    public static func scan(_ options: ScanOptions = ScanOptions(),
                            progress: (@Sendable (String) -> Void)? = nil) async -> ScanResult {
        let disk = DiskStatus.current() ?? DiskStatus(total: 0, available: 0)

        progress?("Finding projects")
        async let projectsTask = Task.detached(priority: .utility) {
            ProjectFinder.find(roots: options.projectRoots)
        }.value
        async let dockerTask = Task.detached(priority: .utility) { DockerProbe.reclaimable() }.value

        // Resolve catalogue entries to the paths that exist now.
        var resolved: [(CatalogEntry, [String])] = []
        for entry in Catalog.builtIn where !options.disabledEntries.contains(entry.id) {
            let paths = resolve(entry.target).filter { path in
                !options.excludedPaths.contains { path.hasPrefix($0) }
            }
            if !paths.isEmpty { resolved.append((entry, paths)) }
        }

        let projects = await projectsTask
        let projectPaths = projects.flatMap { project in
            project.artifacts.filter { $0.kind == .buildCache || project.isDormant(days: options.dormantDays) }.map(\.path)
        }

        progress?("Measuring")
        let sizes = await Sizer.measureAll(resolved.flatMap(\.1) + projectPaths)

        var candidates: [Candidate] = []
        var unreadable = 0
        for (entry, paths) in resolved {
            let size = paths.reduce(SizeInfo.zero) { $0 + (sizes[$1] ?? .zero) }
            unreadable += size.unreadable
            guard size.allocated >= options.minimumBytes else { continue }
            let action: CleanupAction
            switch (entry.target, entry.disposal) {
            case (.adminContents(let dir), _): action = .adminDeleteContents(dir)
            case (_, .trash): action = .trash(paths)
            default: action = .delete(paths)
            }
            candidates.append(Candidate(
                id: entry.id, name: entry.name, detail: detail(for: entry.target, paths: paths),
                group: group(for: entry.level), size: size, isEstimate: false, cost: entry.cost,
                quit: entry.quit, blockRules: entry.blockingProcesses.map { BlockRule(match: $0.match, reason: $0.reason) },
                projectPath: nil, action: action, fixedBlocker: nil))
        }

        if !options.disabledEntries.contains("docker"), let entry = Catalog.entry("docker") {
            let docker = await dockerTask
            if docker.installed, (docker.bytes ?? 0) >= options.minimumBytes || !docker.running {
                candidates.append(Candidate(
                    id: entry.id, name: entry.name, detail: "docker system prune -a",
                    group: .rebuilds, size: SizeInfo(allocated: docker.bytes ?? 0, unshared: docker.bytes ?? 0),
                    isEstimate: true, cost: entry.cost, quit: [], blockRules: [], projectPath: nil,
                    action: .dockerPrune, fixedBlocker: docker.running ? nil : "Docker isn't running. Open Docker Desktop to clean this."))
            }
        }

        for project in projects {
            let dormant = project.isDormant(days: options.dormantDays)
            if dormant {
                let paths = project.artifacts.map(\.path)
                let size = paths.reduce(SizeInfo.zero) { $0 + (sizes[$1] ?? .zero) }
                guard size.allocated >= options.minimumBytes else { continue }
                let folders = Set(project.artifacts.map(\.folderName)).sorted().joined(separator: ", ")
                let when = project.lastActivity.map { "last activity " + RelativeDate.shortDate($0) } ?? ""
                candidates.append(Candidate(
                    id: "dormant:" + project.path, name: project.name, detail: "\(folders) · \(when)",
                    group: .dormant, size: size, isEstimate: false,
                    cost: "The code stays. Reinstall dependencies when you return to it.",
                    quit: [], blockRules: [], projectPath: project.path, action: .delete(paths), fixedBlocker: nil))
            } else {
                for artifact in project.artifacts where artifact.kind == .buildCache {
                    let size = sizes[artifact.path] ?? .zero
                    guard size.allocated >= options.minimumBytes else { continue }
                    candidates.append(Candidate(
                        id: "build:" + artifact.path, name: "\(project.name) build cache",
                        detail: Paths.display(artifact.path), group: .ready, size: size, isEstimate: false,
                        cost: "The next dev start in \(project.name) is slower once.",
                        quit: [], blockRules: [], projectPath: project.path, action: .delete([artifact.path]),
                        fixedBlocker: nil))
                }
            }
        }

        progress?("Done")
        return ScanResult(date: Date(), disk: disk, candidates: candidates, projects: projects, unreadableFiles: unreadable)
    }

    static func group(for level: CleanupLevel) -> CandidateGroup {
        switch level {
        case .safe: .ready
        case .rebuilds: .rebuilds
        case .yourCall: .yourCall
        }
    }

    static func detail(for target: Target, paths: [String]) -> String {
        switch target {
        case .oldChildren(let dir, let days): "\(paths.count) folders in \(Paths.display(Paths.expand(dir))) unused for \(days) days"
        case .oldFiles(let dir, _, let days): "\(paths.count) files in \(Paths.display(Paths.expand(dir))) older than \(days) days"
        default: paths.count == 1 ? Paths.display(paths[0]) : paths.map { Paths.display($0) }.joined(separator: ", ")
        }
    }

    /// Turns a target into the paths that exist right now.
    public static func resolve(_ target: Target, now: Date = Date()) -> [String] {
        let fm = FileManager.default
        switch target {
        case .paths(let list):
            return list.map(Paths.expand).filter { fm.fileExists(atPath: $0) }
        case .adminContents(let dir):
            return fm.fileExists(atPath: dir) ? [dir] : []
        case .docker:
            return []
        case .oldChildren(let dir, let days):
            let base = Paths.expand(dir)
            let cutoff = now.addingTimeInterval(-Double(days) * 86400)
            let names = (try? fm.contentsOfDirectory(atPath: base)) ?? []
            return names.map { base + "/" + $0 }.filter { path in
                guard let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return false }
                return modified < cutoff
            }
        case .oldFiles(let dir, let ext, let days):
            let base = Paths.expand(dir)
            let cutoff = now.addingTimeInterval(-Double(days) * 86400)
            guard let walker = fm.enumerator(at: URL(fileURLWithPath: base),
                                             includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
            var out: [String] = []
            for case let url as URL in walker where url.pathExtension == ext {
                if let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   modified < cutoff {
                    out.append(url.path)
                }
            }
            return out
        }
    }
}

/// Asks Docker how much `docker system prune -a` would free.
public enum DockerProbe {
    public static var executable: String? {
        Shell.which(["/usr/local/bin/docker", "/opt/homebrew/bin/docker",
                     "/Applications/Docker.app/Contents/Resources/bin/docker"])
    }

    public static func reclaimable() -> (installed: Bool, running: Bool, bytes: Int64?) {
        guard let docker = executable else { return (false, false, nil) }
        guard let result = Shell.run(docker, ["system", "df", "--format", "{{json .}}"], timeout: 20),
              result.status == 0 else { return (true, false, nil) }
        var total: Int64 = 0
        for line in result.output.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["Type"] as? String, type != "Local Volumes",
                  let text = object["Reclaimable"] as? String else { continue }
            total += parseSize(text)
        }
        return (true, true, total)
    }

    /// Parses Docker's sizes such as "2.345GB (45%)" or "512.3MB".
    public static func parseSize(_ text: String) -> Int64 {
        let token = text.split(separator: " ").first.map(String.init) ?? ""
        let number = token.prefix { $0.isNumber || $0 == "." }
        let unit = token.dropFirst(number.count).uppercased()
        guard let value = Double(number) else { return 0 }
        let scale: Double = switch unit {
        case "KB": 1e3
        case "MB": 1e6
        case "GB": 1e9
        case "TB": 1e12
        default: 1
        }
        return Int64(value * scale)
    }
}
