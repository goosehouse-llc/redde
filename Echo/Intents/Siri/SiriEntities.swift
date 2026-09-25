import AppIntents
import Foundation
import GeoToolbox
import LinkPresentation
import UniformTypeIdentifiers

// Redde as a Messages-domain app for Siri AI (iOS 27 App Schemas). Your agent is the contact,
// each saved conversation is a conversation, each turn is a message. Everything in this file
// reads the phone's own ConversationStore; nothing here touches the network. All of it is
// dark unless Settings → Siri → "Let Siri use Redde" is on: queries return nothing and the
// intents refuse (SiriAccess), and nothing is indexed in Spotlight (SiriIndex).

// MARK: - Identifiers

/// Message entity ids carry their conversation, so a lookup never has to scan every record.
nonisolated enum SiriID {
    static func message(_ conversation: UUID, _ message: UUID) -> String {
        "\(conversation.uuidString):\(message.uuidString)"
    }

    static func parseMessage(_ id: String) -> (conversation: UUID, message: UUID)? {
        let parts = id.split(separator: ":")
        guard parts.count == 2, let c = UUID(uuidString: String(parts[0])), let m = UUID(uuidString: String(parts[1])) else { return nil }
        return (c, m)
    }
}

// MARK: - Enum schemas

@available(iOS 27.0, *)
@AppEnum(schema: .messages.messageType)
nonisolated enum ReddeMessageType: String {
    case unspecified

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .unspecified: "Message",
    ]
}

@available(iOS 27.0, *)
@AppEnum(schema: .messages.messageAttribute)
nonisolated enum ReddeMessageAttribute: String {
    /// A note injected into a running reply rather than a new question.
    case steer

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .steer: "Steering note",
    ]
}

@available(iOS 27.0, *)
@AppEnum(schema: .messages.conversationAttribute)
nonisolated enum ReddeConversationAttribute: String {
    /// Lives in the Hermes session ledger as well as on the phone.
    case onGateway

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .onGateway: "Saved on the Hermes gateway",
    ]
}

@available(iOS 27.0, *)
@AppEnum(schema: .messages.messageEffect)
nonisolated enum ReddeMessageEffect: String {
    case plain

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .plain: "No effect",
    ]
}

@available(iOS 27.0, *)
@AppEnum(schema: .messages.customReaction)
nonisolated enum ReddeReaction: String {
    case acknowledged

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .acknowledged: "Acknowledged",
    ]
}

/// A reaction is a tapback or free text. Redde's messages never carry one.
@available(iOS 27.0, *)
@UnionValue
enum ReddeMessageReaction {
    case tapback(ReddeReaction)
    case text(AttributedString)
}

// MARK: - People

/// The two people in every Redde conversation: your agent (named in Settings → Name, "Redde"
/// by default) and you. "Tell Sol…" resolves to the agent through `ReddePersonQuery`.
@available(iOS 27.0, *)
@AppEntity(schema: .messages.messagePerson)
struct ReddePersonEntity: IndexedEntity {
    static let defaultQuery = ReddePersonQuery()

    static let agentID = "agent"
    static let meID = "me"

    let id: String
    var person: IntentPerson

    init(id: String, person: IntentPerson) {
        self.id = id
        self.person = person
    }

    static func agent(named name: String) -> ReddePersonEntity {
        ReddePersonEntity(id: agentID, person: IntentPerson(identifier: .applicationDefined(agentID),
                                                            name: .displayName(name), handle: nil))
    }

    static var me: ReddePersonEntity {
        ReddePersonEntity(id: meID, person: IntentPerson(identifier: .applicationDefined(meID),
                                                         name: .displayName("Me"), handle: nil, isMe: true))
    }

    var name: String {
        if case let .displayName(text) = person.name { return text }
        return id == Self.agentID ? "Redde" : "Me"
    }

    var displayRepresentation: DisplayRepresentation {
        let isAgent = id == Self.agentID
        let subtitle: LocalizedStringResource? = isAgent ? "Your agent on Hermes" : nil
        return DisplayRepresentation(title: "\(name)", subtitle: subtitle,
                                     image: .init(systemName: isAgent ? "waveform.circle.fill" : "person.crop.circle"))
    }
}

@available(iOS 27.0, *)
nonisolated struct ReddePersonQuery: EntityStringQuery {
    func entities(for identifiers: [ReddePersonEntity.ID]) async throws -> [ReddePersonEntity] {
        await SiriCatalog.people().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [ReddePersonEntity] {
        await SiriCatalog.agent(matching: string).map { [$0] } ?? []
    }

    func suggestedEntities() async throws -> [ReddePersonEntity] {
        await SiriCatalog.agent().map { [$0] } ?? []
    }
}

// MARK: - Conversations

@available(iOS 27.0, *)
@AppEntity(schema: .messages.conversation)
struct ReddeConversationEntity: IndexedEntity {
    static let defaultQuery = ReddeConversationQuery()

    let id: UUID
    var recipients: [ReddePersonEntity]
    var displayName: String
    var previewText: AttributedString
    var conversationName: String?
    var isRead: Bool
    var attributes: Set<ReddeConversationAttribute>
    var dateLastActive: Date?

    init(id: UUID, recipients: [ReddePersonEntity], displayName: String, previewText: AttributedString,
         conversationName: String?, isRead: Bool, attributes: Set<ReddeConversationAttribute>, dateLastActive: Date?) {
        self.id = id
        self.recipients = recipients
        self.displayName = displayName
        self.previewText = previewText
        self.conversationName = conversationName
        self.isRead = isRead
        self.attributes = attributes
        self.dateLastActive = dateLastActive
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)",
                              subtitle: "\(String(previewText.characters))",
                              image: .init(systemName: "bubble.left.and.text.bubble.right"))
    }
}

@available(iOS 27.0, *)
nonisolated struct ReddeConversationQuery: EntityStringQuery {
    func entities(for identifiers: [ReddeConversationEntity.ID]) async throws -> [ReddeConversationEntity] {
        await SiriCatalog.conversations(ids: identifiers)
    }

    func entities(matching string: String) async throws -> [ReddeConversationEntity] {
        await SiriCatalog.conversations(matching: string)
    }

    func suggestedEntities() async throws -> [ReddeConversationEntity] {
        await SiriCatalog.recentConversations(limit: 5)
    }
}

// MARK: - Messages

@available(iOS 27.0, *)
@AppEntity(schema: .messages.message)
struct ReddeMessageEntity: IndexedEntity {
    static let defaultQuery = ReddeMessageQuery()

    /// `SiriID.message(conversation, message)`.
    let id: String
    var messageType: ReddeMessageType
    var author: ReddePersonEntity
    var isRead: Bool
    var attributes: Set<ReddeMessageAttribute>
    var conversation: ReddeConversationEntity
    var date: Date
    var subject: AttributedString?
    var body: AttributedString?
    var attachments: [IntentFile]
    var audioMessage: IntentFile?
    var customAttachments: [ReddeCustomAttachment]
    var locations: [GeoToolbox.PlaceDescriptor]
    var links: [LinkPresentation.LinkMetadata]
    var messageEffect: ReddeMessageEffect?
    var reaction: ReddeMessageReaction?
    var referencedMessage: ReddeMessageEntity?
    var notificationIdentifier: String?

    init(id: String, author: ReddePersonEntity, isRead: Bool, attributes: Set<ReddeMessageAttribute>,
         conversation: ReddeConversationEntity, date: Date, body: AttributedString?,
         attachments: [IntentFile], notificationIdentifier: String?) {
        self.id = id
        self.messageType = .unspecified
        self.author = author
        self.isRead = isRead
        self.attributes = attributes
        self.conversation = conversation
        self.date = date
        self.subject = nil
        self.body = body
        self.attachments = attachments
        self.audioMessage = nil
        self.customAttachments = []
        self.locations = []
        self.links = []
        self.messageEffect = nil
        self.reaction = nil
        self.referencedMessage = nil
        self.notificationIdentifier = notificationIdentifier
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(String((body ?? "").characters.prefix(120)))",
                              subtitle: "\(author.name) · \(conversation.displayName)")
    }
}

@available(iOS 27.0, *)
nonisolated struct ReddeMessageQuery: EntityQuery {
    func entities(for identifiers: [ReddeMessageEntity.ID]) async throws -> [ReddeMessageEntity] {
        await SiriCatalog.messages(ids: identifiers)
    }

    func suggestedEntities() async throws -> [ReddeMessageEntity] {
        await SiriCatalog.recentMessages(limit: 5)
    }
}

/// Required by the message schema. Redde has no plugin-style attachments, so there are none.
@available(iOS 27.0, *)
@AppEntity(schema: .messages.customAttachment)
struct ReddeCustomAttachment: AppEntity {
    static let defaultQuery = ReddeCustomAttachmentQuery()

    var id: UUID
    var sourceName: AttributedString?
    var description: AttributedString?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(String((description ?? "").characters))")
    }
}

@available(iOS 27.0, *)
nonisolated struct ReddeCustomAttachmentQuery: EntityQuery {
    func entities(for identifiers: [ReddeCustomAttachment.ID]) async throws -> [ReddeCustomAttachment] { [] }
}

// MARK: - Catalog

/// Builds entities from the conversation store (and the live conversation, whose newest turn
/// may not be persisted yet). Main actor, like the store. Returns nothing while Siri access is off.
@available(iOS 27.0, *)
@MainActor
enum SiriCatalog {
    /// How many turns of one conversation Siri can see by id or in suggestions.
    static let messageWindow = 60

    private static var store: ConversationStore { .shared }

    static func agent() -> ReddePersonEntity? {
        guard SiriAccess.isEnabled else { return nil }
        return .agent(named: Settings.shared.headerTitle)
    }

    /// The agent answers to its display name, "Redde", and the Siri alternate names.
    static func agent(matching string: String) -> ReddePersonEntity? {
        guard let agent = agent() else { return nil }
        let wanted = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let names = [Settings.shared.headerTitle, "Redde", "Hermes", "Sol"]
        return names.contains { $0.localizedCaseInsensitiveContains(wanted) || wanted.localizedCaseInsensitiveContains($0) } ? agent : nil
    }

    static func people() -> [ReddePersonEntity] {
        agent().map { [$0, .me] } ?? []
    }

    static func conversations(ids: [UUID]) -> [ReddeConversationEntity] {
        guard SiriAccess.isEnabled else { return [] }
        return ids.compactMap(conversation(id:))
    }

    static func conversations(matching string: String) -> [ReddeConversationEntity] {
        guard SiriAccess.isEnabled else { return [] }
        return store.sorted.filter { $0.title.localizedCaseInsensitiveContains(string) }
            .prefix(10).compactMap { conversation(id: $0.id) }
    }

    static func recentConversations(limit: Int) -> [ReddeConversationEntity] {
        guard SiriAccess.isEnabled else { return [] }
        return store.sorted.prefix(limit).compactMap { conversation(id: $0.id) }
    }

    static func messages(ids: [String]) -> [ReddeMessageEntity] {
        guard SiriAccess.isEnabled else { return [] }
        // Ids usually share a conversation: snapshot it and build its entity once, not per id.
        let unread = ReadState.unreadIDs
        var built: [UUID: (snapshot: Snapshot, entity: ReddeConversationEntity)] = [:]
        return ids.compactMap { id in
            guard let parsed = SiriID.parseMessage(id) else { return nil }
            if built[parsed.conversation] == nil, let s = snapshot(parsed.conversation) {
                built[parsed.conversation] = (s, conversationEntity(s, unread: unread))
            }
            guard let c = built[parsed.conversation],
                  let message = c.snapshot.messages.first(where: { $0.id == parsed.message }) else { return nil }
            return entity(for: message, conversation: c.entity, unread: unread)
        }
    }

    static func recentMessages(limit: Int) -> [ReddeMessageEntity] {
        guard SiriAccess.isEnabled, let latest = store.sorted.first, let snapshot = snapshot(latest.id) else { return [] }
        let unread = ReadState.unreadIDs
        let conversation = conversationEntity(snapshot, unread: unread)
        return snapshot.messages.suffix(limit).reversed().map { entity(for: $0, conversation: conversation, unread: unread) }
    }

    static func conversation(id: UUID) -> ReddeConversationEntity? {
        snapshot(id).map { conversationEntity($0, unread: ReadState.unreadIDs) }
    }

    // MARK: Building

    /// The fields entities need from a conversation, from whichever copy is newest.
    struct Snapshot {
        var id: UUID
        var title: String
        var updatedAt: Date
        var onGateway: Bool
        var messages: [Message]
    }

    /// The live conversation wins over its stored record: its latest turn persists only when
    /// the reply finishes, and Siri may ask about it before that.
    static func snapshot(_ id: UUID) -> Snapshot? {
        if let live = Conversation.current, live.id == id { return snapshot(of: live) }
        guard let record = store.record(id: id) else { return nil }
        return Snapshot(id: record.id, title: record.title, updatedAt: record.updatedAt,
                        onGateway: record.serverSessionID != nil, messages: Array(record.messages.suffix(messageWindow)))
    }

    static func snapshot(of live: Conversation) -> Snapshot {
        Snapshot(id: live.id, title: live.title, updatedAt: live.messages.last?.createdAt ?? live.createdAt,
                 onGateway: live.serverSessionID != nil,
                 messages: Array(live.messages.filter { $0.error == nil }.suffix(messageWindow)))
    }

    /// `unread` is `ReadState.unreadIDs`, read once by the caller for the whole batch.
    static func conversationEntity(_ s: Snapshot, unread: Set<String>) -> ReddeConversationEntity {
        let preview = s.messages.last.map { PlainText.display($0.text) } ?? ""
        let hasUnread = s.messages.contains { unread.contains(SiriID.message(s.id, $0.id)) }
        return ReddeConversationEntity(
            id: s.id,
            recipients: [.agent(named: Settings.shared.headerTitle)],
            displayName: s.title,
            previewText: AttributedString(String(preview.prefix(200))),
            conversationName: s.title,
            isRead: !hasUnread,
            attributes: s.onGateway ? [.onGateway] : [],
            dateLastActive: s.updatedAt)
    }

    /// `withAttachments: false` for Spotlight, which only needs the text; reading the image
    /// bytes back from disk for every indexed message would be wasted work.
    static func entity(for message: Message, conversation: ReddeConversationEntity, unread: Set<String>,
                       withAttachments: Bool = true) -> ReddeMessageEntity {
        let id = SiriID.message(conversation.id, message.id)
        let images = (withAttachments ? message.attachments : []).filter { $0.kind == .image }.prefix(4).map {
            IntentFile(data: $0.data, filename: $0.filename, type: .jpeg)
        }
        return ReddeMessageEntity(
            id: id,
            author: message.role == .user ? .me : .agent(named: Settings.shared.headerTitle),
            isRead: !unread.contains(id),
            attributes: message.isSteer ? [.steer] : [],
            conversation: conversation,
            date: message.createdAt,
            body: AttributedString(PlainText.display(message.text)),
            attachments: Array(images),
            notificationIdentifier: message.role == .assistant ? Notifier.replyNotificationID : nil)
    }
}
