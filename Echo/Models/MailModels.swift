import Foundation
import Synchronization

/// The parts of email (2.4, `Mail.swift`) a reply's cards need: the piles an inbox card shows, and
/// the draft a review card sends. Here, apart, because the Watch reads the same cards.

/// The inbox's piles, as the plugin sorts them: seven every inbox has (plugin 1.31.0, asked
/// 2026-11-14: "more categories as the 4 we have do not catch everything") and the person's own
/// (`p-…`, named in Email settings). A plugin from before 1.31.0 has the first three and
/// newsletters only.
nonisolated struct MailBucket: RawRepresentable, Hashable, Identifiable, Codable, Sendable {
    let rawValue: String

    /// One the plugin names: the seven, `unsorted`, or one of the person's own (`p-…`).
    init?(rawValue: String) {
        guard Self.names.contains(rawValue) || rawValue.hasPrefix("p-") && rawValue.count > 2 else { return nil }
        self.rawValue = rawValue
    }

    private static let names: Set<String> = ["important", "needs_reply", "fyi", "receipts", "notifications", "promotions", "newsletters", "unsorted"]

    private init(_ raw: String) { rawValue = raw }

    static let important = MailBucket("important")
    static let needsReply = MailBucket("needs_reply")
    static let fyi = MailBucket("fyi")
    static let receipts = MailBucket("receipts")
    static let notifications = MailBucket("notifications")
    static let promotions = MailBucket("promotions")
    static let newsletters = MailBucket("newsletters")
    static let unsorted = MailBucket("unsorted")

    var id: String { rawValue }

    /// One the person made (Email settings › Piles).
    var isOwn: Bool { rawValue.hasPrefix("p-") }

    /// Every inbox's, in the Inbox's order.
    static let fixed: [MailBucket] = [.important, .needsReply, .fyi, .receipts, .notifications, .promotions, .newsletters]
    /// What a plugin from before 1.31.0 sorts into.
    static let older: [MailBucket] = [.important, .needsReply, .fyi, .newsletters]

    /// The piles the Inbox shows as tabs, as the plugin last said (`unsorted` only while it hasn't
    /// got to them).
    static var shown: [MailBucket] { MailPiles.shared.shown }

    var label: String {
        switch self {
        case .important: String(localized: "Important", comment: "Email inbox pile: what matters")
        case .needsReply: String(localized: "Needs Reply", comment: "Email inbox pile: emails waiting on an answer")
        case .fyi: String(localized: "FYI", comment: "Email inbox pile: worth knowing, nothing to do")
        case .receipts: String(localized: "Receipts", comment: "The ready-made receipts rule's Gmail label")
        case .notifications: String(localized: "Notifications", comment: "A briefing's menu: how this job's runs reach the person (Notify Me, Drawer Only, Don't Show)")
        case .promotions: String(localized: "Promotions", comment: "Email inbox pile: sales, offers and marketing")
        case .newsletters: String(localized: "Newsletters", comment: "Email inbox pile: newsletters, promotions and receipts")
        case .unsorted: String(localized: "Not Sorted Yet", comment: "Email inbox pile: emails the agent hasn't sorted")
        default: MailPiles.shared.name(of: self) ?? String(localized: "Your Pile", comment: "Email inbox pile: one the person made, its name not known yet")
        }
    }

    /// The Inbox's tab, kept short ("Reply 3").
    var tab: String {
        switch self {
        case .important: String(localized: "Important", comment: "Inbox tab: the important pile")
        case .needsReply: String(localized: "Reply", comment: "Inbox tab: the pile of emails needing a reply (short)")
        case .fyi: String(localized: "FYI", comment: "Inbox tab: the FYI pile")
        case .newsletters: String(localized: "News", comment: "Inbox tab: newsletters and receipts (short)")
        case .unsorted: String(localized: "Unsorted", comment: "Inbox tab: not sorted yet")
        default: label
        }
    }

    var symbol: String {
        switch self {
        case .important: "exclamationmark.circle"
        case .needsReply: "arrowshape.turn.up.left"
        case .fyi: "info.circle"
        case .receipts: "doc.text"
        case .notifications: "bell"
        case .promotions: "tag"
        case .newsletters: "newspaper"
        case .unsorted: "tray"
        default: "folder"
        }
    }
}

/// One of the person's own piles: its id (`p-school`), name and what goes in it, in words the
/// agent sorts by.
nonisolated struct MailPile: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var about: String

    init(id: String = "", name: String, about: String) { self.id = id; self.name = name; self.about = about }

    var bucket: MailBucket { MailBucket(rawValue: id) ?? .unsorted }
}

/// The piles the plugin last said it has (`mail status`'s `piles`), kept for the next launch, so a
/// pile's name is known before the Inbox has asked.
nonisolated final class MailPiles: Sendable {
    static let shared = MailPiles()
    private static let key = "mail.piles"

    private struct Known: Codable { var newer: Bool; var own: [MailPile] }
    private let known: Mutex<Known>

    private init() {
        let saved = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Known.self, from: $0) }
        known = Mutex(saved ?? Known(newer: false, own: []))
    }

    /// The plugin has the piles of 1.31.0.
    var newer: Bool { known.withLock { $0.newer } }
    var own: [MailPile] { known.withLock { $0.own } }

    var shown: [MailBucket] {
        known.withLock { k in k.newer ? MailBucket.fixed + k.own.map(\.bucket) : MailBucket.older }
    }

    func name(of bucket: MailBucket) -> String? { own.first { $0.id == bucket.rawValue }?.name }

    /// What `mail status` said: nil `piles` is a plugin from before 1.31.0.
    func update(newer: Bool, own: [MailPile]) {
        let fresh = Known(newer: newer, own: own)
        known.withLock { $0 = fresh }
        if let data = try? JSONEncoder().encode(fresh) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

/// A reply the agent wrote (`review` card, kind email, with `draft`): sent only as approved, by its
/// hash (`mail draft-send`).
nonisolated struct MailDraft: Codable, Equatable, Hashable, Sendable {
    var id: String
    var to: [String]
    var cc: [String]
    var subject: String
    var body: String
    var replyTo: String?
    var account: String?
    var hash: String

    init?(json v: JSONValue?) {
        guard let v, let id = v["id"]?.string, !id.isEmpty, let hash = v["hash"]?.string, !hash.isEmpty else { return nil }
        self.id = id
        to = Self.addresses(v["to"])
        cc = Self.addresses(v["cc"])
        subject = v["subject"]?.string ?? ""
        body = v["body"]?.string ?? ""
        replyTo = v["reply_to"]?.string?.nilIfEmpty
        account = v["account"]?.string?.nilIfEmpty
        self.hash = hash
    }

    init(id: String, to: [String], cc: [String] = [], subject: String, body: String, replyTo: String? = nil, account: String? = nil, hash: String) {
        self.id = id; self.to = to; self.cc = cc; self.subject = subject; self.body = body
        self.replyTo = replyTo; self.account = account; self.hash = hash
    }

    /// A list, or one address, or several in a line ("a@x.com, b@y.com").
    static func addresses(_ v: JSONValue?) -> [String] {
        if let list = v?.array { return list.compactMap { $0.string?.trimmingCharacters(in: .whitespaces).nilIfEmpty } }
        return (v?.string ?? "").split(separator: ",").compactMap { String($0).trimmingCharacters(in: .whitespaces).nilIfEmpty }
    }

    /// `mail draft-edit`'s JSON.
    var edits: [String: Any] { ["to": to, "cc": cc, "subject": subject, "body": body] }
}
