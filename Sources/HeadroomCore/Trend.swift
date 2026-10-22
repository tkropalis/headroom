import Foundation

/// The lowest free space seen in one hour.
public struct FreeSample: Codable, Sendable, Hashable {
    public var date: Date
    public var available: Int64

    public init(date: Date, available: Int64) {
        self.date = date
        self.available = available
    }
}

/// How fast free space is falling, and when it would run out.
public struct Runway: Sendable, Hashable {
    /// Bytes lost per day; positive means free space is falling.
    public var bytesPerDay: Int64
    public var daysLeft: Int

    public var line: String {
        "Falling about \(ByteFormat.string(bytesPerDay)) a day. Full in about \(daysLeft) \(daysLeft == 1 ? "day" : "days")."
    }
}

public enum Trend {
    /// Adds a reading to the hourly series, keeping the lowest value of each hour and 90 days in all.
    public static func record(_ available: Int64, at date: Date = Date(), into samples: [FreeSample]) -> [FreeSample] {
        let hour = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
        var out = samples
        if let last = out.last, last.date == hour {
            out[out.count - 1].available = min(last.available, available)
        } else {
            out.append(FreeSample(date: hour, available: available))
        }
        let cutoff = date.addingTimeInterval(-90 * 86400)
        return out.filter { $0.date >= cutoff }
    }

    /// A straight-line fit over the last `days` days. Jumps up of more than 1 GB in an hour are
    /// cleanups (Headroom's or anyone's), so they are taken out before fitting: a cleanup doesn't
    /// make the disk look like it is filling more slowly.
    public static func runway(_ samples: [FreeSample], now: Date = Date(), days: Double = 7,
                              minimumSpan: Double = 3) -> Runway? {
        let recent = samples.filter { now.timeIntervalSince($0.date) <= days * 86400 }.sorted { $0.date < $1.date }
        guard recent.count >= 24, let first = recent.first, let last = recent.last,
              last.date.timeIntervalSince(first.date) >= minimumSpan * 86400 else { return nil }

        var adjusted: [(x: Double, y: Double)] = []
        var offset: Int64 = 0
        var previous = first.available
        for sample in recent {
            let jump = sample.available - previous
            if jump > 1_000_000_000 { offset += jump }
            previous = sample.available
            adjusted.append((sample.date.timeIntervalSince(first.date) / 86400, Double(sample.available - offset)))
        }
        let n = Double(adjusted.count)
        let meanX = adjusted.reduce(0) { $0 + $1.x } / n
        let meanY = adjusted.reduce(0) { $0 + $1.y } / n
        let sxx = adjusted.reduce(0) { $0 + ($1.x - meanX) * ($1.x - meanX) }
        guard sxx > 0 else { return nil }
        let slope = adjusted.reduce(0) { $0 + ($1.x - meanX) * ($1.y - meanY) } / sxx
        // Less than 100 MB a day is noise, not a trend.
        guard slope < -100_000_000 else { return nil }
        let perDay = Int64(-slope)
        let days = max(1, Int((Double(last.available) / -slope).rounded()))
        return Runway(bytesPerDay: perDay, daysLeft: days)
    }
}

/// Space macOS can free on its own (purgeable files, local snapshots), beyond what statfs reports.
public enum Purgeable {
    public static func bytes() -> Int64 {
        let url = URL(fileURLWithPath: "/")
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let important = values.volumeAvailableCapacityForImportantUsage,
              let disk = DiskStatus.current() else { return 0 }
        return max(0, important - disk.available)
    }
}
