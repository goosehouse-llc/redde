import Foundation

/// The latest exchange, written by the app into the App Group for the Home Screen widget.
nonisolated struct WidgetSnapshot: Codable, Sendable, Equatable {
    var question: String
    var reply: String
    var date: Date

    private static let key = "widgetSnapshot"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: ShareInbox.appGroup) }

    static func load() -> WidgetSnapshot? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    static func save(question: String, reply: String) {
        let snap = WidgetSnapshot(question: String(question.prefix(140)), reply: String(reply.prefix(600)), date: .now)
        if let data = try? JSONEncoder().encode(snap) { defaults?.set(data, forKey: key) }
    }

    static func clear() { defaults?.removeObject(forKey: key) }
}
