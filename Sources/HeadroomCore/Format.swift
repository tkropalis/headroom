import Foundation

/// Formats byte counts in decimal units, the way Finder and About This Mac do.
public enum ByteFormat {
    public static func string(_ bytes: Int64) -> String {
        let value = Double(max(0, bytes))
        let gb = value / 1e9
        if gb >= 9.95 { return "\(Int(gb.rounded())) GB" }
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = value / 1e6
        if mb >= 1 { return "\(Int(mb.rounded())) MB" }
        return "\(Int((value / 1e3).rounded())) KB"
    }

    /// Whole gigabytes, for the menu bar.
    public static func wholeGB(_ bytes: Int64) -> String {
        "\(Int((Double(max(0, bytes)) / 1e9).rounded())) GB"
    }

    public static func gigabytes(_ gb: Double) -> Int64 { Int64(gb * 1e9) }
}

public enum RelativeDate {
    public static func string(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) h ago" }
        let days = Int(seconds / 86400)
        return days == 1 ? "yesterday" : "\(days) days ago"
    }

    public static func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy"
        return f.string(from: date)
    }

    public static func dateTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "d MMM, HH:mm"
        return f.string(from: date)
    }
}
