import Foundation
import Observation
import os

/// What was typed and not sent, conversation by conversation: each chat keeps its own draft,
/// and the text is still there after the app has been closed. Attachments waiting in a draft
/// are kept for this run only; their bytes belong to no transcript yet, and a file written for
/// a draft that is then thrown away would have nothing to clean it up.
///
/// A conversation with nothing in it has no lasting identity (every "New conversation" is
/// another one), so all of them share one draft, under `newConversation`.
///
/// Observable in one respect only: which conversations have a draft (`waiting`), for the
/// list's "Draft" marker. That changes with the first character typed and the last one
/// deleted; the text itself changes with every key and nobody is redrawn for it.
@Observable
final class Drafts {
    static let shared = Drafts()
    /// The draft of a conversation nothing has been said in yet.
    static let newConversation = "new"
    /// Drafts kept; the ones touched longest ago go first.
    static let limit = 40

    /// Which draft the composer shows for `conversation`.
    static func key(for conversation: Conversation) -> String {
        conversation.hasMessages || !conversation.outbox.isEmpty ? conversation.id.uuidString : newConversation
    }

    private struct Entry: Codable, Equatable {
        var text: String
        var at: Date
    }

    /// The conversations with something written and not sent, by `key(for:)`.
    private(set) var waiting: Set<String> = []

    @ObservationIgnored private var entries: [String: Entry] = [:] {
        didSet {
            let now = Set(entries.keys).union(held.keys)
            if now != waiting { waiting = now }
        }
    }
    @ObservationIgnored private var held: [String: [Attachment]] = [:] {
        didSet {
            let now = Set(entries.keys).union(held.keys)
            if now != waiting { waiting = now }
        }
    }
    @ObservationIgnored private let url: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.goosehouse.echo", category: "drafts")

    init(directory: URL? = nil) {
        let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true)
        url = (directory ?? support ?? URL.temporaryDirectory).appending(path: "drafts.json")
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved
            waiting = Set(saved.keys)   // (a property's observers don't run in its type's initialiser)
        }
    }

    /// Whether the conversation with this local id has a draft waiting: the list's marker.
    func isWaiting(_ conversation: UUID?) -> Bool {
        conversation.map { waiting.contains($0.uuidString) } ?? false
    }

    func text(for key: String) -> String { entries[key]?.text ?? "" }

    func attachments(for key: String) -> [Attachment] { held[key] ?? [] }

    /// Keeps what the composer holds for a conversation. Empty text forgets the draft.
    func set(text: String, for key: String, at now: Date = .now) {
        guard text != (entries[key]?.text ?? "") else { return }
        if text.isEmpty {
            entries[key] = nil
        } else {
            entries[key] = Entry(text: text, at: now)
            if entries.count > Self.limit, let oldest = entries.min(by: { $0.value.at < $1.value.at })?.key {
                entries[oldest] = nil
                held[oldest] = nil
            }
        }
        scheduleSave()
    }

    func set(attachments: [Attachment], for key: String) {
        held[key] = attachments.isEmpty ? nil : attachments
    }

    func forget(_ key: String) {
        held[key] = nil
        guard entries.removeValue(forKey: key) != nil else { return }
        scheduleSave()
    }

    /// Settings → Erase everything.
    func removeAll() {
        saveTask?.cancel()
        saveTask = nil
        entries = [:]
        held = [:]
        try? FileManager.default.removeItem(at: url)
    }

    /// Writes now. Called as the app goes to the background, where a debounced write might
    /// never get its moment.
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        write()
    }

    /// Waits for a pending write. Tests use it instead of sleeping.
    func flush() async { await saveTask?.value }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.write()
        }
    }

    private func write() {
        guard !entries.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        do {
            // The same protection as the transcripts: a draft can say as much as a message.
            try JSONEncoder().encode(entries).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            log.error("drafts not saved: \(error.localizedDescription)")
        }
    }
}
