import SwiftUI

/// Previous sessions. With the ledger transport this is Hermes's own session list, every
/// platform included. Tap to resume, swipe to delete.
/// The iPhone's panel from the left (opening a conversation closes it). On iPad the list lives
/// in the split view's sidebar instead.
struct ConversationsView: View {
    /// The panel stays built while closed, so it slides in without a hitch; this says whether
    /// it's out.
    var isShowing: Bool
    var onOpened: () -> Void
    var body: some View {
        NavigationStack {
            ConversationsList(onOpened: onOpened, isShowing: isShowing)
        }
    }
}

/// Identifies the project a sidebar row pushes to. A dedicated type rather than the bare id,
/// so the destination can't collide with another String route in the same stack.
struct ProjectRoute: Hashable {
    let id: String
}

struct ConversationsList: View {
    /// What to do after a session opens: the iPhone's panel closes; the iPad sidebar stays put.
    var onOpened: () -> Void = {}
    /// False while the iPhone's panel is closed: Chats and Cron refresh when it opens again.
    /// (The Kanban board and its live socket go away once the panel has slid out: `panelParked`.)
    var isShowing = true
    @Environment(Conversation.self) var conversation
    @Environment(\.sidePanelParked) private var panelParked
    @Environment(\.scenePhase) var scenePhase
    @State var store = ConversationStore.shared
    /// Working, Needs you and Unread, for the rows.
    @State var activity = ChatActivity.shared
    @State var pace = Pace.shared
    @State var settings = Settings.shared
    @State var drafts = Drafts.shared
    @State var ledger: [HermesSessionsAPI.SessionSummary] = []
    @State var ledgerError: String?
    @State var loading = false
    @State var opening: String?
    /// A conversation the server wouldn't hand over just now, of which this iPhone has a copy.
    @State var savedCopyOffered: UUID?
    @State var query = ""
    @State var renaming: HermesSessionsAPI.SessionSummary?
    @State var renameText = ""
    /// A group chat being renamed from its row's menu, and the name typed.
    @State var renamingRoom: GroupRoom?
    @State var roomRenameText = ""
    @State var usageFor: HermesSessionsAPI.SessionSummary?
    @State var projects: [HermesServeClient.Project] = []
    /// Every project that is a folder, with or without conversations: where one can be moved to.
    @State var folders: [HermesServeClient.Project] = []
    /// The New Project prompt, and what the project is for once made.
    @State var newProject: NewProject?
    @State var newProjectName = ""
    @State var projectRenaming: HermesServeClient.Project?
    @State var projectRenameText = ""
    @State var projectRemoving: HermesServeClient.Project?
    @AppStorage("sessions.showProjects") var showProjects = true
    /// The server's bots (Hermes's Bot Mode), for the Bots section.
    @State var botDirectory = BotDirectory.shared
    @AppStorage("sessions.showBots") var showBotRows = true
    /// More than six bots: all of them showing, or the first few and "more".
    @AppStorage("sessions.botsExpanded") var botsExpanded = false
    /// New Bot, Topology and Hidden after the bots, or folded into one More (his ask 2026-10-22).
    @AppStorage("sessions.botActionsShown") var botActionsShown = true
    /// Every profile's chats in the list at once, each tagged with its profile, as Hermes Desktop
    /// can (his ask 2026-10-22, after a Reddit request); off, the selected profile's alone.
    @AppStorage("sessions.allProfiles") var allProfiles = false
    /// Every saved server's chats in the list, each tagged with its server (`AllServers`).
    @AppStorage("sessions.allServers") var allServers = false
    /// A bridge connection's agents, for the title's agent menu (`agentMenu`).
    @State var bridgeAgents: [AcpEndpoint.Agent] = []
    /// The servers that didn't answer, with All Servers on.
    @State var serversUnreachable: [String] = []
    /// The bot whose chat is being found or made.
    @State var openingBot: String?
    /// "Let bots message each other", being asked about.
    @State var askingBotMessaging = false
    /// Sections of the Bots (`BotSection`): one being named (new, filing a bot, or renamed), its
    /// name as typed, one asked about deleting, and those folded away on this device.
    @State var namingSection: SectionNaming?
    @State var sectionNameText = ""
    @State var deletingSection: BotSection?
    @AppStorage("bots.foldedSections") var foldedSectionsRaw = ""
    /// The server's group chats (Hermes's bot rooms; the one open in the chat's place is
    /// `groups.open`), and a new one being made.
    @State var groups = GroupDirectory.shared
    @State var makingGroup = false
    /// The bot whose face is being picked.
    @State var facing: HermesBot?
    /// A bot being made or changed, and the hidden ones being looked at.
    @State var editingBot: BotEditor.Mode?
    /// A bot being added for the Hermes API alone.
    @State var addingAPIBot = false
    /// The map of the bots, their group chats and models (`BotTopologyView`).
    @State var showingTopology = false
    /// The bot whose voice is being picked.
    @State var voicing: HermesBot?
    /// The main agent's voice: the app's own, Settings → Voice.
    @State var voicingMain = false
    /// The bot whose schedules are open (`BotSchedulesView`).
    @State var scheduling: HermesBot?
    /// A bot added for the Hermes API alone, its Models & Providers open (no Edit Bot there).
    @State var modelsFor: HermesBot?
    /// The bot whose earlier chats are open (`EarlierChatsView`).
    @State var earlierFor: HermesBot?
    @State var showingHiddenBots = false
    @AppStorage("sessions.showScheduled") var showScheduled = false
    @State var shareItem: ShareItem?
    @State var selecting = false
    /// The New Goal sheet (2.4), from holding New Conversation.
    @State var addingGoal = false
    /// A goal's page (2.4), from its card.
    @State var shownGoal: GoalReport?
    /// The Bots section being put in order: only its bots and group chats show, with handles.
    @State var arrangingBots = false
    @State var selected: Set<String> = []
    @State var confirmBulkDelete = false
    @State var showSettings = false
    @State var drawerPage: NewDrawer.Page?
    @State var drawerWaits: [WaitingRequest] = []
    @State var drawerBotWaits: [NewDrawer.BotWait] = []
    @State var drawerLater: [String] = []
    @State var drawerNeedsOpen = false
    @Environment(\.showSettingsSheet) private var showSettingsSheet
    @Environment(\.wideLayout) var wide
    /// Pinned first, then most recent; filtered by the search field. Cached: the body reads it
    /// several times per pass and every keystroke in the search field would repeat the sort.
    @State var visibleLedger: [HermesSessionsAPI.SessionSummary] = []
    /// The bots' chats listed among the conversations (asked 2026-11-04), by their chat's id.
    @State var botChatRows: [String: HermesBot] = [:]
    /// Conversations with a message matching the search, from the server (`MessageSearch`).
    @State var messageHits: [MessageSearchHit] = []
    @State var searchingMessages = false
    @State var messageSearchProblem: String?

    var usesLedger: Bool { settings.transport.hasLedger }
    var viaServe: Bool { settings.transport == .hermesServe }
    /// The server's bots can be reached: on the Dashboard, and on the Hermes API through the
    /// Dashboard's login (`BotDirectory.reachable`).
    var botsHere: Bool { BotDirectory.reachable(settings) || apiBotsOnly }
    /// The Hermes API with no Dashboard login: the bots are the ones added here (`APIBot`).
    var apiBotsOnly: Bool { BotDirectory.apiOnly(settings) }
    /// Searching inside messages takes the Dashboard (only it has the route), on either connection.
    var searchesMessages: Bool { usesLedger && settings.serveBaseURL != nil }

    /// A project being made: to start a conversation in, or to move one into.
    enum NewProject {
        case start
        case move(HermesSessionsAPI.SessionSummary)
    }

    /// On iPad and the Mac the list stays in the sidebar, the chat in the wide pane beside it.
    var wideDetail = false

    /// The bar's title. "Conversations" over the chats; Cron and Kanban name themselves.
    /// On iPad from iPadOS 27 the sidebar's title is no longer drawn large under the bar but in
    /// it, beside four buttons, where "Conversations" was cut to "Conversa…". There it is
    /// "Chats": what the sidebar lists, whichever section the wide pane shows. And nothing while
    /// selecting, when Cancel and Deselect all need the room.
    private var listTitle: String {
        if #available(iOS 27.0, macOS 27.0, *), wideDetail { return selecting || arrangingBots ? "" : String(localized: "Chats") }
        return String(localized: "Conversations")
    }

    /// A conversation opened (or a new one started), or with `room` a group chat: it takes the
    /// chat's place (on iPad, the wide pane again).
    /// Settings, from the app's root where there is one (it stays up when the layout changes
    /// under the list), else on the list.
    func openSettings() {
        if let showSettingsSheet { showSettingsSheet() } else { showSettings = true }
    }

    /// An idea taken: its request goes to the agent that offered it, as the person's message, in a
    /// new conversation with the main agent or in the bot's chat. A bot gone since: the main agent.
    func takeIdea(_ idea: AgentIdea) {
        IdeasInbox.shared.remove(idea)
        Task {
            do {
                if idea.profile != "default", let bot = botDirectory.roster?.bots.first(where: { $0.name == idea.profile }) {
                    try await conversation.openBot(bot, mainName: settings.headerTitle)
                } else if idea.profile != (settings.profileName ?? ProfileCatalog.defaultID) {
                    // The agent that offered it, whichever profile the app is on (2026-10-29: Sol's
                    // ideas went to the research profile the app was left on, and Claude Code
                    // answered them without the calendar).
                    ProfileCatalog.startConversation(on: idea.profile, conversation: conversation, settings: settings)
                } else if conversation.bot != nil || conversation.elsewhere != nil || conversation.hasMessages || !conversation.outbox.isEmpty {
                    conversation.reset()
                }
                conversation.send(AgentIdea.message(for: idea))
                opened()
            } catch {
                ledgerError = error.localizedDescription
            }
        }
    }

    /// From the Made tab: the chat a thing was made in.
    func openMadeIn(_ id: UUID) {
        Task {
            if let full = await store.loadRecord(id: id) { conversation.load(full) }
            opened()
        }
    }

    func opened(room: GroupRoom? = nil) {
        groups.open = room
        drawerPage = nil
        onOpened()
    }

    var body: some View {
        // In stages, as ContentView.body is: in one chain an unoptimized build kept 290 KB of the
        // phone's 1 MB main-thread stack here (2026-11-13).
        listSheets(AnyView(sessionsList
        // From inside the navigation stack: hiding the whole panel doesn't reach UIKit's list,
        // and VoiceOver could swipe into rows parked off screen.
        .accessibilityHidden(panelParked)
        .navigationTitle(listTitle)
        .toolbarVisibility(panelParked ? .hidden : .automatic, for: .navigationBar)
        // Inline on the iPhone, its title the agent picker (`pickerInTitle`): a large title over the
        // search, the picker and the tabs left the chats off the first screen (2026-11-06).
        .navigationBarTitleDisplayMode(wideDetail ? .large : .inline)
        ))
    }
}

#if DEBUG
extension ConversationsList {
    /// `-echo.openGroup` has opened its group chat.
    static var openedDemoGroup = false

    /// Another server's chats, for `-echo.demoAllServers`.
    static var demoOtherServer: [HermesSessionsAPI.SessionSummary] {
        let json = """
        [{"id":"workshop-1","title":"Garage door sensor","source":"desktop","started_at":1772998000,"last_active":1772999500,"message_count":8,"preview":"The sensor reads closed again."},
         {"id":"workshop-2","title":"Printer queue","source":"desktop","started_at":1772900000,"last_active":1772950000,"message_count":3}]
        """
        let tag = ServerTag(id: UUID(uuidString: "00000000-0000-4000-8000-00000000F00D")!, name: "Workshop")
        return ((try? JSONDecoder().decode([HermesSessionsAPI.SessionSummary].self, from: Data(json.utf8))) ?? []).map {
            var row = $0
            row.otherServer = tag
            return row
        }
    }

    /// One project Hermes found, with one lane and two sessions (enough to reach
    /// ProjectSessionsView and tap a row), and one someone made, still empty.
    static var demoBots: BotRoster {
        // `-echo.demoDay`: the day's video's agents, Sol, Home and Coder (`DemoDay`).
        if DemoDay.on { return DemoDay.roster }
        let all = [
            HermesBot(name: "default", isDefault: true, lastActive: .now.addingTimeInterval(-3_600), preview: "Done: the reminder is set for 4 pm."),
            HermesBot(name: "scout", title: "Scout", description: "Finds things out", lastActive: .now.addingTimeInterval(-600),
                      preview: "Three trails under two hours from you, all open."),
            HermesBot(name: "writer", displayName: "Quill", description: "Edits and drafts", lastActive: .now.addingTimeInterval(-120),
                      preview: "Want me to carry that through the next paragraph?"),
            HermesBot(name: "fixit", title: "Fix-it", description: "Looks after the home server"),
        ].map { bot in
            // `-echo.demoPicture`: Scout has a picture from Hermes Desktop.
            var bot = bot
            bot.hasPicture = bot.name == "scout" && DevHooks.has("-echo.demoPicture")
            // The models they run on, for the Topology map.
            bot.model = ["default": "qwen3.6-35b-a3b", "scout": "qwen3.6-35b-a3b", "writer": "anthropic/claude-sonnet-4.5",
                         "fixit": "gemma-4-12b"][bot.name]
            return bot
        } + extraDemoBots + claudeDemoBot
        // `-echo.demoBotCount 1`: the main profile alone.
        return BotRoster(bots: DevHooks.value("-echo.demoBotCount") == "1" ? all.filter(\.isDefault) : all)
    }

    /// `-echo.demoClaudeBot`: a coding bot that works through Claude Code, as the butler setup's (Topology).
    private static var claudeDemoBot: [HermesBot] {
        guard DevHooks.has("-echo.demoClaudeBot") else { return [] }
        return [HermesBot(name: "claude", title: "Claude", description: "Coding worker: does each card with Claude Code, never seeing a key.",
                          model: "qwen3.6-35b-a3b", lastActive: .now.addingTimeInterval(-900))]
    }

    /// `-echo.demoBotCount n`: the sample bots, and more up to n (for when they fold).
    private static var extraDemoBots: [HermesBot] {
        let names = ["Home", "Chef", "Coach", "Atlas", "Penny", "Tutor", "Ledger", "Nova"]
        let count = DevHooks.value("-echo.demoBotCount").flatMap(Int.init) ?? 0
        return names.prefix(max(0, count - 4)).map { HermesBot(name: $0.lowercased(), title: $0) }
    }

    static var demoProjects: [HermesServeClient.Project] {
        let json = """
        {"id":"/home/redde/echo","label":"Echo","path":"/home/redde/echo","isNoProject":false,
         "sessionCount":2,"lastActive":1773000000,"totalCostUsd":0.42,
         "repos":[{"id":"r","label":"Echo","groups":[{"id":"lane1","label":"main","sessions":[
           {"id":"demo-1","title":"Transcript scrolling","source":"cli","started_at":1772999000,"last_active":1773000000,"message_count":12},
           {"id":"demo-2","title":"Calendar MCP guards","source":"desktop","started_at":1772990000,"last_active":1772999000,"message_count":30}]}]}]}
        """
        // And one made by someone, with no conversations yet.
        let own = """
        {"id":"p_demo","label":"Garden","path":"/home/redde/Projects/Garden","isAuto":false,"isNoProject":false,
         "sessionCount":0,"lastActive":0,"totalCostUsd":0,"repos":[]}
        """
        return [json, own].compactMap { text in
            guard let data = text.data(using: .utf8), let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
            return HermesServeClient.Project(value)
        }
    }

    /// Two runs of a scheduled job, in no project: they fold away under Scheduled runs.
    /// Two more for `-echo.demoMarks`: a reply not yet seen, and the agent waiting on an approval.
    static var demoMarkedRows: [HermesSessionsAPI.SessionSummary] {
        let json = """
        [{"id":"demo-marks-1","title":"Grocery list","source":"api_server","started_at":1772999800,"last_active":1773000300,"message_count":4,
          "preview":"Here's what I found for this week","unread":true},
         {"id":"demo-marks-2","title":"Server cleanup","source":"api_server","started_at":1772999700,"last_active":1772999900,"message_count":6,
          "preview":"Run rm -rf ~/old-backups?","unread":false}]
        """
        return (try? JSONDecoder().decode([HermesSessionsAPI.SessionSummary].self, from: Data(json.utf8))) ?? []
    }

    static var demoScheduledRuns: [HermesSessionsAPI.SessionSummary] {
        let json = """
        [{"id":"demo-cron-1","title":"Morning briefing","source":"cron","started_at":1772998000,"last_active":1772998100,"message_count":2},
         {"id":"demo-cron-2","title":"Morning briefing","source":"cron","started_at":1772911600,"last_active":1772911700,"message_count":2}]
        """
        return (try? JSONDecoder().decode([HermesSessionsAPI.SessionSummary].self, from: Data(json.utf8))) ?? []
    }
}
#endif

extension Theme {
    /// The chat list's page: the theme's own, never a picked wallpaper's colour (the list stays
    /// off the wallpaper, 2026-10-28); nil leaves the system's list as it was.
    var listPage: Color? { palette.background }
}

extension View {
    /// A list on the theme's page: its own background hidden and the page behind it, or the list
    /// untouched when the theme has no page colour of its own.
    @ViewBuilder func themedPage(_ page: Color?) -> some View {
        if let page {
            scrollContentBackground(.hidden).background { page.ignoresSafeArea() }
        } else {
            self
        }
    }
}
