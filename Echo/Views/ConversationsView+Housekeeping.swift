import SwiftUI

// The chat list's refresh and what its rows do to a chat: rename, pin, archive, fork, delete, open.

extension ConversationsList {
    func refresh() async {
        loading = true
        defer { loading = false }
        // An answer from before a server or profile switch belongs to the old list: drop it.
        let key = settings.connectionKey
        var current: Bool { key == settings.connectionKey && !Task.isCancelled }
        #if DEBUG
        // Dev hook: `-echo.demoProjects` fills the list from a fixture, so the project-folder
        // path can be driven without a gateway.
        // (The agents video's demo agent, saved beside it, lists its own chats.)
        if DevHooks.demoProjects, !(DemoAgents.on && settings.transport == .acp) {
            projects = Self.demoProjects
            folders = Self.demoProjects
            ledger = Self.demoProjects.flatMap { $0.lanes.flatMap(\.sessions) } + Self.demoScheduledRuns
            // `-echo.demoAllServers`: two chats of another server's among them (All Servers).
            if DevHooks.has("-echo.demoAllServers") {
                ledger = (ledger + Self.demoOtherServer).sorted { ($0.lastActiveDate ?? .distantPast) > ($1.lastActiveDate ?? .distantPast) }
                serversUnreachable = ["Cabin"]
            }
            if DevHooks.demoBots {
                botDirectory.set(Self.demoBots, key: settings.connectionKey)
                groups.set(rooms: [.demo, .demoDesktop], supported: true, writable: true, key: settings.connectionKey)
                // `-echo.openGroup [desktop]`: that group chat open, or the Hermes Desktop one (screenshots).
                if DevHooks.has("-echo.openGroup"), !Self.openedDemoGroup {
                    Self.openedDemoGroup = true   // once: the list loads again each time it opens
                    // After the launch's conversation has loaded: a change of conversation closes
                    // a group chat, and the iPad's sidebar gets here before that load is done.
                    let room: GroupRoom = DevHooks.value("-echo.openGroup") == "desktop" ? .demoDesktop : .demo
                    Task {
                        await conversation.initialLoad?.value
                        try? await Task.sleep(for: .milliseconds(300))
                        opened(room: room)
                    }
                }
                // `-echo.botSchedules <bot>`: that bot's schedules open (screenshots).
                if let which = DevHooks.value("-echo.botSchedules") { scheduling = Self.demoBots.bots.first { $0.name == which } }
                // `-echo.botEditor new|<bot>`: New Bot, or that bot's settings, open (screenshots).
                if let which = DevHooks.value("-echo.botEditor") {
                    editingBot = which == "new" ? .new : Self.demoBots.bots.first { $0.name == which }.map { .edit($0) }
                }
            }
            // `-echo.demoDay`: an ordinary day's chats, no projects or group chats (`DemoDay`).
            if DemoDay.on {
                projects = []
                folders = []
                ledger = DemoDay.chats
                groups.set(rooms: [], supported: false, writable: false, key: settings.connectionKey)
            }
            if DevHooks.demoMarks {
                ledger += Self.demoMarkedRows
                activity.showDemo(["demo-1": .working, "demo-marks-2": .needsYou], bots: ["scout": .working, "fixit": .needsYou], unreadBots: ["writer"],
                                  rooms: [GroupRoom.demo.id: .needsYou], unreadRooms: [GroupRoom.demoDesktop.id])
            }
            ledgerError = nil
            return
        }
        #endif
        do {
            guard let backend = SessionBackend.list(conversation) else {
                ledgerError = TransportError.addKeyText
                return
            }
            let sessions = allProfiles
                ? try await SessionBackend.everyProfile(conversation, bots: botDirectory.roster)
                : settings.transport == .acp && settings.acpAllAgents
                ? try await AcpAgents.everyAgent(settings)
                : try await backend.listSessions()
            guard current else { return }
            ledger = sessions
            activity.listed(sessions)
            conversation.noteServerTitles(sessions)
            // Every other saved server's, once they answer: this server's rows don't wait for them.
            if allServers, settings.servers.count > 1 {
                let others = await AllServers.otherServers(settings)
                guard current else { return }
                // One Hermes saved twice (its Dashboard and its API) lists its chats once.
                var seen = Set(sessions.map(\.id))
                let theirs = others.rows.filter { seen.insert($0.id).inserted }
                ledger = (sessions + theirs).sorted { ($0.lastActiveDate ?? .distantPast) > ($1.lastActiveDate ?? .distantPast) }
                serversUnreachable = others.unreachable
            } else {
                serversUnreachable = []
            }
            // Bots and projects are a bonus; a failure here must not hide the flat list.
            if botsHere, settings.showBots {
                if apiBotsOnly {
                    activity.listed(await botDirectory.refreshAPI().bots)
                } else {
                    if let roster = try? await botDirectory.refresh() { activity.listed(roster.bots) }
                    await groups.refresh()
                    activity.listed(groups.rooms)
                }
            }
            if settings.transport == .acp {
                projects = AcpProjects.make(sessions)
            }
            if viaServe {
                let all = (try? await HermesServeClient.shared.projectTree()) ?? []
                let tree = HermesServeClient.Project.listed(all)
                guard current else { return }
                ProjectDirectory.shared.set(all, key: key)
                projects = tree
                folders = all.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
            }
            ledgerError = nil
        } catch {
            // A refresh cut short (tab switched, server changed) is not an error to show.
            guard current, !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
            ledgerError = error.localizedDescription
        }
    }

    // MARK: - Housekeeping

    private func housekeeping(_ session: HermesSessionsAPI.SessionSummary, _ work: @escaping () async throws -> Void) {
        Task {
            do { try await work(); await refresh() } catch { ledgerError = error.localizedDescription }
        }
    }

    func rename(_ session: HermesSessionsAPI.SessionSummary, to title: String) {
        renaming = nil
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        let kind = session.otherServer.flatMap { tag in settings.servers.first { $0.id == tag.id }?.transport } ?? settings.transport
        guard kind == .acp else {
            housekeeping(session) {
                try await SessionBackend.owning(session, conversation)?.rename(session.id, to: t)
            }
            return
        }
        // A bridge chat: named here at once, then on the agent (or its bridge) where it keeps
        // names, which every device then shows; this device's name goes once it has.
        AcpTitles.set(t, for: session.id)
        if let i = ledger.firstIndex(where: { $0.id == session.id }) { ledger[i].title = t }
        conversation.noteServerTitles([HermesSessionsAPI.SessionSummary(id: session.id, title: t)])
        Task {
            if (try? await SessionBackend.owning(session, conversation)?.rename(session.id, to: t)) != nil {
                AcpTitles.set(nil, for: session.id)
            }
            await refresh()
        }
    }

    func setPinned(_ session: HermesSessionsAPI.SessionSummary, _ pinned: Bool) {
        housekeeping(session) {
            try await SessionBackend.owning(session, conversation)?.setPinned(session.id, pinned)
        }
    }

    /// The open conversation changed: both have just been marked read on the host (the one left,
    /// the one opened), and the rows say so now rather than at the next fetch.
    func openChanged(from old: String?, to new: String?) {
        for id in [old, new].compactMap(\.self) {
            if let i = ledger.firstIndex(where: { $0.id == id }), ledger[i].unread == true { ledger[i].unread = false }
        }
        // A chat the list doesn't have yet (just started here) goes into it now, and again a
        // moment later with the name its agent gave it. The iPad's sidebar is always up, so the
        // list's own reload on opening never came, and an agent's chat (no live list to watch)
        // stayed out of it: "No conversations yet" beside the chat.
        if let new, usesLedger, isShowing, !ledger.contains(where: { $0.id == new }) {
            Task {
                await refresh()
                try? await Task.sleep(for: .seconds(4))
                await refresh()
            }
        }
    }

    /// Mark as Read / Mark as Unread. A row the host marks (the Dashboard's) changes at once.
    func setUnread(_ session: HermesSessionsAPI.SessionSummary, _ unread: Bool) {
        if let i = ledger.firstIndex(where: { $0.id == session.id }), ledger[i].unread != nil { ledger[i].unread = unread }
        if unread {
            activity.markUnread(session.id, conversation: conversation)
        } else {
            activity.markRead(session.id, conversation: conversation)
        }
    }

    /// While the list is on screen: what the host is doing, every few seconds (a turn under way,
    /// one waiting on the person), and the conversations fetched again when a turn ends or, at
    /// most every thirty seconds, when the Dashboard says they changed.
    func watchActivity() async {
        guard usesLedger, isShowing, scenePhase == .active, pace.onScreen else { return }
        #if DEBUG
        if DevHooks.demoProjects { return }
        #endif
        var fetchedAt = Date.now
        var botsAt = Date.now
        var changes = activity.changes
        var waitsAt = Date.distantPast
        while !Task.isCancelled {
            let before = Set(activity.live.keys), roomsBefore = Set(activity.liveRooms.keys)
            let reached = await activity.look(conversation)
            // The bots' waits for the drawer, in the same wake: at most every 20 s (a minute in
            // Low Power Mode), however busy the list is.
            if reached, Date.now.timeIntervalSince(waitsAt) >= (pace.saving ? 60 : 20) {
                waitsAt = .now
                await lookForBotWaits()
            }
            let ended = !before.subtracting(activity.live.keys).isEmpty
            let changed = activity.changes != changes && Date.now.timeIntervalSince(fetchedAt) >= 30
            if ended || changed {
                changes = activity.changes
                fetchedAt = .now
                botsAt = .now
                await refresh()
            } else if !roomsBefore.subtracting(activity.liveRooms.keys).isEmpty {
                // A group chat went quiet: the group chats alone again, for what is new in it (the
                // whole list was fetched again for each bot's turn, some seven calls a time).
                await groups.refresh()
                activity.listed(groups.rooms)
            } else if botsHere, settings.showBots,
                      Date.now.timeIntervalSince(botsAt) >= (activity.isBusy(conversation) ? 15 : (pace.saving ? 180 : 60)) {
                // The bots' chats and workers, which the gateway's list doesn't all show (a bot's
                // worker runs on its own): their last activity, now and then.
                botsAt = .now
                if apiBotsOnly {
                    activity.listed(await botDirectory.refreshAPI().bots)
                } else {
                    if let roster = try? await botDirectory.refresh() { activity.listed(roster.bots) }
                    // The group chats' latest events, for what is new in them.
                    await groups.refresh()
                    activity.listed(groups.rooms)
                }
            }
            // Every few seconds while something is under way; while nothing is, now and then, or
            // at once when the Dashboard says its conversations changed (a turn another device
            // started). A host that can't be asked is asked less often.
            await activity.nap(for: reached ? pace.wait(busy: activity.isBusy(conversation), .seconds(4), idle: .seconds(20))
                                             : pace.wait(busy: false, .seconds(30), idle: .seconds(30)))
        }
    }

    /// Archived sessions leave the list but stay in Hermes's database (the dashboard can restore them).
    func archive(_ session: HermesSessionsAPI.SessionSummary) {
        ledger.removeAll { $0.id == session.id }
        housekeeping(session) {
            try await SessionBackend.owning(session, conversation)?.archive(session.id)
            if session.id == conversation.serverSessionID { conversation.reset() }
        }
    }

    /// Fork copies the transcript into a new session and opens it.
    func fork(_ session: HermesSessionsAPI.SessionSummary) {
        let title = "\(session.displayTitle) (fork)"
        housekeeping(session) {
            if let forked = try await SessionBackend.owning(session, conversation)?.fork(session.id, title: title) {
                try await load(forked)
                opened()
            }
        }
    }

    func delete(_ session: HermesSessionsAPI.SessionSummary) {
        ledger.removeAll { $0.id == session.id }
        housekeeping(session) {
            try await SessionBackend.owning(session, conversation)?.delete(session.id)
            if let local = store.summaries.first(where: { $0.serverSessionID == session.id }) { conversation.delete(id: local.id) }
        }
    }

    /// Swaps the transcript to this session. Throws, so callers can show what went wrong.
    func load(_ session: HermesSessionsAPI.SessionSummary) async throws {
        // Another server's: the app moves to that server, and opens it there as one of its own.
        if let server = session.otherServer {
            guard settings.servers.contains(where: { $0.id == server.id }) else { throw AllServers.Gone(name: server.name) }
            ServerSwitcher.switchTo(server.id, conversation: conversation)
            var own = session
            own.otherServer = nil
            return try await load(own)
        }
        // Another profile's opens in that profile, by the way it was listed.
        if let route = session.elsewhere {
            if route.viaAPI {
                try await conversation.loadLedgerSession(session, elsewhere: route)
            } else {
                try await conversation.loadServeSession(session, elsewhere: route)
            }
        } else if settings.transport == .acp {
            // With every agent in one list, the app moves to the chat's agent.
            AcpAgents.use(session.acpAgent, settings)
            try await conversation.loadAcpSession(session)
        } else if viaServe {
            try await conversation.loadServeSession(session)
        } else {
            try await conversation.loadLedgerSession(session)
        }
        opened()
    }

    /// Opens a conversation; `find` opens Find in it on those words once it is on screen.
    func open(_ session: HermesSessionsAPI.SessionSummary, find: String? = nil) {
        opening = session.id
        Task {
            do {
                try await load(session)
                if let find { conversation.findRequest = find }
                savedCopyOffered = nil
            } catch {
                ledgerError = error.localizedDescription
                savedCopyOffered = store.summaries.first { $0.serverSessionID == session.id }?.id
            }
            opening = nil
        }
    }
}
