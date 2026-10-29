import Foundation
#if canImport(EventKit)
import EventKit
#endif
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Cards pinned out of their chat to the top of the chat list (asked 2026-10-28: "export the card
/// from the chat and place it somewhere easy to access"): a packing list ticked off on the way,
/// without finding the chat it came in. A pinned card is the same card: its ticks are its key's
/// (`CardAnswers`), wherever it is ticked. Kept in the app's defaults.
@MainActor
@Observable
final class PinnedCards {
    static let shared = PinnedCards()

    nonisolated struct Pin: Codable, Identifiable, Equatable, Sendable {
        var key: String
        var card: ReplyCard
        var title: String
        /// The conversation it came from, to open, and the bot whose chat that was.
        var conversation: UUID?
        var agent: String?
        var pinnedAt: Date
        var id: String { key }
    }

    private(set) var pins: [Pin]
    /// The one open over the chat list.
    var open: Pin?
    private static let key = "pinnedCards"
    static let most = 20
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pins = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([Pin].self, from: $0) } ?? []
    }

    func isPinned(_ key: String) -> Bool { pins.contains { $0.key == key } }

    func pin(_ card: ReplyCard, title: String, conversation: UUID?, agent: String?) {
        guard !card.key.isEmpty, !isPinned(card.key) else { return }
        pins.insert(Pin(key: card.key, card: card, title: title, conversation: conversation, agent: agent, pinnedAt: .now), at: 0)
        pins = Array(pins.prefix(Self.most))
        save()
    }

    func unpin(_ key: String) {
        pins.removeAll { $0.key == key }
        if open?.key == key { open = nil }
        save()
    }

    private func save() { defaults.set(try? JSONEncoder().encode(pins), forKey: Self.key) }
}

/// A checklist out of Redde: as text (Markdown's task list, which Notes and most apps read), or
/// as a list of its own in Reminders.
@MainActor
enum ChecklistExport {
    static func text(_ card: ReplyCard.Checklist, done: Set<Int>) -> String {
        var lines = ["\(card.emoji.map { $0 + " " } ?? "")\(card.title)"]
        for section in card.sections {
            if let title = section.title { lines += ["", "## \(title)"] } else { lines.append("") }
            lines += section.items.map { "- [\(done.contains($0) ? "x" : " ")] \(card.items[$0].text)" }
        }
        return lines.joined(separator: "\n")
    }

    static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    #if canImport(EventKit)
    /// A new Reminders list named for the card, an item for each (its section in its notes), those
    /// ticked done. What to say, as it went.
    static func toReminders(_ card: ReplyCard.Checklist, done: Set<Int>) async -> String {
        guard await DeviceCalendar.allowed(.reminder) else {
            return String(localized: "Redde isn't allowed into Reminders. Turn it on in Settings → Apps → Redde.")
        }
        let store = EKEventStore()
        guard let source = store.defaultCalendarForNewReminders()?.source else {
            return String(localized: "This iPhone has no reminders account to add a list to.")
        }
        let list = EKCalendar(for: .reminder, eventStore: store)
        list.title = card.title
        list.source = source
        do {
            try store.saveCalendar(list, commit: false)
            for (index, item) in card.items.enumerated() {
                let reminder = EKReminder(eventStore: store)
                reminder.calendar = list
                reminder.title = item.text
                reminder.notes = item.section
                reminder.isCompleted = done.contains(index)
                try store.save(reminder, commit: false)
            }
            try store.commit()
            return String(localized: "Added to Reminders as the list “\(card.title)”.")
        } catch {
            store.reset()
            return String(localized: "It couldn't be added to Reminders: \(error.localizedDescription)")
        }
    }
    #endif
}
