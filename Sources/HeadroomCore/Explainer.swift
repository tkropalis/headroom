import CoreServices
import Foundation

/// What Claude said a folder is. Stored per path, so each folder is asked about once.
public struct Explanation: Codable, Sendable, Hashable, Identifiable {
    public enum Verdict: String, Codable, Sendable, CaseIterable {
        case safe, rebuilds, yourCall, keep

        public var title: String {
            switch self {
            case .safe: "Safe to remove"
            case .rebuilds: "Rebuilds on use"
            case .yourCall: "Your call"
            case .keep: "Leave it"
            }
        }

        /// The cleanup level a confirmed answer becomes; nil for folders to leave alone.
        public var level: CleanupLevel? {
            switch self {
            case .safe: .safe
            case .rebuilds: .rebuilds
            case .yourCall: .yourCall
            case .keep: nil
            }
        }
    }

    public enum Confidence: String, Codable, Sendable { case high, medium, low }

    public var id: String { path }
    public var path: String
    public var name: String
    public var what: String
    public var owner: String
    public var ownerBundleID: String
    public var verdict: Verdict
    public var cost: String
    public var howToRemove: String
    public var confidence: Confidence
    /// Size when Claude was asked.
    public var bytes: Int64
    public var askedAt: Date
    public var model: String
    /// Checked on this Mac after the answer: nil when Claude named no app.
    public var appInstalled: Bool?
    /// The person accepted the answer, so the folder joins Headroom's cleanup list.
    public var confirmed: Bool

    /// Can become a cleanup row: Claude says it can go, and Headroom's own safety rules agree.
    public var canConfirm: Bool { verdict.level != nil && PathSafety.isDeletable(path) }
}

/// The facts sent to Claude about one folder: names and sizes, never contents.
public struct FolderFacts: Sendable {
    public struct Child: Sendable {
        public var name: String
        public var bytes: Int64
        public var isDirectory: Bool
    }

    public var path: String
    public var bytes: Int64
    public var isDirectory: Bool
    public var lastOpened: Date?
    public var modified: Date?
    public var kind: SpaceKind?
    public var children: [Child]
    public var childCount: Int

    static let shownChildren = 25

    /// Uses sizes the caller already measured (the Space Map has them) and measures the rest.
    public static func gather(path: String, bytes: Int64? = nil, children measured: [String: Int64]? = nil) async -> FolderFacts {
        let isDirectory = SpaceTree.isDirectoryPath(path)
        var children: [Child] = []
        var count = 0
        if isDirectory {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            count = names.count
            let paths = names.map { path + "/" + $0 }
            var sizes = measured ?? [:]
            let missing = paths.filter { sizes[$0] == nil }
            if !missing.isEmpty {
                for (child, size) in await Sizer.measureAll(missing, unshared: false) { sizes[child] = size.allocated }
            }
            children = paths.map { Child(name: ($0 as NSString).lastPathComponent, bytes: sizes[$0] ?? 0,
                                         isDirectory: SpaceTree.isDirectoryPath($0)) }
                .sorted { $0.bytes > $1.bytes }
        }
        let total = bytes ?? (isDirectory ? children.reduce(0) { $0 + $1.bytes } : Sizer.measure(path, unshared: false).allocated)
        return FolderFacts(path: path, bytes: total, isDirectory: isDirectory, lastOpened: SpaceTree.lastOpened(path),
                           modified: SpaceTree.modificationDate(path), kind: SpaceTree.kind(of: path, isDirectory: isDirectory),
                           children: Array(children.prefix(shownChildren)), childCount: count)
    }

    /// Exactly the text sent to Claude. `headroom explain --show` prints it.
    public var message: String {
        var lines = [
            (isDirectory ? "Folder: " : "File: ") + Paths.display(path),
            "Size: \(ByteFormat.string(bytes))",
        ]
        if let lastOpened { lines.append("Last opened: \(Self.day(lastOpened))") }
        if let modified { lines.append("Last modified: \(Self.day(modified))") }
        if let kind { lines.append("Headroom's guess: \(kind.title)") }
        if isDirectory {
            if children.isEmpty {
                lines.append("Inside: nothing")
            } else {
                let more = childCount > children.count ? ", \(children.count) of \(childCount) items" : ""
                lines.append("Inside (largest first\(more)):")
                lines += children.map { "- \($0.name)\($0.isDirectory ? "/" : "") \(ByteFormat.string($0.bytes))" }
            }
        }
        return lines.joined(separator: "\n")
    }

    static func day(_ date: Date) -> String { date.formatted(.iso8601.year().month().day()) }
}

public enum Explainer {
    /// Personal folders whose names Headroom never sends anywhere.
    static let privateFolders: [String] = {
        let h = Paths.home
        return ["Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music", "Library/Mobile Documents",
                "Library/CloudStorage", "Library/Mail", "Library/Messages", "Library/Containers/com.apple.mail"]
            .map { h + "/" + $0 }
    }()

    /// Why this path can't be sent to Claude, or nil when it can.
    public static func privacyBlocker(_ path: String) -> String? {
        if path == Paths.home || privateFolders.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return "Headroom doesn't send the names of your own files anywhere."
        }
        return nil
    }

    // MARK: Asking

    public static func explain(_ facts: FolderFacts, client: ClaudeClient) async throws -> Explanation {
        if let reason = privacyBlocker(facts.path) { throw ClaudeError.unexpected(reason) }
        let body: [String: Any] = [
            "model": ClaudeClient.model,
            "max_tokens": 16000,
            // Tools and system prompt are the same every time: cached, they cost a tenth when
            // several folders are asked about within a few minutes.
            "system": [["type": "text", "text": systemPrompt, "cache_control": ["type": "ephemeral"]]],
            "messages": [["role": "user", "content": facts.message]],
            "tools": [["type": "web_search_20260209", "name": "web_search", "max_uses": 3]],
            "output_config": ["effort": "medium", "format": ["type": "json_schema", "schema": schema]],
            "fallbacks": "default",
        ]
        let answer = try await client.structuredAnswer(body)
        guard let data = answer.text.data(using: .utf8),
              let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw ClaudeError.unexpected("the answer wasn't in the expected shape")
        }
        // Claude can't see this Mac's apps, so whether the app is installed, and its real
        // bundle identifier (used to quit it before cleaning), are checked here.
        let app = reply.ownerIsApp
            ? installedApp(bundleID: reply.ownerBundleID.trimmingCharacters(in: .whitespaces), name: reply.owner)
            : (bundleID: "", installed: nil)
        return Explanation(path: facts.path, name: tidy(reply.name), what: tidy(reply.what), owner: tidy(reply.owner),
                           ownerBundleID: app.bundleID, verdict: reply.verdict, cost: tidy(reply.cost),
                           howToRemove: tidy(reply.howToRemove), confidence: reply.confidence, bytes: facts.bytes,
                           askedAt: Date(), model: answer.model, appInstalled: app.installed, confirmed: false)
    }

    /// Finds the owning app by bundle identifier, then by name in the Applications folders.
    /// `installed` is nil when Claude named no app.
    static func installedApp(bundleID: String, name: String) -> (bundleID: String, installed: Bool?) {
        if !bundleID.isEmpty, isInstalled(bundleID) { return (bundleID, true) }
        let key = normalized(name)
        guard !key.isEmpty else { return (bundleID, bundleID.isEmpty ? nil : false) }
        // Parts of macOS aren't apps that can be missing. Installed Apple apps were found above.
        if key.hasPrefix("macos") || bundleID.hasPrefix("com.apple.") {
            return (bundleID, nil)
        }
        let fm = FileManager.default
        for dir in ["/Applications", "/Applications/Utilities", Paths.home + "/Applications"] {
            for entry in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where entry.hasSuffix(".app") {
                guard normalized((entry as NSString).deletingPathExtension) == key else { continue }
                let found = Bundle(path: dir + "/" + entry)?.bundleIdentifier ?? bundleID
                return (found, true)
            }
        }
        return (bundleID, false)
    }

    /// One space between words, none at the ends.
    static func tidy(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func normalized(_ name: String) -> String { name.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// Asks, or returns the stored answer. A new answer replaces the stored one and is unconfirmed.
    public static func explain(path: String, bytes: Int64? = nil, children: [String: Int64]? = nil,
                               refresh: Bool = false) async throws -> Explanation {
        if !refresh, let stored = Store.explanation(for: path) { return stored }
        let client = try ClaudeClient()
        let facts = await FolderFacts.gather(path: path, bytes: bytes, children: children)
        let explanation = try await explain(facts, client: client)
        Store.saveExplanation(explanation)
        return explanation
    }

    static func isInstalled(_ bundleID: String) -> Bool {
        guard let urls = LSCopyApplicationURLsForBundleIdentifier(bundleID as CFString, nil)?.takeRetainedValue() as? [URL] else {
            return false
        }
        return !urls.isEmpty
    }

    struct Reply: Decodable {
        var name: String
        var what: String
        var owner: String
        var ownerBundleID: String
        var ownerIsApp: Bool
        var verdict: Explanation.Verdict
        var cost: String
        var howToRemove: String
        var confidence: Explanation.Confidence
    }

    static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "name": ["type": "string", "description": "2 to 5 words, like \"Arc browser cache\"."],
            "what": ["type": "string", "description": "What it is and what makes it, in at most two sentences."],
            "owner": ["type": "string", "description": "The app or tool that makes it, or empty when unknown."],
            "ownerBundleID": ["type": "string", "description": "That app's bundle identifier, or empty when unknown or not an app."],
            "ownerIsApp": ["type": "boolean", "description": "True when the owner is a Mac app, not macOS, a command line tool or a background service."],
            "verdict": ["type": "string", "enum": Explanation.Verdict.allCases.map(\.rawValue)],
            "cost": ["type": "string", "description": "One sentence on what removing it loses."],
            "howToRemove": ["type": "string", "description": "The app's own way to clear it, in one sentence, or empty."],
            "confidence": ["type": "string", "enum": ["high", "medium", "low"]],
        ],
        "required": ["name", "what", "owner", "ownerBundleID", "ownerIsApp", "verdict", "cost", "howToRemove", "confidence"],
        "additionalProperties": false,
    ]

    static let systemPrompt = """
    You help Headroom, a Mac disk space app, explain folders and files it doesn't recognise. For each one you get its \
    path (the home folder is shown as ~), its size and dates, and the names and sizes of what is inside. You never see \
    file contents.

    Say what it is, which app or tool makes it, and what happens if it is removed. Be accurate rather than quick: if a \
    name is unfamiliar, search the web. If you still aren't sure, say so with confidence "low" and verdict "keep". \
    Someone will decide whether to remove this based on your answer.

    Verdicts:
    - safe: a cache, log or temporary data. Removing it loses nothing; the app makes what it needs again.
    - rebuilds: nothing is lost, but the next build, launch or sync is slower, or something downloads again.
    - yourCall: removing it loses something the person may want, such as settings, history, downloads, a game, a \
    virtual machine or saved work.
    - keep: removing it would break macOS or an app, it holds the person's own work, or you aren't sure.

    Never answer safe or rebuilds for anything macOS needs, or for an app's main data (accounts, libraries, settings, \
    databases). Don't guess whether the app is still installed; Headroom checks that on the Mac itself.

    Writing: plain words and short sentences, no marketing and no exclamation marks. British spelling, and say "the Bin", \
    not "the Trash". "cost" is one sentence naming what is lost, such as "Nothing; Arc downloads pages again as you \
    browse." "howToRemove" names the app's own setting or command for clearing this when one exists, otherwise it is empty.
    """
}

/// The answers file, read once: the catalogue consults it for every row the Space Map lists.
final class ExplanationCache: @unchecked Sendable {
    static let shared = ExplanationCache()
    private let lock = NSLock()
    private var items: [Explanation]?
    /// Goes up whenever the answers change, so rules learned from them can be rebuilt.
    private var version = 0

    func get(_ load: () -> [Explanation]) -> [Explanation] {
        lock.lock(); defer { lock.unlock() }
        if let items { return items }
        let loaded = load()
        items = loaded
        return loaded
    }

    func set(_ value: [Explanation]) { lock.lock(); items = value; version += 1; lock.unlock() }

    var currentVersion: Int { lock.lock(); defer { lock.unlock() }; return version }
}

extension Store {
    public static func explanations() -> [Explanation] {
        ExplanationCache.shared.get { load("explanations.json", as: [Explanation].self) ?? [] }
    }

    public static func explanation(for path: String) -> Explanation? { explanations().first { $0.path == path } }

    public static func saveExplanation(_ explanation: Explanation) {
        var all = explanations().filter { $0.path != explanation.path }
        all.insert(explanation, at: 0)
        saveExplanations(all)
    }

    public static func removeExplanation(_ path: String) {
        saveExplanations(explanations().filter { $0.path != path })
    }

    static func saveExplanations(_ all: [Explanation]) {
        ExplanationCache.shared.set(all)
        save(all, as: "explanations.json")
    }
}

extension Catalog {
    /// Folders Claude explained and the person added to the list. They always go to the Bin,
    /// so a wrong answer can be put back.
    public static func learned() -> [CatalogEntry] { learned(from: Store.explanations()) }

    static func learned(from explanations: [Explanation]) -> [CatalogEntry] {
        explanations.filter { $0.confirmed && $0.canConfirm }.compactMap { item in
            guard let level = item.verdict.level else { return nil }
            let quit = item.ownerBundleID.isEmpty ? [] : [AppRef(item.owner.isEmpty ? item.name : item.owner, item.ownerBundleID)]
            return CatalogEntry("learned:" + Paths.display(item.path), item.name, level, .paths([item.path]),
                                disposal: .trash, cost: item.cost, quit: quit)
        }
    }

    /// Built-in entries, then the ones learned from Claude.
    public static var all: [CatalogEntry] { builtIn + learned() }
}
