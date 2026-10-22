import AppKit
import AppleArchive
import CryptoKit
import DiskArbitration
import Foundation
import System

/// Something to move off the internal disk.
public struct OffloadItem: Sendable, Hashable {
    public var path: String
    public var name: String
    public var bytes: Int64
    /// Apps that use the item and are quit, after confirmation, before copying.
    public var quit: [AppRef]

    public init(path: String, name: String, bytes: Int64, quit: [AppRef] = []) {
        self.path = path
        self.name = name
        self.bytes = bytes
        self.quit = quit
    }
}

/// Where an item can be offloaded to: a connected drive, or a compressed archive on this Mac.
public struct OffloadDestination: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        /// `keepsMetadata` is true for APFS and Mac OS Extended, which take a plain copy.
        /// Other formats get one Apple Archive file so permissions and metadata survive.
        case drive(format: String, keepsMetadata: Bool)
        case archive
    }

    public var id: String
    public var name: String
    /// The volume's mount point, or the archive folder on this Mac.
    public var root: String
    public var kind: Kind
    public var available: Int64
    public var volumeUUID: String?

    public init(id: String, name: String, root: String, kind: Kind, available: Int64, volumeUUID: String? = nil) {
        self.id = id
        self.name = name
        self.root = root
        self.kind = kind
        self.available = available
        self.volumeUUID = volumeUUID
    }

    public var isArchive: Bool { if case .archive = kind { true } else { false } }

    /// Writes an `.aar` file rather than a plain folder.
    var writesArchive: Bool {
        switch kind {
        case .archive: true
        case .drive(_, let keepsMetadata): !keepsMetadata
        }
    }

    /// "APFS · 412 GB free", "exFAT · 31 GB free".
    public var detail: String {
        switch kind {
        case .archive: "\(ByteFormat.string(available)) free on this Mac"
        case .drive(let format, _): "\(Offloader.formatName(format)) · \(ByteFormat.string(available)) free"
        }
    }
}

/// An item Headroom has moved off this disk.
public struct OffloadRecord: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var originalPath: String
    /// The copied folder or file, or the `.aar` archive.
    public var storedPath: String
    public var volumeName: String?
    public var volumeUUID: String?
    public var isArchive: Bool
    public var bytes: Int64
    public var date: Date
    public var aliasPath: String?

    public init(id: UUID = UUID(), name: String, originalPath: String, storedPath: String, volumeName: String?,
                volumeUUID: String?, isArchive: Bool, bytes: Int64, date: Date = Date(), aliasPath: String?) {
        self.id = id
        self.name = name
        self.originalPath = originalPath
        self.storedPath = storedPath
        self.volumeName = volumeName
        self.volumeUUID = volumeUUID
        self.isArchive = isArchive
        self.bytes = bytes
        // Whole seconds, so the record survives the ISO 8601 store unchanged.
        self.date = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
        self.aliasPath = aliasPath
    }

    /// Stored on this Mac rather than on a drive.
    public var isOnThisMac: Bool { volumeName == nil }

    /// "On T7 · 22 Oct", "Compressed on this Mac · 22 Oct".
    public var whereLabel: String {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        let when = f.string(from: date)
        if let volumeName { return "On \(volumeName) · \(when)" }
        return "Compressed on this Mac · \(when)"
    }
}

public enum OffloadStep: Sendable, Hashable {
    case quitting, copying, verifying, removing, done
}

public enum OffloadError: LocalizedError, Sendable, Equatable {
    case disconnected(String)
    case notEnoughSpace(String)
    case notEnoughSpaceToRestore(needs: Int64, free: Int64)
    case verificationFailed(Int)
    case stopped
    case appDidNotQuit(String)
    case inUse(String)
    case refused(String)
    case alreadyExists(String)
    case copyFailed(String)
    case notReachable(String)
    case removeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .disconnected(let drive): "\(drive) was disconnected. The original is untouched."
        case .notEnoughSpace(let drive): "Not enough space on \(drive). The original is untouched."
        case .notEnoughSpaceToRestore(let needs, let free):
            "Needs \(ByteFormat.string(needs)); only \(ByteFormat.string(free)) free. Free some space first."
        case .verificationFailed(let count):
            "Verification failed: \(count) \(count == 1 ? "file differs" : "files differ"). The original is untouched."
        case .stopped: "Stopped. The original is untouched."
        case .appDidNotQuit(let app): "\(app) didn't quit. It may have unsaved work. The original is untouched."
        case .inUse(let reason): reason + " The original is untouched."
        case .refused(let reason): reason
        case .alreadyExists(let path): "Something is already at \(Paths.display(path)). Move it away and try again."
        case .copyFailed(let detail): "The copy failed: \(detail). The original is untouched."
        case .notReachable(let drive): "Connect \(drive) to restore this."
        case .removeFailed(let path):
            "Offloaded and verified, but \(Paths.display(path)) couldn't be removed from this Mac. Remove it in Finder."
        }
    }
}

public enum Offloader {
    /// Where the list of offloaded items is kept. Tests point it at a temporary file.
    nonisolated(unsafe) static var storeURL = URL(fileURLWithPath: Paths.appSupport + "/offloaded.json")

    /// The folder for compressed archives on this Mac.
    nonisolated(unsafe) static var archiveRoot = Paths.home + "/Headroom Offload"

    static let folderName = "Headroom Offload"

    // MARK: - Destinations

    /// Connected drives Headroom can write to, then the compressed archive on this Mac.
    public static func destinations() -> [OffloadDestination] {
        var out: [OffloadDestination] = []
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey, .volumeIsRootFileSystemKey,
                                      .volumeIsReadOnlyKey, .volumeIsLocalKey, .volumeAvailableCapacityKey,
                                      .volumeUUIDStringKey, .volumeIsBrowsableKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                            options: [.skipHiddenVolumes]) ?? []
        for url in volumes {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  url.path.hasPrefix("/Volumes/"),
                  values.volumeIsRootFileSystem != true,
                  values.volumeIsInternal != true,
                  values.volumeIsReadOnly != true,
                  values.volumeIsLocal == true,
                  values.volumeIsBrowsable != false,
                  !isDiskImage(url.path) else { continue }
            let format = fileSystemType(url.path) ?? "unknown"
            let keeps = format == "apfs" || format == "hfs"
            out.append(OffloadDestination(
                id: values.volumeUUIDString ?? url.path, name: values.volumeName ?? url.lastPathComponent,
                root: url.path, kind: .drive(format: format, keepsMetadata: keeps),
                available: Int64(values.volumeAvailableCapacity ?? 0), volumeUUID: values.volumeUUIDString))
        }
        out.append(OffloadDestination(id: "archive", name: "Compressed archive on this Mac", root: archiveRoot,
                                      kind: .archive, available: DiskStatus.current()?.available ?? 0))
        return out
    }

    static func fileSystemType(_ path: String) -> String? {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return nil }
        return withUnsafeBytes(of: &s.f_fstypename) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }

    static func formatName(_ type: String) -> String {
        switch type {
        case "apfs": "APFS"
        case "hfs": "Mac OS Extended"
        case "exfat": "exFAT"
        case "msdos": "FAT"
        case "ntfs": "NTFS"
        default: type
        }
    }

    /// Mounted disk images look like drives; offloading into one would be pointless.
    static func isDiskImage(_ mountPoint: String) -> Bool {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, URL(fileURLWithPath: mountPoint) as CFURL),
              let info = DADiskCopyDescription(disk) as? [String: Any] else { return false }
        let model = (info[kDADiskDescriptionDeviceModelKey as String] as? String) ?? ""
        let proto = (info[kDADiskDescriptionDeviceProtocolKey as String] as? String) ?? ""
        return model.contains("Disk Image") || proto == "Virtual Interface"
    }

    // MARK: - What can be offloaded

    /// nil when the item can be offloaded, else the reason it can't.
    public static func canOffload(_ path: String) -> String? {
        let standard = (path as NSString).standardizingPath
        let home = Paths.home
        let fm = FileManager.default
        guard fm.fileExists(atPath: standard) else { return "It no longer exists." }
        if standard.split(separator: "/").contains(where: { $0.hasSuffix(".app") }) {
            return "Apps can't be offloaded. Move the app itself in Finder."
        }
        guard PathSafety.isDeletable(standard) else { return "Headroom never moves this folder." }
        let catalogue = Set(Catalog.builtIn.flatMap { entry -> [String] in
            if case .paths(let list) = entry.target { return list.map(Paths.expand) }
            return []
        })
        if catalogue.contains(standard) { return nil }
        guard standard.hasPrefix(home + "/") else { return "Only items in your home folder can be offloaded." }
        let relative = standard.dropFirst(home.count + 1)
        if relative.hasPrefix("Library/") { return "Headroom doesn't move app data it doesn't know." }
        if standard.hasPrefix(archiveRoot + "/") || standard == archiveRoot { return "This is already offloaded." }
        return nil
    }

    /// Files under the item that a running process has open. Run just before copying.
    static func openFilesReason(_ path: String) -> String? {
        if let line = ProcessSnapshot.capture().processUsing(folder: path) {
            let tool = (line.split(separator: " ").first.map(String.init) ?? line) as NSString
            return "\(tool.lastPathComponent) is using files in \((path as NSString).lastPathComponent)."
        }
        guard let run = Shell.run("/usr/sbin/lsof", ["-t", "+D", path], timeout: 30), run.status == 0,
              let pid = run.output.split(separator: "\n").first.flatMap({ Int32($0) }) else { return nil }
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "Another app"
        return "\(name) has files in \((path as NSString).lastPathComponent) open."
    }

    /// Already-compressed kinds gain almost nothing from an archive.
    public static func compresses(_ path: String) -> Bool {
        let incompressibleBundles: Set<String> = ["avd", "vmbundle", "utm", "vmwarevm", "pvm", "dmg", "iso",
                                                  "sparseimage", "sparsebundle", "img", "qcow2", "photoslibrary"]
        if incompressibleBundles.contains((path as NSString).pathExtension.lowercased()) { return false }
        var compressed: Int64 = 0, total: Int64 = 0, seen = 0
        for (file, size) in sampleFiles(path, limit: 3000) {
            seen += 1
            total += size
            if incompressibleExtensions.contains((file as NSString).pathExtension.lowercased()) { compressed += size }
        }
        guard seen > 0, total > 0 else { return true }
        return Double(compressed) / Double(total) < 0.5
    }

    static let incompressibleExtensions: Set<String> = [
        "mp4", "mov", "mkv", "avi", "m4v", "webm", "mp3", "m4a", "aac", "flac", "ogg", "opus",
        "jpg", "jpeg", "png", "heic", "gif", "webp", "avif",
        "zip", "gz", "tgz", "xz", "bz2", "7z", "rar", "zst", "br", "lz4", "aar", "xip", "pkg",
        "dmg", "iso", "img", "qcow2", "vdi", "vmdk", "apk", "ipa", "jar", "aab",
        "pak", "vpk", "upk", "assets", "bundle", "unity3d", "woff2", "pdf",
    ]

    /// Up to `limit` regular files under a path, with their sizes.
    static func sampleFiles(_ path: String, limit: Int) -> [(String, Int64)] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return [] }
        if !isDir.boolValue {
            return [(path, (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0)]
        }
        var out: [(String, Int64)] = []
        let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: path),
                                                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        while let url = walker?.nextObject() as? URL, out.count < limit {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            out.append((url.path, Int64(values.fileSize ?? 0)))
        }
        return out
    }

    /// Compresses a sample of about 20 MB and returns the fraction saved, for example 0.4.
    public static func estimateSaving(_ path: String) async -> Double? {
        await Task.detached(priority: .utility) { () -> Double? in
            var original = 0, packed = 0
            for (file, size) in sampleFiles(path, limit: 2000) where size > 0 {
                guard original < 20_000_000, let handle = FileHandle(forReadingAtPath: file) else { continue }
                let data = (try? handle.read(upToCount: 4_000_000)) ?? Data()
                try? handle.close()
                guard !data.isEmpty, let out = try? (data as NSData).compressed(using: .lzfse) else { continue }
                original += data.count
                packed += out.length
            }
            guard original > 0 else { return nil }
            return max(0, 1 - Double(packed) / Double(original))
        }.value
    }

    // MARK: - Records

    public static func records() -> [OffloadRecord] {
        guard let data = try? Data(contentsOf: storeURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([OffloadRecord].self, from: data)) ?? []
    }

    static func saveRecords(_ records: [OffloadRecord]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(records) else { return }
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: .atomic)
    }

    /// The stored copy's current path. A drive mounted under a new name is found by its UUID.
    public static func storedLocation(_ record: OffloadRecord) -> String? {
        if FileManager.default.fileExists(atPath: record.storedPath) { return record.storedPath }
        guard let uuid = record.volumeUUID else { return nil }
        let parts = record.storedPath.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count > 2, parts[0] == "Volumes" else { return nil }
        let inside = parts.dropFirst(2).joined(separator: "/")
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeUUIDStringKey],
                                                            options: []) ?? []
        for url in volumes where (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString == uuid {
            let candidate = url.path + "/" + inside
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }

    public static func isReachable(_ record: OffloadRecord) -> Bool { storedLocation(record) != nil }

    // MARK: - Offload

    public static func offload(_ item: OffloadItem, to destination: OffloadDestination,
                               progress: @escaping @Sendable (OffloadStep) -> Void,
                               shouldStop: @escaping @Sendable () -> Bool) async throws -> OffloadRecord {
        let source = (item.path as NSString).standardizingPath
        if let reason = canOffload(source) { throw OffloadError.refused(reason) }
        let driveName = destination.isArchive ? "this Mac" : destination.name

        if !item.quit.isEmpty {
            progress(.quitting)
            for app in item.quit where !(await Cleaner().quit(app)) { throw OffloadError.appDidNotQuit(app.name) }
        }
        if shouldStop() { throw OffloadError.stopped }
        if let reason = openFilesReason(source) { throw OffloadError.inUse(reason) }

        let fm = FileManager.default
        guard fm.fileExists(atPath: destination.root) else { throw OffloadError.disconnected(driveName) }
        let available = destination.isArchive ? (DiskStatus.current()?.available ?? 0) : currentAvailable(destination.root)
        // An archive on this Mac needs room for its compressed copy; a drive needs the whole item.
        let needed = destination.isArchive ? Int64(Double(item.bytes) * 0.6) + 1_000_000_000 : Int64(Double(item.bytes) * 1.05)
        guard available >= needed else { throw OffloadError.notEnoughSpace(driveName) }

        let folder = destination.isArchive ? destination.root : destination.root + "/" + folderName
        try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let leaf = (source as NSString).lastPathComponent
        let stored = uniquePath(folder + "/" + leaf + (destination.writesArchive ? ".aar" : ""))

        func cleanUpPartial() { try? removeTree(stored) }

        progress(.copying)
        do {
            if destination.writesArchive {
                try await writeArchive(of: source, to: stored, compress: destination.isArchive, shouldStop: shouldStop)
            } else {
                try await runInterruptible("/usr/bin/ditto", [source, stored], shouldStop: shouldStop)
            }
        } catch {
            cleanUpPartial()
            if !fm.fileExists(atPath: destination.root) { throw OffloadError.disconnected(driveName) }
            throw error
        }

        progress(.verifying)
        let differences: Int
        do {
            let original = try treeEntries(source, shouldStop: shouldStop)
            let copy = destination.writesArchive
                ? try archiveEntries(stored, shouldStop: shouldStop)
                : try treeEntries(stored, rootName: leaf, shouldStop: shouldStop)
            differences = countDifferences(original, copy)
        } catch {
            cleanUpPartial()
            if !fm.fileExists(atPath: destination.root) { throw OffloadError.disconnected(driveName) }
            throw error
        }
        guard differences == 0 else { cleanUpPartial(); throw OffloadError.verificationFailed(differences) }
        if shouldStop() { cleanUpPartial(); throw OffloadError.stopped }

        progress(.removing)
        var record = OffloadRecord(name: item.name, originalPath: source, storedPath: stored,
                                   volumeName: destination.isArchive ? nil : destination.name,
                                   volumeUUID: destination.volumeUUID, isArchive: destination.writesArchive,
                                   bytes: item.bytes, aliasPath: nil)
        guard PathSafety.isDeletable(source) else { cleanUpPartial(); throw OffloadError.refused("Headroom never moves this folder.") }
        let removed = (try? removeTree(source)) != nil
        if wantsAlias(source) { record.aliasPath = makeAlias(to: stored, beside: source) }
        saveRecords(records() + [record])
        guard removed else { throw OffloadError.removeFailed(source) }
        progress(.done)
        return record
    }

    // MARK: - Restore

    public static func restore(_ record: OffloadRecord, keepCopy: Bool,
                               progress: @escaping @Sendable (OffloadStep) -> Void) async throws {
        guard let stored = storedLocation(record) else {
            throw OffloadError.notReachable(record.volumeName ?? "the drive")
        }
        let fm = FileManager.default
        let target = record.originalPath
        guard !fm.fileExists(atPath: target) else { throw OffloadError.alreadyExists(target) }
        let free = DiskStatus.current()?.available ?? 0
        let needs = Int64(Double(record.bytes) * 1.05)
        guard free >= needs else { throw OffloadError.notEnoughSpaceToRestore(needs: record.bytes, free: free) }

        let parent = (target as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
        let leaf = (target as NSString).lastPathComponent

        progress(.copying)
        do {
            if record.isArchive {
                try await runInterruptible("/usr/bin/aa", ["extract", "-i", stored, "-d", parent], shouldStop: { false })
            } else {
                try await runInterruptible("/usr/bin/ditto", [stored, target], shouldStop: { false })
            }
        } catch {
            try? removeTree(target)
            throw error
        }

        progress(.verifying)
        let copy = record.isArchive ? try archiveEntries(stored) : try treeEntries(stored, rootName: leaf)
        let restored = try treeEntries(target)
        let differences = countDifferences(copy, restored)
        guard differences == 0 else {
            try? removeTree(target)
            throw OffloadError.verificationFailed(differences)
        }

        if let alias = record.aliasPath, isAliasFile(alias) { try? fm.removeItem(atPath: alias) }
        if !keepCopy {
            progress(.removing)
            try? removeTree(stored)
        }
        saveRecords(records().filter { $0.id != record.id })
        progress(.done)
    }

    /// Deletes the stored copy of an item that has been restored.
    public static func deleteCopy(_ record: OffloadRecord) throws {
        guard let stored = storedLocation(record) else { return }
        guard PathSafety.isDeletable(stored), stored != record.originalPath else {
            throw OffloadError.refused("Headroom won't delete \(Paths.display(stored)).")
        }
        try removeTree(stored)
    }

    /// Whether offloading this path leaves a Finder alias behind.
    public static func leavesAlias(_ path: String) -> Bool { wantsAlias((path as NSString).standardizingPath) }

    // MARK: - Copying

    static func writeArchive(of source: String, to output: String, compress: Bool,
                             shouldStop: @escaping @Sendable () -> Bool) async throws {
        let parent = (source as NSString).deletingLastPathComponent
        let leaf = (source as NSString).lastPathComponent
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: source, isDirectory: &isDir)
        var args = ["archive", "-d", parent, "-o", output, "-a", compress ? "lzfse" : "raw", "-x"]
        args += isDir.boolValue ? ["-subdir", leaf] : ["-include-path", leaf]
        try await runInterruptible("/usr/bin/aa", args, shouldStop: shouldStop)
    }

    /// Runs a tool, polling `shouldStop`; a stop terminates it.
    static func runInterruptible(_ executable: String, _ arguments: [String],
                                 shouldStop: @escaping @Sendable () -> Bool) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let errorFile = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-offload-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: errorFile.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errorFile) }
        let errorHandle = try FileHandle(forWritingTo: errorFile)
        defer { try? errorHandle.close() }
        process.standardError = errorHandle
        do { try process.run() } catch { throw OffloadError.copyFailed("couldn't start \((executable as NSString).lastPathComponent)") }
        while process.isRunning {
            if shouldStop() {
                process.terminate()
                process.waitUntilExit()
                throw OffloadError.stopped
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard process.terminationStatus == 0 else {
            let message = (try? String(contentsOf: errorFile, encoding: .utf8))?
                .split(separator: "\n").last.map(String.init) ?? "exit status \(process.terminationStatus)"
            throw OffloadError.copyFailed(String(message.prefix(160)))
        }
    }

    static func currentAvailable(_ path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        if let value = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity {
            return Int64(value)
        }
        return 0
    }

    static func uniquePath(_ path: String) -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return path }
        let ext = (path as NSString).pathExtension
        let base = ext.isEmpty ? path : (path as NSString).deletingPathExtension
        for n in 2... {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            if !fm.fileExists(atPath: candidate) { return candidate }
        }
        return path
    }

    /// Removes a file or folder, making read-only files writable when needed.
    static func removeTree(_ path: String) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) || (try? fm.destinationOfSymbolicLink(atPath: path)) != nil else { return }
        do { try fm.removeItem(atPath: path) } catch {
            Shell.run("/usr/bin/chflags", ["-R", "nouchg", path])
            Shell.run("/bin/chmod", ["-R", "u+w", path])
            try fm.removeItem(atPath: path)
        }
    }

    // MARK: - Aliases

    /// User folders get an alias; app data and hidden folders don't, because an app could follow it.
    static func wantsAlias(_ path: String) -> Bool {
        let home = Paths.home
        guard path.hasPrefix(home + "/") else { return false }
        let relative = path.dropFirst(home.count + 1)
        if relative.hasPrefix("Library/") { return false }
        return !relative.split(separator: "/").contains { $0.hasPrefix(".") }
    }

    static func makeAlias(to target: String, beside original: String) -> String? {
        let parent = (original as NSString).deletingLastPathComponent
        let name = (original as NSString).lastPathComponent + " (offloaded)"
        let aliasPath = uniquePath(parent + "/" + name)
        guard let data = try? URL(fileURLWithPath: target).bookmarkData(options: .suitableForBookmarkFile,
                                                                         includingResourceValuesForKeys: nil, relativeTo: nil),
              (try? URL.writeBookmarkData(data, to: URL(fileURLWithPath: aliasPath))) != nil else { return nil }
        return aliasPath
    }

    static func isAliasFile(_ path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isAliasFileKey]))?.isAliasFile == true
    }

    // MARK: - Verification

    enum Entry: Hashable {
        case directory
        case file(size: Int64, sha256: String)
        case link(String)
    }

    /// Every entry under a path, keyed by its path relative to the path's parent ("name/sub/file").
    static func treeEntries(_ path: String, rootName: String? = nil,
                            shouldStop: @Sendable () -> Bool = { false }) throws -> [String: Entry] {
        let root = rootName ?? (path as NSString).lastPathComponent
        var out: [String: Entry] = [:]
        func add(_ full: String, _ relative: String) throws {
            if shouldStop() { throw OffloadError.stopped }
            var st = stat()
            guard lstat(full, &st) == 0 else { out[relative] = .link("<unreadable>"); return }
            switch st.st_mode & S_IFMT {
            case S_IFDIR: out[relative] = .directory
            case S_IFLNK: out[relative] = .link((try? FileManager.default.destinationOfSymbolicLink(atPath: full)) ?? "")
            case S_IFREG: out[relative] = .file(size: Int64(st.st_size), sha256: try hashFile(full))
            default: break
            }
        }
        try add(path, root)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
              (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) == nil else { return out }
        guard let walker = FileManager.default.enumerator(atPath: path) else { return out }
        while let relative = walker.nextObject() as? String {
            try add(path + "/" + relative, root + "/" + relative)
        }
        return out
    }

    static func hashFile(_ path: String) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { return "<unreadable>" }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Reads every entry of an Apple Archive, hashing file data as it decompresses.
    static func archiveEntries(_ path: String, shouldStop: @Sendable () -> Bool = { false }) throws -> [String: Entry] {
        guard let file = ArchiveByteStream.fileStream(path: FilePath(path), mode: .readOnly, options: [],
                                                      permissions: FilePermissions(rawValue: 0o644)) else {
            throw OffloadError.copyFailed("couldn't open the archive")
        }
        defer { try? file.close() }
        guard let decompressed = ArchiveByteStream.decompressionStream(readingFrom: file) else {
            throw OffloadError.copyFailed("couldn't read the archive")
        }
        defer { try? decompressed.close() }
        guard let decoder = ArchiveStream.decodeStream(readingFrom: decompressed) else {
            throw OffloadError.copyFailed("couldn't decode the archive")
        }
        defer { try? decoder.close() }

        let chunk = 1 << 20
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunk, alignment: 16)
        defer { buffer.deallocate() }
        let typKey = ArchiveHeader.FieldKey("TYP"), patKey = ArchiveHeader.FieldKey("PAT")
        let datKey = ArchiveHeader.FieldKey("DAT"), lnkKey = ArchiveHeader.FieldKey("LNK")

        var out: [String: Entry] = [:]
        while let header = try decoder.readHeader() {
            if shouldStop() { throw OffloadError.stopped }
            guard case .uint(_, let typ)? = header.field(forKey: typKey) else { continue }
            var name = ""
            if case .string(_, let value)? = header.field(forKey: patKey) { name = value }
            switch UInt8(truncatingIfNeeded: typ) {
            case UInt8(ascii: "D"):
                out[name] = .directory
            case UInt8(ascii: "L"):
                if case .string(_, let value)? = header.field(forKey: lnkKey) { out[name] = .link(value) }
            case UInt8(ascii: "F"):
                var hasher = SHA256()
                var size: Int64 = 0
                if case .blob(_, let blobSize, _)? = header.field(forKey: datKey) {
                    size = Int64(blobSize)
                    var left = Int(blobSize)
                    while left > 0 {
                        let n = min(left, chunk)
                        let part = UnsafeMutableRawBufferPointer(rebasing: buffer[0..<n])
                        try decoder.readBlob(key: datKey, into: part)
                        hasher.update(bufferPointer: UnsafeRawBufferPointer(part))
                        left -= n
                    }
                }
                out[name] = .file(size: size, sha256: hex(hasher.finalize()))
            default:
                break
            }
        }
        return out
    }

    /// Entries missing on either side or different in content.
    static func countDifferences(_ a: [String: Entry], _ b: [String: Entry]) -> Int {
        var count = 0
        for (key, value) in a where b[key] != value { count += 1 }
        for key in b.keys where a[key] == nil { count += 1 }
        return count
    }
}
