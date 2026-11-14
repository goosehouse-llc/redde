// Conversation's streamed deltas, the files and cards a reply names, tool details, quotes and follow-ups.
import Foundation

extension Conversation {
    // MARK: - Delta coalescing
    //
    // Models emit a token every few milliseconds; applying each one re-renders the transcript
    // (Markdown parse, highlighting, scroll). Buffer them and apply at ~20 fps instead. Thinking
    // alone goes at 5: it is a few grey lines that scroll by, a model can think for minutes, and
    // every update costs the same as one of reply text.

    private static let reasoningFlushInterval: Duration = .milliseconds(200)

    /// Reply text goes at 20 fps while the reply is short, and less often as it grows: each
    /// update lays the whole reply out again (SwiftUI's graph and text layout, not Redde's code,
    /// measured 2026-10-20), so a long one cost the same per update and twice as much a second.
    nonisolated static func textFlushInterval(forLength bytes: Int) -> Duration {
        bytes < 4_000 ? .milliseconds(50) : bytes < 16_000 ? .milliseconds(100) : .milliseconds(150)
    }

    func markFirstToken(_ id: UUID) {
        guard firstTokenMarked != id else { return }
        firstTokenMarked = id
        update(id) { if $0.metrics?.firstTokenAt == nil { $0.metrics?.firstTokenAt = .now } }
    }

    func buffer(text: String = "", reasoning: String = "", for id: UUID) {
        if pendingFor != id { flushDeltas(); pendingFor = id }
        pendingText += text
        pendingReasoning += reasoning
        let slow = pendingText.isEmpty
        // Reply text doesn't wait out a flush that was scheduled for thinking.
        if flushIsSlow, !slow { flushTask?.cancel(); flushTask = nil }
        guard flushTask == nil else { return }
        flushIsSlow = slow
        let wait = slow ? Self.reasoningFlushInterval
            : Self.textFlushInterval(forLength: messages.last(where: { $0.id == id })?.text.utf8.count ?? 0)
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self?.flushTask = nil
            self?.flushDeltas()
        }
    }

    /// Over the Hermes API a reply's task list is worked out from what its to-do calls wrote,
    /// since that stream gives no answers. The transcript has them, and the tool's own answer is
    /// the list: Hermes 0.21.3 and 0.21.5 start a later turn there on an empty list, so a merge
    /// leaves fewer items than the calls replayed would. Asked only after a reply that touched
    /// the list.
    func settleTodos(_ id: UUID) async {
        guard let session = serverSessionID, messages.last(where: { $0.id == id })?.todos != nil,
              let answered = await ledgerAPI()?.answeredTodos(sessionID: session) else { return }
        update(id) { if $0.todos != answered { $0.todos = answered } }
    }

    /// Over the Hermes API a card call (`redde_show`, `request_secret`) comes in the stream by its name alone, its
    /// arguments left out: the transcript has them, read once the reply is done. Only the newest
    /// reply's, and only for a reply that made such a call and has no cards yet.
    func settleCards(_ id: UUID) async {
        guard let session = serverSessionID, let reply = messages.last(where: { $0.id == id }), (reply.cards ?? []).isEmpty,
              reply.tools.contains(where: { ReplyCards.carriesCards($0.name) && $0.status != .failed }),
              let rows = try? await ledgerAPI()?.newestMessages(sessionID: session, limit: 60) else { return }
        var read = Conversation.mapStored(rows)
        ReplyCards.resolve(&read)
        guard let cards = read.last(where: { $0.role == .assistant })?.cards, !cards.isEmpty else { return }
        update(id) { if ($0.cards ?? []).isEmpty { $0.cards = cards } }
        Task { await fillCards(id) }   // not holding up the end of the turn
    }

    /// A reply's weather and time cards that the plugin's answer didn't fill in (a plugin older
    /// than 1.7.0, or its answer not read), looked up on the phone (`CardLookup`). Only a reply
    /// coming in: one read back later keeps what it was saved with.
    func fillCards(_ id: UUID) async {
        #if DEBUG
        if DemoDay.on { return }   // the day's video: its made-up forecast stays as written
        #endif
        guard let cards = messages.last(where: { $0.id == id })?.cards, cards.contains(where: CardLookup.needsLookup) else { return }
        let filled = await cardLookup.fill(cards)
        guard filled != cards else { return }
        update(id) { if $0.cards == cards { $0.cards = filled } }   // unless another call changed them meanwhile
    }

    /// A reply that delivers a file carries a bare server path (`MEDIA:` tag, markdown image,
    /// or "[IMAGE: …]"). Fetch each over the serve dashboard file API and attach it — photos
    /// for images, document chips for the rest. Paths that fail to fetch stay in the text.
    /// Whether a reply names a file for the phone to fetch: on the Hermes API the Dashboard is only
    /// asked whether it lets this phone in when there is something to fetch.
    func replyNamesFiles(_ id: UUID) -> Bool {
        messages.first(where: { $0.id == id }).map { ServeMedia.mayName(in: $0.text) } ?? false
    }

    func resolveServeMedia(_ id: UUID) async {
        guard let text = messages.first(where: { $0.id == id })?.text else { return }
        let candidates = ServeMedia.candidates(in: text)
        guard !candidates.isEmpty else { return }
        var attachments: [Attachment] = []
        var fetched: Set<String> = []
        // A photo the phone handed over in this very reply is in it already (`DeviceToolsService`):
        // the agent naming it as well is no reason to show it twice. Its name on the server ends
        // in the name it has here.
        let shown = messages.first(where: { $0.id == id })?.attachments.map(\.filename) ?? []
        // A page named twice, once to show and once as a file, is shown.
        for c in candidates.filter(\.isPage) + candidates.filter({ !$0.isPage }) where !fetched.contains(c.path) {
            if ServeMedia.isFromThePhone(c.path), shown.contains(where: { c.filename.hasSuffix($0) }) {
                fetched.insert(c.path)
                continue
            }
            guard let dataURL = await fetchServerFile(c.path, fileSource),
                  var att = ServeMedia.attachment(dataURL: dataURL, name: c.filename) else { continue }
            if c.isPage { att = AgentPage.attachment(att, from: c.path) }
            fetched.insert(c.path)
            attachments.append(att)
        }
        guard !fetched.isEmpty else { return }
        var cleaned = text
        for c in candidates where fetched.contains(c.path) {
            cleaned = cleaned.replacingOccurrences(of: c.whole, with: "")
        }
        // The speech tool's request for a voice bubble went with its file.
        if attachments.contains(where: \.isAudio) { cleaned = cleaned.replacingOccurrences(of: ServeMedia.voiceMarker, with: "") }
        // And Hermes's stand-in for a picture's bytes with the picture.
        if candidates.contains(where: { $0.isPicture && fetched.contains($0.path) }) { cleaned = ServeMedia.withoutPlaceholders(cleaned) }
        // The message may have been replaced while its files were on their way (another chat opened).
        guard messages.contains(where: { $0.id == id && $0.text == text }) else { return }
        update(id) { $0.text = cleaned.trimmingCharacters(in: .whitespacesAndNewlines); $0.attachments += attachments }
    }

    /// A page read again after the turn it sent: the agent's answer is the page it wrote. Shown
    /// anew only when it changed.
    func refreshPage(_ turn: PageTurn) async {
        guard let dataURL = await fetchServerFile(turn.path, fileSource),
              let fetched = ServeMedia.attachment(dataURL: dataURL, name: String(turn.path.split(separator: "/").last ?? "page.html")),
              let shown = messages.first(where: { $0.id == turn.message })?.attachments.first(where: { $0.page == turn.path }),
              fetched.data != shown.data else { return }
        update(turn.message) { message in
            guard let i = message.attachments.firstIndex(where: { $0.page == turn.path }) else { return }
            message.attachments[i] = AgentPage.attachment(fetched, from: turn.path)
        }
    }

    /// Where the files this chat's replies name are on the server.
    var fileSource: FileSource { FileSource(sessionID: serverSessionID, profile: routeProfile ?? settings.profileName) }

    /// How many replies of a chat opened from the server have their files fetched again.
    static let reopenedMediaReach = 8

    /// A chat opened from the server comes back as text: the files its replies delivered are
    /// bare paths again, pictures and sound alike, and the pictures sent with its messages are
    /// `@image:` lines (from Hermes Desktop, or Redde on another device; GitHub issue 18). The
    /// newest of them are fetched once more, newest first; older ones stay as they are written.
    func resolveReopenedMedia() {
        reopenedMedia?.cancel()
        guard settings.transport == .hermesServe || (settings.transport == .hermesSessions && dashboard.hasCredentials) else { return }
        let opened = id
        let replies = messages.reversed().lazy.filter { !ServeMedia.candidates(in: $0.text).isEmpty }
            .prefix(Self.reopenedMediaReach).map(\.id)
        guard !replies.isEmpty else { return }
        reopenedMedia = Task { [weak self] in
            for reply in replies {
                guard let self, !Task.isCancelled, id == opened else { return }
                await resolveServeMedia(reply)
            }
            guard let self, !Task.isCancelled, id == opened else { return }
            persist()
        }
    }

    /// Throws away text deltas buffered for this reply, keeping any pending reasoning. Used when
    /// the backend sends its own final text for the turn.
    func discardPendingText(for id: UUID) {
        guard pendingFor == id else { flushDeltas(); return }
        pendingText = ""
        if pendingReasoning.isEmpty {
            flushTask?.cancel()
            flushTask = nil
        }
    }

    func flushDeltas() {
        flushTask?.cancel()
        flushTask = nil
        guard let id = pendingFor, !(pendingText.isEmpty && pendingReasoning.isEmpty && pendingUsage == nil) else { return }
        let text = pendingText, reasoning = pendingReasoning, usage = pendingUsage
        pendingText = ""; pendingReasoning = ""; pendingUsage = nil
        update(id) { message in
            message.text += text
            message.reasoning += reasoning
            if !reasoning.isEmpty, message.reasoningStartedAt == nil { message.reasoningStartedAt = .now }
            if !text.isEmpty, message.reasoningStartedAt != nil, message.reasoningEndedAt == nil { message.reasoningEndedAt = .now }
            if let usage { message.metrics?.usage = usage }
        }
    }

    // MARK: Tool details

    /// Whether `loadToolDetails` has anything to ask: a server session and the Hermes API.
    var canLoadToolDetails: Bool {
        serverSessionID != nil && settings.gatewayBaseURL != nil && !(settings.gatewayAPIKey ?? "").isEmpty
    }

    /// Fills in what a reply's tools were called with and what they returned, from the gateway's
    /// stored transcript. The Hermes API's stream names a finished tool without its result, and
    /// a reopened session's rows leave results out; the stored messages have them. A Dashboard
    /// conversation can use this too when the Hermes API is set up: both write one ledger.
    func loadToolDetails(for id: UUID) async {
        guard let sessionID = serverSessionID, let base = settings.gatewayBaseURL, let key = settings.gatewayAPIKey, !key.isEmpty,
              let local = messages.first(where: { $0.id == id }), !local.tools.isEmpty,
              let stored = try? await HermesSessionsAPI(baseURL: base, apiKey: key, headers: settings.apiHeaders).messages(sessionID: sessionID),
              let found = Self.storedTools(for: local, in: Self.mapStored(stored)) else { return }
        update(id) { message in
            for (i, tool) in found.enumerated() where i < message.tools.count {
                if message.tools[i].args == nil { message.tools[i].args = tool.args }
                if message.tools[i].output == nil { message.tools[i].output = tool.output }
            }
        }
        persist()
    }

    /// The tools of the stored reply that is `local`: the same tools in the same order, and the
    /// same text when several fit (else the newest of them).
    nonisolated static func storedTools(for local: Message, in stored: [Message]) -> [ToolActivity]? {
        let names = local.tools.map(\.name)
        let fits = stored.filter { $0.role == .assistant && $0.tools.map(\.name) == names }
        let text = local.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (fits.last { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == text } ?? fits.last)?.tools
    }

    // MARK: Quotes

    /// "Quote": the message goes above the composer for the next one to quote.
    func quote(_ message: Message, speaker: String?, mine: Bool = false) {
        let text = Quote.excerpt(message.text)
        guard !text.isEmpty else { return }
        quoting = QuotedText(text: text, speaker: speaker, messageID: message.id, mine: mine)
    }

    /// A tap on a quote in the chat: the message it came from, if this device has it.
    func reveal(quote: String, in messageID: UUID) {
        guard let source = Quote.source(of: quote, in: messages, before: messageID) else { return }
        revealRequest = RevealRequest(id: source, count: (revealRequest?.count ?? 0) + 1)
    }

    // MARK: Follow-ups

    #if DEBUG
    func showFollowUpsForDemo(_ suggestions: [String]) { followUps = suggestions }
    #endif

    func clearFollowUps() {
        followUpTask?.cancel()
        followUpTask = nil
        followUps = []
    }

    /// Suggested replies to a finished reply (`FollowUps`): from Apple's on-device model where
    /// there is one, else the fast lane's; shown only while that reply is still the last message.
    func suggestFollowUps(question: String, replyID: UUID, reply: String) {
        guard settings.suggestFollowUps, !reply.isEmpty, !isWorkerTranscript else { return }
        let base = Settings.normalizedBase(settings.fastLaneURL)
        let fastLane = base != nil && !settings.fastLaneModel.isEmpty
        let source = FollowUps.source(fastLaneSet: fastLane)
        guard source != .none else { return }
        let (model, key) = (settings.fastLaneModel, fastLane ? Keychain.read(.fastLaneAPIKey) : nil)
        followUpTask = Task { [weak self] in
            let suggestions = switch source {
            case .onDevice: await FollowUps.suggestOnDevice(question: question, reply: reply)
            case .fastLane: await FollowUps.suggest(question: question, reply: reply, baseURL: base!, apiKey: key, model: model)
            case .none: [String]()
            }
            guard let self, !Task.isCancelled, messages.last?.id == replyID, !isStreaming else { return }
            followUps = suggestions
        }
    }

    func fail(_ id: UUID, _ description: String) {
        flushDeltas()
        lastError = description
        TurnActivity.shared.fail(description)
        Notifier.shared.notify(.failed, title: String(localized: "Redde couldn't reply"), body: description, session: serverSessionID)
        // A paired Hermes will say so too, minutes later: that note then arrives quietly.
        if let serverSessionID { ToldAlready.failed(session: serverSessionID) }
        update(id) { message in
            message.error = description
            if message.text.isEmpty { message.text = "⚠️ \(description)" }
        }
        isStreaming = false
    }
}
