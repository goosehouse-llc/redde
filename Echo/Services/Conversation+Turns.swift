// Conversation's turns: sending, steering, running a turn and applying its events.
import Foundation
import WidgetKit

extension Conversation {
    // MARK: - Actions

    /// Sends one user turn. The returned stream mirrors the transport events for callers that
    /// want them live (the voice loop); the transcript is updated regardless.
    /// `brief`: asked by voice in a car, for an answer short enough to follow there
    /// (`CarBrevity`). `live`: handed over by GPT-Live (`LiveTurn`). A message that has to wait
    /// its turn goes out later as an ordinary one.
    @discardableResult
    func send(_ text: String, attachments: [Attachment] = [], brief: Bool = false, live: LiveTurn? = nil) -> AsyncStream<TurnEvent> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return Self.finishedStream() }
        guard !isWorkerTranscript else {
            lastError = String(localized: "This is a Kanban worker's run. To go on with it, retry or unblock its card on the board.")
            return Self.finishedStream()
        }
        relayHops = 0   // the person has written: the agents may ask each other again
        dropProposedAsks()   // and has moved on from what its agent wanted to ask
        // A normal chat's message that tags bots goes to them (`BotAsides`): the open Hermes's, an
        // agent on a saved bridge, another server's (`TagRoster`).
        if attachments.isEmpty, case let roster = tagRoster, !roster.isEmpty {
            let tagged = BotAsides.tagged(in: trimmed, roster: roster, speaking: tagSpeaker)
            if !tagged.isEmpty {
                ask(trimmed, of: tagged)
                return Self.finishedStream()
            }
        }
        // A chat from before the connection type changed: it stays as it was, and this message
        // starts a new chat on the connection in use.
        if serverSessionID != nil, !sessionFitsConnection, !isStreaming, outbox.isEmpty { reset() }
        userSendCount += 1
        var userMessage = Message(role: .user, text: trimmed)
        userMessage.attachments = attachments
        userMessage.answering = pendingAnswering
        pendingAnswering = nil
        // A reply is still streaming, or earlier messages are still waiting: this one goes behind them.
        if isStreaming || !outbox.isEmpty {
            let waiting = outbox.first?.state == .waitingForConnection
            outbox.append(OutboxItem(message: userMessage, state: waiting ? .waitingForConnection : .queued, queuedAt: .now))
            lastSendWasHeld = true
            persist()
            if !isStreaming { retryOutbox() }
            return Self.finishedStream()
        }
        return startTurn(userMessage, brief: brief, live: live)
    }

    /// What a page in a reply sends the agent (`window.hermes.send`, `data-hermes-send`): a turn
    /// with no message of the person's to show, as the desktop app sends one. The agent answers by
    /// writing the page again, so the page is read again once it has (`refreshPage`).
    func sendFromPage(_ prompt: String, page: String, in messageID: UUID) -> PageSend {
        guard connection.isHermes else { return .unavailable }
        guard !isStreaming, outbox.isEmpty else { return .busy }
        // A page is the agent's, in a conversation it has: never the first message of a new one.
        guard serverSessionID != nil else { return .unavailable }
        startTurn(Message(role: .user, text: prompt), fromPage: PageTurn(message: messageID, path: page))
        return .sent
    }

    private static func finishedStream() -> AsyncStream<TurnEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: TurnEvent.self)
        continuation.finish()
        return stream
    }

    /// Runs one turn for a user message that isn't in the transcript yet. `heldSince` is when a
    /// message coming out of the outbox was first queued, so holding it again keeps its age.
    /// `unseen`: Redde's, not the person's (the answers to the agent's own tags, `relayTags`), not shown.
    @discardableResult
    func startTurn(_ outgoing: Message, heldSince: Date? = nil, brief: Bool = false, live: LiveTurn? = nil,
                           fromPage: PageTurn? = nil, unseen: Bool = false) -> AsyncStream<TurnEvent> {
        let (mirror, mirrorContinuation) = AsyncStream.makeStream(of: TurnEvent.self)
        lastSendWasHeld = false
        turnFromOutbox = false
        lastError = nil
        clearFollowUps()
        // Only the fast lane sends history; the ledger transports keep theirs on the server.
        let history = connection == .chatCompletions ? messages.filter { $0.error == nil } : []
        var userMessage = outgoing
        userMessage.createdAt = .now   // a held message is stamped when it actually goes out
        let trimmed = userMessage.text
        let attachments = userMessage.attachments
        let userID = userMessage.id
        // The person's own message: shown, and the notes Redde owes the agent go with it.
        let shown = fromPage == nil && !unseen
        if shown { messages.append(userMessage) }
        var reply = Message(role: .assistant, text: "")
        reply.beginsAssistantTurn = !shown
        reply.metrics = TurnMetrics(sentAt: .now)
        messages.append(reply)
        let replyID = reply.id

        // Held messages of a chat whose session is another kind of connection's: a new session here.
        if serverSessionID != nil, !sessionFitsConnection { serverSessionID = nil }
        let hermesModel = settings.transport == .chatCompletions ? nil : turnModel
        var request = TurnRequest(
            userText: trimmed,
            history: history,
            sessionID: connection.hasLedger ? serverSessionID : nil,
            model: settings.transport == .chatCompletions ? settings.fastLaneModel : hermesModel?.model,
            provider: hermesModel?.provider,
            reasoningEffort: settings.reasoningEffort.nilIfEmpty,
            instructions: nil,
            attachments: attachments,
            replyLanguage: settings.replyLanguage.nilIfEmpty,
            brief: brief
        )
        if connection == .acp, serverSessionID == nil { request.folder = startsIn?.path }
        if connection == .hermesServe, serverSessionID == nil {
            request.folder = startsIn?.path
            request.profile = bot == nil ? elsewhere?.profile : nil
        }
        request.incognito = isIncognito
        request.fromPage = fromPage != nil
        request.live = live
        if let call = answeringCall, fromPage == nil {
            answeringCall = nil
            if Date.now.timeIntervalSince(call.at) < 600 { request.answeringCall = call.line }
        }
        // The Hermes API's run for this message, should it go again after a dropped connection.
        request.turnKey = userID.uuidString
        // A place question with Current Location on: the place kept goes with it as it is (never
        // waited for), and a fresh fix is asked for if that one is a few minutes old.
        if CurrentLocation.isOn, CurrentLocation.asksPlace(trimmed) { CurrentLocationService.shared.refresh() }
        // Who it can ask by @name, when this chat hasn't been told (`RosterNote`); before the asides'
        // note, which is read back from the end.
        if shown, let note = rosterNote() { request.userText += note }
        // Asides to tagged bots since the agent last heard: told with this message, kept with it on the host.
        if connection.isHermes || connection == .acp, shown, let note = AsideNote.note(for: AsideNote.pending(in: messages)) {
            request.userText += note
            for i in messages.indices where messages[i].isAside { messages[i].delivered?.noted = true }
        }
        // Agents the person said no to asking: told, so the agent doesn't wait on them.
        if shown, let note = DeclinedNote.note(pendingDeclined) {
            request.userText += note
            pendingDeclined = []
        }
        // Reactions since the person last wrote (`Reactions`): told with this message, once.
        if shown, let note = ReactionNote.note(unsaidReactions()) {
            request.userText += note
            for i in messages.indices where messages[i].reaction != nil { messages[i].reactionSaid = true }
        }
        // On this message alone, last: "Make This a Routine"'s, or a card's answer.
        if let note = pendingNote, shown {
            request.userText += note
            pendingNote = nil
        }
        // The conversation's fast mode: the Hermes API keeps none for a session, so each turn asks.
        if connection == .hermesSessions, let stored = serverSessionID, store === ConversationStore.shared {
            request.fast = RunChatControls.shared.isFast(stored)
        }
        // A bot's chat: the other bots the message tags, and the note that says which they are.
        if connection == .hermesServe, let bot, settings.hermesBotsTalk {
            let mentioned = BotMentions.mentioned(in: trimmed, roster: BotDirectory.shared.bots(for: settings.connectionKey), to: bot.profile)
            request.mentionNote = BotMentions.note(for: mentioned)
        }
        let departure = TurnDeparture()
        self.departure = departure
        request.departure = departure
        guard let transport = makeTransport() else {
            fail(replyID, settings.isConfigured ? TransportError.badURL.localizedDescription
                                                : String(localized: "No connection is set up yet. Go to Settings → Connection → Set up connection…."))
            pauseQueue()
            mirrorContinuation.finish()
            return mirror
        }

        isStreaming = true
        // An incognito chat's words stay in the app: not on the Lock Screen or in a widget.
        // Both say who is answering: the bot in its chat, else the main agent ("Sol is thinking").
        TurnActivity.shared.start(question: isIncognito ? IncognitoNote.title : trimmed, agent: answeringName)
        BackgroundTurn.shared.begin(question: isIncognito ? IncognitoNote.title : trimmed, agent: answeringName)
        turnSerial += 1
        let myTurn = turnSerial
        let transportKind = connection
        let fastLaneBase = transportKind == .chatCompletions ? settings.activeBaseURL : nil
        let fastLaneModel = settings.fastLaneModel
        let fallbackWindow = settings.contextWindow
        streamTask = Task { [weak self] in
            guard let self else { return }
            var outcome = TurnOutcome.failed
            // Resolve the context window in parallel with the request; cached after the first turn.
            let windowTask = Task { () -> Int in
                if let fastLaneBase,
                   let detected = await ContextWindowProbe.window(fastLaneBase: fastLaneBase, model: fastLaneModel,
                                                                  apiKey: Keychain.read(.fastLaneAPIKey)) {
                    return detected
                }
                return fallbackWindow
            }
            do {
                // A new conversation takes its model and provider at create, from a pick that
                // may be older than the host's current providers; later turns are pinned.
                if transportKind.isHermes, request.sessionID == nil, let model = request.model?.nilIfEmpty {
                    let provider = Self.liveProvider(for: model, saved: request.provider, in: await listedModels())
                    if provider != request.provider {
                        request.provider = provider
                        if unsentModel?.model == model { unsentModel?.provider = provider }
                    }
                }
                // Ledger transport: the session row must exist before the first turn.
                if transportKind == .hermesSessions, request.sessionID == nil {
                    guard let api = ledgerAPI() else { throw TransportError.noAPIKey }
                    let created = try await api.createSession(title: Self.sessionTitle(from: trimmed),
                                                              model: request.model, provider: request.provider,
                                                              reasoningEffort: request.reasoningEffort)
                    serverSessionID = created.id
                    request.sessionID = created.id
                    if isIncognito { Incognito.add(.init(session: created.id, server: settings.activeServerID.uuidString, transport: .hermesSessions)) }
                }
                // The Hermes API takes text and pictures: other files go to the server through the
                // Dashboard's login, and the message says where they are.
                if transportKind == .hermesSessions, request.attachments.contains(where: { $0.kind == .pdf || $0.kind == .other }),
                   await dashboard.canUse() {
                    statusLine = String(localized: "putting the file on the server…")
                    request = try await Self.placingFiles(request)
                }
                // Pictures go in the run itself, but the Hermes API keeps none of them, only a
                // "[screenshot]" in their place, so the chat opened anywhere else had no picture
                // (GitHub issue 18). With the Dashboard's login a copy goes to the server too, and
                // the message names it as Hermes Desktop's pictures are named.
                if transportKind == .hermesSessions, request.attachments.contains(where: { $0.kind == .image }),
                   dashboard.hasCredentials {
                    request = await Self.namingPictures(request)
                }
                for try await event in transport.stream(request) {
                    mirrorContinuation.yield(event)
                    apply(event, to: replyID)
                }
                // An AsyncThrowingStream ends quietly on cancellation; don't report that as a reply.
                try Task.checkCancellation()
                flushDeltas()
                // Serve hands MEDIA:<path> tags through verbatim, and the sessions API only
                // inlines small images — both daemons share the Hermes host's filesystem, so the serve
                // file API can fetch what either transport left as a bare path. Runs before the
                // reply is persisted, notified, and mirrored to the widget.
                // (On the Hermes API, the Dashboard is asked only when the reply names a file.)
                var fetchesFiles = transportKind == .hermesServe
                if !fetchesFiles, transportKind == .hermesSessions, replyNamesFiles(replyID) { fetchesFiles = await dashboard.canUse() }
                // An agent through the bridge: from the bridge's computer, where the bridge hands files over.
                if transportKind == .acp, replyNamesFiles(replyID) { fetchesFiles = fetchesReplyFiles }
                if fetchesFiles {
                    await resolveServeMedia(replyID)
                    try Task.checkCancellation()   // Stop during the fetch must not finish the turn
                    if let fromPage { await refreshPage(fromPage) }
                }
                if transportKind == .hermesSessions {
                    await settleTodos(replyID)
                    await settleCards(replyID)
                    try Task.checkCancellation()
                }
                let window = await windowTask.value
                try Task.checkCancellation()
                update(replyID) { message in
                    message.metrics?.completedAt = .now
                    message.metrics?.characters = message.text.count
                    message.metrics?.contextWindow = window
                    if message.reasoningStartedAt != nil, message.reasoningEndedAt == nil { message.reasoningEndedAt = .now }
                }
                let replyText = messages.last { $0.id == replyID }?.text ?? ""
                TurnActivity.shared.finish(reply: isIncognito ? IncognitoNote.replied : replyText)
                if !replyText.isEmpty, shown, !settings.requireBiometrics, !isIncognito {   // a locked app shouldn't print replies on the Home Screen
                    WidgetSnapshot.save(question: trimmed, reply: replyText)
                    WidgetCenter.shared.reloadTimelines(ofKind: "com.goosehouse.echo.lastreply")
                }
                let incognito = isIncognito
                Notifier.shared.notify(.replied, title: String(localized: "Redde replied"), body: incognito ? IncognitoNote.replied : PlainText.display(replyText),   // autoclosure: only stripped when a banner will post
                                       category: Notifier.repliedCategory, userInfo: [Notifier.conversationKey: self.id.uuidString], session: serverSessionID,
                                       messageEntityID: SiriID.message(self.id, replyID))
                persist()
                outcome = .completed
                noteSeen(onlyOnScreen: true)
                suggestFollowUps(question: unseen ? asked(before: replyID) ?? trimmed : trimmed, replyID: replyID, reply: replyText)
            } catch is CancellationError {
                windowTask.cancel()
                flushDeltas()
                persist()
                outcome = .cancelled
            } catch {
                windowTask.cancel()
                if myTurn != turnSerial {
                    // A superseded turn's tail erroring late: record it on its own reply, but
                    // never through fail(), which resets isStreaming/lastError and would let
                    // the UI start a second turn while the live one still streams.
                    update(replyID) { $0.error = error.localizedDescription }
                } else if shown, NetworkFailure.isConnectivity(error), replyIsBlank(replyID) {
                    // Never reached the server: hold the message instead of reporting a failure.
                    hold(userID: userID, replyID: replyID, queuedAt: heldSince ?? .now)
                    outcome = .held
                } else if transportKind == .chatCompletions, BackgroundTurn.shared.expired, NetworkFailure.isConnectivity(error) {
                    fail(replyID, Self.backgroundCutoff)
                } else {
                    fail(replyID, error.localizedDescription)
                }
            }
            // Seen through, failed or stopped here: the run needn't be asked after. Left, it is.
            if transportKind == .hermesSessions, !departure.hasLeft, let stored = request.sessionID, store === ConversationStore.shared {
                ChatActivity.shared.turnEnded(sessionID: stored, settings: settings)
            }
            // Only the current turn may reset shared state; a cancelled turn's tail must not
            // clobber the turn that replaced it.
            if myTurn == turnSerial {
                clearStatus()
                isStreaming = false
                currentRunID = nil
                settleWaiting()   // a turn that is over waits on nothing, whatever became of its card
                publishContext()
                BackgroundTurn.shared.end(success: outcome == .completed)
                switch outcome {
                case .completed:
                    retryAttempt = 0
                    retryOutbox()
                    // Other agents it asked by @name: asked, and their answers given back to it.
                    if fromPage == nil, !isStreaming, outbox.isEmpty { relayTags(from: replyID) }
                case .held: scheduleRetry()
                case .cancelled, .failed: pauseQueue()
                }
            }
            mirrorContinuation.finish()
        }
        return mirror
    }

    /// A turn's files the Hermes API can't take (anything but pictures and text), put in
    /// "Redde attachments" in the server's home through the Dashboard, and named in the message
    /// instead (`AttachedFileNote`): the agent reads them there with its own tools.
    static func placingFiles(_ request: TurnRequest, client: some ServerFileBrowsing = HermesServeClient.shared) async throws -> TurnRequest {
        var request = request
        let files = request.attachments.filter { $0.kind == .pdf || $0.kind == .other }
        guard !files.isEmpty else { return request }
        for placed in try await ServerFiles.place(files, client: client) { request.userText += AttachedFileNote.note(path: placed.path) }
        request.attachments.removeAll { $0.kind == .pdf || $0.kind == .other }
        return request
    }

    /// A turn's pictures, each put on the server through the Dashboard (its own pictures folder,
    /// as the Dashboard's chat puts them) and named on a line of the message (`@image:`), which
    /// is how Hermes keeps a picture with a session for every other client to show. One that
    /// can't be put there still goes with the run, unnamed, as before.
    static func namingPictures(_ request: TurnRequest,
                               upload: (Attachment) async throws -> String = { try await HermesServeClient.shared.uploadPicture($0) }) async -> TurnRequest {
        var request = request
        for picture in request.attachments where picture.kind == .image {
            guard let path = try? await upload(picture) else { continue }
            request.userText += "\n" + ServeMedia.pictureRef(path)
        }
        return request
    }

    /// One event of a turn, written into its reply.
    func apply(_ event: TurnEvent, to replyID: UUID) {
        switch event {
        case let .textDelta(delta):
            clearStatus()
            interruptResolvedElsewhere()
            TurnActivity.shared.replyDelta(delta)
            markFirstToken(replyID)
            buffer(text: delta, for: replyID)
        case let .textFinal(text):
            // Drop the buffered deltas rather than flushing them: this text replaces
            // them, and appending first would duplicate the whole reply.
            clearStatus()
            markFirstToken(replyID)
            discardPendingText(for: replyID)
            // Inline data-URL images become photo attachments, like a received MMS.
            let (clean, images) = InlineImages.extract(from: text)
            update(replyID) { $0.text = clean; $0.attachments = images }
        case let .interim(text, alreadyStreamed):
            // Working text beside a tool call: it goes with the steps, and the reply starts again.
            flushDeltas()
            update(replyID) { message in
                let note = alreadyStreamed ? message.text : text
                if !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    message.notes.append(WorkingNote(text: note, afterTools: message.tools.count))
                }
                if alreadyStreamed { message.text = "" }
            }
        case let .status(status):
            statusLine = status
        case let .prefill(processed, total, cached):
            // Only worth surfacing when the prompt is big enough to take real time;
            // a short prompt would just flash "100%". Cleared by the first token.
            if total - cached >= 512 {
                let share = Double(min(100, processed * 100 / total)) / 100
                statusLine = String(localized: "Processing prompt… \(share.formatted(.percent.precision(.fractionLength(0))))")
            }
        case let .usage(usage):
            // hermes serve ticks this every few hundred ms; it rides the next flush.
            // Retarget the buffer first: with pendingUsage set, the flush that
            // retargeting triggers would write this tick onto the previous reply.
            buffer(for: replyID)
            pendingUsage = usage
        case let .reasoningDelta(delta):
            clearStatus()
            // Reasoning tokens count toward the reply, so the decode clock starts here too.
            markFirstToken(replyID)
            buffer(reasoning: delta, for: replyID)
        case let .toolStarted(name, preview, args):
            flushDeltas()
            clearStatus()
            TurnActivity.shared.tool(name)
            // One of the phone's own tools: the plugin is holding a request for this iPhone.
            if settings.phoneTools.on {
                phoneTools.toolStarted(name) { [weak self] picture in self?.update(replyID) { $0.attachments.append(picture) } }
            }
            update(replyID) { message in
                let step = ToolActivity(name: name, preview: preview, status: .running, startedAt: .now, args: args)
                message.tools.append(step)
                // A map, places, the weather: shown as soon as the call is made.
                if let cards = ReplyCards.cards(from: step), !cards.isEmpty { message.cards = (message.cards ?? []) + cards }
            }
        case let .toolFinished(name, failed, output):
            interruptResolvedElsewhere()
            var finished: ToolActivity?
            update(replyID) { message in
                // Match by name when given, else the most recent running tool.
                if let i = message.tools.lastIndex(where: { $0.status == .running && (name.isEmpty || $0.name == name) }) {
                    message.tools[i].status = failed ? .failed : .completed
                    message.tools[i].endedAt = .now
                    if let output { message.tools[i].output = output }
                    finished = message.tools[i]
                    // A card call: the plugin's answer has the weather and the time filled in, and a
                    // call it turned down shows nothing after all.
                    if ReplyCards.carriesCards(message.tools[i].name) {
                        let kept = message.tools.compactMap(ReplyCards.cards(from:)).flatMap { $0 }
                        message.cards = kept.isEmpty ? nil : kept
                    }
                }
            }
            if finished?.name == ReplyCards.tool { Task { await fillCards(replyID) } }
            // One of the person's lists changed (`redde_list`): its tile on the Today row follows.
            if finished?.name == TodayLists.tool, finished?.status == .completed { Task { await TodayLists.shared.refresh() } }
            // The agent's to-do tool: what a finished call wrote, applied to the list so far, is
            // the list now. (The Dashboard says the list itself right after: `.todos`.)
            if let finished, let list = TodoList.after(step: finished, previous: TodoList.latest(in: messages)) {
                update(replyID) { $0.todos = list }
                TurnActivity.shared.tasks(list)
            }
        case let .todos(list):
            update(replyID) { $0.todos = list }
            TurnActivity.shared.tasks(list)
        case let .subagent(u):
            clearStatus()
            if case .started = u.phase { TurnActivity.shared.tool("delegating") }
            update(replyID) { message in
                var row = message.subagents.first { $0.id == u.id }
                    ?? SubagentActivity(id: u.id, goal: u.goal, taskIndex: u.taskIndex, taskCount: u.taskCount, depth: u.depth)
                if !u.goal.isEmpty { row.goal = u.goal }
                if let n = u.toolCount { row.toolCount = n }
                if let s = u.childSessionID { row.childSessionID = s }
                if let m = u.model { row.model = m }
                switch u.phase {
                case .started: row.status = .running
                case let .tool(name): row.lastTool = name; row.status = .running
                case let .progress(text): row.lastTool = text.isEmpty ? row.lastTool : text
                case .dispatched: if row.status == .running { row.status = .dispatched }
                case let .completed(ok, summary, duration):
                    row.status = ok ? .completed : .failed
                    row.summary = summary
                    row.durationSeconds = duration
                }
                if let i = message.subagents.firstIndex(where: { $0.id == u.id }) { message.subagents[i] = row }
                else { message.subagents.append(row) }
            }
        case let .sessionID(id):
            serverSessionID = id
            // An incognito chat's session, to be deleted however the app goes (`Incognito`).
            if isIncognito { Incognito.add(.init(session: id, server: settings.activeServerID.uuidString, transport: connection)) }
            // Saved as soon as the host has a session for it, not only with the reply: if the app
            // doesn't live to see the reply, it can find its way back to it (`catchUp`).
            if questionSavedFor != replyID {
                questionSavedFor = replyID
                persist()
            }
        case let .title(title):
            // The agent's name for the chat, unless it was named on this device (`AcpTitles`) or
            // it's a bot's.
            guard bot == nil, let id = serverSessionID, AcpTitles.title(for: id) == nil else { break }
            setName(Self.name(fromServerTitle: title, firstQuestion: messages.first { $0.role == .user && !$0.isSteer }?.text))
        case let .picture(picture):
            flushDeltas()
            update(replyID) { $0.attachments.append(picture) }
        case let .runID(id):
            currentRunID = id
            // A run goes on on the host whatever becomes of the app: noted, so it can be taken up
            // again if the app doesn't see it through.
            if connection == .hermesSessions, store === ConversationStore.shared, let stored = serverSessionID {
                ChatActivity.shared.noteRun(sessionID: stored, runID: id, profile: apiProfile, settings: settings)
            }
        case let .interrupt(interrupt, runtime):
            flushDeltas()
            pendingInterrupt = (dressed(interrupt), runtime)
            statusLine = String(localized: "waiting for you", comment: "Status under a reply: the agent waits for an answer")
            noteWaiting(interrupt)
            if case let .approval(request) = interrupt {
                Notifier.shared.notifyApproval(request)
                TurnActivity.shared.needsApproval(request)
            } else if case let .clarify(request) = interrupt {
                Notifier.shared.notifyClarify(request)
            } else {
                Notifier.shared.notify(.interrupt, title: Self.interruptTitle(interrupt), body: Self.interruptBody(interrupt), session: serverSessionID)
            }
        case let .interruptExpired(id):
            if pendingInterrupt?.interrupt.id == id { pendingInterrupt = nil; statusLine = String(localized: "request expired", comment: "Status under a reply: the agent's question or approval timed out") }
        case .done:
            break
        }
    }

    /// Steering is possible while a Hermes turn is streaming, or an ACP agent's that takes it.
    var canSteer: Bool {
        isStreaming && (connection.isHermes || (connection == .acp && AcpClient.current(settings)?.info?.steers == true))
    }

    /// Nudge the running turn without cancelling it. Shows in the transcript as a steer note.
    /// `queued`: a message from the outbox sent this way (`sendQueuedNow`), which goes back to the
    /// front of it if the turn won't take it.
    func steer(_ text: String, queued: OutboxItem? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSteer, !trimmed.isEmpty else { return }
        userSendCount += 1
        var note = Message(id: queued?.id ?? UUID(), role: .user, text: trimmed)
        note.isSteer = true
        // Keep the streaming reply last so the live row stays live.
        let insertAt = messages.lastIndex(where: { $0.role == .assistant }) ?? messages.endIndex
        messages.insert(note, at: insertAt)
        let transport = connection
        let stored = serverSessionID
        let runID = currentRunID
        let dashboard = dashboard
        let acp = transport == .acp ? AcpClient.current(settings) : nil
        let noteID = note.id
        run { [weak self] in
            var accepted = false
            do {
                switch transport {
                case .hermesServe:
                    guard let stored else { throw TransportError.malformed("no session to steer") }
                    accepted = try await dashboard.steer(stored: stored, text: trimmed)
                case .hermesSessions:
                    guard let runID, let api = self?.ledgerAPI() else { throw TransportError.malformed("no run to steer") }
                    accepted = try await api.steer(runID: runID, text: trimmed)
                case .acp:
                    guard let stored, let acp else { throw TransportError.malformed("no session to steer") }
                    accepted = try await acp.steer(stored, text: trimmed)
                case .chatCompletions:
                    accepted = false
                }
            } catch {
                // A queued message isn't lost to a failed steer: it waits again.
                if let queued { self?.putBack(queued, note: noteID) }
                throw error
            }
            guard let self else { return }
            if !accepted, let queued { self.putBack(queued, note: noteID) }
            self.statusLine = accepted ? String(localized: "steer queued", comment: "Status under a reply: a message added to the turn is waiting")
                : queued != nil ? String(localized: "The reply was finishing: your message goes after it.", comment: "Status under a reply: a queued message tapped Send Now couldn't join the reply")
                : String(localized: "steer rejected (turn already finishing)")
        }
    }

    /// A queued message the turn wouldn't take: out of the transcript, back at the front of the line.
    private func putBack(_ item: OutboxItem, note: UUID) {
        messages.removeAll { $0.id == note }
        outbox.insert(OutboxItem(message: item.message, state: .queued, queuedAt: item.queuedAt), at: 0)
        persist()
        if !isStreaming { retryOutbox() }
    }

    /// A queued message can join the reply under way instead of waiting for it: there is one to
    /// join, and it is words alone (a steer carries no attachments).
    func canSteer(_ item: OutboxItem) -> Bool {
        canSteer && item.message.attachments.isEmpty && !item.message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private enum TurnOutcome { case completed, cancelled, failed, held }

    /// A direct (stateless) connection dropped because iOS suspended the app mid-reply.
    static let backgroundCutoff = String(localized: "Stopped when Redde went to the background. iOS gives an app about 30 seconds there, so keep Redde open (or the screen awake) for long replies.")
}
