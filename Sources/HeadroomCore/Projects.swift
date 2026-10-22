import Foundation

public struct Project: Codable, Sendable, Hashable, Identifiable {
    public var path: String
    public var lastActivity: Date?
    public var artifacts: [Artifact]

    public var id: String { path }

    /// Folder name, or the path from home for nested projects (job-agent/backend).
    public var name: String {
        let home = Paths.home + "/"
        return path.hasPrefix(home) ? String(path.dropFirst(home.count)) : (path as NSString).lastPathComponent
    }

    public func isDormant(days: Int, now: Date = Date()) -> Bool {
        guard let last = lastActivity else { return false }
        return now.timeIntervalSince(last) > Double(days) * 86400
    }
}

public struct Artifact: Codable, Sendable, Hashable {
    public var path: String
    public var kind: Kind

    public enum Kind: String, Codable, Sendable {
        case buildCache    // .next, .turbo, .nuxt …: safe in any project
        case dependencies  // node_modules, vendor, .venv, Pods: only for dormant projects
    }

    public var folderName: String { (path as NSString).lastPathComponent }
}

/// Finds code projects and the folders inside them that can be rebuilt.
public enum ProjectFinder {
    static let markers: Set<String> = [
        "package.json", "composer.json", "pyproject.toml", "requirements.txt", "build.gradle",
        "build.gradle.kts", "Podfile", "Package.swift", "Cargo.toml", "pubspec.yaml", "Gemfile", "go.mod",
    ]

    static let buildCaches: Set<String> = [".next", ".turbo", ".nuxt", ".svelte-kit", ".parcel-cache", ".angular"]
    static let dependencyFolders: Set<String> = ["node_modules", ".venv", "venv", "Pods", ".dart_tool"]

    /// Folders never descended into while looking for projects.
    static let skip: Set<String> = [
        "Library", "Applications", "Music", "Movies", "Pictures", "Public", "node_modules", "vendor",
        ".git", ".venv", "venv", "Pods", "build", "dist", ".next", "DerivedData", ".Trash",
    ]

    public static func find(roots: [String], maxDepth: Int = 4) -> [Project] {
        var projects: [Project] = []
        for root in roots { walk(root, depth: 0, maxDepth: maxDepth, into: &projects) }
        return projects
    }

    private static func walk(_ dir: String, depth: Int, maxDepth: Int, into projects: inout [Project]) {
        guard depth <= maxDepth,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        if !markers.isDisjoint(with: names) {
            projects.append(project(at: dir, names: names))
            return
        }
        for name in names where !name.hasPrefix(".") && !skip.contains(name) {
            let path = dir + "/" + name
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
                  !isSymlink(path) else { continue }
            walk(path, depth: depth + 1, maxDepth: maxDepth, into: &projects)
        }
    }

    static func project(at path: String, names: [String]) -> Project {
        var artifacts: [Artifact] = []
        collectArtifacts(path, depth: 0, hasComposer: names.contains("composer.json"), into: &artifacts)
        return Project(path: path, lastActivity: lastActivity(path), artifacts: artifacts)
    }

    /// Looks a few levels down so monorepos (apps/web/.next) and ios/Pods are found.
    private static func collectArtifacts(_ dir: String, depth: Int, hasComposer: Bool, into out: inout [Artifact]) {
        guard depth <= 3, let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        let composerHere = hasComposer || names.contains("composer.json")
        for name in names {
            let path = dir + "/" + name
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
                  !isSymlink(path) else { continue }
            if buildCaches.contains(name) {
                out.append(Artifact(path: path, kind: .buildCache))
            } else if dependencyFolders.contains(name) || (name == "vendor" && composerHere) {
                out.append(Artifact(path: path, kind: .dependencies))
            } else if !name.hasPrefix(".") && !skip.contains(name) {
                collectArtifacts(path, depth: depth + 1, hasComposer: false, into: &out)
            }
        }
    }

    /// The later of the last git commit and the newest top-level file change.
    static func lastActivity(_ path: String) -> Date? {
        var latest: Date?
        if FileManager.default.fileExists(atPath: path + "/.git"),
           let result = Shell.run("/usr/bin/git", ["-C", path, "log", "-1", "--format=%ct"], timeout: 10),
           result.status == 0, let seconds = Double(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) {
            latest = Date(timeIntervalSince1970: seconds)
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        for name in names where !buildCaches.contains(name) && !dependencyFolders.contains(name)
            && name != "vendor" && name != ".git" && name != ".DS_Store" {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path + "/" + name),
               let modified = attrs[.modificationDate] as? Date {
                if latest == nil || modified > latest! { latest = modified }
            }
        }
        return latest
    }

    static func isSymlink(_ path: String) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
    }
}
