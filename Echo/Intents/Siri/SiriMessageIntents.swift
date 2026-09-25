import AppIntents
import Foundation
import GeoToolbox
import UIKit
import UniformTypeIdentifiers
import os

// The Messages-domain intents. The schema asks for all five together (draft, send, edit,
// unsend, read status), so Redde implements each in its own terms:
//   send   → a turn in the open conversation, reply spoken if quick
//   draft  → Redde opens with the text in the composer
//   edit   → "Edit & resend": the turn and everything after it are replaced
//   unsend → the turn and everything after it are removed (serve rewinds the gateway too)
//   read   → Redde's own unread marks (replies that landed while you were away)

nonisolated private let siriLog = Logger(subsystem: "com.goosehouse.echo", category: "siri")

/// Who Siri is messaging. The schema allows people only, no conversations, so a Siri message
/// always lands in the open conversation.
@available(iOS 27.0, *)
@UnionValue
enum ReddeMessageDestination {
    case contact(ReddePersonEntity)
    case recipients([ReddePersonEntity])
    /// People Siri resolved outside Redde, e.g. from Contacts; matched by name.
    case people([IntentPerson])
}

// MARK: - Send

@available(iOS 27.0, *)
@AppIntent(schema: .messages.sendMessage)
struct ReddeSendMessageIntent: AppIntent {
    /// The turn uses the gateway credentials, so Siri asks for Face ID on a locked phone.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    var destination: ReddeMessageDestination
    var subject: AttributedString?
    var content: AttributedString?
    @Parameter(supportedContentTypes: [.image]) var attachments: [IntentFile]
    @Parameter(supportedContentTypes: [.audio]) var audioMessage: IntentFile?
    var locations: [GeoToolbox.PlaceDescriptor]
    var links: [URL]
    var scheduledDate: Date?

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<[ReddeMessageEntity]> & ProvidesDialog {
        try SiriAccess.require()
        guard scheduledDate == nil else { throw SiriError.scheduling }
        try SiriTurn.check(destination)
        let text = SiriTurn.compose(content: content, subject: subject, links: links)
        let images = SiriTurn.images(from: attachments)
        guard !text.isEmpty || !images.isEmpty else {
            throw audioMessage != nil ? SiriError.audioOnly : SiriError.emptyMessage
        }
        siriLog.info("send: \(text.count) chars, \(images.count) images")
        let outcome = try await SiriTurn.send(text, attachments: images)
        let name = Settings.shared.headerTitle
        switch outcome.reply {
        case let .replied(reply):
            return .result(value: outcome.sent, dialog: IntentDialog("\(reply)"))
        case .pending:
            return .result(value: outcome.sent, dialog: Settings.shared.notifyInBackground
                ? IntentDialog("Sent to \(name). I'll let you know when \(name) replies.")
                : IntentDialog("Sent to \(name). The reply will be waiting in Redde."))
        case .queued:
            return .result(value: outcome.sent, dialog: IntentDialog("\(name) is still answering something else. I'll send this right after."))
        case let .failed(reason):
            return .result(value: outcome.sent, dialog: IntentDialog("\(name) couldn't answer. \(reason)"))
        }
    }
}

// MARK: - Draft

@available(iOS 27.0, *)
@AppIntent(schema: .messages.draftMessage)
struct ReddeDraftMessageIntent: AppIntent {
    static let supportedModes: IntentModes = .foreground

    var destination: ReddeMessageDestination?
    var subject: AttributedString?
    var content: AttributedString?
    @Parameter(supportedContentTypes: [.image]) var attachments: [IntentFile]
    @Parameter(supportedContentTypes: [.audio]) var audioMessage: IntentFile?
    var locations: [GeoToolbox.PlaceDescriptor]
    var links: [URL]
    var scheduledDate: Date?

    @MainActor func perform() async throws -> some IntentResult {
        try SiriAccess.require()
        if let destination { try SiriTurn.check(destination) }
        let text = SiriTurn.compose(content: content, subject: subject, links: links)
        LaunchRouter.shared.requestDraft(text: text, attachments: SiriTurn.images(from: attachments))
        return .result()
    }
}

// MARK: - Edit, unsend, read status

@available(iOS 27.0, *)
@AppIntent(schema: .messages.editSentMessage)
struct ReddeEditSentMessageIntent: AppIntent {
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    var message: ReddeMessageEntity
    var content: AttributedString

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        try SiriAccess.require()
        let text = String(content.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SiriError.emptyMessage }
        let (live, original) = try SiriTurn.ownMessage(message.id)
        await live.resend(replacing: original.id, text: text, attachments: original.attachments)
        let name = Settings.shared.headerTitle
        return .result(dialog: IntentDialog("Edited. \(name) is answering again."))
    }
}

@available(iOS 27.0, *)
@AppIntent(schema: .messages.unsendMessage)
struct ReddeUnsendMessageIntent: AppIntent {
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    var message: ReddeMessageEntity

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        try SiriAccess.require()
        let (live, original) = try SiriTurn.ownMessage(message.id)
        await live.truncate(from: original.id)
        // The API server's ledger has no undo; hermes serve rewinds the gateway session too.
        return .result(dialog: Settings.shared.transport == .hermesSessions
            ? IntentDialog("Removed from Redde. The Hermes ledger keeps its copy.")
            : IntentDialog("Unsent."))
    }
}

@available(iOS 27.0, *)
@AppIntent(schema: .messages.setMessageReadStatus)
struct ReddeSetMessageReadStatusIntent: AppIntent {
    var message: ReddeMessageEntity
    var isRead: Bool

    @MainActor func perform() async throws -> some IntentResult {
        try SiriAccess.require()
        ReadState.set(message.id, read: isRead)
        return .result()
    }
}

// MARK: - The turn

/// Runs a Siri-sent message through the same `Conversation` the screen uses, so it lands in
/// the transcript, the ledger, the Live Activity and the widget exactly like a typed one.
/// Waits `replyBudget` for the reply so Siri can speak it; after that the turn carries on and
/// the usual "Redde replied" notification (tagged with the reply's entity) brings it back.
@available(iOS 27.0, *)
@MainActor
enum SiriTurn {
    /// How long Siri waits for the agent before saying "Sent". Local models with a tool loop
    /// often take longer; the notification covers those.
    static var replyBudget: Duration = .seconds(20)

    enum Reply: Equatable { case replied(String), pending, queued, failed(String) }

    struct Outcome {
        var sent: [ReddeMessageEntity]
        var reply: Reply
    }

    /// The agent is the only valid recipient.
    static func check(_ destination: ReddeMessageDestination) throws {
        let ok = switch destination {
        case let .contact(person): person.id == ReddePersonEntity.agentID
        case let .recipients(people): !people.isEmpty && people.allSatisfy { $0.id == ReddePersonEntity.agentID }
        case let .people(people): !people.isEmpty && people.allSatisfy(isAgent)
        }
        guard ok else { throw SiriError.unknownRecipient(Settings.shared.headerTitle) }
    }

    private static func isAgent(_ person: IntentPerson) -> Bool {
        if case let .applicationDefined(id) = person.identifier, id == ReddePersonEntity.agentID { return true }
        guard case let .displayName(name) = person.name else { return false }
        return SiriCatalog.agent(matching: name) != nil
    }

    /// Siri's message as Redde sends it: subject as a first line, links appended.
    static func compose(content: AttributedString?, subject: AttributedString?, links: [URL]) -> String {
        var parts: [String] = []
        if let subject { parts.append(String(subject.characters)) }
        if let content { parts.append(String(content.characters)) }
        if !links.isEmpty { parts.append(links.map(\.absoluteString).joined(separator: "\n")) }
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// Photos only, downscaled like the composer's; other files have no Siri phrasing worth it.
    static func images(from files: [IntentFile]) -> [Attachment] {
        files.prefix(4).compactMap { file in
            UIImage(data: file.data).flatMap { Attachment.image($0, filename: file.filename) }
        }
    }

    /// The live conversation, switched to `id` first when Siri named another one. Tests pass
    /// their own conversation (with a scripted transport) as `live`.
    static func conversation(switchingTo id: UUID?, live: Conversation? = nil) throws -> Conversation {
        let live = try live ?? {
            guard let current = Conversation.current else { throw SiriError.notRunning }
            guard Settings.shared.isConfigured else { throw SiriError.notConfigured }
            return current
        }()
        if let id, id != live.id {
            guard !live.isStreaming else { throw SiriError.busy }
            guard let record = ConversationStore.shared.record(id: id) else { throw SiriError.noSuchConversation }
            live.load(record)
        }
        return live
    }

    /// One of your own turns, in the conversation made current for the edit.
    static func ownMessage(_ entityID: String) throws -> (Conversation, Message) {
        guard let parsed = SiriID.parseMessage(entityID) else { throw SiriError.noSuchMessage }
        let live = try conversation(switchingTo: parsed.conversation)
        guard !live.isStreaming else { throw SiriError.busy }
        guard let message = live.messages.first(where: { $0.id == parsed.message }) else { throw SiriError.noSuchMessage }
        guard message.role == .user, !message.isSteer else { throw SiriError.notYourMessage }
        return (live, message)
    }

    static func send(_ text: String, attachments: [Attachment], live: Conversation? = nil) async throws -> Outcome {
        let live = try conversation(switchingTo: nil, live: live)
        await live.initialLoad?.value   // cold launch: continue the latest conversation, not a new one
        let before = live.messages.count
        // While Siri is waiting it will speak the reply itself; a banner as well would be noise.
        Notifier.shared.holdsReplies = true
        defer { Notifier.shared.holdsReplies = false }

        let events = live.send(text, attachments: attachments)
        if live.lastSendWasHeld { return Outcome(sent: [], reply: .queued) }
        guard live.messages.count >= before + 2 else { return Outcome(sent: [], reply: .failed("Nothing was sent.")) }
        let question = live.messages[before]
        let replyID = live.messages[before + 1].id
        let unread = ReadState.unreadIDs
        let sent = [SiriCatalog.entity(for: question, conversation: SiriCatalog.conversationEntity(SiriCatalog.snapshot(of: live), unread: unread), unread: unread)]

        guard await finishes(events, within: replyBudget) else { return Outcome(sent: sent, reply: .pending) }
        guard let reply = live.messages.first(where: { $0.id == replyID }) else { return Outcome(sent: sent, reply: .pending) }
        if let error = reply.error { return Outcome(sent: sent, reply: .failed(error)) }
        guard !reply.text.isEmpty else { return Outcome(sent: sent, reply: .pending) }
        ReadState.set(SiriID.message(live.id, replyID), read: true)
        // Interpolated into the dialog, never a format string: a reply containing %@ stays text.
        return Outcome(sent: sent, reply: .replied(String(PlainText.spoken(reply.text).prefix(600))))
    }

    /// True when the turn's event stream ends inside the budget. Giving up only stops
    /// listening to the mirror stream; the turn itself keeps running.
    private static func finishes(_ events: AsyncStream<TurnEvent>, within budget: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { for await _ in events {}; return true }
            group.addTask { try? await Task.sleep(for: budget); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}

// MARK: - Errors

/// What Siri says when it can't do the thing. Spoken, so short and actionable.
nonisolated enum SiriError: LocalizedError, Equatable {
    case disabled, notRunning, notConfigured, busy, scheduling, audioOnly, emptyMessage
    case unknownRecipient(String)
    case noSuchConversation, noSuchMessage, notYourMessage

    var errorDescription: String? {
        switch self {
        case .disabled: "Siri access is off. Turn on “Let Siri use Redde” in Redde's Settings."
        case .notRunning: "Open Redde once, then try again."
        case .notConfigured: "Redde isn't connected to a server yet. Open Redde to finish setup."
        case .busy: "Redde is in the middle of another reply. Try again when it's done."
        case .scheduling: "Redde can't schedule messages. Ask it to set up a cron job instead."
        case .audioOnly: "Redde needs the message as text."
        case .emptyMessage: "The message was empty."
        case let .unknownRecipient(name): "In Redde you can only message \(name)."
        case .noSuchConversation: "I couldn't find that conversation in Redde."
        case .noSuchMessage: "I couldn't find that message in Redde."
        case .notYourMessage: "You can only change your own messages."
        }
    }
}
