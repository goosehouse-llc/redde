import Foundation
import Observation
import os

/// Quick capture: a note said or typed in passing, for Hermes to file, with nothing said back.
/// "The plumber comes Thursday at ten" is not a question, and the conversation that happens to
/// be open is not where it belongs.
///
/// A note is kept here the moment it is taken, and handed over as soon as the server can be
/// reached: at once as a rule, later if the phone is offline (when the network comes back, when
/// Redde comes forward, and on a schedule while it runs). On a Hermes connection the notes go
/// as one message into a chat of their own, "Notes", in a turn nobody watches
/// (`ShortcutRunner`), so the agent files them with whatever it has: its memory, a list, a
/// calendar. What it answers is in that chat and is never read out. On the OpenAI-compatible
/// connection there is no agent to file anything, and the notes are kept in a conversation
/// called "Notes" on the phone.
///
/// A note belongs to the server and profile that were in use when it was taken, and waits for
/// them: one taken for Work is not handed to Home because Home is what is open an hour later.
@Observable
final class CaptureInbox {
    static let shared = CaptureInbox()

    nonisolated struct Note: Codable, Identifiable, Equatable, Sendable {
        var id = UUID()
        var text: String
        var at: Date
        /// The server and profile it was taken for.
        var server: UUID
        var profile: String?
    }

    /// Notes not yet handed over, oldest first.
    private(set) var waiting: [Note] {
        didSet { if waiting != oldValue { defaults.set(try? JSONEncoder().encode(waiting), forKey: Self.key) } }
    }
    private(set) var isFiling = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let settings: Settings
    /// Hands notes over; throws when they didn't get there. Tests put their own here.
    @ObservationIgnored private let deliver: ([Note]) async throws -> Void
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var attempts = 0
    @ObservationIgnored private var watchingNetwork = false
    @ObservationIgnored private let log = Logger(subsystem: "com.goosehouse.echo", category: "capture")
    /// How long to wait before trying again, in seconds; the last one repeats.
    @ObservationIgnored var retryDelays: [Double] = [15, 60, 180, 600]

    private static let key = "capture.waiting"

    init(defaults: UserDefaults = .standard, settings: Settings = .shared, deliver: (([Note]) async throws -> Void)? = nil) {
        self.defaults = defaults
        self.settings = settings
        self.deliver = deliver ?? { try await CaptureFiler.deliver($0, settings: settings) }
        waiting = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([Note].self, from: $0) } ?? []
    }

    /// The notes that can go now: the ones taken for the server and profile in use.
    var ready: [Note] { waiting.filter { $0.server == settings.activeServerID && $0.profile == settings.profileName } }

    /// Takes a note and starts handing it over. False for one with nothing in it.
    @discardableResult
    func add(_ text: String, at date: Date = .now) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        waiting.append(Note(text: trimmed, at: date, server: settings.activeServerID, profile: settings.profileName))
        attempts = 0
        Task { await file() }
        return true
    }

    func remove(_ id: UUID) {
        waiting.removeAll { $0.id == id }
    }

    /// Hands over what can go now, all of it in one go. What doesn't get there stays, and is
    /// tried again. Called when a note is taken, when Redde comes forward, when the network
    /// comes back and on the schedule.
    func file() async {
        let batch = ready
        guard !isFiling, !batch.isEmpty else { return }
        isFiling = true
        retry?.cancel()
        retry = nil
        do {
            try await deliver(batch)
            let sent = Set(batch.map(\.id))
            waiting.removeAll { sent.contains($0.id) }
            attempts = 0
            log.info("filed \(batch.count) note(s)")
        } catch {
            log.info("notes not filed yet: \(error.localizedDescription)")
            scheduleRetry()
        }
        isFiling = false
        // One taken while that was under way.
        if !ready.isEmpty, retry == nil { await file() }
    }

    /// Waits until what can go has gone or has failed to, or until `limit` is up: for a run
    /// outside the app, which is over when its caller returns.
    func settle(within limit: Duration) async {
        let deadline = ContinuousClock.now + limit
        while !ready.isEmpty, retry == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func scheduleRetry() {
        if !watchingNetwork {
            watchingNetwork = true
            ConnectivityMonitor.shared.onRestored { [weak self] in Task { await self?.file() } }
        }
        let delay = retryDelays[min(attempts, retryDelays.count - 1)]
        attempts += 1
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            retry = nil
            await file()
        }
    }
}

/// How notes reach where they are kept.
@MainActor
enum CaptureFiler {
    /// The chat the notes go into, on the server and on the phone.
    static let title = "Notes"

    /// What the agent is sent: the notes, when each was taken, and that nobody is waiting.
    nonisolated static func message(for notes: [CaptureInbox.Note]) -> String {
        let style = Date.FormatStyle(locale: Locale(identifier: "en_US")).weekday(.wide).month(.wide).day().hour().minute()
        func when(_ note: CaptureInbox.Note) -> String {
            note.at.formatted(style).replacingOccurrences(of: "\u{202F}", with: " ")
        }
        let several = notes.count > 1
        let lead = "\(several ? "Notes" : "A note") I took in passing, with Redde's quick capture. File \(several ? "each" : "it") where it "
            + "belongs: your memory, a list, a reminder, the calendar, whatever fits. I'm not waiting for an answer, so reply in a few "
            + "words with what you did, and don't ask me anything back."
        let body = several ? notes.map { "- \(when($0)): \($0.text)" }.joined(separator: "\n") : notes.first.map { "\(when($0)): \($0.text)" } ?? ""
        return lead + "\n\n" + body
    }

    static func deliver(_ notes: [CaptureInbox.Note], settings: Settings = .shared, store: ConversationStore = .shared,
                        defaults: UserDefaults = .standard) async throws {
        guard !notes.isEmpty else { return }
        guard settings.transport.hasLedger else {
            try keep(notes, store: store, defaults: defaults)
            return
        }
        // Once the server has answered at all it has the message: a turn that then breaks off is
        // not sent again, or the note would be in the chat twice.
        var taken = false
        do {
            _ = try await ShortcutRunner.ask(message(for: notes), in: .notes) { taken = true }
        } catch {
            if !taken { throw error }
        }
    }

    /// The OpenAI-compatible connection: no agent, so the notes are kept, in a conversation of
    /// their own on the phone.
    private static func keep(_ notes: [CaptureInbox.Note], store: ConversationStore, defaults: UserDefaults) throws {
        let key = "capture.localNotes"
        let known = defaults.string(forKey: key).flatMap(UUID.init(uuidString:)).flatMap { store.record(id: $0) }
        var record = known ?? ConversationRecord(id: UUID(), title: title, createdAt: .now, updatedAt: .now, transport: .chatCompletions,
                                                 serverSessionID: nil, messages: [], name: title)
        // The open conversation writes itself out as it stands: while it is that one, and busy,
        // a note put under it would be written over. It waits a moment.
        let open = Conversation.current.flatMap { $0.id == record.id ? $0 : nil }
        if let open, open.isStreaming { throw TransportError.malformed(String(localized: "The Notes conversation is busy.")) }
        record.messages += notes.map { Message(role: .user, text: $0.text, createdAt: $0.at) }
        record.updatedAt = .now
        store.upsert(record)
        defaults.set(record.id.uuidString, forKey: key)
        open?.load(record)
    }
}
