import Foundation

/// App options, stored in UserDefaults. Views bind with @AppStorage(Prefs.key...); other code reads the statics.
enum Prefs {
    static let modeKey = "lastMode"          // default permission mode for new sessions
    static let modelKey = "lastModel"
    static let effortKey = "lastEffort"
    static let notifyNeedsYouKey = "notifyNeedsYou"
    static let notifyDoneKey = "notifyDone"
    static let showToolsKey = "showToolSteps"
    static let hapticsKey = "haptics"
    static let liveActivityKey = "liveActivities"
    static let quickRepliesKey = "quickReplies"
    static let favoritesKey = "favoriteFolders"
    static let pinnedKey = "pinnedSessions"

    static let defaultQuickReplies = ["Continue", "Yes, go ahead", "Run the tests", "Explain what you changed", "Commit the changes"]

    private static func bool(_ key: String) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
    static var notifyNeedsYou: Bool { bool(notifyNeedsYouKey) }
    static var notifyDone: Bool { bool(notifyDoneKey) }
    static var liveActivities: Bool { bool(liveActivityKey) }
}

enum Effort {
    static let all = ["default", "low", "medium", "high", "xhigh", "max"]
    static func label(_ effort: String) -> String {
        switch effort {
        case "low": "Low"
        case "medium": "Medium"
        case "high": "High"
        case "xhigh": "Extra high"
        case "max": "Max"
        default: "Default"
        }
    }
    static func detail(_ effort: String) -> String {
        switch effort {
        case "low": "Fastest, for simple tasks"
        case "medium": "Balanced"
        case "high": "Thorough"
        case "xhigh": "Best for most coding"
        case "max": "Deepest thinking, slowest"
        default: "Claude Code's setting on your Mac"
        }
    }
}

/// Lets @AppStorage hold a list of strings (stored as JSON).
extension Array: @retroactive RawRepresentable where Element == String {
    public init?(rawValue: String) {
        guard let list = try? JSONDecoder().decode([String].self, from: Data(rawValue.utf8)) else { return nil }
        self = list
    }

    public var rawValue: String {
        (try? String(decoding: JSONEncoder().encode(self), as: UTF8.self)) ?? "[]"
    }
}

extension Array where Element == String {
    /// Adds or removes `item`, keeping order.
    mutating func toggle(_ item: String) {
        if let i = firstIndex(of: item) { remove(at: i) } else { append(item) }
    }
}
