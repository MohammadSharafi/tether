import Foundation
import Security

struct SessionSummary: Decodable, Identifiable, Hashable {
    let id: String
    let title: String?
    let cwd: String?
    let branch: String?
    let updated: Double
    let state: String?
    let dir: String?
    let mac: MacRun?

    var folder: String { cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Other" }
    var date: Date { Date(timeIntervalSince1970: updated / 1000) }
}

struct Usage: Decodable {
    var input: Int?
    var output: Int?
    var cacheRead: Int?
    var cacheWrite: Int?
}

struct Question: Decodable, Hashable {
    struct Option: Decodable, Hashable {
        let label: String
        let description: String?
    }
    let question: String
    let header: String?
    let options: [Option]
    let multiSelect: Bool?
}

/// The parts of a tool's input the app renders specially. All optional: each tool fills a few.
struct ToolInput: Decodable {
    struct Edit: Decodable { let old_string: String?; let new_string: String? }
    let file_path: String?
    let old_string: String?
    let new_string: String?
    let edits: [Edit]?
    let content: String?
    let command: String?
    let description: String?
    let plan: String?
    let questions: [Question]?
}

/// One line in a session, as sent by the server (history and live stream share this shape).
struct Event: Decodable, Identifiable {
    let id = UUID()               // row identity in the app; history events carry no server id
    let kind: String
    let text: String?
    let name: String?
    let title: String?
    let requestID: String?        // permission request id
    let input: ToolInput?
    let canAlways: Bool?
    let images: Int?
    let state: String?
    let allow: Bool?
    let always: Bool?
    let cost: Double?
    let isError: Bool?
    let usage: Usage?
    let mode: String?
    let model: String?
    let effort: String?
    let status: String?
    let resetsAt: Double?
    let utilization: Double?
    let seq: Int?

    private enum CodingKeys: String, CodingKey {
        case kind, text, name, title, requestID = "id", input, canAlways, images, state, allow, always, cost, isError,
             usage, mode, model, effort, status, resetsAt, utilization, seq
    }
}

struct SessionDetail: Decodable {
    let id: String
    let state: String?
    let seq: Int
    let mode: String?
    let model: String?
    let effort: String?
    let usage: Usage
    let events: [Event]
}

struct ModelOption: Decodable, Hashable {
    let value: String
    let displayName: String
    let description: String?
}

/// A session running on the Mac outside this app (desktop app or Terminal).
struct MacRun: Decodable, Hashable {
    let source: String
    let working: Bool
    var place: String { source == "desktop" ? "desktop app" : "Terminal" }
    var icon: String { source == "desktop" ? "macwindow" : "terminal" }
}

/// Claude Code login state for one sessions folder on the Mac.
struct Account: Decodable, Hashable {
    let dir: String
    let loggedIn: Bool?
    var name: String { URL(fileURLWithPath: dir).lastPathComponent }
}

struct ServerInfo: Decodable {
    let configDir: String
    let push: Bool
    let models: [ModelOption]
    let modes: [String]
    let efforts: [String]?
    let home: String?
    let accounts: [Account]?
}

struct FolderListing: Decodable {
    struct Folder: Decodable, Identifiable, Hashable {
        let name: String
        let path: String
        let repo: Bool
        var id: String { path }
    }
    let path: String
    let parent: String?
    let repo: Bool
    let dirs: [Folder]
}

struct ChangesReport: Decodable {
    struct File: Decodable, Identifiable, Hashable {
        let path: String
        let status: String
        let added: Int?
        let removed: Int?
        let diff: String?
        let truncated: Bool?
        var id: String { path }
    }
    let repo: Bool
    let branch: String?
    let total: Int?
    let files: [File]
}

struct SlashCommand: Decodable, Identifiable, Hashable {
    let name: String
    let description: String
    let argumentHint: String?
    let builtin: Bool
    var id: String { name }
}

struct PlanUsage: Decodable, Equatable {
    struct Window: Decodable, Equatable {
        let utilization: Double
        let resetsAt: String?
        var resetDate: Date? {
            guard let resetsAt else { return nil }
            return (try? Date(resetsAt, strategy: .iso8601))
                ?? (try? Date(resetsAt, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        }
    }
    let available: Bool
    let subscription: String?
    let fiveHour: Window?
    let sevenDay: Window?
}

struct UsageReport: Decodable {
    struct Day: Decodable, Identifiable {
        let date: String
        let input, output, cacheRead, cacheWrite: Int
        var id: String { date }
        var day: Date { Self.parser.date(from: date) ?? .now }
        static let parser: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            return f
        }()
    }
    struct Project: Decodable, Identifiable {
        let name: String
        let input, output, cacheRead, cacheWrite: Int
        var id: String { name }
    }
    struct Model: Decodable, Identifiable {
        let name: String
        let output: Int
        var id: String { name }
    }
    let days: [Day]
    let projects: [Project]
    let models: [Model]
}

/// A photo ready to send: JPEG bytes, already downscaled.
struct Attachment: Identifiable {
    let id = UUID()
    let jpeg: Data
}

struct Pairing: Equatable {
    let server: String
    let token: String
}

struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// "claude-opus-5-5" → "Opus 5.5"; ids that don't look like Claude model ids are returned as-is.
func prettyModel(_ id: String) -> String {
    let parts = id.replacingOccurrences(of: "claude-", with: "").split(separator: "-")
    guard let family = parts.first, family.allSatisfy(\.isLetter) else { return id }
    let version = parts.dropFirst().filter { $0.count < 8 } // drop date suffixes like 20251101
    return ([family.capitalized] + [version.joined(separator: ".")]).filter { !$0.isEmpty }.joined(separator: " ")
}

enum Mode {
    static func label(_ mode: String) -> String {
        switch mode {
        case "acceptEdits": "Auto-accept edits"
        case "plan": "Plan mode"
        case "auto": "Auto mode"
        default: "Ask before acting"
        }
    }
    static func icon(_ mode: String) -> String {
        switch mode {
        case "acceptEdits": "pencil.and.list.clipboard"
        case "plan": "list.bullet.clipboard"
        case "auto": "bolt.badge.automatic"
        default: "hand.raised"
        }
    }
}

@MainActor @Observable
final class Client {
    static let shared = Client()

    var baseURL: String = UserDefaults.standard.string(forKey: "baseURL") ?? "" {
        didSet { UserDefaults.standard.set(baseURL, forKey: "baseURL") }
    }
    var token: String = Keychain.load() {
        didSet { Keychain.save(token) }
    }
    var info: ServerInfo?
    /// Session to open, set by a notification tap or after starting a session.
    var openSessionID: String?
    /// Bumped when something changed sessions on the Mac, so the list reloads now instead of on its timer.
    var listVersion = 0
    /// A pairing link waiting for the user to confirm in Settings.
    var pendingPairing: Pairing?
    /// APNs device token, registered with the Mac once connected.
    var deviceToken: String? {
        didSet { Task { await registerDevice() } }
    }

    /// The last copy of each session read in this run, so reopening one shows it at once.
    /// shortcut: kept in memory only (a few hundred KB per session), add a disk cache if cold starts feel slow.
    @ObservationIgnored var detailCache: [String: SessionDetail] = [:]

    var isConfigured: Bool { URL(string: baseURL)?.host != nil && !token.isEmpty }

    private func makeRequest(_ path: String, method: String = "GET", body: [String: Any]? = nil, timeout: TimeInterval = 30) throws -> URLRequest {
        let root = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: root + path) else { throw APIError(message: "Invalid server address.") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    @discardableResult
    private func call(_ path: String, method: String = "GET", body: [String: Any]? = nil, timeout: TimeInterval = 30) async throws -> Data {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: makeRequest(path, method: method, body: body, timeout: timeout))
        } catch let error as URLError {
            // A cancelled request (view went away, app paused) is not a failure to show.
            if error.code == .cancelled { throw CancellationError() }
            throw APIError(message: "Can't reach your Mac. Check that it's awake and on Tailscale.")
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        // Tailscale answers for the Mac when the Tether server itself is restarting or stopped.
        if [502, 503, 504].contains(code) { throw APIError(message: "Tether on your Mac is not answering. Retrying…") }
        guard (200..<300).contains(code) else {
            let msg = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw APIError(message: msg ?? "Your Mac returned error \(code).")
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, _ path: String, timeout: TimeInterval = 30) async throws -> T {
        try JSONDecoder().decode(T.self, from: await call(path, timeout: timeout))
    }

    func loadInfo() async throws {
        info = try await decode(ServerInfo.self, "/info")
        await registerDevice()
    }

    func sessions() async throws -> [SessionSummary] { try await decode([SessionSummary].self, "/sessions") }
    // The Mac answers in well under a second; a short timeout turns a dead connection into a quick retry.
    func detail(_ id: String) async throws -> SessionDetail { try await decode(SessionDetail.self, "/sessions/\(id)", timeout: 10) }
    func usage(days: Int) async throws -> UsageReport { try await decode(UsageReport.self, "/usage?days=\(days)") }

    private func payload(text: String, images: [Attachment], mode: String?, model: String?, effort: String? = nil) -> [String: Any] {
        var body: [String: Any] = ["text": text]
        if !images.isEmpty {
            body["images"] = images.map { ["mediaType": "image/jpeg", "data": $0.jpeg.base64EncodedString()] }
        }
        if let mode { body["mode"] = mode }
        if let model { body["model"] = model }
        if let effort { body["effort"] = effort }
        return body
    }

    func start(cwd: String, prompt: String, images: [Attachment], mode: String, model: String, effort: String) async throws -> String {
        var body = payload(text: prompt, images: images, mode: mode, model: model, effort: effort)
        body["cwd"] = cwd
        let data = try await call("/sessions", method: "POST", body: body)
        return try JSONDecoder().decode([String: String].self, from: data)["id"] ?? ""
    }

    func send(_ id: String, text: String, images: [Attachment], mode: String? = nil, model: String? = nil, effort: String? = nil) async throws {
        try await call("/sessions/\(id)/messages", method: "POST", body: payload(text: text, images: images, mode: mode, model: model, effort: effort))
    }

    func decide(_ id: String, request: String, allow: Bool, always: Bool = false, answers: [String: String]? = nil, message: String? = nil) async throws {
        var body: [String: Any] = ["allow": allow, "always": always]
        if let answers { body["answers"] = answers }
        if let message, !message.isEmpty { body["message"] = message }
        try await call("/sessions/\(id)/permissions/\(request)", method: "POST", body: body)
    }

    func setSettings(_ id: String, mode: String? = nil, model: String? = nil, effort: String? = nil) async throws {
        var body: [String: Any] = [:]
        if let effort { body["effort"] = effort }
        if let mode { body["mode"] = mode }
        if let model { body["model"] = model }
        try await call("/sessions/\(id)/settings", method: "POST", body: body)
    }

    func interrupt(_ id: String) async throws { try await call("/sessions/\(id)/interrupt", method: "POST") }
    func close(_ id: String) async throws { try await call("/sessions/\(id)/close", method: "POST") }
    func stopOnMac(_ id: String) async throws { try await call("/sessions/\(id)/stop-mac", method: "POST") }
    func rename(_ id: String, title: String) async throws { try await call("/sessions/\(id)/rename", method: "POST", body: ["title": title]) }
    func delete(_ id: String) async throws { try await call("/sessions/\(id)", method: "DELETE") }
    func fork(_ id: String) async throws -> String {
        try JSONDecoder().decode([String: String].self, from: await call("/sessions/\(id)/fork", method: "POST"))["id"] ?? ""
    }
    func export(_ id: String) async throws -> String { String(decoding: try await call("/sessions/\(id)/export"), as: UTF8.self) }
    func changes(_ id: String) async throws -> ChangesReport { try await decode(ChangesReport.self, "/sessions/\(id)/changes") }
    func commands(_ id: String) async throws -> [SlashCommand] { try await decode([SlashCommand].self, "/sessions/\(id)/commands") }
    func plan() async throws -> PlanUsage { try await decode(PlanUsage.self, "/plan") }
    func folders(_ path: String?) async throws -> FolderListing {
        let query = path.flatMap { $0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) }.map { "?path=\($0)" } ?? ""
        return try await decode(FolderListing.self, "/folders\(query)")
    }
    func registerActivity(_ id: String, token: String) async {
        try? await call("/sessions/\(id)/activity", method: "POST", body: ["token": token, "sandbox": Self.sandboxPush])
    }

    #if DEBUG
    static let sandboxPush = true // Xcode builds get development (sandbox) push tokens
    #else
    static let sandboxPush = false
    #endif

    /// Also called when the notification choices in Settings change.
    func registerDevice() async {
        guard let deviceToken, isConfigured, info?.push == true else { return }
        let prefs = ["needsYou": Prefs.notifyNeedsYou, "done": Prefs.notifyDone]
        try? await call("/devices", method: "POST", body: ["token": deviceToken, "sandbox": Self.sandboxPush, "prefs": prefs])
    }

    /// Live events after `after`, read from the server's Server-Sent Events stream.
    func events(_ id: String, after: Int) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = try makeRequest("/sessions/\(id)/events?after=\(after)")
                    req.timeoutInterval = 60 // the Mac sends a ping every 25 s, so silence means the connection is gone
                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                        throw APIError(message: "Session is not live.")
                    }
                    for try await line in bytes.lines where line.hasPrefix("data: ") {
                        continuation.yield(try JSONDecoder().decode(Event.self, from: Data(line.dropFirst(6).utf8)))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Parses a pairing link (`tether://pair?url=…&token=…`) from the QR code the Mac shows.
    static func pairing(from url: URL) -> Pairing? {
        guard url.scheme == "tether", url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let server = items.first(where: { $0.name == "url" })?.value,
              let token = items.first(where: { $0.name == "token" })?.value,
              let parsed = URL(string: server), ["https", "http"].contains(parsed.scheme), parsed.host != nil, !token.isEmpty
        else { return nil }
        return Pairing(server: server, token: token)
    }
}
