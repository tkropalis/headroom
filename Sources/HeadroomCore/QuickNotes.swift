import CryptoKit
import Foundation

/// Short notes Ollie writes without being asked: a summary for the top of the menu, why a
/// folder grew, and a first guess at folders Headroom doesn't know. They use Haiku, which costs
/// a small fraction of a cent each, and every note is saved so the same question is never sent twice.
public enum QuickNotes {
    public static let model = "claude-haiku-5-5"

    // MARK: Summary

    /// What the summary is written from: totals only, no paths.
    public struct SummaryInput: Sendable {
        public var free: Int64
        public var total: Int64
        public var warnGB: Int
        public var runway: String?
        public var categories: [(name: String, bytes: Int64)]
        public var groups: [(name: String, bytes: Int64, count: Int, largest: [String])]
        public var growth: [String]

        public init(free: Int64, total: Int64, warnGB: Int, runway: String?, categories: [(name: String, bytes: Int64)],
                    groups: [(name: String, bytes: Int64, count: Int, largest: [String])], growth: [String]) {
            self.free = free
            self.total = total
            self.warnGB = warnGB
            self.runway = runway
            self.categories = categories
            self.groups = groups
            self.growth = growth
        }

        /// Sizes in whole GB, so small changes in free space don't make a new note.
        public var message: String {
            // Above the warning level the menu already shows the number, so the note needn't repeat it.
            var lines = [free >= Int64(warnGB) * 1_000_000_000
                ? "Free space is above the \(warnGB) GB warning level; nothing is urgent."
                : "Free: \(ByteFormat.wholeGB(free)) of \(ByteFormat.wholeGB(total)). Warning level: \(warnGB) GB."]
            if let runway { lines.append("Trend: \(runway)") }
            lines.append("Space by category: " + categories.map { "\($0.name) \(ByteFormat.wholeGB($0.bytes))" }.joined(separator: ", "))
            if groups.isEmpty {
                lines.append("Cleanup: nothing to clean.")
            } else {
                lines.append("Cleanup:")
                lines += groups.map { group in
                    let largest = group.largest.isEmpty ? "" : ", largest: " + group.largest.joined(separator: ", ")
                    return "- \(group.name): \(rounded(group.bytes)) in \(group.count) items\(largest)"
                }
            }
            if !growth.isEmpty { lines.append("Grew fast: " + growth.joined(separator: "; ")) }
            return lines.joined(separator: "\n")
        }

        /// Builds the input from what the app already knows. Folders that grew in personal places are not named.
        public static func make(disk: DiskStatus, candidates: [Candidate], snapshot: FolderSnapshot?, warnGB: Int,
                                runway: Runway?, growth: [GrowthAlert]) -> SummaryInput {
            let categories = snapshot.map { SpaceTree.categories(snapshot: $0, disk: disk) } ?? []
            let groups = CandidateGroup.allCases.compactMap { group -> (name: String, bytes: Int64, count: Int, largest: [String])? in
                let items = candidates.filter { $0.group == group }.sorted { $0.expectedBytes > $1.expectedBytes }
                guard !items.isEmpty else { return nil }
                // Forgotten files, identical files and project caches are named after your own files and projects.
                let named = [.ready, .rebuilds, .yourCall].contains(group)
                    ? items.filter { $0.projectPath == nil }.prefix(2).map { "\($0.name) \(ByteFormat.string($0.expectedBytes))" } : []
                return (group.title, items.reduce(0) { $0 + $1.expectedBytes }, items.count, named)
            }
            let grew = growth.map { alert in
                let name = Explainer.privacyBlocker(alert.path) == nil ? alert.name : "a personal folder"
                return "\(name) grew \(ByteFormat.string(alert.delta))"
            }
            return SummaryInput(free: disk.available, total: disk.total, warnGB: warnGB, runway: runway?.line,
                                categories: categories.map { ($0.name, $0.bytes) }, groups: groups, growth: grew)
        }

        func rounded(_ bytes: Int64) -> String { bytes >= 1_000_000_000 ? ByteFormat.wholeGB(bytes) : "under 1 GB" }
    }

    public static func summary(_ input: SummaryInput) async throws -> String {
        try await note(kind: "summary", prompt: input.message, system: """
        You write the note at the top of Headroom, a Mac disk space app. From the numbers given, say what matters most \
        right now and the one thing most worth doing, if anything. One or two short sentences, at most 25 words in \
        all. Lead with the action when there is one, like "Clear <item> (<size>) under Rebuilds on use; nothing \
        is lost, the next build is slower."

        Cleanup groups, from no cost to most: "Ready to clean" loses nothing; "Rebuilds on use" loses nothing but the \
        next build or launch is slower; "Your call" loses something the person may want; "Identical files" shares \
        space between copies and deletes nothing; "Forgotten files" are big files not opened for months; "Dormant \
        projects" are dependencies of inactive projects. "System and other" is macOS and space Headroom can't measure; \
        it can't be cleaned, so don't suggest it. When free space is below the warning level, say so first. Prefer \
        the action that gives back the most for the least cost, and name the item when that helps.

        Use only the numbers given and round them as given. Plain words, no greeting, no exclamation marks, no \
        markdown. British spelling; say "the Bin", not "the Trash".
        """)
    }

    // MARK: Growth

    /// Why a folder grew, from the names and sizes of what is inside it now.
    public static func growthReason(_ alert: GrowthAlert, children: [FolderFacts.Child]) async throws -> String {
        var lines = ["Folder: \(Paths.display(alert.path))",
                     "Was \(ByteFormat.string(alert.previous)) on \(FolderFacts.day(alert.since)), now \(ByteFormat.string(alert.current))."]
        if !children.isEmpty {
            lines.append("Inside now (largest first):")
            lines += children.prefix(12).map { "- \($0.name)\($0.isDirectory ? "/" : "") \(ByteFormat.string($0.bytes))" }
        }
        return try await note(kind: "growth", prompt: lines.joined(separator: "\n"), system: """
        A folder on a Mac grew fast. From its path and what is inside it, say what most likely made it grow, in one \
        short sentence of at most 15 words, such as "Probably a new iOS simulator runtime that Xcode downloaded." \
        Start with "Probably" when you aren't certain. Plain words, no markdown, British spelling. Don't say whether \
        to delete it.
        """)
    }

    // MARK: First guesses

    /// One short guess per folder, asked in a single request. Saved per path.
    public static func guesses(_ folders: [FolderFacts]) async throws -> [String: String] {
        var out: [String: String] = [:]
        var missing: [FolderFacts] = []
        for facts in folders where Explainer.privacyBlocker(facts.path) == nil {
            if let saved = NoteStore.get("guess:" + facts.path) { out[facts.path] = saved } else { missing.append(facts) }
        }
        guard !missing.isEmpty else { return out }

        let prompt = missing.enumerated().map { index, facts in
            let inside = facts.children.prefix(8).map(\.name).joined(separator: ", ")
            return "\(index + 1). \(Paths.display(facts.path)) · \(ByteFormat.string(facts.bytes))" + (inside.isEmpty ? "" : " · contains \(inside)")
        }.joined(separator: "\n")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2000,
            "system": """
            For each numbered folder on a Mac, guess in at most 10 words what it is and which app or tool makes it, \
            like "Postman's app data: sign-in, settings and history". Plain words, no markdown. Don't say whether it \
            is safe to delete. If you can't tell, say "Not sure what this is".
            """,
            "messages": [["role": "user", "content": prompt]],
            "output_config": ["effort": "low", "format": ["type": "json_schema", "schema": [
                "type": "object",
                "properties": ["guesses": ["type": "array", "items": [
                    "type": "object",
                    "properties": ["number": ["type": "integer"], "guess": ["type": "string"]],
                    "required": ["number", "guess"], "additionalProperties": false,
                ]]],
                "required": ["guesses"], "additionalProperties": false,
            ] as [String: Any]]],
        ]
        let text = try await ClaudeClient().text(body)
        struct Reply: Decodable { struct Item: Decodable { var number: Int; var guess: String }; var guesses: [Item] }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: Data(text.utf8)) else {
            throw ClaudeError.unexpected("the guesses weren't in the expected shape")
        }
        for item in reply.guesses where (1...missing.count).contains(item.number) {
            let path = missing[item.number - 1].path
            let guess = Explainer.tidy(item.guess)
            out[path] = guess
            NoteStore.set("guess:" + path, guess)
        }
        return out
    }

    /// A saved guess, without asking.
    public static func savedGuess(_ path: String) -> String? { NoteStore.get("guess:" + path) }

    // MARK: Asking

    /// One plain-text note, saved under a hash of what was sent.
    static func note(kind: String, prompt: String, system: String) async throws -> String {
        let key = kind + ":" + SHA256.hash(data: Data((system + prompt).utf8)).map { String(format: "%02x", $0) }.joined()
        if let saved = NoteStore.get(key) { return saved }
        let body: [String: Any] = [
            "model": model,
            // Room for Haiku's adaptive thinking as well as the short answer.
            "max_tokens": 1500,
            "system": system,
            "messages": [["role": "user", "content": prompt]],
            "output_config": ["effort": "low"],
        ]
        let text = Explainer.tidy(try await ClaudeClient().text(body))
        NoteStore.set(key, text)
        return text
    }
}

/// Saved notes in notes.json, newest first, at most 300.
enum NoteStore {
    struct Entry: Codable { var key: String; var text: String; var date: Date }
    private static let lock = NSLock()

    static func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return (Store.load("notes.json", as: [Entry].self) ?? []).first { $0.key == key }?.text
    }

    static func set(_ key: String, _ text: String) {
        lock.lock(); defer { lock.unlock() }
        var all = (Store.load("notes.json", as: [Entry].self) ?? []).filter { $0.key != key }
        all.insert(Entry(key: key, text: text, date: Date()), at: 0)
        Store.save(Array(all.prefix(300)), as: "notes.json")
    }
}
