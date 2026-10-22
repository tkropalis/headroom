import Foundation
import Testing
@testable import HeadroomCore

@Suite struct TrendTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Hourly samples over `days`, falling `perDay` bytes a day from `start`.
    func series(days: Int, start: Int64, perDay: Int64) -> [FreeSample] {
        (0..<(days * 24)).map { hour in
            let date = now.addingTimeInterval(-Double(days * 24 - hour) * 3600)
            return FreeSample(date: date, available: start - perDay * Int64(hour) / 24)
        }
    }

    @Test func fallingDiskGivesARunway() throws {
        let samples = series(days: 7, start: 28_000_000_000, perDay: 1_400_000_000)
        let runway = try #require(Trend.runway(samples, now: now))
        #expect(abs(runway.bytesPerDay - 1_400_000_000) < 20_000_000)
        // About 18.2 GB left at 1.4 GB a day.
        #expect(runway.daysLeft == 13)
        #expect(runway.line == "Falling about 1.4 GB a day. Full in about 13 days.")
    }

    @Test func steadyDiskHasNone() {
        #expect(Trend.runway(series(days: 7, start: 30_000_000_000, perDay: 10_000_000), now: now) == nil)
    }

    @Test func needsThreeDays() {
        #expect(Trend.runway(series(days: 2, start: 30_000_000_000, perDay: 3_000_000_000), now: now) == nil)
    }

    @Test func cleanupsDontHideTheTrend() throws {
        var samples = series(days: 7, start: 28_000_000_000, perDay: 1_400_000_000)
        // A 10 GB cleanup halfway through.
        for i in (samples.count / 2)..<samples.count { samples[i].available += 10_000_000_000 }
        let runway = try #require(Trend.runway(samples, now: now))
        #expect(abs(runway.bytesPerDay - 1_400_000_000) < 50_000_000)
    }

    @Test func recordKeepsTheHourlyMinimum() {
        let start = Date(timeIntervalSince1970: 3600 * 1000)
        var samples = Trend.record(20, at: start, into: [])
        samples = Trend.record(15, at: start.addingTimeInterval(600), into: samples)
        samples = Trend.record(18, at: start.addingTimeInterval(1200), into: samples)
        samples = Trend.record(30, at: start.addingTimeInterval(3700), into: samples)
        #expect(samples.map(\.available) == [15, 30])
    }
}

@Suite struct LeftoverTests {
    @Test func brewEstimate() {
        #expect(DevLeftovers.parseBrewEstimate("==> This operation would free approximately 34.6MB of disk space.") == 34_600_000)
        #expect(DevLeftovers.parseBrewEstimate("nothing to do") == 0)
    }

    @Test func installerNames() {
        let apps = (try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []
        if apps.contains("Safari.app") || FileManager.default.fileExists(atPath: "/Applications/Safari.app") {
            #expect(ForgottenFiles.installedApp(forInstaller: "Safari-17.2.dmg") == "Safari")
        }
        #expect(ForgottenFiles.installedApp(forInstaller: "nothing-like-this-9.dmg") == nil)
        #expect(ForgottenFiles.installedApp(forInstaller: "1.2.dmg") == nil)
    }

    @Test func forgottenSkipsLibraryAndProjects() {
        let home = Paths.home
        #expect(!ForgottenFiles.eligible(home + "/Library/Caches/big.bin", projects: [], excluded: []))
        #expect(!ForgottenFiles.eligible(home + "/.cache/big.bin", projects: [], excluded: []))
        #expect(!ForgottenFiles.eligible(home + "/code/app/video.mov", projects: [home + "/code/app"], excluded: []))
        #expect(!ForgottenFiles.eligible(home + "/Movies/Lib.photoslibrary/x.mov", projects: [], excluded: []))
        #expect(ForgottenFiles.eligible(home + "/Desktop/recording.mov", projects: [], excluded: []))
    }
}

@Suite struct PutBackTests {
    @Test func trashAndPutBack() throws {
        let dir = Paths.home + "/.headroom-test-putback-\(UUID().uuidString)"
        let file = dir + "/item.txt"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "keep me".write(toFile: file, atomically: true, encoding: .utf8)

        let moved = Cleaner().trash([file])
        #expect(moved.step.removedAnything)
        #expect(!FileManager.default.fileExists(atPath: file))
        #expect(Cleaner.canPutBack(moved.locations))

        #expect(Cleaner.putBack(moved.locations).isEmpty)
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "keep me")
        #expect(!Cleaner.canPutBack(moved.locations))
    }
}
