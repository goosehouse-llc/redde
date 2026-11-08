import Foundation

/// Watch templates (2.4, picked 2026-10-30 from the Muse / Grok Bot comparison): one tap for the
/// watches people set most (urgent emails, messages from the school, a package, a price drop), as
/// ordinary watches (`Watches`), each with a fixed id so Redde finds it again and can turn it off.
/// Offered in Ahead of Your Day and as a new watch's "Start from a template".
///
/// The email ones need a way to read email on the Hermes (an email MCP server). Over the Dashboard
/// Redde can see the server's MCP servers (`emailAccess`); over the Hermes API it can't, so the
/// first look runs at once and says: the prompt asks for exactly NO EMAIL ACCESS when there is none,
/// which the watch's row turns into what to do (`WatchReport.needsEmail`; plugin 1.15 sends it as
/// its own kind of note, `w: "noemail"`).
enum WatchTemplate: Hashable, Sendable {
    case urgentEmail
    /// From whom: a school's or a teacher's name; empty, any school.
    case schoolMessages(from: String)
    case package(tracking: String)
    /// `below`: the price that counts, as typed ("$40"); empty, any drop.
    case priceDrop(url: String, below: String)

    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case urgentEmail, schoolMessages, package, priceDrop
        var id: String { rawValue }

        var title: String {
            switch self {
            case .urgentEmail: String(localized: "Urgent Emails", comment: "A watch template: emails that can't wait")
            case .schoolMessages: String(localized: "School Messages", comment: "A watch template: messages from a child's school")
            case .package: String(localized: "A Package", comment: "A watch template: a parcel on its way")
            case .priceDrop: String(localized: "A Price Drop", comment: "A watch template: a product's price")
            }
        }

        var symbol: String {
            switch self {
            case .urgentEmail: "envelope.badge"
            case .schoolMessages: "graduationcap"
            case .package: "shippingbox"
            case .priceDrop: "tag"
            }
        }

        /// The fixed id's start: the email ones are one each; a package's and a price's carry a
        /// short hash of what they watch, so there can be several.
        var idStart: String {
            switch self {
            case .urgentEmail: "t-urgentmail"
            case .schoolMessages: "t-school"
            case .package: "t-pkg"
            case .priceDrop: "t-price"
            }
        }

        var needsEmail: Bool { self == .urgentEmail || self == .schoolMessages }
    }

    var kind: Kind {
        switch self {
        case .urgentEmail: .urgentEmail
        case .schoolMessages: .schoolMessages
        case .package: .package
        case .priceDrop: .priceDrop
        }
    }

    var needsEmail: Bool { kind.needsEmail }

    /// The watch's id (its job's `[redde-watch:<id>]`).
    var id: String {
        switch self {
        case .urgentEmail, .schoolMessages: kind.idStart
        case let .package(tracking): kind.idStart + "-" + Self.short(tracking)
        case let .priceDrop(url, _): kind.idStart + "-" + Self.short(url)
        }
    }

    /// The template a watch was made from, by its id.
    static func kind(ofWatch id: String) -> Kind? {
        Kind.allCases.first { id == $0.idStart || id.hasPrefix($0.idStart + "-") }
    }

    /// Six hex digits of what is watched (FNV-1a: the same on every device and every launch).
    static func short(_ text: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return String(String(hash, radix: 16).suffix(6))
    }

    /// The watch's name, after its tag.
    var name: String {
        switch self {
        case .urgentEmail: String(localized: "Urgent emails", comment: "A watch's name: emails that can't wait")
        case let .schoolMessages(from):
            from.isEmpty ? String(localized: "Messages from the school", comment: "A watch's name")
                : String(localized: "Messages from \(from)", comment: "A watch's name: messages from a school or a teacher, by name")
        case let .package(tracking): String(localized: "The package \(tracking)", comment: "A watch's name: a parcel by its tracking number")
        case let .priceDrop(url, below):
            below.isEmpty ? String(localized: "The price at \(Self.site(url))", comment: "A watch's name: a product's price, by its site")
                : String(localized: "The price at \(Self.site(url)), under \(below)", comment: "A watch's name: a product's price, by its site, and the price that counts")
        }
    }

    /// What the agent is asked to look at, in its words (English: the agent's prompt).
    var what: String {
        switch self {
        case .urgentEmail:
            "their unread email from the last hour that needs them soon: a person waiting on an answer today, a deadline, " +
            "a bill or an account problem, travel changes, anything from family marked urgent. Not newsletters, receipts, " +
            "promotions or notifications from apps. Say who it's from and what they need, one line each"
        case let .schoolMessages(from):
            "new email from \(from.isEmpty ? "their children's school or teachers" : from): what it asks of them, any date or " +
            "deadline, anything to sign, pay or bring. One line each; leave out newsletters with nothing to do"
        case let .package(tracking):
            "the package with tracking number \(tracking) (find the carrier from the number, or from the shipping email): " +
            "say when it ships, is out for delivery, is delivered, or is delayed or held, with the carrier's latest date"
        case let .priceDrop(url, below):
            "the price of the product at \(url)" +
            (below.isEmpty ? ": tell them when it drops" : ": tell them when it drops below \(below)") +
            ", with the price and whether it's in stock. Read the page itself; never guess a price"
        }
    }

    /// How often it looks.
    var often: Watches.Often {
        switch self {
        case .urgentEmail: .quarter
        case .schoolMessages: .half
        case .package: .fourHours
        case .priceDrop: .morning
        }
    }

    /// How many looks before Hermes lets it go: a package's two weeks, a price's month; the email
    /// ones until turned off.
    var runs: Int? {
        switch self {
        case .urgentEmail, .schoolMessages: nil
        case .package: 14 * 6
        case .priceDrop: 30
        }
    }

    static let noEmailAnswer = "NO EMAIL ACCESS"
    static let noEmailLine = "If you have no tool that can read their email, answer exactly \(noEmailAnswer)."

    var prompt: String {
        let watch = Watches.prompt(id, what: what)
        return needsEmail ? watch + " " + Self.noEmailLine : watch
    }

    /// "example.com" from a link, or the text as it is.
    static func site(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = URL(string: trimmed.contains("://") ? trimmed : "https://" + trimmed)?.host() ?? trimmed
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: Email on the Hermes

    /// An MCP server whose name says it reads email.
    static func readsEmail(_ server: MCPServer) -> Bool {
        server.enabled && server.name.range(of: "gmail|mail|imap|outlook|himalaya|fastmail|proton|jmap", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Whether the Hermes can read email: over the Dashboard, by its MCP servers; nil when that
    /// can't be told (the Hermes API alone, or the Dashboard didn't answer).
    static func emailAccess() async -> Bool? {
        guard let backend = CronBackend.current(), case .serve = backend else { return nil }
        // Redde's own email (2.4, `mail.py`): an account the plugin can use is access enough.
        if let status = await MailCenter.shared.refreshStatus(), !status.usable.isEmpty { return true }
        guard let servers = try? await HermesServeClient.shared.mcpServers() else { return nil }
        return servers.contains(where: readsEmail)
    }

    static let needsEmailHint = String(localized: "Needs email on your Hermes: connect an account in Settings → Agent → Email (or add an email MCP server in Settings → Gateway), then check again.",
                                       comment: "A watch that reads email, on a Hermes that can't")

    // MARK: Making and finding

    /// Sets the watch up. An email one whose access can't be told looks at once, so the answer comes
    /// now rather than in a quarter of an hour.
    static func create(_ template: WatchTemplate, emailKnown: Bool? = nil) async throws {
        guard let backend = CronBackend.current() else { throw TransportError.malformed(String(localized: "Scheduled jobs need the Hermes Dashboard or the Hermes API.")) }
        let name = "\(Watches.watchTag)\(template.id)] \(template.name)"
        // On Watcher when there is one, as a written watch is (`Watches.defaultWatcher`).
        try await backend.create(name: name, schedule: template.often.rawValue, prompt: template.prompt, deliver: "local",
                                 profile: Watches.defaultWatcher, runs: template.runs)
        guard template.needsEmail, emailKnown == nil else { return }
        // Not waited for: on the Dashboard a run blocks until it ends.
        Task {
            guard let job = try? await backend.list().first(where: { $0.name == name }) else { return }
            try? await backend.runNow(job.id, profile: job.profile)
        }
    }

    /// The watch made from a template of `kind`, among the jobs.
    static func find(_ kind: Kind, in jobs: [CronJob]) -> CronJob? {
        jobs.first { job in Watches.id(of: job).flatMap(Self.kind(ofWatch:)) == kind && job.name.hasPrefix(Watches.watchTag) }
    }
}
