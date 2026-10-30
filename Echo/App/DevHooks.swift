#if DEBUG
#if canImport(AlarmKit)
import AlarmKit
#endif
import EventKit
import Foundation
import os
import UserNotifications
import WidgetKit

/// Debug-only launch hooks for screenshots, demos and live tests; none of this exists in release
/// builds. Every flag the app reads is listed here, and only here.
///
/// Launch arguments (`xcrun simctl launch <device> com.goosehouse.echo <flags>`):
/// - `-echo.demo`: seed the demo conversation. `-echo.demoShort` keeps its first exchange,
///   `-echo.demoTwo` its first two (ending on the checklist and table), `-echo.demoLong` seeds a
///   transcript many screens long, `-echo.demoLibrary` adds a few local conversations
///   (`-echo.demoSaved`: the same as copies of conversations on the active Hermes server).
///   `-echo.demoStream [seconds]` plays the first exchange live, thinking and all (the promo
///   video); with a number, from an empty conversation, the question sent after that long.
/// - `-echo.demoHeavy [turns]`: a thread of long replies (32 turns of about 10,000 characters by
///   default), for measuring. `-echo.pageBudget <characters>` overrides how much of a thread the
///   transcript lays out (`TranscriptPage`); 0 lifts the limit.
/// - `-echo.hitches`: log every frame the main thread made late (`FrameMonitor`). With `-echo.tour device`
///   the tour sends nothing, changes no setting and deletes the conversations the launch seeded. With
///   `-echo.autoScroll [seconds]`, the transcript (or list) scrolls up and back by itself, to measure;
///   with `-echo.autoOpen [times]`, the conversation and the shortest other one are opened in turn;
///   with `-echo.autoType "text"`, the text is typed into the composer a letter at a time; with
///   `-echo.tour`, the app goes through what people do in it by itself, each step measured.
/// - `-echo.demoProjects`: fill the conversation list's Projects from a fixture (Dashboard connection).
///   Add `-echo.demoMarks` for rows marked working, needing you and unread (`ChatActivity`), and
///   `-echo.demoBots` for the Bots section, with a bot's chat open (Quill's) (`-echo.demoBotCount n`
///   for n bots, up to 12, where they fold, or 1 for the main profile alone; `-echo.demoPicture` gives Scout a picture from Hermes Desktop); with
///   `-echo.openGroup` its group chat is open, and `-echo.demoDraft` plays a bot's reply there as
///   it is written; `-echo.groupFind <words>` opens Find in Chat on those words, and
///   `-echo.groupVoice [bot]` the voice screen on the room (with that bot's reply being read; with
///   `-echo.demoDraft`, the sample reply read as it is written; with `-echo.demoRound`, a question
///   and the three bots answering it in turn). `-echo.demoMuted` mutes Scout and the group chat.
/// - `-echo.demoHosts`: replace any real endpoints with example hosts.
/// - `-echo.demoLinkPreview`: link previews from made-up pages, with no network (`LinkPreviews.demo`).
/// - `-echo.flipLayout [seconds]`: the layout swapped under the chat, as opening or closing an iPhone
///   Duo swaps it, on the Darwin notification `LayoutFlip.notification` and every so many seconds.
/// - `-echo.incognito`: open on a new incognito chat.
/// - `-echo.demoKanban`: a sample Kanban board instead of the server's.
/// - `-echo.demoGateway`: Settings → Gateway on sample data, with no server (and the row unlocked).
/// - `-echo.demoFiles`: Settings → Files on sample folders, with no server (and the row unlocked).
/// - `-echo.demoPlugin missing|old|off|there [restart]`: the notifications screen's plugin line on a
///   made-up server, with no Dashboard. Installing leaves it running; with `restart`, waiting for one.
/// - `-echo.demoChatControls`: the model menu's "This conversation" switches on sample data.
/// - `-echo.demoTodos`: a conversation in which the agent keeps a task list (the checklist under a reply).
/// - `-echo.demoPhoneShot`: a short conversation in which the agent has used the phone four
///   times (the Phone tools store screenshot).
/// - `-echo.demoPhone [settings]`: Phone tools switched on, each area set (in these settings
///   only: nothing of iOS's is asked for), and the agent using the phone played live: the
///   calendar, a reminder that Phone tools asks about for real, a photo found by what it
///   shows. With `reach`, a call and a message instead, the message in the real Messages
///   sheet. With `settings`, only the switches are set, to look at Settings → Phone tools.
/// - `-echo.demoFun <scene>`: a scene of the second Phone tools video, a day with the agent:
///   `morning` (the calendar, and a reminder asked about for real), `timer` (a real nine-minute
///   timer; Alarms has to be allowed already), `widget` (writes on the real widget), `photo`,
///   `look` (plays once voice mode's made-up camera has been opened: add `-echo.voiceView
///   -echo.voiceLook`), `reach` (a call and a message). Switches set as with `-echo.demoPhone`.
/// - `-echo.demoAudio`: a reply that came with a sound file (the player in the conversation).
/// - `-echo.demoDocument`: a reply that came with a Markdown file (a tile that opens in QuickLook),
///   then one that names its files by path (links that open them).
/// - `-echo.demoPage`: a reply with a page the agent made, live in the chat, with buttons that talk back.
/// - `-echo.demoCards`: a reply with a map (a walk), three places and the weather, then the time in Tokyo (`ReplyCards`).
///   `-echo.demoCards weather` (or `places`): that card alone.
/// - `-echo.demoAgenda`: what's on the calendar tomorrow, then the rest of the week with a free day, as agenda cards (`AgendaCard`); `-echo.demoAgenda tomorrow` the first alone.
///   `-echo.demoAddEvent`: the first day with a timeline adds an event at its first free stretch, as a tap
///   there does (Apple's editor on the iPhone, the message field's line on the Mac). `-agendaCalendars "(Family, Home)"`
///   shows those calendars only; `-echo.screen calendars` opens Settings → Agent → Calendars.
/// - `-echo.demoApprovalCard <coder|command|push|script|skill>`: an approval waiting, in words (`ApprovalSummary`);
///   `skill` is Coder's change put in place by the main agent, under the chat that asked for it (the store screenshot).
/// - `-echo.demoQuestion <one|few|open>`: the agent's question card (Hermes's clarify), with
///   choices, several questions, or one to answer in words.
/// - `-echo.demoAsks`: cards answered with a tap: a review of a message, a choice of restaurants;
///   with `-echo.demoAsksMore`, a packing checklist and a booking form instead (`-echo.demoAsksListOnly`:
///   the list alone; `-echo.demoPinned`: the list pinned to the chat list).
///   `-echo.demoAsksReviewOnly`: the email alone; `-echo.demoAsksBooking`: a text's review, then a booking's (rows).
/// - `-echo.demoPhotos [n]`: messages with two photos, one, and n (five by default), to look at
///   how pictures are set out together and at the full-screen viewer.
/// - `-echo.demoWidgets`: fill the "Needs you" and Context widgets with sample data (two requests
///   that wait, a context about two thirds full), to look at them on the Home Screen.
///   `-echo.demoWidgets clear` empties them again.
/// - `-echo.screen settings|sessions|setup|profiles|servers|model|tips|push|gateway|files`: open that
///   screen at launch (the last two want `-echo.demoGateway` and `-echo.demoFiles` without a server).
/// - `-echo.pushLink <link>`: open a pairing link for notifications, as the Camera would.
///   `-push.relay <url>` points the app at another push relay (the lab's, on this Mac).
/// - `-echo.demoNotify [seconds]`: ask to send notifications, then post one that many seconds
///   later (twelve by default), for the test that closes the app and taps it.
/// - `-echo.demoLeaveBy [seconds]`: a Leave-By Alert for a made-up dentist's appointment (leave in five
///   minutes, 25 minutes by car), posted that many seconds after launch (three by default), as a banner
///   over the screen (App Store screenshots; notifications must be allowed already).
/// - `-echo.leaveByTest`: on the simulator only, two test events in its calendar (one at a street
///   address 90 minutes from now, one in a room), Leave-By Alerts on by car, one run, and the
///   alerts pending in the log (category leaveby). `-echo.leaveByClean` deletes the test events,
///   logs what is pending once the calendar's change has been followed, and turns the switch off.
///   `-echo.settingsAnchor leaveBy` opens Settings → Agent on Leave-By Alerts; `-echo.screen headsUps`
///   the Heads-Ups page, where they are too.
/// - `-echo.section cron|kanban`: open the conversation list on that tab.
/// - `-echo.settingsAnchor [icloud|plugin|location]`: scroll Settings to the context and memory files, to iCloud,
///   to the Redde Plugin row, or (Agent) to Current Location.
/// - `-echo.expandAppIcons`: open Settings' app icon grid.
/// - `-echo.draft "text"`: type a question into a focused composer (keyboard screenshots).
///   `-echo.clearDrafts` forgets every conversation's unsent draft first (UI tests).
///   `-echo.forget "title"` deletes the saved conversations whose title starts so (a UI test's
///   own, which the list can't always reach: a message still waiting to go closes it).
/// - `-echo.ask "text"`: send a question at launch (the lab, screenshots of a live reply).
///   `-echo.fresh` starts on a new conversation first.
/// - `-echo.share "text"`: the text arrives as from the share sheet; `-echo.shareNew "text"` with
///   its "New conversation" on. `-echo.siriDraft "text"`: as Siri's "draft a message" (in a new
///   conversation with `-siriDraftsInNewConversation YES`).
/// - `-echo.voiceView`: open voice mode without listening. `-echo.voiceDemo ["<words>"]` poses it mid-listen;
///   with `-echo.voiceDemoPhase speaking`, mid-reply instead (the words are the reply's), for screenshots;
///   `-echo.autoVoice` opens it and starts listening. More poses for the promo video:
///   `-echo.voiceDemoPhase thinking`; `-echo.voiceDemoPhase follow` (the pose follows the conversation
///   played into it, as `-echo.demoCall` does); `-echo.voiceDemoCall` (on a call: "On a call" while
///   listening); `-echo.voiceDemoSaid "<words>"` (speaking, the call's voice's words as its caption);
///   `-echo.voiceDemoReveal <seconds a word>` (the words come in a word at a time).
/// - `-echo.demoCall story [seconds]`: on a live call, a bedtime story asked for after that many
///   seconds and its answer written a word at a time (`Conversation.streamCallDemo`), for voice mode
///   posed with `-echo.voiceDemoPhase follow`.
///   `-echo.voiceHandoff` hands its face to other bots and back, as spoken prefixes do.
/// - `-echo.demoDay [morning|week|ideas|evening|home|dinner|packing|routine|watch]`: the "A day with Redde" video
///   (`DemoDay`), with `-echo.demoProjects -echo.demoBots -displayName Sol`: the agents Sol, Home and
///   Coder, a day's chats, canned answers to chats and @tags, sample Agent Activity and Plugin
///   Updates, and the scene's briefings, ideas, notification or sheet. `-echo.demoDayAt <seconds>`:
///   when the morning's heads-up or Home's notification comes. With it, `-echo.screen
///   activity|pluginUpdates|triggers` opens Agent Activity, Plugin Updates or Triggers from Your
///   iPhone in a sheet.
/// - `-echo.demoBoard [clear]`: write on the agent's widget as its phone tool does (a day's plan
///   now, and a line that takes over in a minute), to look at it on the Home Screen.
/// - `-echo.demoAlarm [seconds]`: set a timer as the phone tool does (thirty seconds by default;
///   Alarms has to be allowed already), to look at its countdown and at what rings.
///   `-echo.demoAlarm clear` cancels every alarm and timer iOS holds for Redde.
/// - `-echo.liveEndpoint <url>`: GPT-Live calls go to a stand-in for OpenAI's sessions at that
///   address (scripts/live-standin.py), with no key, instead of to OpenAI. `-echo.liveMeasure`:
///   how long each step of setting a call up took, and every ten seconds what the call costs the
///   phone (CPU, memory), in Library/Caches/live-measure.log.
/// - `-echo.voiceLook`: give voice mode a made-up camera (`DemoEye`), since the simulator has
///   none: the camera button shows, and a question asked with it on goes with a drawn picture.
/// - `-echo.dictation`: listen with the transcriber an iPhone 11 or SE 2 gets (`Transcriber`),
///   on a device that has the newer one too.
/// - `-echo.demoTips`: sample tips on Settings → About → Support Redde (App Review screenshot).
/// - `-echo.whatsNew`: show this version's "What's New" sheet (any other `-echo.` flag hides it).
///   Its "Set Up Ahead of Your Day…" button shows until it has been offered once
///   (`-aheadOfYourDay.answered NO` brings it back for a launch).
/// - `-echo.screen aheadOfYourDay`: Ahead of Your Day's sheet (`AheadOfYourDay`). With
///   `-echo.demoAhead old|missing|there|restart|api|none` on a made-up server (`DemoAheadHost`: the
///   plugin 1.9.0, none, current, 1.9.0 that needs a restart once updated, the Hermes API alone
///   with Location not allowed, no connection for jobs); nothing is made and no setting changes.
///   `-echo.demoAheadRun` presses Turn On a second after the sheet opens (`-echo.demoAheadRun bottom`:
///   and then scrolls to What It Takes).
/// - `-echo.switchProfile <name>`: switch profile five seconds after launch.
/// - `-echo.botKokoro <profile> <voice>`: that bot's Kokoro voice, a blend too ("bf_emma(1)+af_heart(4)").
/// - `-echo.wallpaper <RRGGBB>`: the theme in use gets that wallpaper ("none" takes it off).
/// - `-echo.ringMe <profile> <seconds>`: that agent calls ("default" the main one) that many seconds
///   after launch, as if its push had come (`AgentCalls.ring`): CallKit without the relay. Calls
///   must be on (Settings → Notifications → Calls from Agents), or `-echo.callsOn` turns them on.
/// - `-echo.askProfile <name>`: what Siri's "Ask <name> in Redde" does, at launch: the name is
///   made known, then voice mode is asked for on that profile ("default" is the main one).
/// - `-echo.dropHint`: show the outline a drag over the chat brings up, without a drag.
/// - `-echo.demoTasks [n|run]`: a Live Activity for a job with a six-task list, `n` of them done
///   (or one more every few seconds with `run`), to look at the progress on the Lock Screen.
/// - `-echo.demoApproval`: a Live Activity with a command waiting for a yes or no, to look at
///   its buttons on the Lock Screen; the activity then shows which one was pressed.
/// - `-echo.slowMotion <factor>`: stretch a conversation opening out of its row or card
///   (`OpeningCover`) by that much, to look at it a frame at a time.
/// - `-echo.setupCode <setup link, either form>`: open that setup link at launch, as if it had been
///   scanned (the simulator has no camera).
/// - `-echo.testServer <name> <Dashboard URL> <username>`: add a server with that name if there's
///   none (its password from `ECHO_TEST_SERVER_PASSWORD`). `-echo.switchServer <name>` switches to
///   a server by name five seconds after launch.
///
/// Environment (`SIMCTL_CHILD_<NAME>=value`, so secrets stay out of arguments and logs; an empty
/// value deletes): `ECHO_TEST_SERVE_PASSWORD`, `ECHO_TEST_GATEWAY_KEY`, `ECHO_TEST_PROFILE_KEY`
/// (the selected profile's Hermes API key). `ECHO_TEST_SERVE_SIGNIN`, empty, forgets a browser
/// sign-in to the Dashboard (there is nothing to set it to: signing in takes the browser).
/// `ECHO_TEST_API_BOT`, "<profile>:<its API key>", adds a bot for the Hermes API alone.
///
/// Settings can also be set for one launch with their UserDefaults keys, e.g. `-transport hermesServe`.
///
/// The watch app has a few of its own (`-echo.connection`, `-echo.ask`, `-echo.preview`), described
/// where they are read, in `Watch/EchoWatchApp.swift`.
enum DevHooks {
    private static let args = CommandLine.arguments

    static func has(_ flag: String) -> Bool { args.contains(flag) }

    /// The argument after `flag`, if there is one.
    static func value(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// Any demo or screen flag: an App Store capture or a test, which the "What's New" sheet
    /// must not cover (`-echo.whatsNew` shows it on purpose).
    static var screenshotRun: Bool { args.contains { $0.hasPrefix("-echo.") } }

    private static var demoNewEventShown = false
    /// `-echo.demoAddEvent`: once, a moment after the card shows, the first free stretch of the
    /// first timeline (else 2 PM on it), to add an event at.
    static func demoNewEvent(_ timeline: AgendaCard.Timeline?) async -> AgendaCard.Slot? {
        guard has("-echo.demoAddEvent"), !demoNewEventShown, let timeline else { return nil }
        demoNewEventShown = true
        try? await Task.sleep(for: .seconds(2))
        return timeline.free.first.flatMap(timeline.slot(for:)) ?? timeline.slot(atY: CGFloat(14 - timeline.firstHour) * AgendaCard.Timeline.hourHeight)
    }

    static var demoKanban: Bool { has("-echo.demoKanban") }
    static var demoProjects: Bool { has("-echo.demoProjects") }
    static var demoMarks: Bool { has("-echo.demoMarks") }
    static var demoBots: Bool { has("-echo.demoBots") }
    static var demoGateway: Bool { has("-echo.demoGateway") }
    static var demoChatControls: Bool { has("-echo.demoChatControls") }
    static var demoFiles: Bool { has("-echo.demoFiles") }
    static var expandAppIcons: Bool { has("-echo.expandAppIcons") }
    static var voiceDemo: Bool { has("-echo.voiceDemo") }
    /// `-echo.voiceDemoPhase speaking`: the voice demo posed speaking rather than listening.
    static var voiceDemoSpeaking: Bool { value("-echo.voiceDemoPhase") == "speaking" }
    static var settingsAnchor: Bool { has("-echo.settingsAnchor") }

    /// The conversations there were before any hook seeded one: what `-echo.tour device` leaves.
    @MainActor static var conversationsAtLaunch: Set<UUID> = []

    /// The launch-time hooks that don't touch a view's own state: demo content, example hosts,
    /// test credentials and the delayed profile switch.
    @MainActor
    static func applyAtLaunch(conversation: Conversation, settings: Settings) {
        conversationsAtLaunch = Set(conversation.storeForContext.summaries.map(\.id))
        if has("-echo.demo") { conversation.seedDemo() }
        if has("-echo.demoShort") { conversation.keepFirstMessages(2) }
        if has("-echo.demoTwo") { conversation.keepFirstMessages(4) }
        if has("-echo.demoLibrary") { conversation.seedDemoLibrary() }
        if has("-echo.demoSaved") { conversation.seedDemoLibrary(savedFrom: settings.activeServerID) }
        if has("-echo.clearDrafts") { Drafts.shared.removeAll() }
        if let prefix = value("-echo.forget") {
            Task {
                // After the last conversation has loaded: a load still under way would bring it back.
                await conversation.initialLoad?.value
                for record in conversation.storeForContext.summaries where record.title.hasPrefix(prefix) {
                    conversation.delete(id: record.id)
                }
            }
        }
        // The Projects section only shows on the Dashboard connection.
        if demoProjects { settings.transport = .hermesServe }
        if demoBots {
            if !DemoDay.on { conversation.seedBotDemo() }   // (the day's video starts on a chat of Sol's)
            BotDirectory.shared.set(ConversationsList.demoBots, key: settings.connectionKey)
            #if canImport(UIKit)
            if has("-echo.demoPicture") { BotPictures.shared.seed("scout", BotPictures.demoPicture) }
            #endif
        }
        if has("-echo.demoLong") { conversation.seedLongDemo() }
        if has("-echo.incognito") { conversation.startIncognito() }
        if has("-echo.demoTodos") { conversation.seedTodoDemo() }
        if has("-echo.demoPhoneShot") { conversation.seedPhoneShotDemo() }
        if has("-echo.demoPhone") {
            var tools = PhoneToolsSettings()
            tools.on = true
            for (area, access) in [(DeviceArea.calendar, PhoneToolsSettings.Access.allow), (.reminders, .ask), (.contacts, .ask), (.photos, .allow), (.files, .ask),
                                   (.alarms, .ask), (.widget, .allow), (.people, .allow)] {
                tools.set(area, access)
            }
            settings.phoneTools = tools
            if value("-echo.demoPhone") != "settings" { conversation.streamPhoneDemo(reach: value("-echo.demoPhone") == "reach") }
        }
        if let scene = value("-echo.demoFun") {
            var tools = PhoneToolsSettings()
            tools.on = true
            for area in DeviceArea.allCases { tools.set(area, area == .reminders ? .ask : .allow) }
            settings.phoneTools = tools
            conversation.streamFunDemo(scene)
        }
        if value("-echo.demoCall") == "story" {
            let at = args.firstIndex(of: "-echo.demoCall").map { $0 + 2 }
            let delay = at.flatMap { $0 < args.count ? Double(args[$0]) : nil } ?? 3
            conversation.streamCallDemo(after: delay)
        }
        DemoDay.applyAtLaunch(conversation: conversation, settings: settings)
        if has("-echo.demoAudio") { conversation.seedAudioDemo() }
        if has("-echo.demoDocument") { conversation.seedDocumentDemo() }
        if has("-echo.demoPage") { conversation.seedPageDemo() }
        if has("-echo.demoCards") { conversation.seedCardsDemo(only: value("-echo.demoCards")) }
        if has("-echo.demoAgenda") { conversation.seedAgendaDemo(tomorrowOnly: value("-echo.demoAgenda") == "tomorrow") }
        // A key a bot asked for, its card open over the app, answered by nothing (screenshots).
        if has("-echo.demoKeyRequest") { KeyRequests.shared.showDemo() }
        if has("-echo.demoAsks") { conversation.seedAsksDemo(more: has("-echo.demoAsksMore")) }
        if let kind = value("-echo.demoQuestion") { conversation.seedQuestionDemo(kind) }
        if let kind = value("-echo.demoApprovalCard") { conversation.seedApprovalDemo(kind) }
        if has("-echo.demoPhotos") { conversation.seedPhotoDemo(count: value("-echo.demoPhotos").flatMap(Int.init) ?? 5) }
        if has("-echo.demoWidgets") {
            NeedsYou.clear()
            ContextReading.clear()
            if value("-echo.demoWidgets") != "clear" {
                StatusWidgets.waiting(WaitingRequest(id: "demo-1", kind: .approval, title: "Clear out the old builds", text: "rm -rf ~/builds/2025-*",
                                                     session: "demo-1", since: .now, until: .now.addingTimeInterval(NeedsYou.lifetime(.approval))))
                StatusWidgets.waiting(WaitingRequest(id: "demo-2", kind: .question, title: "Move the blog to the new site",
                                                     text: "Should the old addresses redirect at the server, or with a plugin?",
                                                     session: "demo-2", since: .now, until: .now.addingTimeInterval(NeedsYou.lifetime(.question))))
                StatusWidgets.reading(ContextReading(used: 84_600, window: 128_000, title: "Move the blog to the new site", date: .now))
            }
            WidgetCenter.shared.reloadAllTimelines()
        }
        if has("-echo.demoHeavy") { conversation.seedHeavyDemo(turns: value("-echo.demoHeavy").flatMap(Int.init) ?? 32) }
        if has("-echo.demoBoard") {
            AgentBoard.clear()
            if value("-echo.demoBoard") != "clear" {
                AgentBoard.put(AgentBoard(title: "Today", text: "9:30 standup\n12:15 lunch with Dana\nLeave by 4:40 for the vet", from: .now))
                AgentBoard.put(AgentBoard(title: "Leave now", text: "The vet is 20 minutes away and it is raining.",
                                          from: .now.addingTimeInterval(60), until: .now.addingTimeInterval(180)))
            }
            WidgetCenter.shared.reloadTimelines(ofKind: AgentBoard.widgetKind)
        }
        #if os(iOS)
        if has("-echo.demoAlarm") {
            if value("-echo.demoAlarm") == "clear" {
                for alarm in (try? AlarmManager.shared.alarms) ?? [] { try? AlarmManager.shared.cancel(id: alarm.id) }
                AlarmTrace.note("cleared; holds \((try? AlarmManager.shared.alarms).map(AlarmTrace.describe) ?? "unreadable")")
            } else {
                let seconds = value("-echo.demoAlarm").flatMap(Double.init) ?? 30
                Task { _ = try? await DeviceAlarms().set(.object(["title": .string("Pasta"), "minutes": .number(seconds / 60)])) }
            }
        }
        #endif
        // `-echo.demoLeaveBy [seconds]`: the dentist's Leave-By Alert, as `LeaveByAlerts` posts one
        // (leave in five minutes, 25 minutes by car), that many seconds after launch (three by default),
        // with Redde in front: a banner over what is on the screen (the store screenshot).
        if has("-echo.demoLeaveBy") {
            let wait = value("-echo.demoLeaveBy").flatMap(Double.init) ?? 3
            Task {
                let center = UNUserNotificationCenter.current()
                guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
                try? await Task.sleep(for: .seconds(wait))
                let minute = Calendar.current.dateInterval(of: .minute, for: .now)?.start ?? .now
                let leave = minute.addingTimeInterval(5 * 60), start = leave.addingTimeInterval(25 * 60)
                let content = LeaveTime.content(event: "Dentist", startsAt: start, leave: leave, travel: 25 * 60, mode: .driving,
                                                worked: minute, saying: .distantPast)
                content.categoryIdentifier = LeaveBy.mapsCategory
                content.sound = .default
                try? await center.add(UNNotificationRequest(identifier: LeaveBy.alertID(event: "Dentist", start: start), content: content, trigger: nil))
            }
        }
        if has("-echo.demoNotify") {
            let wait = value("-echo.demoNotify").flatMap(Double.init) ?? 12
            Task {
                let center = UNUserNotificationCenter.current()
                guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
                let content = UNMutableNotificationContent()
                content.title = "Redde"
                content.body = "A notification to tap"
                try? await center.add(UNNotificationRequest(identifier: "redde.demo", content: content,
                                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: wait, repeats: false)))
            }
        }
        #if targetEnvironment(simulator)
        if has("-echo.leaveByTest") { Task { await LeaveByTest.seed(settings: settings) } }
        if has("-echo.leaveByClean") {
            Task {
                await LeaveByTest.clean()
                // The calendar's change takes the alerts of the events gone; then the switch goes off.
                try? await Task.sleep(for: .seconds(6))
                await LeaveByTest.logPending()
                settings.leaveByAlerts = false
            }
        }
        #endif
        if has("-echo.demoApproval") {
            TurnActivity.shared.start(question: "Clear out the old build folders", agent: settings.headerTitle)
            TurnActivity.shared.tool("terminal")
            TurnActivity.shared.needsApproval(ApprovalRequest(id: "demo", command: "rm -rf ~/builds/2025-*", description: nil,
                                                              choices: ["once", "session", "always", "deny"]))
            #if os(iOS)
            ApprovalAnswer.deliver = { _, choice in
                TurnActivity.shared.finish(reply: choice == "deny" ? "Denied. Nothing was removed." : "Approved (\(choice)).")
            }
            #endif
        }
        if has("-echo.demoTasks") {
            // "3": that many of the six done, and it stays so. "run": one more every few seconds.
            let titles = ["Export the posts", "Set up the new theme", "Import the posts", "Redirect the old addresses",
                          "Check every link", "Switch the domain over"]
            func list(done: Int) -> [TodoItem] {
                titles.enumerated().map { i, title in
                    TodoItem(id: "\(i + 1)", content: title, status: i < done ? .completed : i == done ? .inProgress : .pending, parent: nil)
                }
            }
            let start = min(max(value("-echo.demoTasks").flatMap(Int.init) ?? 0, 0), titles.count)
            TurnActivity.shared.start(question: "Move the blog to the new site", agent: settings.headerTitle)
            TurnActivity.shared.tool("terminal")
            TurnActivity.shared.tasks(list(done: start))
            if value("-echo.demoTasks") == "run" {
                Task {
                    for done in 1 ... titles.count {
                        try? await Task.sleep(for: .seconds(4))
                        TurnActivity.shared.tasks(list(done: done))
                    }
                    try? await Task.sleep(for: .seconds(2))
                    TurnActivity.shared.finish(reply: "The blog is on the new site, and the old addresses lead to it.")
                }
            }
        }
        if has("-echo.demoStream") { conversation.streamDemo(askingAfter: value("-echo.demoStream").flatMap(Double.init)) }
        if has("-echo.demoHosts") {
            settings.gatewayURL = "https://redde.home.example:8642"
            settings.serveURL = "http://redde.home.example:9119"
            settings.serveUsername = "redde"
            settings.fastLaneURL = "http://llama.home.example:11500"
            settings.fastLaneModel = "qwen36-35b-a3b"
        }

        let env = ProcessInfo.processInfo.environment
        if let v = env["ECHO_TEST_SERVE_PASSWORD"] { Keychain.write(.serveDashboardPassword, value: v) }
        if env["ECHO_TEST_SERVE_SIGNIN"] == "" { Keychain.delete(.serveSignIn) }
        if let v = env["ECHO_TEST_GATEWAY_KEY"] { Keychain.write(.gatewayAPIKey, value: v) }
        if let v = env["ECHO_TEST_PROFILE_KEY"], let profile = settings.profileName {
            Keychain.write(account: Keychain.profileAccount(profile), value: v)
        }
        // A bot for the Hermes API alone, "<profile>:<its API key>" (`APIBot`).
        if let v = env["ECHO_TEST_API_BOT"], let colon = v.firstIndex(of: ":") {
            let profile = String(v[..<colon])
            Keychain.write(account: Keychain.profileAccount(profile, server: settings.activeServerID.uuidString), value: String(v[v.index(after: colon)...]))
            if !settings.apiBotsHere.contains(where: { $0.profile == profile }) { settings.apiBotsHere.append(APIBot(profile: profile, title: profile.capitalized)) }
        }

        if let i = args.firstIndex(of: "-echo.testServer"), i + 3 < args.count {
            let name = args[i + 1]
            if !settings.servers.contains(where: { $0.name == name }) {
                let id = settings.addServer(name: name)
                let original = settings.activeServerID
                settings.activateServer(id)
                settings.transport = .hermesServe
                settings.serveURL = args[i + 2]
                settings.serveUsername = args[i + 3]
                if let password = env["ECHO_TEST_SERVER_PASSWORD"] { Keychain.write(.serveDashboardPassword, value: password) }
                settings.activateServer(original)
            }
        }
        if let name = value("-echo.switchServer") {
            Task {
                try? await Task.sleep(for: .seconds(5))
                if let target = settings.servers.first(where: { $0.name == name || $0.title == name }) {
                    ServerSwitcher.switchTo(target.id, conversation: conversation)
                }
            }
        }

        // `-echo.keychainReport`: which saved server has which secret stored, yes or no, never
        // the value, in Library/Caches/keychain-report.log (Skills greyed out on Marta, 2026-10-26).
        if has("-echo.keychainReport") {
            var lines = ["active \(Keychain.activeServerID ?? "none")"]
            for server in settings.servers {
                let id = server.id.uuidString
                func stored(_ item: Keychain.Item) -> String { Keychain.read(account: Keychain.account(item, server: id)) == nil ? "no" : "yes" }
                lines.append("\(id) \(server.serveURL) \(server.serveUsername): password \(stored(.serveDashboardPassword)), sign-in \(stored(.serveSignIn)), API key \(stored(.gatewayAPIKey))")
            }
            lines.append("unscoped password \(Keychain.read(account: Keychain.Item.serveDashboardPassword.rawValue) == nil ? "no" : "yes")")
            LiveMeasure.write(lines.joined(separator: "\n"), to: "keychain-report.log")
        }

        // `-echo.botKokoro <profile> <voice>`: that bot's Kokoro voice, a blend as well (Home's,
        // set from the Mac 2026-10-26), its speed and conversation as they were.
        if let at = args.firstIndex(of: "-echo.botKokoro"), at + 2 < args.count {
            var record = settings.botVoicesHere[args[at + 1]] ?? BotVoice()
            (record.kokoro, record.onDevice, record.elevenLabs, record.sameAsMain) = (args[at + 2], nil, nil, nil)
            settings.botVoicesHere[args[at + 1]] = record
        }

        // `-echo.wallpaper <RRGGBB>|none`: the theme in use's wallpaper (screenshots).
        if let hex = value("-echo.wallpaper") {
            let key = settings.theme.rawValue
            if hex == "none" {
                settings.themeColors[key]?.wallpaper = nil
            } else if hex.count == 6, let n = Int(hex, radix: 16) {
                settings.themeColors[key, default: ThemeColors()].wallpaper = ThemeColors.RGB(
                    red: Double((n >> 16) & 0xFF) / 255, green: Double((n >> 8) & 0xFF) / 255, blue: Double(n & 0xFF) / 255)
            }
        }

        #if os(iOS)
        // `-echo.ringMe <profile> <seconds>` (and `-echo.callsOn`): an agent's call, without the relay.
        if has("-echo.callsOn") {
            settings.agentCalls = true
            if settings.callersHere.isEmpty { settings.callersHere = ["default"] }
            AgentCalls.shared.start()
        }
        if let at = args.firstIndex(of: "-echo.ringMe"), at + 1 < args.count {
            let profile = args[at + 1]
            let delay = at + 2 < args.count ? Double(args[at + 2]) ?? 5 : 5
            Task {
                try? await Task.sleep(for: .seconds(delay))
                AgentCalls.shared.ring(from: profile, saying: "This is a test call from Redde. The garage door has been open for an hour.")
            }
        }
        #endif

        if let name = value("-echo.askProfile") {
            ProfileCatalog.keep(named: name)
            LaunchRouter.shared.requestVoice(handsFree: false, profile: name)
        }

        // The simulator can't tap the picker, so this checks that open screens follow a switch.
        if let name = value("-echo.switchProfile") {
            Task {
                try? await Task.sleep(for: .seconds(5))
                settings.hermesProfile = name == "default" ? "" : name
                conversation.reset()
            }
        }
    }
}

#if targetEnvironment(simulator)
/// `-echo.leaveByTest` and `-echo.leaveByClean`: test events in the simulator's own calendar, for
/// Leave-By Alerts (`LeaveByAlerts`). Their titles start with `prefix`; nothing else is touched.
@MainActor
enum LeaveByTest {
    static let prefix = "Redde Test: "
    private static let log = Logger(subsystem: "com.goosehouse.echo", category: "leaveby")

    static func seed(settings: Settings) async {
        guard await DeviceCalendar.allowed(.event) else { return log.notice("test: no calendar access") }
        await clean()
        let store = EKEventStore()
        guard let calendar = store.defaultCalendarForNewEvents else { return log.notice("test: no calendar") }
        let start = Date(timeIntervalSince1970: (Date.now.addingTimeInterval(90 * 60).timeIntervalSince1970 / 300).rounded() * 300)
        for (title, place) in [("Dentist", "200 East Robinson St, Orlando, FL 32801"), ("Standup", "Office · Room 4")] {
            let event = EKEvent(eventStore: store)
            event.calendar = calendar
            event.title = prefix + title
            event.location = place
            event.startDate = start
            event.endDate = start.addingTimeInterval(3600)
            do { try store.save(event, span: .thisEvent) } catch { log.notice("test: not saved \(error.localizedDescription, privacy: .public)") }
        }
        LeaveTime.setMode(.driving)
        // Notifications quietly allowed (provisional), with no prompt for a test to tap.
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .provisional])
        settings.leaveByAlerts = true
        await LeaveByAlerts.shared.turned(on: true)
        await logPending()
        log.notice("test: next \(LeaveByAlerts.shared.next.map { "\($0.title) \($0.leave.formatted())" } ?? "none", privacy: .public); missing \(LeaveByAlerts.shared.missing.count)")
    }

    static func logPending() async {
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests().filter { $0.identifier.hasPrefix(LeaveTime.reminderPrefix) }
        for request in pending {
            let at = (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
            log.notice("test: pending \(request.identifier, privacy: .public) at \(at?.formatted() ?? "now", privacy: .public): \(request.content.title, privacy: .public) / \(request.content.body, privacy: .public)")
        }
        log.notice("test: \(pending.count) leaving reminders pending")
    }

    static func clean() async {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
        let store = EKEventStore()
        let found = store.events(matching: store.predicateForEvents(withStart: .now.addingTimeInterval(-86_400), end: .now.addingTimeInterval(3 * 86_400), calendars: nil))
            .filter { $0.title?.hasPrefix(prefix) == true }
        for event in found { try? store.remove(event, span: .thisEvent, commit: false) }
        try? store.commit()
        log.notice("test: removed \(found.count) test events")
    }
}
#endif
#endif