import Foundation
import HeadroomCore

let usage = """
Usage: headroom <command> [options]

Commands:
  status                    Free space on the internal disk
  scan [--json]             What can be cleaned, grouped by what it costs
  clean [ids…] [options]    Clean items, after showing exactly what will happen
      --group <name>        ready (default), rebuilds, yourCall or dormant
      --dry-run             Show the plan and stop
      --yes                 Don't ask for confirmation
  history                   Past cleanups and what they freed
  growth [--record]         Folders that grew fast; --record takes today's snapshot

Sizes are in decimal GB, like Finder.
"""

var arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.isEmpty ? "status" : arguments.removeFirst()
func flag(_ name: String) -> Bool {
    if let i = arguments.firstIndex(of: name) { arguments.remove(at: i); return true }
    return false
}
func option(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
    let value = arguments[i + 1]
    arguments.removeSubrange(i...(i + 1))
    return value
}
func pad(_ s: String, _ width: Int) -> String { s.count >= width ? s : s + String(repeating: " ", count: width - s.count) }
func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func printStatus() {
    guard let disk = DiskStatus.current() else { fail("Couldn't read the disk.") }
    print("\(ByteFormat.string(disk.available)) free of \(ByteFormat.string(disk.total))")
}

func scanQuietly() async -> ScanResult {
    let scan = await Scanner.scan()
    Store.saveScan(scan)
    return scan
}

switch command {
case "status":
    printStatus()

case "scan":
    let json = flag("--json")
    let scan = await scanQuietly()
    if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(scan), as: UTF8.self))
        break
    }
    print("\(ByteFormat.string(scan.disk.available)) free of \(ByteFormat.string(scan.disk.total))\n")
    let processes = ProcessSnapshot.capture()
    for group in CandidateGroup.allCases {
        let items = scan.candidates(in: group)
        guard !items.isEmpty else { continue }
        print("\(group.title) · \(ByteFormat.string(scan.total(in: group))) · \(group.note)")
        for item in items {
            let status = item.status(with: processes)
            print("  \(pad(item.sizeLabel, 14)) \(pad(item.id, 22)) \(item.name)")
            if let note = status.note { print("  \(pad("", 14)) \(pad("", 22)) ! \(note)") }
        }
        print("")
    }
    if scan.unreadableFiles > 0 {
        print("\(scan.unreadableFiles) files couldn't be read. Give your terminal Full Disk Access to include them.")
    }

case "clean":
    let dryRun = flag("--dry-run")
    let yes = flag("--yes")
    let groupName = option("--group")
    let scan = await scanQuietly()
    let processes = ProcessSnapshot.capture()

    var chosen: [Candidate]
    if !arguments.isEmpty {
        chosen = arguments.compactMap { id in scan.candidates.first { $0.id == id } }
        let missing = arguments.filter { id in !scan.candidates.contains { $0.id == id } }
        if !missing.isEmpty { fail("Not found in this scan: \(missing.joined(separator: ", ")). Run `headroom scan` for ids.") }
    } else {
        guard let group = CandidateGroup(rawValue: groupName ?? "ready") else { fail("Unknown group. Use ready, rebuilds, yourCall or dormant.") }
        chosen = scan.candidates(in: group).filter { $0.status(with: processes).selectedByDefault }
    }

    var plan: [Candidate] = []
    print("Plan:")
    for item in chosen {
        let status = item.status(with: processes)
        if let blocker = status.blocker {
            print("  skip   \(item.name): \(blocker)")
            continue
        }
        plan.append(item)
        let quitting = status.appsToQuit.isEmpty ? "" : " (quits \(status.appsToQuit.map(\.name).joined(separator: ", ")))"
        let how = if case .trash = item.action { "to Bin" } else { "delete" }
        print("  \(pad(how, 6)) \(pad(item.sizeLabel, 14)) \(item.name)\(quitting)")
        print("         \(item.cost)")
    }
    let expected = plan.reduce(Int64(0)) { $0 + $1.expectedBytes }
    guard !plan.isEmpty else { print("Nothing to clean."); break }
    print("\nAbout \(ByteFormat.string(expected)) in \(plan.count) items.")
    if dryRun { break }
    if !yes {
        print("Clean now? [y/N] ", terminator: "")
        guard readLine()?.lowercased().hasPrefix("y") == true else { print("Cancelled. Nothing was removed."); break }
    }

    let names = plan.map(\.name)
    let outcomes = await Cleaner().run(plan, onStart: { i in print("Cleaning \(names[i])…") },
                                       onFinish: { o in
        let freed = o.freed > 0 ? ByteFormat.string(o.freed) : "0 KB"
        print("  \(o.state.rawValue): \(freed)\(o.message.map { " · " + $0 } ?? "")")
    })
    let total = outcomes.reduce(Int64(0)) { $0 + $1.freed }
    let done = outcomes.filter { $0.state == .done }
    if !done.isEmpty { Store.appendHistory(HistoryEntry(items: done.map(\.name), freed: total)) }
    print("\nFreed \(ByteFormat.string(total)), measured from free space before and after.")
    printStatus()

case "history":
    let entries = Store.history()
    if entries.isEmpty { print("No cleanups yet.") }
    for entry in entries {
        print("\(pad(RelativeDate.dateTime(entry.date), 16)) \(pad(ByteFormat.string(entry.freed), 9)) \(entry.summary)")
    }

case "growth":
    let record = flag("--record")
    let history = Store.snapshots()
    if record {
        let started = Date()
        let snapshot = await GrowthTracker.record()
        Store.appendSnapshot(snapshot)
        print("Recorded \(snapshot.sizes.count) folders in \(Int(Date().timeIntervalSince(started))) s.")
        let alerts = GrowthTracker.alerts(history: history, current: snapshot, threshold: 5_000_000_000)
        if history.isEmpty { print("This is the first snapshot. Growth is compared from tomorrow.") }
        for alert in alerts { print("  \(alert.headline) since \(RelativeDate.dateTime(alert.since))") }
        if !history.isEmpty && alerts.isEmpty { print("Nothing grew more than 5 GB.") }
    } else if let last = history.last {
        print("Last snapshot \(RelativeDate.string(last.date)), \(last.sizes.count) folders. Largest:")
        for (path, size) in last.sizes.sorted(by: { $0.value > $1.value }).prefix(15) {
            print("  \(pad(ByteFormat.string(size), 9)) \(Paths.display(path))")
        }
    } else {
        print("No snapshots yet. Run `headroom growth --record`.")
    }

case "help", "--help", "-h":
    print(usage)

default:
    fail(usage)
}
