// Compiled into both the app and the Live Activity widget extension.
import Foundation
import Security
import ActivityKit
import AppIntents

/// A session shown as a Live Activity on the lock screen and in the Dynamic Island.
/// ContentState must match what the Mac server pushes (server.mjs: activityState).
struct SessionActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var status: String        // running | waiting | idle | closed
        var title: String
        var detail: String
        var requestId: String?    // set while Claude waits for Allow / Deny
        var updatedAt: Double
    }
    var sessionId: String
}

/// Allow / Deny straight from the Live Activity. As a LiveActivityIntent it runs in the app's process,
/// so it can read the app's server address and the token in the Keychain.
struct DecideIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Answer Claude"
    static let isDiscoverable = false

    @Parameter(title: "Session") var sessionId: String
    @Parameter(title: "Request") var requestId: String
    @Parameter(title: "Allow") var allow: Bool

    init() {}

    init(sessionId: String, requestId: String, allow: Bool) {
        self.sessionId = sessionId
        self.requestId = requestId
        self.allow = allow
    }

    func perform() async throws -> some IntentResult {
        guard let base = UserDefaults.standard.string(forKey: "baseURL"),
              let url = URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) + "/sessions/\(sessionId)/permissions/\(requestId)")
        else { return .result() }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(Keychain.load())", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["allow": allow])
        let (_, response) = try await URLSession.shared.data(for: req)
        // Show the answer at once; the Mac's next update confirms it.
        if (response as? HTTPURLResponse)?.statusCode == 200 {
            for activity in Activity<SessionActivityAttributes>.activities where activity.attributes.sessionId == sessionId {
                var state = activity.content.state
                state.status = "running"
                state.requestId = nil
                state.detail = allow ? "Allowed" : "Denied"
                await activity.update(.init(state: state, staleDate: nil))
            }
        }
        return .result()
    }
}

enum Keychain {
    private static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "Tether",
        kSecAttrAccount as String: "token",
    ]

    static func load() -> String {
        var query = base
        query[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func save(_ value: String) {
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        // Readable after first unlock so lock-screen Allow/Deny actions can reach the Mac.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}
