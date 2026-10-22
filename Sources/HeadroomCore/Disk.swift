import Foundation

/// Free and total space on the internal data volume, as `df` reports it.
public struct DiskStatus: Codable, Sendable, Equatable {
    public var total: Int64
    public var available: Int64

    public init(total: Int64, available: Int64) {
        self.total = total
        self.available = available
    }

    public var used: Int64 { total - available }
    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    /// Space the macOS system, preboot, recovery and swap volumes use in the same container.
    /// statfs on the data volume reports the whole container, so this is what it counts beyond the data volume.
    public static func otherVolumesBytes() -> Int64 {
        var s = statfs()
        guard statfs("/System/Volumes/Data", &s) == 0, let disk = current() else { return 0 }
        let dataUsed = Int64(s.f_blocks - s.f_bfree) * Int64(s.f_bsize)
        return max(0, disk.used - dataUsed)
    }

    public static func current() -> DiskStatus? {
        for path in ["/System/Volumes/Data", "/"] {
            var s = statfs()
            if statfs(path, &s) == 0 {
                let block = Int64(s.f_bsize)
                return DiskStatus(total: Int64(s.f_blocks) * block, available: Int64(s.f_bavail) * block)
            }
        }
        return nil
    }
}

public enum HeadroomLevel: String, Codable, Sendable, Comparable {
    case ok, low, critical

    public init(available: Int64, warnBytes: Int64, criticalBytes: Int64) {
        if available < criticalBytes { self = .critical }
        else if available < warnBytes { self = .low }
        else { self = .ok }
    }

    private var rank: Int { switch self { case .ok: 0; case .low: 1; case .critical: 2 } }
    public static func < (a: HeadroomLevel, b: HeadroomLevel) -> Bool { a.rank < b.rank }
}
