import Foundation

/// The parts of email (2.4, `Mail.swift`) a reply's cards need: the piles an inbox card shows, and
/// the draft a review card sends. Here, apart, because the Watch reads the same cards.

/// The inbox's piles, as the plugin sorts them.
nonisolated enum MailBucket: String, CaseIterable, Identifiable, Codable, Sendable {
    case important
    case needsReply = "needs_reply"
    case fyi
    case newsletters
    case unsorted

    var id: String { rawValue }

    /// The four the Inbox shows as tabs; `unsorted` only while the plugin hasn't got to them.
    static let shown: [MailBucket] = [.important, .needsReply, .fyi, .newsletters]

    var label: String {
        switch self {
        case .important: String(localized: "Important", comment: "Email inbox pile: what matters")
        case .needsReply: String(localized: "Needs Reply", comment: "Email inbox pile: emails waiting on an answer")
        case .fyi: String(localized: "FYI", comment: "Email inbox pile: worth knowing, nothing to do")
        case .newsletters: String(localized: "Newsletters", comment: "Email inbox pile: newsletters, promotions and receipts")
        case .unsorted: String(localized: "Not Sorted Yet", comment: "Email inbox pile: emails the agent hasn't sorted")
        }
    }

    /// The Inbox's tab, short enough for four across an iPhone ("Reply 3").
    var tab: String {
        switch self {
        case .important: String(localized: "Important", comment: "Inbox tab: the important pile")
        case .needsReply: String(localized: "Reply", comment: "Inbox tab: the pile of emails needing a reply (short)")
        case .fyi: String(localized: "FYI", comment: "Inbox tab: the FYI pile")
        case .newsletters: String(localized: "News", comment: "Inbox tab: newsletters and receipts (short)")
        case .unsorted: String(localized: "Unsorted", comment: "Inbox tab: not sorted yet")
        }
    }

    var symbol: String {
        switch self {
        case .important: "exclamationmark.circle"
        case .needsReply: "arrowshape.turn.up.left"
        case .fyi: "info.circle"
        case .newsletters: "newspaper"
        case .unsorted: "tray"
        }
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
