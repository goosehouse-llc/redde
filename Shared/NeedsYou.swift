import Foundation

/// Something an agent has stopped for: a command to approve, a question, a password or a secret
/// it wants. One per conversation, since Hermes waits on one thing at a time in a session.
nonisolated struct WaitingRequest: Codable, Sendable, Equatable, Identifiable {
    enum Kind: String, Codable, Sendable { case approval, question, sudo, secret }

    /// The Hermes session's id, or the app's own conversation's when the server has none for it
    /// (`NeedsYou.key`). A request the app saw and the notification a paired Hermes sent about
    /// it are one entry this way.
    var id: String
    var kind: Kind
    /// The conversation's title, when known.
    var title: String?
    /// The command, or the question.
    var text: String
    /// The session to open for it. Nil for a conversation the server has no session for.
    var session: String?
    var since: Date
    /// When Hermes gives up waiting, as far as the phone can tell (`NeedsYou.lifetime`).
    var until: Date
}

/// What the "Needs you" widget shows: the requests waiting on the person, kept in the App Group.
/// Two things write it. The app does while it follows a turn, and takes an entry away the moment
/// it is answered, expires or its turn is stopped. The notification extension does for a note a
/// paired Hermes sends, which is how a request made while Redde is closed gets here; that entry
/// goes when a later note says the turn went on, when it is answered from its notification, when
/// its conversation is opened, or when its time is up.
nonisolated enum NeedsYou {
    static let widgetKind = "com.goosehouse.echo.needsyou"
    private static let key = "needsYou"
    private static let settledKey = "needsYou.settled"
    private static let hiddenKey = "needsYou.hidesWords"

    /// A request that is over, remembered for as long as Hermes would have waited on it. A note
    /// about it can still be on its way (a push takes its time, and an answer on the card in
    /// the app can beat it), and must not bring it back.
    private struct Settled: Codable {
        var kind: WaitingRequest.Kind
        var text: String
        var at: Date
    }

    static var shared: UserDefaults? { UserDefaults(suiteName: PushVault.group) }

    /// How long Hermes waits before it gives up, by its own defaults (0.21.0 to 0.21.5): an
    /// approval five minutes (`approvals.timeout`), a question an hour (`clarify_timeout`), the
    /// sudo password two minutes, a secret five. A server set up otherwise isn't known here; an
    /// entry that outlives its request is put right when the conversation is opened.
    static func lifetime(_ kind: WaitingRequest.Kind) -> TimeInterval {
        switch kind {
        case .approval, .secret: 300
        case .question: 3600
        case .sudo: 120
        }
    }

    static func key(session: String?, conversation: UUID) -> String {
        session ?? "c:\(conversation.uuidString)"
    }

    /// What still waits, the one that runs out first at the top.
    static func waiting(at now: Date = .now, in defaults: UserDefaults? = shared) -> [WaitingRequest] {
        all(in: defaults).filter { $0.until > now }.sorted { ($0.until, $0.id) < ($1.until, $1.id) }
    }

    /// Records a request, in place of whatever its conversation waited on before. False when
    /// that is what was there already.
    @discardableResult
    static func note(_ request: WaitingRequest, at now: Date = .now, in defaults: UserDefaults? = shared) -> Bool {
        var requests = all(in: defaults).filter { $0.until > now }
        if let i = requests.firstIndex(where: { $0.id == request.id }) {
            // The same request heard of twice, from the app's card and from Hermes's note a few
            // seconds apart, keeps its clock.
            if requests[i].kind == request.kind, requests[i].text == request.text,
               abs(requests[i].since.timeIntervalSince(request.since)) < 60 { return false }
            requests[i] = request
        } else {
            requests.append(request)
        }
        save(requests, in: defaults)
        remember(nil, for: request.id, at: now, in: defaults)
        return true
    }

    /// A conversation waits on nothing any more. False when it didn't.
    @discardableResult
    static func settle(_ id: String, at now: Date = .now, in defaults: UserDefaults? = shared) -> Bool {
        let requests = all(in: defaults)
        guard let over = requests.first(where: { $0.id == id }) else { return false }
        save(requests.filter { $0.id != id }, in: defaults)
        remember(Settled(kind: over.kind, text: over.text, at: now), for: id, at: now, in: defaults)
        return true
    }

    static func clear(in defaults: UserDefaults? = shared) {
        defaults?.removeObject(forKey: key)
        defaults?.removeObject(forKey: settledKey)
    }

    /// What a note from a paired Hermes means for the list. One that says the agent stopped for
    /// something adds it; one that says the turn ended, with a reply or without, takes that
    /// conversation's entry away. False when the list is as it was.
    @discardableResult
    static func take(_ pushed: PushNote, at now: Date = .now, in defaults: UserDefaults? = shared) -> Bool {
        guard let session = pushed.s, !session.isEmpty, let kind = pushed.kind else { return false }
        let waiting: WaitingRequest.Kind
        switch kind {
        case .approval: waiting = .approval
        case .question: waiting = .question
        case .sudo: waiting = .sudo
        case .secret: waiting = .secret
        case .reply, .failed: return settle(session, in: defaults)
        case .task, .paired, .test: return false
        }
        let since = pushed.at.map { Date(timeIntervalSince1970: $0) } ?? now
        let until = since.addingTimeInterval(lifetime(waiting))
        guard until > now else { return false }   // a note that arrived after its request ran out
        let text = pushed.b?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // The request this note is about is over already, by the app's own account.
        if let over = settled(in: defaults)[session], over.kind == waiting, now.timeIntervalSince(over.at) < lifetime(waiting),
           sameWords(over.text, text) { return false }
        return note(WaitingRequest(id: session, kind: waiting, title: pushed.t?.isEmpty == false ? pushed.t : nil,
                                   text: String(text.prefix(300)), session: session, since: since, until: until), at: now, in: defaults)
    }

    /// The app is locked behind Face ID (Settings → Privacy): the widgets then say that something
    /// waits and how full the context is, without the command, the question or a title.
    static var hidesWords: Bool {
        get { shared?.bool(forKey: hiddenKey) ?? false }
        set { shared?.set(newValue, forKey: hiddenKey) }
    }

    /// The plugin cuts a long command short, so the start is what is compared.
    private static func sameWords(_ a: String, _ b: String) -> Bool {
        let n = min(a.count, b.count, 40)
        return a.prefix(n) == b.prefix(n)
    }

    private static func settled(in defaults: UserDefaults?) -> [String: Settled] {
        guard let data = defaults?.data(forKey: settledKey) else { return [:] }
        return (try? JSONDecoder().decode([String: Settled].self, from: data)) ?? [:]
    }

    /// Sets or forgets what is remembered of a conversation's last request, and drops what is
    /// too old to matter for any kind.
    private static func remember(_ over: Settled?, for id: String, at now: Date, in defaults: UserDefaults?) {
        var kept = settled(in: defaults)
        guard over != nil || kept[id] != nil else { return }
        kept[id] = over
        kept = kept.filter { now.timeIntervalSince($0.value.at) < lifetime(.question) }
        if kept.isEmpty { defaults?.removeObject(forKey: settledKey); return }
        if let data = try? JSONEncoder().encode(kept) { defaults?.set(data, forKey: settledKey) }
    }

    private static func all(in defaults: UserDefaults?) -> [WaitingRequest] {
        guard let data = defaults?.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([WaitingRequest].self, from: data)) ?? []
    }

    private static func save(_ requests: [WaitingRequest], in defaults: UserDefaults?) {
        if requests.isEmpty { defaults?.removeObject(forKey: key); return }
        if let data = try? JSONEncoder().encode(requests) { defaults?.set(data, forKey: key) }
    }
}

extension WaitingRequest {
    /// "Needs your approval", for the line above the command or the question.
    var headline: String {
        switch kind {
        case .approval: "Needs your approval"
        case .question: "Has a question"
        case .sudo: "Needs the sudo password"
        case .secret: "Needs a secret"
        }
    }

    /// The request in a word, where there is no room for more.
    var name: String {
        switch kind {
        case .approval: "Approval"
        case .question: "Question"
        case .sudo: "Password"
        case .secret: "Secret"
        }
    }

    var symbol: String {
        switch kind {
        case .approval: "hand.raised.fill"
        case .question: "questionmark.bubble.fill"
        case .sudo: "lock.fill"
        case .secret: "key.fill"
        }
    }

    /// What stands in for the words when they are hidden.
    var hiddenLine: String {
        switch kind {
        case .approval: "A command is waiting for a yes or no."
        case .question: "The agent asked you something."
        case .sudo: "A command is waiting for the sudo password."
        case .secret: "A skill is waiting for a secret."
        }
    }
}

/// How full a conversation's context was at its newest reply that said, for the Context widget.
/// Written by the app when a turn ends or a conversation is opened; kept until the next reading,
/// so a new conversation that has none yet leaves the one before on the widget, with its title.
nonisolated struct ContextReading: Codable, Sendable, Equatable {
    static let widgetKind = "com.goosehouse.echo.context"
    private static let key = "contextReading"

    var used: Int
    var window: Int
    /// The conversation's title; nil while the app is locked behind Face ID.
    var title: String?
    var date: Date

    var share: Double { window > 0 ? min(1, max(0, Double(used) / Double(window))) : 0 }

    /// The same reading: the date it was taken doesn't make it a new one.
    func says(_ other: ContextReading?) -> Bool {
        other.map { $0.used == used && $0.window == window && $0.title == title } ?? false
    }

    /// "54k of 128k".
    var amounts: String { "\(Self.compact(used)) of \(Self.compact(window))" }

    static func compact(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1_000_000) : n >= 10_000 ? String(format: "%.0fk", Double(n) / 1000)
            : n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : String(n)
    }

    static func load(in defaults: UserDefaults? = NeedsYou.shared) -> ContextReading? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ContextReading.self, from: data)
    }

    /// False when this is the reading already there.
    @discardableResult
    func save(in defaults: UserDefaults? = NeedsYou.shared) -> Bool {
        guard !says(Self.load(in: defaults)), let data = try? JSONEncoder().encode(self) else { return false }
        defaults?.set(data, forKey: Self.key)
        return true
    }

    static func clear(in defaults: UserDefaults? = NeedsYou.shared) { defaults?.removeObject(forKey: key) }
}
