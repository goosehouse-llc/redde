import AppIntents
import CoreSpotlight
import Foundation
import SwiftUI
import UserNotifications
import os

// Everything Siri AI needs outside the intents themselves: the opt-in switch, Redde's own
// read marks, the Spotlight index, intent donations and the on-screen / notification entity
// tags. The rest of the app calls `SiriHooks`, which is safe on iOS 26 and does nothing there.

/// The opt-in. Off by default: with it on, Apple Intelligence reads what you say to Siri and
/// can see Redde's conversations, which is the one path around the tailnet-only invariant.
@MainActor
enum SiriAccess {
    static var isEnabled: Bool { Settings.shared.siriAIEnabled }

    static func require() throws {
        guard isEnabled else { throw SiriError.disabled }
    }
}

/// Unread marks for Siri ("read my messages from Sol", "mark that as unread"). A reply is
/// unread when it arrived as a notification while you were away; opening its conversation
/// reads it. Kept small in UserDefaults, newest last.
nonisolated enum ReadState {
    private static let key = "siri.unreadMessages"
    private static let cap = 200

    private static var unread: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }

    static func isRead(_ messageEntityID: String) -> Bool { !unread.contains(messageEntityID) }

    /// One read for a whole batch of entities, instead of a UserDefaults lookup per message.
    static var unreadIDs: Set<String> { Set(unread) }

    static func set(_ messageEntityID: String, read: Bool) {
        var list = unread.filter { $0 != messageEntityID }
        if !read { list.append(messageEntityID) }
        UserDefaults.standard.set(Array(list.suffix(cap)), forKey: key)
    }

    static func markConversationRead(_ conversationID: UUID) {
        let prefix = conversationID.uuidString + ":"
        let list = unread
        let kept = list.filter { !$0.hasPrefix(prefix) }
        if kept.count != list.count { UserDefaults.standard.set(kept, forKey: key) }
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

/// Call sites in the rest of the app. Each is a no-op before iOS 27.
@MainActor
enum SiriHooks {
    static func appLaunched() {
        if #available(iOS 27.0, *) { Task { await SiriIndex.shared.reindexIfNeeded() } }
    }

    static func accessChanged(_ enabled: Bool) {
        guard #available(iOS 27.0, *) else { return }
        Task {
            if enabled { await SiriIndex.shared.reindexAll() } else { await SiriIndex.shared.removeAll() }
        }
    }

    /// App Lock or the agent's name changed: what the index holds is out of date.
    static func indexInputsChanged() {
        if #available(iOS 27.0, *) { Task { await SiriIndex.shared.reindexIfNeeded() } }
    }

    static func conversationChanged(_ id: UUID) {
        if #available(iOS 27.0, *) { SiriIndex.shared.changed(id) }
    }

    static func conversationDeleted(_ id: UUID, messageIDs: [UUID]) {
        ReadState.markConversationRead(id)
        if #available(iOS 27.0, *) { SiriIndex.shared.deleted(id, messageIDs: messageIDs) }
    }

    static func allConversationsDeleted() {
        ReadState.clear()
        if #available(iOS 27.0, *) { Task { await SiriIndex.shared.removeAll() } }
    }

    /// Something you sent from the composer or the voice screen. Teaches Siri the habit, so
    /// it can suggest "Message Sol" at the times you usually do.
    static func donateSend(_ text: String) {
        guard #available(iOS 27.0, *), SiriAccess.isEnabled, !text.isEmpty else { return }
        let intent = ReddeSendMessageIntent()
        intent.destination = .contact(.agent(named: Settings.shared.headerTitle))
        intent.content = AttributedString(text)
        Task {
            do { _ = try await IntentDonationManager.shared.donate(intent: intent) }
            catch { Logger(subsystem: "com.goosehouse.echo", category: "siri").error("donation failed: \(error.localizedDescription)") }
        }
    }

    /// Tags a reply banner with its message, so Siri can read it out and "Reply…" works on
    /// AirPods. Also marks it unread until you open the conversation.
    static func annotateReply(_ content: UNMutableNotificationContent, messageEntityID: String) {
        ReadState.set(messageEntityID, read: false)
        guard #available(iOS 27.0, *), SiriAccess.isEnabled else { return }
        content.appEntityIdentifiers = [EntityIdentifier(for: ReddeMessageEntity.self, identifier: messageEntityID)]
    }
}

extension View {
    /// On-screen awareness: "Siri, summarize this" / "reply to that" knows which message you mean.
    @ViewBuilder
    func siriMessage(conversationID: UUID, messageID: UUID) -> some View {
        if #available(iOS 27.0, *) {
            if SiriAccess.isEnabled {
                appEntityIdentifier(EntityIdentifier(for: ReddeMessageEntity.self,
                                                     identifier: SiriID.message(conversationID, messageID)))
            } else {
                self
            }
        } else {
            self
        }
    }
}

/// Keeps Spotlight's copy of Redde's people, conversations and recent messages current, which
/// is what lets Siri find "the conversation about the backup" semantically. Only while Siri
/// access is on; turning it off deletes everything Redde indexed. With App Lock on, only
/// conversation titles are indexed, never message text.
@available(iOS 27.0, *)
@MainActor
final class SiriIndex {
    static let shared = SiriIndex()

    /// Bump when the shape of what gets indexed changes, so the next launch rebuilds it once.
    private static let schemaVersion = 1
    private static let stampKey = "siri.indexStamp"
    private static let conversationLimit = 30
    private static let messagesPerConversation = 30

    private let log = Logger(subsystem: "com.goosehouse.echo", category: "siri")
    private var pending: Set<UUID> = []
    private var flushTask: Task<Void, Never>?
    /// Fresh each use: the index isn't Sendable, and its async calls run off the main actor.
    private nonisolated static var index: CSSearchableIndex { .default() }

    /// Everything the index's contents depend on besides the conversations themselves.
    private var stamp: String {
        let settings = Settings.shared
        return "\(Self.schemaVersion)|\(settings.requireBiometrics ? "titles" : "bodies")|\(settings.headerTitle)"
    }

    func reindexIfNeeded() async {
        guard SiriAccess.isEnabled, UserDefaults.standard.string(forKey: Self.stampKey) != stamp else { return }
        await reindexAll()
    }

    func reindexAll() async {
        guard SiriAccess.isEnabled else { return }
        let ids = ConversationStore.shared.sorted.prefix(Self.conversationLimit).map(\.id)
        do {
            try await Self.index.deleteAppEntities(ofType: ReddeMessageEntity.self)
            try await Self.index.indexAppEntities(SiriCatalog.people())
            try await indexConversations(Array(ids))
            UserDefaults.standard.set(stamp, forKey: Self.stampKey)
            log.info("indexed \(ids.count) conversations for Siri")
        } catch {
            log.error("Spotlight reindex failed: \(error.localizedDescription)")
        }
    }

    func removeAll() async {
        flushTask?.cancel()
        pending = []
        UserDefaults.standard.removeObject(forKey: Self.stampKey)
        do {
            try await Self.index.deleteAppEntities(ofType: ReddeMessageEntity.self)
            try await Self.index.deleteAppEntities(ofType: ReddeConversationEntity.self)
            try await Self.index.deleteAppEntities(ofType: ReddePersonEntity.self)
        } catch {
            log.error("Spotlight removal failed: \(error.localizedDescription)")
        }
    }

    /// A conversation was saved. Batched: a turn saves several times in quick succession.
    func changed(_ id: UUID) {
        guard SiriAccess.isEnabled else { return }
        pending.insert(id)
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            let ids = Array(self.pending)
            self.pending = []
            do { try await self.indexConversations(ids) }
            catch { self.log.error("Spotlight update failed: \(error.localizedDescription)") }
        }
    }

    func deleted(_ id: UUID, messageIDs: [UUID]) {
        pending.remove(id)
        Task {
            try? await Self.index.deleteAppEntities(identifiedBy: [id], ofType: ReddeConversationEntity.self)
            let messages = messageIDs.map { SiriID.message(id, $0) }
            if !messages.isEmpty { try? await Self.index.deleteAppEntities(identifiedBy: messages, ofType: ReddeMessageEntity.self) }
        }
    }

    private func indexConversations(_ ids: [UUID]) async throws {
        let snapshots = ids.compactMap { SiriCatalog.snapshot($0) }
        guard !snapshots.isEmpty else { return }
        let unread = ReadState.unreadIDs
        let conversations = snapshots.map { SiriCatalog.conversationEntity($0, unread: unread) }
        try await Self.index.indexAppEntities(conversations)
        guard !Settings.shared.requireBiometrics else { return }   // App Lock: titles only
        let messages = zip(snapshots, conversations).flatMap { snapshot, conversation in
            snapshot.messages.suffix(Self.messagesPerConversation).map {
                SiriCatalog.entity(for: $0, conversation: conversation, unread: unread, withAttachments: false)
            }
        }
        if !messages.isEmpty { try await Self.index.indexAppEntities(messages) }
    }
}
