import Foundation
import Observation

/// Email (asked 2026-11-03: "clear and smart email inbox control", for every Redde user, not only
/// Gmail's). iOS lets no app read the Mail app's inbox, so the mail is the Hermes server's: Redde's
/// plugin 1.16 (`mail.py`) logs in with an app password the person pastes through Keys Asked For
/// (or Hermes's own Gmail sign-in), sorts the inbox and keeps rules; this side asks it, over the
/// Dashboard as phone tools do (`/redde-push mail …`, tmp/mail-contract.md), only when the Inbox
/// opens. His picks: unsubscribe on his tap alone; rules he makes run on their own and are logged;
/// the agent sees snippets, and the whole of an email only when he opens or asks about it.

/// One account the plugin can reach (`mail status`).
nonisolated struct MailAccount: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var address: String
    var provider: String
    /// `imap`, `gmail_api` (Hermes's Google sign-in), `nous` (Nous's connector: listed, not usable).
    var via: String
    var usable: Bool
    /// Plain words, never a secret ("The password was refused…").
    var problem: String?
    var lastSync: Date?
    var unread: Int
    var counts: [String: Int]
    /// Gmail only: Redde's sorting can show there as labels, and tagging rules can label (11-03).
    var canLabel = false
    /// "Show Sorting in Gmail": the Redde/… labels.
    var groupLabels = false
    /// The 30-day backfill and the label removal: queued, running, done.
    var backfill: LabelJob?
    var unlabel: LabelJob?
    var labelsProblem: String?
    /// How many emails Redde has labelled (written down, so only those are ever unlabelled).
    var labelled = 0
    /// "Suggest Rules": patterns turned into proposed rules, none run until accepted.
    var suggest = false
    var suggestionCount = 0

    nonisolated struct LabelJob: Codable, Equatable, Sendable {
        var state: String
        var done: Int
        var total: Int
        init?(json v: JSONValue?) {
            guard let v, let state = v["state"]?.string else { return nil }
            self.state = state; done = v["done"]?.int ?? 0; total = v["total"]?.int ?? 0
        }
        var busy: Bool { state == "queued" || state == "running" }
    }

    init?(json v: JSONValue) {
        guard let id = v["id"]?.string, !id.isEmpty else { return nil }
        self.id = id
        address = v["address"]?.string ?? ""
        provider = v["provider"]?.string ?? ""
        name = v["name"]?.string?.nilIfEmpty ?? MailProvider(rawValue: provider)?.label ?? address
        via = v["via"]?.string ?? "imap"
        usable = v["usable"]?.bool ?? false
        problem = v["problem"]?.string?.nilIfEmpty
        lastSync = v["last_sync"]?.number.map { Date(timeIntervalSince1970: $0) }
        unread = v["unread"]?.int ?? 0
        counts = (v["buckets"]?.object ?? [:]).compactMapValues(\.int)
        canLabel = v["can_label"]?.bool ?? false
        groupLabels = v["labels"]?["groups"]?.bool ?? false
        backfill = LabelJob(json: v["backfill"])
        unlabel = LabelJob(json: v["unlabel"])
        labelsProblem = v["labels_problem"]?.string?.nilIfEmpty
        labelled = v["labelled"]?.int ?? 0
        suggest = v["suggest"]?.bool ?? false
        suggestionCount = v["suggestions"]?.array?.count ?? 0
    }

    init(id: String, name: String, address: String, provider: String, via: String = "imap", usable: Bool = true,
         problem: String? = nil, lastSync: Date? = nil, unread: Int = 0, counts: [String: Int] = [:]) {
        self.id = id; self.name = name; self.address = address; self.provider = provider; self.via = via
        self.usable = usable; self.problem = problem; self.lastSync = lastSync; self.unread = unread; self.counts = counts
    }

    func count(_ bucket: MailBucket) -> Int { counts[bucket.rawValue] ?? 0 }
}

/// `mail brief` (also in `mail status`): each account's counts and the few emails waiting most,
/// from what was sorted, for the morning briefing's email page.
nonisolated struct MailBrief: Codable, Equatable, Sendable {
    nonisolated struct Account: Codable, Equatable, Sendable {
        var id: String
        var name: String
        var unread: Int
        var important: Int
        var needsReply: Int
        var newsletters: Int
        var asOf: Date?
        var top: [MailThread]
    }

    var accounts: [Account]

    /// Nil for `null` (no account works, or none has synced) and for a brief with nothing in it.
    init?(json v: JSONValue?) {
        guard let v, let list = v["accounts"]?.array else { return nil }
        accounts = list.compactMap { a in
            guard let id = a["id"]?.string, !id.isEmpty else { return nil }
            return Account(id: id, name: a["name"]?.string?.nilIfEmpty ?? id, unread: a["unread"]?.int ?? 0,
                           important: a["important"]?.int ?? 0, needsReply: a["needs_reply"]?.int ?? 0,
                           newsletters: a["newsletters"]?.int ?? 0, asOf: a["as_of"]?.number.map { Date(timeIntervalSince1970: $0) },
                           top: (a["top"]?.array ?? []).prefix(4).compactMap(MailThread.init(json:)))
        }
        if accounts.isEmpty { return nil }
    }

    init(accounts: [Account]) { self.accounts = accounts }

    var important: Int { accounts.reduce(0) { $0 + $1.important } }
    var needsReply: Int { accounts.reduce(0) { $0 + $1.needsReply } }
    var unread: Int { accounts.reduce(0) { $0 + $1.unread } }
    var top: [MailThread] { Array(accounts.flatMap(\.top).prefix(4)) }
    var asOf: Date? { accounts.compactMap(\.asOf).max() }
    /// Worth a page: something waits on him.
    var worthShowing: Bool { important + needsReply > 0 || !top.isEmpty }

    /// The page's headline: "2 important · 3 to answer".
    var headline: String {
        let parts = [important > 0 ? String(localized: "\(important) important", comment: "Email brief headline") : nil,
                     needsReply > 0 ? String(localized: "\(needsReply) to answer", comment: "Email brief headline") : nil].compactMap { $0 }
        return parts.isEmpty ? String(localized: "Nothing needs you", comment: "Email brief headline: nothing waiting") : parts.joined(separator: " · ")
    }
}

/// `mail status`: the accounts, and the plugin's own settings.
nonisolated struct MailStatus: Codable, Equatable, Sendable {
    var accounts: [MailAccount]
    var triage: String
    var syncMinutes: Int
    /// The plugin takes the settings that aren't secret in one `mail setup`.
    var setupCommand: Bool
    var brief: MailBrief?

    init(json v: JSONValue) {
        accounts = (v["accounts"]?.array ?? []).compactMap(MailAccount.init(json:))
        triage = v["triage"]?.string ?? "auto"
        syncMinutes = v["sync_minutes"]?.int ?? 3
        setupCommand = v["setup"]?["command"]?.bool ?? false
        brief = MailBrief(json: v["brief"])
    }

    init(accounts: [MailAccount], triage: String = "auto", syncMinutes: Int = 3, setupCommand: Bool = false, brief: MailBrief? = nil) {
        self.accounts = accounts; self.triage = triage; self.syncMinutes = syncMinutes; self.setupCommand = setupCommand; self.brief = brief
    }

    var usable: [MailAccount] { accounts.filter(\.usable) }
}

/// An email in a list: what the plugin says of it, never its whole text.
nonisolated struct MailThread: Codable, Identifiable, Equatable, Hashable, Sendable {
    /// Opaque; handed back as it came.
    var id: String
    var from: String
    var address: String
    var subject: String
    var snippet: String
    var date: Date
    var unread: Bool
    var bucket: MailBucket
    /// The agent's line about it; nil until sorted.
    var summary: String?
    var hasAttachments: Bool
    var canUnsubscribe: Bool
    var receipt: Bool
    var flagged: Bool

    init?(json v: JSONValue) {
        guard let id = v["id"]?.string, !id.isEmpty else { return nil }
        self.id = id
        address = v["address"]?.string ?? ""
        from = v["from"]?.string?.nilIfEmpty ?? address
        subject = v["subject"]?.string?.nilIfEmpty ?? String(localized: "(no subject)", comment: "An email with no subject")
        snippet = v["snippet"]?.string ?? ""
        date = Date(timeIntervalSince1970: v["date"]?.number ?? 0)
        unread = v["unread"]?.bool ?? false
        bucket = MailBucket(rawValue: v["bucket"]?.string ?? "") ?? .unsorted
        summary = v["summary"]?.string?.nilIfEmpty
        hasAttachments = v["has_attachments"]?.bool ?? false
        canUnsubscribe = v["can_unsubscribe"]?.bool ?? false
        receipt = v["receipt"]?.bool ?? false
        flagged = v["flagged"]?.bool ?? false
    }

    init(id: String, from: String, address: String, subject: String, snippet: String = "", date: Date, unread: Bool,
         bucket: MailBucket, summary: String?, hasAttachments: Bool = false, canUnsubscribe: Bool = false,
         receipt: Bool = false, flagged: Bool = false) {
        self.id = id; self.from = from; self.address = address; self.subject = subject; self.snippet = snippet
        self.date = date; self.unread = unread; self.bucket = bucket; self.summary = summary
        self.hasAttachments = hasAttachments; self.canUnsubscribe = canUnsubscribe; self.receipt = receipt; self.flagged = flagged
    }

    /// What the row says under the subject: the agent's line, else the email's own start.
    var line: String { summary ?? snippet }
}

/// `mail list`: a page of one pile.
nonisolated struct MailPage: Equatable, Sendable {
    var account: String
    var bucket: String
    var page: Int
    var more: Bool
    var threads: [MailThread]

    init(json v: JSONValue) {
        account = v["account"]?.string ?? ""
        bucket = v["bucket"]?.string ?? "all"
        page = v["page"]?.int ?? 0
        more = v["more"]?.bool ?? false
        threads = (v["threads"]?.array ?? []).compactMap(MailThread.init(json:))
    }
}

/// `mail read`: one email whole, as plain text (the plugin strips its HTML; no pictures load).
nonisolated struct MailMessage: Equatable, Sendable {
    nonisolated enum Unsubscribe: String, Equatable, Sendable {
        /// RFC 8058's one-click: done on his tap.
        case oneClick = "one_click"
        /// Only by sending an email: that's a send, so the app asks first.
        case mailto
        /// Only a web page: opened.
        case link
    }

    var id: String
    var from: String
    var address: String
    var to: [String]
    var cc: [String]
    var subject: String
    var date: Date
    var text: String
    var links: [(text: String, url: URL)]
    var attachments: [(name: String, size: Int)]
    var unsubscribe: Unsubscribe?
    /// The email as its sender laid it out, its own pictures in it (plugin 1.19.2; nil before, or
    /// for a plain-text email): the reader draws it, the agent never gets it.
    var html: String?

    init?(json v: JSONValue) {
        guard let id = v["id"]?.string, !id.isEmpty else { return nil }
        self.id = id
        address = v["address"]?.string ?? ""
        from = v["from"]?.string?.nilIfEmpty ?? address
        to = (v["to"]?.array ?? []).compactMap(\.string)
        cc = (v["cc"]?.array ?? []).compactMap(\.string)
        subject = v["subject"]?.string?.nilIfEmpty ?? String(localized: "(no subject)", comment: "An email with no subject")
        date = Date(timeIntervalSince1970: v["date"]?.number ?? 0)
        text = v["text"]?.string ?? ""
        links = (v["links"]?.array ?? []).compactMap { link in
            // Only the web: no app links, no javascript:, nothing an email could pass off.
            guard let raw = link["url"]?.string, let url = URL(string: raw), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return (link["text"]?.string?.nilIfEmpty ?? url.host() ?? raw, url)
        }
        attachments = (v["attachments"]?.array ?? []).compactMap { a in
            a["name"]?.string.map { ($0, a["size"]?.int ?? 0) }
        }
        unsubscribe = (v["can_unsubscribe"]?.bool ?? false) ? v["unsubscribe"]?.string.flatMap(Unsubscribe.init(rawValue:)) : nil
        html = v["html"]?.string?.nilIfEmpty
    }

    static func == (a: MailMessage, b: MailMessage) -> Bool { a.id == b.id && a.text == b.text && a.subject == b.subject }
}

/// A rule he made (`mail rules`): when an email matches, what's done, on its own and logged.
nonisolated struct MailRule: Codable, Identifiable, Equatable, Hashable, Sendable {
    nonisolated enum Action: String, Codable, CaseIterable, Identifiable, Sendable {
        case archive, read, label, move, notify
        var id: String { rawValue }

        var label: String {
            switch self {
            case .archive: String(localized: "Archive it", comment: "An email rule's action")
            case .read: String(localized: "Mark it read", comment: "An email rule's action")
            case .label: String(localized: "Label it", comment: "An email rule's action")
            case .move: String(localized: "Move it to a folder", comment: "An email rule's action")
            case .notify: String(localized: "Tell me", comment: "An email rule's action: a notification when it arrives")
            }
        }

        var symbol: String {
            switch self {
            case .archive: "archivebox"
            case .read: "envelope.open"
            case .label: "tag"
            case .move: "folder"
            case .notify: "bell"
            }
        }

        /// Needs a name: the label or the folder.
        var takesName: Bool { self == .label || self == .move }
    }

    /// Which attachment a rule asks for (tagging rules, 11-03).
    nonisolated enum Attachment: String, Codable, CaseIterable, Identifiable, Sendable {
        case any, pdf, image
        var id: String { rawValue }
        var label: String {
            switch self {
            case .any: String(localized: "Any attachment", comment: "An email rule: has an attachment")
            case .pdf: String(localized: "A PDF", comment: "An email rule: has a PDF attached")
            case .image: String(localized: "A picture", comment: "An email rule: has a picture attached")
            }
        }
    }

    var id: String
    var from: String?
    var to: String?
    var subject: String?
    var bucket: String?
    var receipt: Bool?
    var action: Action
    var arg: String?
    /// A tagging rule's other labels, after `arg` (several labels, asked 11-06; plugin 1.19.1).
    var also: [String] = []
    var notify: Bool
    var made: Date?
    // Tagging rules (Gmail labels, 11-03); kept for every rule so saving never drops them.
    var domain: String?
    var cc: String?
    var body: String?
    var attachment: Attachment?
    /// Mail older than this is passed over (nil: 30 days, the plugin's default; 0: any age).
    var newerThanDays: Int?
    /// Any one condition, rather than all of them.
    var matchAny = false
    var enabled = true
    /// Only this account's mail (nil: every account).
    var account: String?
    var name: String?
    /// A tagging rule also archives (off unless set).
    var archive = false
    /// The ready-made Paperless rule, offered until saved.
    var builtin = false
    /// Emails it acted on in the last 30 days (from the plugin; not sent back).
    var matches = 0

    init?(json v: JSONValue) {
        guard let id = v["id"]?.string, !id.isEmpty, let action = Action(rawValue: v["do"]?.string ?? "") else { return nil }
        self.id = id
        let when = v["when"]
        from = when?["from"]?.string?.nilIfEmpty
        to = when?["to"]?.string?.nilIfEmpty
        subject = when?["subject"]?.string?.nilIfEmpty
        bucket = when?["bucket"]?.string?.nilIfEmpty
        receipt = when?["receipt"]?.bool
        domain = when?["domain"]?.string?.nilIfEmpty
        cc = when?["cc"]?.string?.nilIfEmpty
        body = when?["body"]?.string?.nilIfEmpty
        attachment = (when?["attachment"]?.string).flatMap(Attachment.init(rawValue:))
        newerThanDays = when?["newer_than_days"]?.int
        self.action = action
        arg = v["arg"]?.string?.nilIfEmpty
        also = v["also"]?.array?.compactMap { $0.string?.nilIfEmpty } ?? []
        notify = v["notify"]?.bool ?? (action == .notify)
        made = v["made"]?.number.map { Date(timeIntervalSince1970: $0) }
        matchAny = v["match"]?.string == "any"
        enabled = v["enabled"]?.bool ?? true
        account = v["account"]?.string?.nilIfEmpty
        name = v["name"]?.string?.nilIfEmpty
        archive = v["archive"]?.bool ?? false
        builtin = v["builtin"]?.bool ?? false
        matches = v["matches"]?.int ?? 0
    }

    /// A tagging rule: Gmail labels what matches, with "also archive" off unless set.
    var isTagging: Bool { action == .label }

    /// Every label a tagging rule adds, the first one first.
    var labels: [String] {
        var names: [String] = []
        for name in [arg].compactMap({ $0 }) + (isTagging ? also : []) where !names.contains(name) { names.append(name) }
        return names
    }

    init(id: String, from: String? = nil, subject: String? = nil, action: Action, arg: String? = nil, made: Date? = .now) {
        self.id = id; self.from = from; self.subject = subject; self.action = action; self.arg = arg
        self.notify = action == .notify; self.made = made
    }

    /// As `mail rules set` takes it.
    var json: [String: Any] {
        var when: [String: Any] = [:]
        if let from { when["from"] = from }
        if let to { when["to"] = to }
        if let subject { when["subject"] = subject }
        if let bucket { when["bucket"] = bucket }
        if let receipt { when["receipt"] = receipt }
        if let domain { when["domain"] = domain }
        if let cc { when["cc"] = cc }
        if let body { when["body"] = body }
        if let attachment { when["attachment"] = attachment.rawValue }
        if let newerThanDays { when["newer_than_days"] = newerThanDays }
        var out: [String: Any] = ["id": id, "when": when, "do": action.rawValue, "notify": notify,
                                  "match": matchAny ? "any" : "all", "enabled": enabled, "archive": isTagging && archive]
        if let arg { out["arg"] = arg }
        if isTagging, !also.isEmpty { out["also"] = also }
        if let made { out["made"] = Int(made.timeIntervalSince1970) }
        if let account { out["account"] = account }
        if let name { out["name"] = name }
        if builtin { out["builtin"] = true }
        return out
    }

    /// Its conditions in words: "From shop.example · A PDF".
    var conditions: String {
        var parts: [String] = []
        if let from { parts.append(String(localized: "From \(from)", comment: "An email rule: mail from a sender")) }
        if let domain { parts.append(String(localized: "From @\(domain)", comment: "An email rule: mail from a domain")) }
        if let to { parts.append(String(localized: "To \(to)", comment: "An email rule: mail to an address")) }
        if let cc { parts.append(String(localized: "Cc \(cc)", comment: "An email rule: copied to an address")) }
        if let subject { parts.append(String(localized: "Subject has “\(subject)”", comment: "An email rule: words in the subject")) }
        if let body { parts.append(String(localized: "Text has “\(body)”", comment: "An email rule: words in the email")) }
        if receipt == true { parts.append(String(localized: "Receipts", comment: "An email rule: receipts and orders")) }
        if let attachment { parts.append(attachment.label) }
        if let bucket, let pile = MailBucket(rawValue: bucket) { parts.append(pile.label) }
        if parts.isEmpty { return String(localized: "Every email", comment: "An email rule with no condition") }
        return parts.joined(separator: matchAny ? String(localized: " or ", comment: "An email rule: any one condition") : " · ")
    }

    /// The rule in a line: "From receipts@shop.example: archive it".
    var described: String {
        var what = action.takesName ? "\(action.label): \(labels.joined(separator: ", "))" : action.label
        if isTagging && archive { what += String(localized: ", and archive", comment: "An email tagging rule that also archives") }
        return "\(name ?? conditions): \(what)"
    }
}

/// A rule the plugin proposes from a pattern ("You archived 6 emails from … this month"). Nothing runs
/// it until it's accepted (as it is, or changed).
nonisolated struct MailSuggestion: Identifiable, Equatable, Sendable {
    var id: String
    var why: String
    var rule: MailRule

    init?(json v: JSONValue) {
        guard let id = v["id"]?.string, let raw = v["rule"], let why = v["why"]?.string else { return nil }
        var object = raw.object ?? [:]
        object["id"] = .string("s" + id)
        guard let rule = MailRule(json: .object(object)) else { return nil }
        self.id = id; self.why = why; self.rule = rule
    }
}

/// What a rule, a tap or the agent did to the mail (`mail log`), for the Rules page and Agent Activity.
nonisolated struct MailLogEntry: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var at: Date
    var rule: String?
    var action: String
    var account: String
    var ids: [String]
    var title: String
    var undone: Bool
    /// `rule`, `you`, `agent`.
    var by: String
    /// Its account was removed: kept in the log, no longer undoable.
    var gone: Bool?

    init?(json v: JSONValue) {
        guard let id = v["id"]?.string, !id.isEmpty else { return nil }
        self.id = id
        gone = v["gone"]?.bool
        at = Date(timeIntervalSince1970: v["at"]?.number ?? 0)
        rule = v["rule"]?.string?.nilIfEmpty
        action = v["action"]?.string ?? ""
        account = v["account"]?.string ?? ""
        ids = (v["ids"]?.array ?? []).compactMap(\.string)
        title = v["title"]?.string?.nilIfEmpty ?? action
        undone = v["undone"]?.bool ?? false
        by = v["by"]?.string ?? "you"
    }

    /// Undo makes sense for these (a notification can't be taken back).
    var undoable: Bool { !undone && gone != true && action != "notify" }
}

/// What a `mail act` did, to undo it.
nonisolated struct MailActResult: Equatable, Sendable {
    var done: [String]
    var failed: [String]
    var log: String?

    init(json v: JSONValue) {
        done = (v["done"]?.array ?? []).compactMap(\.string)
        failed = (v["failed"]?.array ?? []).compactMap(\.string)
        log = v["log"]?.string?.nilIfEmpty
    }
}

/// `mail setup-check`.
nonisolated struct MailCheck: Equatable, Sendable {
    var imap: String
    var smtp: String
    var problem: String?
    var ok: Bool { imap == "ok" && smtp != "failed" }

    init(json v: JSONValue) {
        imap = v["imap"]?.string ?? "failed"
        smtp = v["smtp"]?.string ?? "skipped"
        problem = v["problem"]?.string?.nilIfEmpty
    }
}

/// A tap on an email: what goes to `mail act`.
nonisolated enum MailAction: Equatable, Sendable {
    case archive, unarchive, read, unread, flag, unflag, trash
    case snooze(Date)
    case unsubscribe
    case label(String)
    case move(String)
    /// Into another of Redde's groups (an email's hold menu, 11-05): plugin 1.17.0's `act group`.
    case group(MailBucket)

    var words: String {
        switch self {
        case .archive: "archive"
        case .unarchive: "unarchive"
        case .read: "read"
        case .unread: "unread"
        case .flag: "flag"
        case .unflag: "unflag"
        case .trash: "trash"
        case .snooze: "snooze"
        case .unsubscribe: "unsubscribe"
        case .label: "label"
        case .move: "move"
        case .group: "group"
        }
    }

    var arg: String? {
        switch self {
        case let .snooze(until): String(Int(until.timeIntervalSince1970))
        case let .label(name), let .move(name): name
        case let .group(bucket): bucket.rawValue
        default: nil
        }
    }

    /// Takes it off the inbox's list (so the row goes at once).
    var removes: Bool {
        switch self {
        case .archive, .trash, .snooze, .move, .unsubscribe: true
        default: false
        }
    }

    /// The toast after it: "Archived".
    var done: String {
        switch self {
        case .archive: String(localized: "Archived", comment: "Toast after archiving an email")
        case .unarchive: String(localized: "Back in the inbox", comment: "Toast after un-archiving an email")
        case .read: String(localized: "Marked read", comment: "Toast")
        case .unread: String(localized: "Marked unread", comment: "Toast")
        case .flag: String(localized: "Flagged", comment: "Toast")
        case .unflag: String(localized: "Unflagged", comment: "Toast")
        case .trash: String(localized: "Moved to the trash", comment: "Toast")
        case let .snooze(until): String(localized: "Snoozed until \(until.formatted(.relative(presentation: .named)))", comment: "Toast after snoozing an email, with when it comes back")
        case .unsubscribe: String(localized: "Unsubscribed", comment: "Toast")
        case let .label(name): String(localized: "Labelled \(name)", comment: "Toast after labelling an email")
        case let .move(name): String(localized: "Moved to \(name)", comment: "Toast after moving an email to a folder")
        case let .group(bucket): String(localized: "Moved to \(bucket.label)", comment: "Toast after moving an email to another of Redde's groups (Important, FYI…)")
        }
    }
}

nonisolated enum MailError: LocalizedError, Equatable {
    /// No Dashboard login for this server: the only way the plugin is asked.
    case noDashboard
    /// No Redde plugin, or one older than mail.
    case noPlugin
    case server(code: String, message: String)
    case malformed
    /// The rule was saved with its first label only: the plugin is older than 1.19.1.
    case oneLabel

    var errorDescription: String? {
        switch self {
        case .noDashboard:
            String(localized: "Email goes through your Hermes's Redde plugin, which Redde reaches with the Hermes Dashboard login (Settings › Connection). Over the Hermes API alone it can't be asked.")
        case .noPlugin:
            String(localized: "This Hermes's Redde plugin doesn't do email yet. Update the plugin (Settings › Redde Plugin), restart Hermes, and try again.")
        case let .server(code, message):
            message.isEmpty ? String(localized: "Your Hermes said no (\(code)).") : message
        case .malformed:
            String(localized: "Your Hermes answered in a way Redde can't read. Update the Redde plugin there.")
        case .oneLabel:
            String(localized: "Saved with its first label only: more than one label needs the Redde plugin 1.19.1 or later. Update it in Settings › Redde Plugin, then add the others again.", comment: "Email tagging rule: the plugin is too old for several labels")
        }
    }

}

/// Reading the plugin's answers (`redde-push mail {…}`).
nonisolated enum MailWire {
    static let prefix = "redde-push mail "

    static func parse(_ reply: String) throws -> JSONValue {
        guard reply.contains(prefix) else {
            // "Unknown subcommand" and the like: a plugin from before mail.
            throw reply.isEmpty || reply.contains("usage") || reply.lowercased().contains("unknown") ? MailError.noPlugin : MailError.malformed
        }
        guard let json = PluginReply.json(reply, "mail") else { throw MailError.malformed }
        if let code = json["error"]?.string {
            throw MailError.server(code: code, message: json["message"]?.string ?? "")
        }
        return json
    }

    /// A JSON argument, compact, on one line.
    static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

/// The providers Redde knows how to set up: where their mail servers are, and where to make an app
/// password (Gmail, iCloud, Fastmail and Yahoo all give them; Microsoft has mostly stopped).
nonisolated enum MailProvider: String, CaseIterable, Identifiable, Sendable {
    case gmail, icloud, fastmail, yahoo, outlook, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .gmail: "Gmail"
        case .icloud: "iCloud Mail"
        case .fastmail: "Fastmail"
        case .yahoo: "Yahoo Mail"
        case .outlook: "Outlook.com"
        case .other: String(localized: "Other (IMAP)", comment: "Email provider: any other, by its server's name")
        }
    }

    var symbol: String {
        switch self {
        case .gmail: "envelope.badge"
        case .icloud: "icloud"
        case .fastmail: "bolt.horizontal"
        case .yahoo: "envelope"
        case .outlook: "envelope.open"
        case .other: "server.rack"
        }
    }

    /// IMAP over SSL and SMTP, as the plugin's presets have them (shown, not sent: the plugin fills them).
    var imap: (host: String, port: Int)? {
        switch self {
        case .gmail: ("imap.gmail.com", 993)
        case .icloud: ("imap.mail.me.com", 993)
        case .fastmail: ("imap.fastmail.com", 993)
        case .yahoo: ("imap.mail.yahoo.com", 993)
        case .outlook: ("outlook.office365.com", 993)
        case .other: nil
        }
    }

    var smtp: (host: String, port: Int)? {
        switch self {
        case .gmail: ("smtp.gmail.com", 465)
        case .icloud: ("smtp.mail.me.com", 587)
        case .fastmail: ("smtp.fastmail.com", 465)
        case .yahoo: ("smtp.mail.yahoo.com", 465)
        case .outlook: ("smtp.office365.com", 587)
        case .other: nil
        }
    }

    /// Where the provider makes app passwords.
    var appPasswordPage: URL? {
        switch self {
        case .gmail: URL(string: "https://myaccount.google.com/apppasswords")
        case .icloud: URL(string: "https://support.apple.com/102654")
        case .fastmail: URL(string: "https://www.fastmail.help/hc/en-us/articles/360058752854")
        case .yahoo: URL(string: "https://login.yahoo.com/account/security/app-passwords")
        case .outlook: URL(string: "https://support.microsoft.com/account-billing/5896ed9b-4263-e681-128a-a6f2979a7944")
        case .other: nil
        }
    }

    /// Where an app password made for Redde can be revoked after the account is removed.
    var revokePage: URL? {
        switch self {
        case .gmail, .icloud, .yahoo, .fastmail: appPasswordPage
        case .outlook, .other: nil
        }
    }

    /// How to get one, in a few lines.
    var howTo: String {
        switch self {
        case .gmail:
            String(localized: "Turn on 2-Step Verification for your Google Account, then open App Passwords, make one named “Redde” and paste its 16 letters below. Your Google password itself never leaves Google.")
        case .icloud:
            String(localized: "At account.apple.com, open Sign-In and Security › App-Specific Passwords, make one named “Redde” and paste it below. Use your full iCloud address.")
        case .fastmail:
            String(localized: "In Fastmail, open Settings › Privacy & Security › Manage app passwords, make one with IMAP and SMTP access and paste it below.")
        case .yahoo:
            String(localized: "In Yahoo's Account Security, open Generate app password, make one named “Redde” and paste it below.")
        case .outlook:
            String(localized: "Microsoft has turned off app passwords for mail on most Outlook.com and Microsoft 365 accounts, and asks for a sign-in Hermes can't do yet. If your account still offers app passwords you can try; otherwise forward your mail to an account that does, or use Hermes's own email setup.")
        case .other:
            String(localized: "Your provider's help pages name its IMAP and SMTP servers. Use an app password if it offers one, never the password you sign in with everywhere.")
        }
    }

    /// Whether setting it up by app password is likely to work at all.
    var appPasswordsWork: Bool { self != .outlook }
}

/// The names the plugin reads from the main profile's .env (tmp/mail-contract.md). The first
/// account's are `REDDE_MAIL_*`; another's carry its key, `REDDE_MAIL_WORK_*`, and the key is listed in
/// `REDDE_MAIL_ACCOUNTS`.
nonisolated enum MailSecrets {
    /// The key for an extra account from its name ("Work" → "WORK", "Side job" → "SIDE_JOB").
    static func key(for name: String) -> String {
        let upper = name.uppercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_" }
        let joined = String(upper).split(separator: "_").joined(separator: "_")
        let key = joined.isEmpty ? "EXTRA" : String(joined.prefix(20))
        return key.first?.isNumber == true ? "A" + key : key
    }

    /// The account's id as the plugin will call it: `main`, or the key lower-cased.
    static func accountID(key: String?) -> String { key.map { $0.lowercased() } ?? "main" }

    static func name(_ field: String, key: String?) -> String {
        guard let key else { return "REDDE_MAIL_" + field }
        return "REDDE_MAIL_\(key)_\(field)"
    }

    /// What one account's setup writes, in order (the password last: the one that matters most).
    /// The settings that aren't secret, as `mail setup` takes them (`account` for another account's).
    static func settings(provider: MailProvider, address: String, name: String, user: String?,
                         imap: (host: String, port: Int)?, smtp: (host: String, port: Int)?, key: String?) -> [String: Any] {
        var out: [String: Any] = ["address": address, "provider": provider.rawValue]
        if !name.isEmpty { out["name"] = name }
        if let user, !user.isEmpty, user != address { out["user"] = user }
        if provider == .other {
            if let imap { out["imap_host"] = imap.host; out["imap_port"] = imap.port }
            if let smtp { out["smtp_host"] = smtp.host; out["smtp_port"] = smtp.port }
        }
        if let key { out["account"] = accountID(key: key) }
        return out
    }

    static func values(provider: MailProvider, address: String, password: String, name: String, user: String?,
                       imap: (host: String, port: Int)?, smtp: (host: String, port: Int)?, key: String?) -> [(name: String, value: String)] {
        var out: [(String, String)] = [(Self.name("ADDRESS", key: key), address), (Self.name("PROVIDER", key: key), provider.rawValue)]
        if !name.isEmpty { out.append((Self.name("NAME", key: key), name)) }
        if let user, !user.isEmpty, user != address { out.append((Self.name("USER", key: key), user)) }
        if provider == .other {
            if let imap { out += [(Self.name("IMAP_HOST", key: key), imap.host), (Self.name("IMAP_PORT", key: key), String(imap.port))] }
            if let smtp { out += [(Self.name("SMTP_HOST", key: key), smtp.host), (Self.name("SMTP_PORT", key: key), String(smtp.port))] }
        }
        out.append((Self.name("PASSWORD", key: key), password))
        return out
    }
}

/// One account to set up, from the Add Email sheet.
nonisolated struct MailSetup: Sendable {
    var provider: MailProvider
    var address: String
    var password: String
    var name: String
    var user: String?
    var imap: (host: String, port: Int)?
    var smtp: (host: String, port: Int)?
    /// Another account's key ("WORK"); nil for the first.
    var key: String?
    /// The extra accounts there already, for REDDE_MAIL_ACCOUNTS when the plugin can't write it.
    var others: [String] = []

    var settings: [String: Any] {
        MailSecrets.settings(provider: provider, address: address, name: name, user: user, imap: imap, smtp: smtp, key: key)
    }

    var passwordName: String { MailSecrets.name("PASSWORD", key: key) }

    /// Every value as a sealed setting, for a plugin without `mail setup`.
    var values: [(name: String, value: String)] {
        var out = MailSecrets.values(provider: provider, address: address, password: password, name: name, user: user,
                                     imap: imap, smtp: smtp, key: key)
        if let key { out.insert(("REDDE_MAIL_ACCOUNTS", (others.filter { $0 != key } + [key]).joined(separator: ",")), at: 0) }
        return out
    }

}

/// The inbox as last seen, in the app group: the chat list's row and the Inbox show it at once,
/// before the plugin answers (and with no network at all for the row).
nonisolated struct MailSnapshot: Codable, Equatable, Sendable {
    var accounts: [MailAccount]
    var threads: [String: [MailThread]]
    var at: Date
    var brief: MailBrief?
    /// When the brief was last asked for: at most hourly, from the chat list.
    var briefAt: Date?

    private static let key = "mailSnapshot"

    static func load(in defaults: UserDefaults? = NeedsYou.shared) -> MailSnapshot? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(MailSnapshot.self, from: data)
    }

    func save(in defaults: UserDefaults? = NeedsYou.shared) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults?.set(data, forKey: Self.key)
    }

}

/// The inbox, the rules and the setup: asked of the plugin only when a page opens or he pulls to
/// refresh, never on a timer (the server keeps the inbox fresh itself, every few minutes).
@MainActor
@Observable
final class MailCenter {
    static let shared = MailCenter()

    private(set) var status: MailStatus?
    /// When the counts were last asked for (`refreshStatusIfStale`), this launch.
    @ObservationIgnored private var statusAt: Date?
    /// Each account's threads by pile (`all` included), as last listed.
    private(set) var threads: [String: [MailThread]] = [:]
    private(set) var more: [String: Bool] = [:]
    private(set) var rules: [MailRule] = []
    /// The label Paperless-ngx takes mail from: the ready-made Paperless rule's, else "Paperless"
    /// ("an easy way to label or tag emails to be sent to paperless", 2026-11-06).
    var paperlessLabel: String { rules.first { $0.id == "paperless" }?.arg ?? "Paperless" }
    private(set) var log: [MailLogEntry] = []
    private(set) var loading = false
    /// Something that went wrong, said where the list would be.
    var problem: String?
    /// The account the Inbox shows, or `MailCenter.all` for every one together. Kept (2026-11-06:
    /// "make whatever is selected sticky"), so the Inbox opens on the last pick.
    var accountID: String? = UserDefaults.standard.string(forKey: "mail.inboxAccount") {
        didSet { UserDefaults.standard.set(accountID, forKey: "mail.inboxAccount") }
    }
    /// "All Mailboxes": every working account's mail in one list, newest first, as Apple Mail's
    /// All Inboxes (asked 2026-11-06). Merged here, so any plugin version gives it.
    static let all = "*"
    /// The toast at the bottom of the Inbox, with its Undo.
    var toast: Toast?
    /// Opened over the app (a mail note's notification, Ahead of Your Day).
    var showingInbox = false
    var showingSetup = false
    /// Bumped to close the Inbox's sheets before a chat opens (Reply with Agent).
    var closeRequests = 0

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        var text: String
        /// The log entry to undo, or nil when there's nothing to undo.
        var undo: String?
        /// What was on the list before, put back at once on Undo.
        var before: [String: [MailThread]]
        var account: String
    }

    /// When the brief was last asked for.
    @ObservationIgnored private var briefAt: Date?
    @ObservationIgnored var plugin: PushService.PluginCommand = PushService.command(over: .shared)
    @ObservationIgnored var reachable: () async -> Bool = { await HermesServeClient.shared.canUse() }

    init() {
        if let snapshot = MailSnapshot.load() {
            status = MailStatus(accounts: snapshot.accounts, brief: snapshot.brief)
            threads = snapshot.threads
            briefAt = snapshot.briefAt
        }
        #if DEBUG
        if MailDemo.on { MailDemo.install(in: self) }
        #endif
    }

    var accounts: [MailAccount] { status?.accounts ?? [] }
    var account: MailAccount? { accounts.first { $0.id == accountID } ?? accounts.first(where: \.usable) ?? accounts.first }
    /// All Mailboxes is picked and there is more than one account to put together.
    var showsAll: Bool { accountID == Self.all && accounts.filter(\.usable).count > 1 }
    /// What the Inbox shows: the account picked, or every working account added up.
    var inbox: MailAccount? {
        guard showsAll else { return account }
        let usable = accounts.filter(\.usable)
        var counts: [String: Int] = [:]
        for one in usable { counts.merge(one.counts, uniquingKeysWith: +) }
        return MailAccount(id: Self.all, name: String(localized: "All Mailboxes", comment: "Inbox: every email account together"),
                           address: "", provider: "", via: "all", usable: true, problem: nil,
                           lastSync: usable.compactMap(\.lastSync).min(), unread: usable.reduce(0) { $0 + $1.unread }, counts: counts)
    }
    /// The accounts the Inbox's list is made of.
    private var inboxAccounts: [MailAccount] { showsAll ? accounts.filter(\.usable) : account.map { [$0] } ?? [] }
    /// There's something to show: the chat list's row appears.
    var isSetUp: Bool { accounts.contains(where: \.usable) }

    private func key(_ account: String, _ bucket: String) -> String { "\(account)/\(bucket)" }

    func threads(in bucket: MailBucket?, account: String? = nil) -> [MailThread] {
        guard let id = account ?? inbox?.id else { return [] }
        return threads[key(id, bucket?.rawValue ?? "all")] ?? []
    }

    func hasMore(in bucket: MailBucket?, account: String? = nil) -> Bool {
        guard let id = account ?? inbox?.id else { return false }
        return more[key(id, bucket?.rawValue ?? "all")] ?? false
    }

    // MARK: Asking the plugin

    private func ask(_ words: String) async throws -> JSONValue {
        guard await reachable() else { throw MailError.noDashboard }
        do {
            return try MailWire.parse(try await plugin("mail " + words))
        } catch PushError.noPlugin {
            throw MailError.noPlugin
        } catch let error as PushError {
            throw MailError.server(code: "failed", message: error.localizedDescription)
        }
    }

    /// `mail status`: the accounts and their piles' counts.
    @discardableResult
    func refreshStatus() async -> MailStatus? {
        do {
            let fresh = MailStatus(json: try await ask("status"))
            statusAt = .now
            status = fresh
            problem = nil
            if accountID == nil || (accountID != Self.all && !fresh.accounts.contains(where: { $0.id == accountID })) {
                accountID = fresh.usable.first?.id ?? fresh.accounts.first?.id
            }
            remember()
            return fresh
        } catch {
            problem = error.localizedDescription
            return nil
        }
    }

    /// A pile's first page (or the next, `page`), for the account shown; for All Mailboxes, that
    /// page of each account, put together newest first.
    func load(_ bucket: MailBucket?, page: Int = 0) async {
        let accounts = inboxAccounts
        guard !accounts.isEmpty else { return }
        let pile = bucket?.rawValue ?? "all"
        loading = true
        defer { loading = false }
        do {
            for account in accounts {
                let k = key(account.id, pile)
                // Past the end of a shorter account's mail: nothing more to ask it for.
                if page > 0, accounts.count > 1, more[k] != true { continue }
                let listed = MailPage(json: try await ask("list \(pile) \(page) \(account.id)"))
                threads[k] = page == 0 ? listed.threads : (threads[k] ?? []) + listed.threads.filter { t in !(threads[k] ?? []).contains { $0.id == t.id } }
                more[k] = listed.more
            }
            if showsAll {
                let k = key(Self.all, pile)
                threads[k] = accounts.flatMap { threads[key($0.id, pile)] ?? [] }.sorted { $0.date > $1.date }
                more[k] = accounts.contains { more[key($0.id, pile)] == true }
            }
            problem = nil
            remember()
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Opening the Inbox, or pulling it: the status, then the pile shown.
    func refresh(_ bucket: MailBucket?) async {
        await refreshStatus()
        guard isSetUp else { return }
        await load(bucket)
    }

    /// One email whole. The plugin marks it read; so does the list here.
    func read(_ id: String) async throws -> MailMessage {
        guard let message = MailMessage(json: try await ask("read \(id)")) else { throw MailError.malformed }
        mark(ids: [id]) { $0.unread = false }
        return message
    }

    /// A tap: done on the list at once, then on the server; put back if the server says no.
    @discardableResult
    func act(_ action: MailAction, on ids: [String]) async -> Bool {
        guard let account = account?.id, !ids.isEmpty else { return false }
        let before = threads
        apply(action, to: ids)
        do {
            let result = MailActResult(json: try await ask("act \(action.words) \(ids.joined(separator: ","))" + (action.arg.map { " " + $0 } ?? "")))
            if !result.failed.isEmpty, result.done.isEmpty { throw MailError.server(code: "failed", message: String(localized: "Your mail server didn't take it.")) }
            let count = result.done.count
            toast = Toast(text: count > 1 ? String(localized: "\(action.done): \(count) emails", comment: "Toast after acting on several emails; what was done, how many") : action.done,
                          undo: result.log, before: before, account: account)
            remember()
            return true
        } catch {
            threads = before
            toast = Toast(text: error.localizedDescription, undo: nil, before: before, account: account)
            return false
        }
    }

    /// The toast's Undo: the list as it was, and the server told.
    func undo(_ toast: Toast) async {
        self.toast = nil
        threads = toast.before
        remember()
        guard let log = toast.undo else { return }
        _ = try? await ask("act undo \(log)")
    }

    /// Undo from the log (Agent Activity, the Rules page).
    func undo(log entry: MailLogEntry) async throws {
        _ = try await ask("act undo \(entry.id)")
        if let at = log.firstIndex(where: { $0.id == entry.id }) { log[at].undone = true }
    }

    private func apply(_ action: MailAction, to ids: [String]) {
        if case let .group(bucket) = action {
            // Out of the pile it was in, into the one picked (where that one is loaded), newest first.
            var moved: [MailThread] = []
            for k in threads.keys where !k.hasSuffix("/all") {
                moved += threads[k]?.filter { ids.contains($0.id) } ?? []
                threads[k]?.removeAll { ids.contains($0.id) }
            }
            mark(ids: ids) { $0.bucket = bucket }
            if moved.isEmpty { moved = threads.values.flatMap { $0 }.filter { ids.contains($0.id) } }
            // Into each loaded list of that pile its account's (All Mailboxes' takes every one).
            for k in threads.keys where k.hasSuffix("/" + bucket.rawValue) {
                let owner = String(k.dropLast(bucket.rawValue.count + 1))
                guard var list = threads[k] else { continue }
                for var thread in moved where (owner == Self.all || thread.id.hasPrefix(owner + ":")) && !list.contains(where: { $0.id == thread.id }) {
                    thread.bucket = bucket
                    list.append(thread)
                }
                threads[k] = list.sorted { $0.date > $1.date }
            }
            return
        }
        if action.removes {
            for k in threads.keys { threads[k]?.removeAll { ids.contains($0.id) } }
            return
        }
        mark(ids: ids) { thread in
            switch action {
            case .read: thread.unread = false
            case .unread: thread.unread = true
            case .flag: thread.flagged = true
            case .unflag: thread.flagged = false
            default: break
            }
        }
    }

    private func mark(ids: [String], _ change: (inout MailThread) -> Void) {
        for k in threads.keys {
            guard var list = threads[k] else { continue }
            for i in list.indices where ids.contains(list[i].id) { change(&list[i]) }
            threads[k] = list
        }
    }

    private func remember() {
        MailSnapshot(accounts: accounts, threads: threads.filter { entry in entry.key.hasSuffix("/all") || MailBucket.shown.contains { entry.key.hasSuffix("/" + $0.rawValue) } },
                     at: .now, brief: status?.brief, briefAt: briefAt).save()
    }

    // MARK: The morning page

    var brief: MailBrief? { status?.brief }

    /// The briefing deck's email page: asked of the plugin when the chat list shows, at most once an
    /// hour, and only once email is set up (the plugin answers from what it sorted; no new look).
    /// The counts again for the Today page's Inbox tile, at most every 5 minutes: they were only
    /// asked for when the Inbox opened, so a phone that hadn't opened it in a while showed mail
    /// long since read (11-13: 5 unread on the phone, none on the iPad).
    func refreshStatusIfStale(now: Date = .now) async {
        guard isSetUp, now.timeIntervalSince(statusAt ?? .distantPast) > 300 else { return }
        statusAt = now
        await refreshStatus()
    }

    func refreshBriefIfStale(now: Date = .now) async {
        guard isSetUp, now.timeIntervalSince(briefAt ?? .distantPast) > 3600 else { return }
        briefAt = now
        guard let answer = try? await ask("brief") else { return }
        status?.brief = MailBrief(json: answer["brief"])
        remember()
    }

    // MARK: Rules and the log

    func loadRules() async {
        do {
            rules = (try await ask("rules list"))["rules"]?.array?.compactMap(MailRule.init(json:)) ?? []
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    /// The whole list, as `mail rules set` replaces it.
    func save(rules new: [MailRule]) async throws {
        // A plain list, as `mail rules set` takes it (11-05: wrapped in {"rules": …}, every save was
        // turned down with "Rules are a list.", so a rule's switch sprang back).
        let stored = try await ask("rules set " + MailWire.json(new.map(\.json)))
        rules = stored["rules"]?.array?.compactMap(MailRule.init(json:)) ?? new
    }

    func add(_ rule: MailRule) async throws { try await save(rules: rules + [rule]) }

    func remove(_ rule: MailRule) async throws { try await save(rules: rules.filter { $0.id != rule.id }) }

    func loadLog(_ count: Int = 40) async {
        do {
            log = (try await ask("log \(count)"))["log"]?.array?.compactMap(MailLogEntry.init(json:)) ?? []
        } catch {
            log = []
        }
    }

    // MARK: Drafts

    /// The agent's draft, sent as he approved it; changed first if he edited it.
    func send(_ draft: MailDraft, edited: MailDraft?) async throws {
        var hash = draft.hash
        if let edited, edited != draft {
            guard let fresh = MailDraft(json: try await ask("draft-edit \(draft.id) " + MailWire.json(edited.edits))) else { throw MailError.malformed }
            hash = fresh.hash
        }
        let sent = try await ask("draft-send \(draft.id) \(hash)")
        guard sent["sent"]?.bool == true else { throw MailError.malformed }
    }

    // MARK: Removing an account

    /// `mail remove <id>` (asked 11-03: "can I delete an email account"): the account out of Redde
    /// and the Hermes, its password, its kept mail and the rules only it matches. The mail itself
    /// stays with the provider. Not for a Gmail connected through Hermes or Nous: not Redde's.
    func removeAccount(_ id: String) async throws {
        let answer = try await ask("remove \(id)")
        guard answer["removed"]?.string == id else { throw MailError.malformed }
        forget(account: id)
        await refreshStatus()
    }

    /// What this device kept of a removed account: its piles, its page in the brief, the Inbox's pick.
    func forget(account id: String) {
        threads = threads.filter { !$0.key.hasPrefix(id + "/") }
        more = more.filter { !$0.key.hasPrefix(id + "/") }
        status?.accounts.removeAll { $0.id == id }
        status?.brief?.accounts.removeAll { $0.id == id }
        log = log.map { entry in
            guard entry.account == id else { return entry }
            var gone = entry
            gone.gone = true
            return gone
        }
        if toast?.account == id { toast = nil }
        if accountID == id { accountID = accounts.first(where: \.usable)?.id ?? accounts.first?.id }
        remember()
    }

    /// Redde can take it out: an account set up in Redde, not Hermes's or Nous's Gmail.
    static func removable(_ account: MailAccount) -> Bool { account.via == "imap" }

    // MARK: Setup

    func check(_ account: String?) async throws -> MailCheck {
        MailCheck(json: try await ask("setup-check" + (account.map { " " + $0 } ?? "")))
    }

    // MARK: Gmail labels (11-03: sorting shown in Gmail, tagging rules)

    /// "Show Sorting in Gmail" for one account.
    func setGroupLabels(_ on: Bool, account id: String) async throws {
        _ = try await ask("settings " + MailWire.json(["labels": [id: ["groups": on]]]))
        await refreshStatus()
    }

    /// The last 30 days, labelled a little at a time on the Hermes.
    func backfillLabels(account id: String) async throws {
        _ = try await ask("labels backfill \(id)")
        await refreshStatus()
    }

    /// Redde's labels off again: `groups` (the Redde/… ones) or `all` (the tagging rules' too). Only
    /// labels Redde wrote down as its own.
    func removeLabels(account id: String, which: String) async throws {
        _ = try await ask("labels remove \(id) \(which)")
        await refreshStatus()
    }

    /// The account's own labels, to pick one for a tagging rule.
    func labelNames(account id: String) async throws -> [String] {
        (try await ask("labels list \(id)"))["labels"]?.array?.compactMap(\.string) ?? []
    }

    /// "Suggest Rules" for one account.
    func setSuggest(_ on: Bool, account id: String) async throws {
        _ = try await ask("settings " + MailWire.json(["labels": [id: ["suggest": on]]]))
        await refreshStatus()
    }

    func suggestions(account id: String, refresh: Bool = false) async throws -> [MailSuggestion] {
        (try await ask("suggest \(refresh ? "refresh" : "list") \(id)"))["suggestions"]?.array?.compactMap(MailSuggestion.init(json:)) ?? []
    }

    /// Becomes a real rule (as changed, when `edited`), running from then on.
    func accept(_ suggestion: MailSuggestion, account id: String, edited: MailRule? = nil) async throws {
        var words = "suggest accept \(id) \(suggestion.id)"
        if let edited {
            var rule = edited.json
            rule.removeValue(forKey: "id")
            words += " " + MailWire.json(rule)
        }
        _ = try await ask(words)
        await loadRules()
        await refreshStatus()
        if let edited, !edited.also.isEmpty, rules.first(where: { $0.id == "s" + suggestion.id })?.also.isEmpty == true { throw MailError.oneLabel }
    }

    func dismiss(_ suggestion: MailSuggestion, account id: String) async throws {
        _ = try await ask("suggest dismiss \(id) \(suggestion.id)")
        await refreshStatus()
    }

    /// Replaces one rule (or adds it) and saves the list.
    func put(_ rule: MailRule) async throws {
        var list = rules
        if let i = list.firstIndex(where: { $0.id == rule.id }) { list[i] = rule } else { list.append(rule) }
        try await save(rules: list)
        // A plugin before 1.19.1 keeps a rule's first label only.
        if rule.also.count > 0, rules.first(where: { $0.id == rule.id })?.also.isEmpty == true { throw MailError.oneLabel }
    }

    func setTriage(_ on: Bool) async {
        if let json = try? await ask("settings " + MailWire.json(["triage": on ? "auto" : "off"])) {
            status?.triage = json["triage"]?.string ?? (on ? "auto" : "off")
        }
    }

    /// An account's setup (plugin 1.16): the settings that aren't secret written at once (`mail
    /// setup`), then the app password alone sealed straight into the main profile's .env (Keys Asked
    /// For's way: `keys ask` opens a request for it, `keys set` hands it over sealed to that request;
    /// no chat, log or notification holds it). Hermes reads both without a restart. A plugin without
    /// `mail setup` gets every value the sealed way, one request each.
    func setUp(_ account: MailSetup, progress: (Int, Int) -> Void = { _, _ in }) async throws {
        guard await reachable() else { throw MailError.noDashboard }
        if status?.setupCommand != true { await refreshStatus() }
        if status?.setupCommand == true {
            progress(0, 2)
            let answer = try await ask("setup " + MailWire.json(account.settings))
            if let fresh = answer["status"], fresh.object != nil {
                status = MailStatus(json: fresh)
                remember()
            }
            progress(1, 2)
            try await seal(account.passwordName, account.password)
            progress(2, 2)
        } else {
            let all = account.values
            for (n, entry) in all.enumerated() {
                progress(n, all.count)
                try await seal(entry.name, entry.value)
            }
            progress(all.count, all.count)
        }
    }

    /// One value, sealed to a request the app opens for it.
    private func seal(_ name: String, _ value: String) async throws {
        let why = name.hasSuffix("PASSWORD")
            ? "The app password Redde's email signs in with. It goes straight into this .env."
            : "A setting for Redde's email."
        let reply: String
        do {
            reply = try await plugin("keys ask \(name) default \(why)")
        } catch PushError.noPlugin {
            throw MailError.noPlugin
        }
        _ = try await KeyRequests.shared.answer(try Self.request(from: reply), with: value)
    }

    /// `keys ask`'s answer: the request, or why there is none.
    nonisolated static func request(from reply: String) throws -> KeyRequest {
        if let refused = reply.range(of: "redde-push keys refused") {
            let why = reply[refused.upperBound...].trimmingCharacters(in: .whitespaces)
            throw MailError.server(code: "refused", message: why.hasPrefix("busy")
                ? String(localized: "Your Hermes has taken ten settings in the last hour. Try again in a while.")
                : String(localized: "Your Hermes's Redde plugin turned the setting down (\(why)). Update the plugin and try again."))
        }
        guard let json = PluginReply.json(reply, "keys"), let request = KeyRequest(listed: json) else {
            throw MailError.server(code: "no_key_ask", message: String(localized: "This Hermes's Redde plugin can't take email settings from the app yet. Update the plugin, or ask your agent to set it up, which puts each setting in a key card."))
        }
        return request
    }

    /// Without `keys ask`: the main agent asked, in a chat, to request each name, so each arrives
    /// as a key card (`request_secret`). What the chat says, in English as Redde's other asks.
    static func setupAsk(names: [String], provider: MailProvider) -> String {
        "Set up email for Redde (provider: \(provider.rawValue)). Use request_secret to ask me for each of these, for the "
            + "default profile, so I can paste them into Redde's key cards: \(names.joined(separator: ", ")). "
            + "Don't ask for any of them in the chat."
    }
}
