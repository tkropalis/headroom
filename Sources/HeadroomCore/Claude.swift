import Foundation
import Security

/// What Headroom calls the folder explainer. The answers come from Claude; screens that say
/// what is sent where still name Anthropic and Claude.
public enum Helper {
    public static let name = "Ollie"
}

/// The Claude API key, kept in the login Keychain. `ANTHROPIC_API_KEY` wins when it is set,
/// so the command line tool can run without touching the Keychain.
public enum ClaudeKey {
    static let service = "claude-api-key"
    static let account = "headroom"

    public static func read() -> String? {
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !env.isEmpty { return env }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        return key
    }

    /// True when a key is stored, without reading it (reading can ask for Keychain access).
    public static var isStored: Bool {
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !env.isEmpty { return true }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public static func save(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        delete()
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: account,
                                   kSecAttrLabel as String: "Headroom Claude API key",
                                   kSecValueData as String: Data(trimmed.utf8)]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    public static func delete() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

public enum ClaudeError: LocalizedError, Equatable {
    case noKey, badKey, busy, unavailable, declined, network(String), unexpected(String)

    public var errorDescription: String? {
        switch self {
        case .noKey: "No Claude API key. Add one in Settings, under \(Helper.name)."
        case .badKey: "Anthropic didn't accept the API key. Check it in Settings, under \(Helper.name)."
        case .busy: "\(Helper.name) is busy. Try again in a minute."
        case .unavailable: "\(Helper.name) isn't available right now. Try again later."
        case .declined: "\(Helper.name) declined to answer about this folder."
        case .network(let reason): "Couldn't reach Anthropic: \(reason)"
        case .unexpected(let reason): "\(Helper.name) sent an answer Headroom couldn't read: \(reason)"
        }
    }
}

/// A minimal Messages API client. There is no official Swift SDK, so this posts JSON with URLSession.
public struct ClaudeClient: Sendable {
    public static let model = "claude-opus-5-5"
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    let key: String

    public init(key: String) { self.key = key }

    public init() throws {
        guard let key = ClaudeKey.read() else { throw ClaudeError.noKey }
        self.key = key
    }

    /// Sends one request and returns the decoded response, retrying when Claude is busy.
    func send(_ body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 180)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        // If Opus 5.5's safety classifiers decline, the API retries on the model it recommends.
        // Haiku has no server-side fallback, so its requests don't carry the parameter.
        if body["fallbacks"] != nil {
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var attempt = 0
        while true {
            attempt += 1
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                if attempt < 3 { try await Task.sleep(for: .seconds(2 * attempt)); continue }
                throw ClaudeError.network(error.localizedDescription)
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200:
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw ClaudeError.unexpected("not JSON")
                }
                return json
            case 401, 403:
                throw ClaudeError.badKey
            case 429, 500...599:
                if attempt < 3 {
                    let wait = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "retry-after").flatMap(Double.init) ?? Double(4 * attempt)
                    try await Task.sleep(for: .seconds(min(wait, 30)))
                    continue
                }
                throw status == 429 ? ClaudeError.busy : ClaudeError.unavailable
            default:
                let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
                    .flatMap { $0["error"] as? [String: Any] }?["message"] as? String
                throw ClaudeError.unexpected(message ?? "HTTP \(status)")
            }
        }
    }

    /// The text of a request without tools, for short notes.
    func text(_ body: [String: Any]) async throws -> String {
        let response = try await send(body)
        switch response["stop_reason"] as? String {
        case "refusal": throw ClaudeError.declined
        case "max_tokens": throw ClaudeError.unexpected("the answer was cut off")
        default: break
        }
        let text = (response["content"] as? [[String: Any]] ?? [])
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !text.isEmpty else { throw ClaudeError.unexpected("no text") }
        return text
    }

    /// Runs a request to the end, continuing when a server tool pauses the turn, and
    /// returns the JSON text of a structured-output answer.
    func structuredAnswer(_ body: [String: Any]) async throws -> (text: String, model: String) {
        var body = body
        var messages = body["messages"] as? [[String: Any]] ?? []
        for _ in 0..<4 {
            body["messages"] = messages
            let response = try await send(body)
            let content = response["content"] as? [[String: Any]] ?? []
            switch response["stop_reason"] as? String {
            case "refusal":
                throw ClaudeError.declined
            case "pause_turn":
                messages.append(["role": "assistant", "content": content])
                continue
            case "max_tokens":
                throw ClaudeError.unexpected("the answer was cut off")
            default:
                // Text after the last web search result is the answer; citations can split it into blocks.
                let lastTool = content.lastIndex { ($0["type"] as? String)?.hasSuffix("tool_result") == true } ?? -1
                let text = content.enumerated()
                    .filter { $0.offset > lastTool && $0.element["type"] as? String == "text" }
                    .compactMap { $0.element["text"] as? String }
                    .joined()
                guard !text.isEmpty else { throw ClaudeError.unexpected("no text") }
                return (text, response["model"] as? String ?? Self.model)
            }
        }
        throw ClaudeError.unexpected("the answer took too many steps")
    }
}
