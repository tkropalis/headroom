import CoreServices
import Foundation

/// Big files nobody has opened for months, and installers for apps that are already installed.
public enum ForgottenFiles {
    static let installerExtensions: Set<String> = ["dmg", "pkg", "xip", "iso"]
    static let packageExtensions: Set<String> = ["app", "photoslibrary", "musiclibrary", "tvlibrary", "bundle",
                                                 "framework", "xcarchive", "fcpbundle", "logicx", "band", "sparsebundle"]

    public static func find(minimumBytes: Int64 = 500_000_000, days: Int = 180, projects: [String] = [],
                            excluded: [String] = [], now: Date = Date()) -> [Candidate] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        var out: [Candidate] = []
        var seen = Set<String>()

        for path in spotlight(minimumBytes: minimumBytes) where eligible(path, projects: projects, excluded: excluded) {
            guard seen.insert(path).inserted, let bytes = regularFileSize(path) else { continue }
            let opened = lastOpened(path)
            guard (opened ?? .distantFuture) < cutoff else { continue }
            out.append(candidate(path, bytes: bytes, cost: "Not opened since \(RelativeDate.shortDate(opened!))."))
        }

        let installerCutoff = now.addingTimeInterval(-14 * 86400)
        let downloads = Paths.home + "/Downloads"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: downloads)) ?? [] {
            let path = downloads + "/" + name
            guard installerExtensions.contains((name as NSString).pathExtension.lowercased()),
                  !seen.contains(path), let bytes = regularFileSize(path), bytes >= 20_000_000,
                  let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                  modified < installerCutoff, let app = installedApp(forInstaller: name) else { continue }
            seen.insert(path)
            out.append(candidate(path, bytes: bytes, cost: "An installer for \(app), which is already installed."))
        }
        return Array(out.sorted { $0.size.allocated > $1.size.allocated }.prefix(30))
    }

    static func candidate(_ path: String, bytes: Int64, cost: String) -> Candidate {
        let folder = Paths.display((path as NSString).deletingLastPathComponent)
        return Candidate(id: "forgotten:" + path, name: (path as NSString).lastPathComponent, detail: folder,
                         group: .forgotten, size: SizeInfo(allocated: bytes, unshared: bytes, files: 1),
                         isEstimate: false, cost: cost, quit: [], blockRules: [], projectPath: nil,
                         action: .trash([path]), fixedBlocker: nil)
    }

    /// Asks Spotlight for files in the home folder of at least this size.
    static func spotlight(minimumBytes: Int64) -> [String] {
        guard let run = Shell.run("/usr/bin/mdfind", ["-onlyin", Paths.home, "kMDItemFSSize >= \(minimumBytes)"], timeout: 60),
              run.status == 0 else { return [] }
        return run.output.split(separator: "\n").map(String.init)
    }

    static func eligible(_ path: String, projects: [String], excluded: [String]) -> Bool {
        let home = Paths.home
        guard path.hasPrefix(home + "/") else { return false }
        let relative = path.dropFirst(home.count + 1)
        if relative.hasPrefix("Library/") || relative.hasPrefix(".Trash/") { return false }
        let parts = relative.split(separator: "/")
        // Hidden folders (caches, tool data) and anything inside a package are not "files you made".
        if parts.dropLast().contains(where: { $0.hasPrefix(".") || packageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }) {
            return false
        }
        if projects.contains(where: { path.hasPrefix($0 + "/") }) { return false }
        if excluded.contains(where: { path.hasPrefix($0) }) { return false }
        return true
    }

    /// Size of a regular, downloaded file; nil for folders, links and iCloud placeholders.
    static func regularFileSize(_ path: String) -> Int64? {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        if st.st_flags & 0x40000000 != 0 { return nil } // SF_DATALESS: not downloaded
        return Int64(st.st_blocks) * 512
    }

    /// Spotlight's last-opened date, else the last time the content changed.
    public static func lastOpened(_ path: String) -> Date? {
        if let item = MDItemCreate(kCFAllocatorDefault, path as CFString),
           let date = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date {
            return date
        }
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// "android-studio-2025.3.dmg" matches "Android Studio.app".
    static func installedApp(forInstaller name: String) -> String? {
        let base = (name as NSString).deletingPathExtension.lowercased()
        var words: [String] = []
        for token in base.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            if token.first?.isNumber == true { break }
            words.append(String(token))
        }
        let key = words.joined()
        guard key.count >= 3 else { return nil }
        let fm = FileManager.default
        for dir in ["/Applications", Paths.home + "/Applications"] {
            for app in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where app.hasSuffix(".app") {
                let appName = (app as NSString).deletingPathExtension
                let appKey = appName.lowercased().filter { $0.isLetter || $0.isNumber }
                if appKey == key || (key.hasPrefix(appKey) && appKey.count >= 4) { return appName }
            }
        }
        return nil
    }
}
