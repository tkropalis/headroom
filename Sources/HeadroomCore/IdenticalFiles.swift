import CryptoKit
import Darwin
import Foundation

/// What a file looked like when it was found, so a later change can be noticed before sharing.
public struct FileStamp: Codable, Sendable, Hashable {
    public var size: Int64
    public var mtimeSeconds: Int
    public var mtimeNanoseconds: Int
    public var inode: UInt64

    init(_ st: stat) {
        size = Int64(st.st_size)
        mtimeSeconds = Int(st.st_mtimespec.tv_sec)
        mtimeNanoseconds = Int(st.st_mtimespec.tv_nsec)
        inode = UInt64(st.st_ino)
    }
}

/// Files with byte-for-byte identical content that don't share their disk blocks yet.
public struct IdenticalSet: Codable, Sendable, Hashable, Identifiable {
    /// Full-content SHA-256, in hex.
    public var id: String
    /// The file kept as the source of the clones: the oldest one.
    public var keeper: String
    /// Files that will become clones of the keeper.
    public var copies: [String]
    /// Allocated bytes of one file.
    public var fileSize: Int64
    /// Copies that hold their own blocks today. Copies that are already clones of each other
    /// count once, because their blocks are only freed when all of them share the keeper's.
    public var freeableCopies: Int
    /// Size and modification time of the keeper and every copy when they were found.
    public var stamps: [String: FileStamp]

    public var reclaimable: Int64 { fileSize * Int64(freeableCopies) }
}

/// Sets shown together in the review: one npm package across projects, or one file.
public struct IdenticalGroup: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// "react-native 0.81.4", or the file name.
    public var name: String
    /// "6 identical copies across projects", "In Downloads and on the Desktop".
    public var detail: String
    public var sets: [IdenticalSet]
    /// Project folders the files live in, so a running dev server can block sharing.
    public var projectPaths: [String]
    public var reclaimable: Int64
}

public struct ShareOutcome: Sendable, Hashable {
    /// Copies that now share the keeper's blocks.
    public var sharedFiles: Int
    /// Copies left alone because they changed, are open, locked or owned by someone else.
    public var skipped: Int
    public var failures: [String]
}

/// Finds identical files and makes the copies APFS clones of one file. Nothing is deleted:
/// every path stays and reads the same; editing one later only uses space for the change.
public enum IdenticalFiles {
    public static func defaultRoots() -> [String] { [Paths.home] }

    /// Directory extensions that are packages or bundles. Their insides are left alone.
    static let packageExtensions: Set<String> = [
        "app", "framework", "bundle", "plugin", "kext", "appex", "xpc", "dsym", "photoslibrary",
        "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle", "logicx", "band", "sparsebundle",
        "xcarchive", "pkg", "mpkg", "rtfd", "pages", "numbers", "key", "playground", "xcworkspace",
        "xcodeproj", "lrcat", "lrdata", "aplibrary", "photolibrary", "qlgenerator", "mdimporter",
        "prefpane", "saver", "wdgt", "docarchive", "mlmodelc", "scptd",
    ]

    /// Groups whose copies would free less than this aren't worth a row.
    static let minimumGroupBytes: Int64 = 1_000_000

    public static func find(roots: [String], minimumBytes: Int64 = 100_000, excluded: [String] = [],
                            shouldStop: (@Sendable () -> Bool)? = nil) async -> [IdenticalGroup] {
        await Task.detached(priority: .utility) {
            findNow(roots: roots, minimumBytes: minimumBytes, excluded: excluded, shouldStop: shouldStop)
        }.value
    }

    // MARK: - Finding

    struct Found {
        var path: String
        var st: stat
    }

    static func findNow(roots: [String], minimumBytes: Int64, excluded: [String],
                        shouldStop: (@Sendable () -> Bool)?) -> [IdenticalGroup] {
        let stop: @Sendable () -> Bool = shouldStop ?? { false }

        // 1. Same device and size.
        var bySize: [String: [Found]] = [:]
        for root in roots {
            walk(root, minimumBytes: minimumBytes, excluded: excluded, stop: stop) { found in
                bySize["\(found.st.st_dev):\(found.st.st_size)", default: []].append(found)
            }
        }
        let sized = bySize.values.filter { $0.count > 1 }.flatMap { $0 }
        if stop() || sized.isEmpty { return [] }

        // 2. Same first and last 16 KB.
        let partial = hashAll(sized.map(\.path), stop: stop, partialHash)
        var byPartial: [String: [Found]] = [:]
        for (index, found) in sized.enumerated() {
            guard let hash = partial[index] else { continue }
            byPartial["\(found.st.st_dev):\(found.st.st_size):\(hash)", default: []].append(found)
        }
        let likely = byPartial.values.filter { $0.count > 1 }.flatMap { $0 }
        if stop() || likely.isEmpty { return [] }

        // 3. Same full SHA-256.
        let full = hashAll(likely.map(\.path), stop: stop, fullHash)
        var byFull: [String: [Found]] = [:]
        for (index, found) in likely.enumerated() {
            guard let hash = full[index] else { continue }
            byFull["\(found.st.st_dev):\(hash)", default: []].append(found)
        }
        if stop() { return [] }

        let sets = byFull.compactMap { key, files -> IdenticalSet? in
            guard files.count > 1 else { return nil }
            return makeSet(hash: String(key.split(separator: ":").last ?? ""), files: files)
        }
        return group(sets)
    }

    /// Calls `visit` for every regular file worth comparing under `root`.
    static func walk(_ root: String, minimumBytes: Int64, excluded: [String],
                     stop: () -> Bool, visit: (Found) -> Void) {
        let home = Paths.home
        let skipped: Set<String> = [home + "/Library", home + "/.Trash"]
        let rootCopy = strdup(root)
        defer { free(rootCopy) }
        var roots: [UnsafeMutablePointer<CChar>?] = [rootCopy, nil]
        guard let fts = fts_open(&roots, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return }
        defer { fts_close(fts) }

        var count = 0
        while let entry = fts_read(fts) {
            count += 1
            if count % 4096 == 0, stop() { return }
            let info = Int32(entry.pointee.fts_info)
            let path = String(cString: entry.pointee.fts_path)
            switch info {
            case FTS_D:
                let name = (path as NSString).lastPathComponent
                let ext = (name as NSString).pathExtension.lowercased()
                // Hidden folders in the home folder are tool data (~/.gradle, ~/.expo); the cache
                // groups clean those, so sharing their files would only make the list noisy.
                let toolData = entry.pointee.fts_level == 1 && root == home && name.hasPrefix(".")
                if entry.pointee.fts_level > 0,
                   toolData || name == ".git" || packageExtensions.contains(ext) || skipped.contains(path)
                    || excluded.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                    fts_set(fts, entry, FTS_SKIP)
                }
            case FTS_F:
                guard let sp = entry.pointee.fts_statp else { continue }
                let st = sp.pointee
                guard isCandidate(st, minimumBytes: minimumBytes) else { continue }
                visit(Found(path: path, st: st))
            default:
                break
            }
        }
    }

    static func isCandidate(_ st: stat, minimumBytes: Int64) -> Bool {
        let flags = UInt32(st.st_flags)
        let blocked = UInt32(SF_DATALESS) | UInt32(UF_COMPRESSED) | UInt32(UF_IMMUTABLE) | UInt32(SF_IMMUTABLE)
        return (st.st_mode & S_IFMT) == S_IFREG
            && st.st_nlink == 1
            && Int64(st.st_size) >= minimumBytes
            && st.st_blocks > 0
            && flags & blocked == 0
    }

    /// Hashes files in parallel. A nil entry means the file couldn't be read.
    static func hashAll(_ paths: [String], stop: @escaping @Sendable () -> Bool,
                        _ hash: @escaping @Sendable (String) -> String?) -> [String?] {
        let results = HashResults(count: paths.count)
        DispatchQueue.concurrentPerform(iterations: paths.count) { index in
            if index % 64 == 0, stop() { return }
            results.set(index, hash(paths[index]))
        }
        return results.values
    }

    static let chunk = 16 * 1024

    @Sendable static func partialHash(_ path: String) -> String? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        var st = stat()
        guard fstat(fd, &st) == 0 else { return nil }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: chunk)
        for offset in [Int64(0), max(0, Int64(st.st_size) - Int64(chunk))] {
            let n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, chunk, off_t(offset)) }
            guard n >= 0 else { return nil }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
        }
        return hex(hasher.finalize())
    }

    @Sendable static func fullHash(_ path: String) -> String? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0 { return nil }
            if n == 0 { break }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
        }
        return hex(hasher.finalize())
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Picks the keeper and the copies that would free space, or nil when they all share already.
    static func makeSet(hash: String, files: [Found]) -> IdenticalSet? {
        let keeper = files.min { a, b in
            let ta = a.st.st_birthtimespec, tb = b.st.st_birthtimespec
            return ta.tv_sec != tb.tv_sec ? ta.tv_sec < tb.tv_sec
                : ta.tv_nsec != tb.tv_nsec ? ta.tv_nsec < tb.tv_nsec : a.path < b.path
        }!
        // Files that are already clones of each other have the same clone ID.
        var clusters: [String: [Found]] = [:]
        for file in files {
            let key = cloneID(file.path).map { "c\($0)" } ?? "p" + file.path
            clusters[key, default: []].append(file)
        }
        let keeperKey = cloneID(keeper.path).map { "c\($0)" } ?? "p" + keeper.path
        var copies: [Found] = []
        var freeable = 0
        for (key, members) in clusters where key != keeperKey {
            // A lone file whose blocks are all shared with something else frees nothing.
            if members.count == 1, Sizer.privateSize(members[0].path) == 0 { continue }
            copies += members
            freeable += 1
        }
        guard !copies.isEmpty else { return nil }
        copies.sort { $0.path < $1.path }
        var stamps: [String: FileStamp] = [keeper.path: FileStamp(keeper.st)]
        for copy in copies { stamps[copy.path] = FileStamp(copy.st) }
        return IdenticalSet(id: hash, keeper: keeper.path, copies: copies.map(\.path),
                            fileSize: Int64(keeper.st.st_blocks) * 512, freeableCopies: freeable, stamps: stamps)
    }

    /// The ID APFS gives a file's data; pure clones of each other share it.
    public static func cloneID(_ path: String) -> UInt64? {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.forkattr = attrgroup_t(ATTR_CMNEXT_CLONEID)
        var buffer = [UInt8](repeating: 0, count: 32)
        let options = UInt32(FSOPT_ATTR_CMN_EXTENDED) | UInt32(FSOPT_NOFOLLOW)
        let status = buffer.withUnsafeMutableBytes { raw in
            getattrlist(path, &list, raw.baseAddress, raw.count, options)
        }
        guard status == 0 else { return nil }
        return buffer.withUnsafeBytes { raw in
            let length = raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            guard length >= 12 else { return nil }
            return raw.loadUnaligned(fromByteOffset: 4, as: UInt64.self)
        }
    }

    // MARK: - Grouping

    /// The npm package a path belongs to: its name and folder, from the last `node_modules`.
    static func package(of path: String) -> (name: String, folder: String)? {
        guard let range = path.range(of: "/node_modules/", options: .backwards) else { return nil }
        let rest = path[range.upperBound...].split(separator: "/")
        guard rest.count >= 2 else { return nil }
        let name = rest[0].hasPrefix("@") && rest.count >= 3 ? rest[0] + "/" + rest[1] : String(rest[0])
        return (name, String(path[..<range.upperBound]) + name)
    }

    static func version(ofPackageAt folder: String) -> String? {
        guard let data = FileManager.default.contents(atPath: folder + "/package.json"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["version"] as? String
    }

    /// The project folder above a path: before the first `node_modules`, else the nearest
    /// folder with a project marker.
    static func projectRoot(of path: String) -> String? {
        if let range = path.range(of: "/node_modules/") { return String(path[..<range.lowerBound]) }
        let home = Paths.home
        var dir = (path as NSString).deletingLastPathComponent
        while dir.count > 1 && dir != home {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            if !ProjectFinder.markers.isDisjoint(with: names) { return dir }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }

    static func group(_ sets: [IdenticalSet]) -> [IdenticalGroup] {
        var packageSets: [String: [IdenticalSet]] = [:]
        var groups: [IdenticalGroup] = []

        for set in sets {
            let all = [set.keeper] + set.copies
            let names = Set(all.compactMap { package(of: $0)?.name })
            if names.count == 1, all.allSatisfy({ package(of: $0) != nil }), let name = names.first {
                packageSets[name, default: []].append(set)
            } else {
                groups.append(fileGroup(set))
            }
        }

        for (name, sets) in packageSets {
            let all = sets.flatMap { [$0.keeper] + $0.copies }
            let folders = Set(all.compactMap { package(of: $0)?.folder })
            let projects = Set(all.compactMap(projectRoot))
            let keeperFolder = package(of: sets[0].keeper)?.folder
            let title = keeperFolder.flatMap(version).map { "\(name) \($0)" } ?? name
            let detail = projects.count > 1
                ? "\(folders.count) identical copies across projects"
                : folders.count == 1
                    ? "Repeated files inside the package, in \((projects.first.map { ($0 as NSString).lastPathComponent }) ?? "one project")"
                    : "\(folders.count) identical copies in \((projects.first.map { ($0 as NSString).lastPathComponent }) ?? "one project")"
            groups.append(IdenticalGroup(
                id: "pkg:" + name, name: title, detail: detail,
                sets: sets.sorted { $0.reclaimable > $1.reclaimable },
                projectPaths: projects.sorted(), reclaimable: sets.reduce(0) { $0 + $1.reclaimable }))
        }

        return groups.filter { $0.reclaimable >= minimumGroupBytes }.sorted { $0.reclaimable > $1.reclaimable }
    }

    static func fileGroup(_ set: IdenticalSet) -> IdenticalGroup {
        let all = [set.keeper] + set.copies
        let folders = all.map { ($0 as NSString).deletingLastPathComponent }
        var unique: [String] = []
        for folder in folders.map(place) where !unique.contains(folder) { unique.append(folder) }
        let detail: String
        if unique.count == 1 {
            detail = "\(all.count) identical copies \(unique[0])"
        } else {
            let places = Array(unique.prefix(3))
            let joined = places.count == 2 ? places.joined(separator: " and ")
                : places.dropLast().joined(separator: ", ") + " and " + places.last!
            let more = unique.count > 3 ? " and \(unique.count - 3) more" : ""
            detail = joined.prefix(1).uppercased() + joined.dropFirst() + more
        }
        return IdenticalGroup(id: "file:" + set.id, name: (set.keeper as NSString).lastPathComponent,
                              detail: detail, sets: [set], projectPaths: Array(Set(all.compactMap(projectRoot))).sorted(),
                              reclaimable: set.reclaimable)
    }

    /// "in Downloads", "on the Desktop", "in oikos", "in ~/Documents/Invoices". Deep folders are
    /// named by their project, or by their first two levels, so a row stays one line.
    static func place(_ folder: String) -> String {
        let home = Paths.home
        switch folder {
        case home + "/Desktop": return "on the Desktop"
        case home + "/Downloads": return "in Downloads"
        case home + "/Documents": return "in Documents"
        default:
            if let project = projectRoot(of: folder + "/x") { return "in " + (project as NSString).lastPathComponent }
            guard folder.hasPrefix(home + "/") else { return "in " + Paths.display(folder) }
            let parts = folder.dropFirst(home.count + 1).split(separator: "/").prefix(2)
            return "in ~/" + parts.joined(separator: "/")
        }
    }

    // MARK: - Sharing

    public static func share(_ group: IdenticalGroup) -> ShareOutcome {
        var outcome = ShareOutcome(sharedFiles: 0, skipped: 0, failures: [])
        let open = openFiles(group.sets.flatMap { [$0.keeper] + $0.copies })

        for set in group.sets {
            guard let keeperStat = lstatOf(set.keeper), let stamp = set.stamps[set.keeper],
                  FileStamp(keeperStat) == stamp, !open.contains(set.keeper) else {
                outcome.skipped += set.copies.count
                continue
            }
            for copy in set.copies {
                switch shareCopy(copy, with: set.keeper, keeperStat: keeperStat,
                                 expected: set.stamps[copy], open: open) {
                case .shared: outcome.sharedFiles += 1
                case .skipped: outcome.skipped += 1
                case .failed(let reason): outcome.failures.append(Paths.display(copy) + ": " + reason)
                }
            }
        }
        return outcome
    }

    enum CopyResult: Equatable { case shared, skipped, failed(String) }

    static func shareCopy(_ copy: String, with keeper: String, keeperStat: stat,
                          expected: FileStamp?, open: Set<String>) -> CopyResult {
        guard let st = lstatOf(copy), let expected, FileStamp(st) == expected,
              !open.contains(copy), isCandidate(st, minimumBytes: 0),
              st.st_uid == keeperStat.st_uid, st.st_size == keeperStat.st_size else { return .skipped }
        guard sameBytes(keeper, copy) else { return .skipped }

        let dir = (copy as NSString).deletingLastPathComponent
        let temp = dir + "/.headroom-share-" + UUID().uuidString
        guard clonefile(keeper, temp, UInt32(CLONE_NOFOLLOW | CLONE_NOOWNERCOPY)) == 0 else {
            return .failed(String(cString: strerror(errno)))
        }
        // From here on, any failure removes the temporary clone and leaves the copy as it was.
        func fail(_ reason: String) -> CopyResult { unlink(temp); return .failed(reason) }

        // The clone carries the keeper's extended attributes; the copy keeps its own.
        removeAllXattrs(temp)
        guard copyfile(copy, temp, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else {
            return fail("couldn't copy its permissions and attributes")
        }
        let created = Date(timeIntervalSince1970: Double(st.st_birthtimespec.tv_sec) + Double(st.st_birthtimespec.tv_nsec) / 1e9)
        let modified = Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9)
        try? FileManager.default.setAttributes([.creationDate: created, .modificationDate: modified], ofItemAtPath: temp)

        // Last look before the swap: the copy must still be the file that was compared.
        guard let again = lstatOf(copy), FileStamp(again) == expected else { return fail("it changed while sharing") }
        guard renamex_np(temp, copy, UInt32(RENAME_SWAP)) == 0 else {
            return fail(String(cString: strerror(errno)))
        }
        // `temp` now holds the old copy. Check the new file before letting the old one go.
        guard let swapped = lstatOf(copy), swapped.st_size == st.st_size, sameBytes(keeper, copy) else {
            renamex_np(temp, copy, UInt32(RENAME_SWAP))
            return fail("the shared file didn't match, so the original was put back")
        }
        unlink(temp)
        return .shared
    }

    static func lstatOf(_ path: String) -> stat? {
        var st = stat()
        return lstat(path, &st) == 0 ? st : nil
    }

    static func sameBytes(_ a: String, _ b: String) -> Bool {
        let fa = open(a, O_RDONLY | O_NOFOLLOW), fb = open(b, O_RDONLY | O_NOFOLLOW)
        defer { if fa >= 0 { close(fa) }; if fb >= 0 { close(fb) } }
        guard fa >= 0, fb >= 0 else { return false }
        _ = fcntl(fa, F_NOCACHE, 1)
        _ = fcntl(fb, F_NOCACHE, 1)
        let size = 1 << 20
        var ba = [UInt8](repeating: 0, count: size), bb = [UInt8](repeating: 0, count: size)
        while true {
            let na = ba.withUnsafeMutableBytes { read(fa, $0.baseAddress, size) }
            let nb = bb.withUnsafeMutableBytes { read(fb, $0.baseAddress, size) }
            if na < 0 || nb < 0 || na != nb { return false }
            if na == 0 { return true }
            if memcmp(ba, bb, na) != 0 { return false }
        }
    }

    static func removeAllXattrs(_ path: String) {
        let length = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard length > 0 else { return }
        var names = [CChar](repeating: 0, count: length)
        guard listxattr(path, &names, length, XATTR_NOFOLLOW) == length else { return }
        var start = 0
        for index in 0..<length where names[index] == 0 {
            let name = names[start..<index].withUnsafeBufferPointer { buffer in
                String(decoding: buffer.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
            removexattr(path, name, XATTR_NOFOLLOW)
            start = index + 1
        }
    }

    /// Paths that some process has open, according to lsof. Empty when lsof isn't available.
    static func openFiles(_ paths: [String]) -> Set<String> {
        guard FileManager.default.isExecutableFile(atPath: "/usr/sbin/lsof") else { return [] }
        var open = Set<String>()
        var start = 0
        while start < paths.count {
            let batch = Array(paths[start..<min(start + 200, paths.count)])
            start += batch.count
            guard let result = Shell.run("/usr/sbin/lsof", ["-F", "n", "--"] + batch, timeout: 30) else { continue }
            for line in result.output.split(separator: "\n") where line.hasPrefix("n") {
                open.insert(String(line.dropFirst()))
            }
        }
        return open
    }
}

/// Results written from concurrent hashing.
private final class HashResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String?]
    init(count: Int) { storage = Array(repeating: nil, count: count) }
    func set(_ index: Int, _ value: String?) { lock.lock(); storage[index] = value; lock.unlock() }
    var values: [String?] { lock.lock(); defer { lock.unlock() }; return storage }
}
