import Foundation

/// How much space a folder takes, counted two ways.
///
/// `allocated` is what `du` reports. `unshared` leaves out blocks a file shares with
/// APFS clones, so it is closer to what deleting the folder gives back. The real gain
/// lies between the two; Headroom measures it after cleaning.
public struct SizeInfo: Codable, Sendable, Hashable {
    public var allocated: Int64
    public var unshared: Int64
    public var files: Int
    public var unreadable: Int

    public init(allocated: Int64 = 0, unshared: Int64 = 0, files: Int = 0, unreadable: Int = 0) {
        self.allocated = allocated
        self.unshared = unshared
        self.files = files
        self.unreadable = unreadable
    }

    public static let zero = SizeInfo()

    /// True when clones make `allocated` overstate what deleting would free.
    public var sharesSpace: Bool {
        allocated > 100_000_000 && Double(unshared) < Double(allocated) * 0.85
    }

    /// The number to show: unshared size when it is known, else allocated.
    public var reclaimable: Int64 { unshared > 0 ? unshared : allocated }

    public static func + (a: SizeInfo, b: SizeInfo) -> SizeInfo {
        SizeInfo(allocated: a.allocated + b.allocated, unshared: a.unshared + b.unshared,
                 files: a.files + b.files, unreadable: a.unreadable + b.unreadable)
    }
}

public enum Sizer {
    /// Measures a file or folder without crossing into other volumes or following links.
    /// - Parameter unshared: also ask APFS how much of each file is not shared with clones.
    public static func measure(_ path: String, unshared: Bool = true) -> SizeInfo {
        var st = stat()
        guard lstat(path, &st) == 0 else { return .zero }

        var result = SizeInfo()
        var seenLinks = Set<UInt64>()
        let pathCopy = strdup(path)
        defer { free(pathCopy) }
        var roots: [UnsafeMutablePointer<CChar>?] = [pathCopy, nil]
        guard let fts = fts_open(&roots, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return .zero }
        defer { fts_close(fts) }

        while let entry = fts_read(fts) {
            let info = Int32(entry.pointee.fts_info)
            switch info {
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                guard let sp = entry.pointee.fts_statp else { continue }
                let s = sp.pointee
                if s.st_nlink > 1 && info == FTS_F {
                    let key = (UInt64(UInt32(bitPattern: s.st_dev)) << 40) ^ UInt64(s.st_ino)
                    if !seenLinks.insert(key).inserted { continue }
                }
                let blocks = Int64(s.st_blocks) * 512
                result.allocated += blocks
                result.files += 1
                if unshared && info == FTS_F && blocks > 0 {
                    result.unshared += privateSize(entry.pointee.fts_path) ?? blocks
                } else {
                    result.unshared += blocks
                }
            case FTS_D:
                if let sp = entry.pointee.fts_statp {
                    let blocks = Int64(sp.pointee.st_blocks) * 512
                    result.allocated += blocks
                    result.unshared += blocks
                }
            case FTS_DNR, FTS_ERR, FTS_NS:
                result.unreadable += 1
            default:
                break
            }
        }
        return result
    }

    /// Bytes of a file that are not shared with any clone (ATTR_CMNEXT_PRIVATESIZE).
    public static func privateSize(_ path: UnsafePointer<CChar>) -> Int64? {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
        var buffer = [UInt8](repeating: 0, count: 32)
        let options = UInt32(FSOPT_ATTR_CMN_EXTENDED) | UInt32(FSOPT_NOFOLLOW)
        let status = buffer.withUnsafeMutableBytes { raw in
            getattrlist(path, &list, raw.baseAddress, raw.count, options)
        }
        guard status == 0 else { return nil }
        return buffer.withUnsafeBytes { raw in
            let length = raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            guard length >= 12 else { return nil }
            return raw.loadUnaligned(fromByteOffset: 4, as: Int64.self)
        }
    }

    public static func privateSize(_ path: String) -> Int64? {
        path.withCString { privateSize($0) }
    }

    /// Measures several paths concurrently.
    public static func measureAll(_ paths: [String], unshared: Bool = true) async -> [String: SizeInfo] {
        await withTaskGroup(of: (String, SizeInfo).self) { group in
            for path in Set(paths) {
                group.addTask(priority: .utility) { (path, measure(path, unshared: unshared)) }
            }
            var out: [String: SizeInfo] = [:]
            for await (path, size) in group { out[path] = size }
            return out
        }
    }
}
