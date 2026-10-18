import Foundation
import Testing
@testable import Echo

/// The chat list's marks (`ChatActivity`): what Hermes's answers become, and Unread where the app
/// keeps it itself. What Hermes says is checked against real releases in `HermesLabStatusTests`.
@MainActor
struct ChatActivityTests {
    private struct Setup {
        let activity: ChatActivity
        let conversation: Conversation
        let settings: Settings
        let defaults: UserDefaults
    }

    private func setup(_ transport: Transport) -> Setup {
        let defaults = UserDefaults(suiteName: "chat-activity-\(UUID().uuidString)")!
        let settings = Settings(defaults: defaults)
        settings.transport = transport
        let store = ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "chat-activity-\(UUID().uuidString)"))
        return Setup(activity: ChatActivity(defaults: defaults), conversation: Conversation(settings: settings, store: store),
                     settings: settings, defaults: defaults)
    }

    private func row(_ id: String, lastActive: Double, unread: Bool? = nil) -> HermesSessionsAPI.SessionSummary {
        var row = HermesSessionsAPI.SessionSummary(id: id)
        row.last_active = lastActive
        row.unread = unread
        return row
    }

    @Test func theDashboardsListOfTurnsBecomesMarks() throws {
        let answer = try JSONValue.parse(Data("""
        {"sessions":[{"id":"rt-1","session_key":"s-1","status":"working"},
                     {"id":"rt-2","session_key":"s-2","status":"waiting"},
                     {"id":"rt-3","session_key":"s-3","status":"idle"},
                     {"id":"rt-4","session_key":"s-4","status":"starting"}]}
        """.utf8))
        #expect(ChatActivity.kinds(activeList: answer) == ["s-1": .working, "s-2": .needsYou, "s-4": .working],
                "by stored id; idle is nothing, starting is on its way")
        #expect(ChatActivity.kinds(activeList: .object([:])).isEmpty)
    }

    @Test func aRunsStatusBecomesAMark() {
        #expect(ChatActivity.kind(runStatus: "running") == .working)
        #expect(ChatActivity.kind(runStatus: "queued") == .working)
        #expect(ChatActivity.kind(runStatus: "waiting_for_approval") == .needsYou)
        for over in ["completed", "failed", "cancelled", "interrupted"] { #expect(ChatActivity.kind(runStatus: over) == nil, "\(over)") }
    }

    @Test func unreadIsTheHostsWordWhereItHasOne() {
        #expect(ChatActivity.unread(server: true, lastActive: 0, seen: 100, isOpen: false, busy: false))
        #expect(!ChatActivity.unread(server: false, lastActive: 500, seen: 100, isOpen: false, busy: false),
                "the host's word beats a time kept here")
        #expect(!ChatActivity.unread(server: true, lastActive: 0, seen: nil, isOpen: true, busy: false), "the open one is read")
        #expect(!ChatActivity.unread(server: true, lastActive: 0, seen: nil, isOpen: false, busy: true),
                "the agent's own activity while it works isn't a reply yet")
    }

    @Test func whereTheHostCantSayItIsWhatCameAfterItWasSeen() {
        #expect(ChatActivity.unread(server: nil, lastActive: 1000, seen: 990, isOpen: false, busy: false))
        #expect(!ChatActivity.unread(server: nil, lastActive: 994, seen: 990, isOpen: false, busy: false),
                "within the clocks' slack it isn't")
        #expect(ChatActivity.unread(server: nil, lastActive: 10, seen: 0, isOpen: false, busy: false), "marked unread")
        #expect(!ChatActivity.unread(server: nil, lastActive: 1000, seen: nil, isOpen: false, busy: false), "never listed: read")
    }

    @Test func onTheHermesAPIAConversationFirstListedIsReadUntilSomethingComes() {
        let s = setup(.hermesSessions)
        s.activity.listed([row("s-1", lastActive: 1000)], settings: s.settings)
        #expect(!s.activity.isUnread(row("s-1", lastActive: 1000), open: s.conversation, settings: s.settings))
        #expect(s.activity.isUnread(row("s-1", lastActive: 1100), open: s.conversation, settings: s.settings), "a reply after it was listed")
        s.activity.listed([row("s-1", lastActive: 1100)], settings: s.settings)
        #expect(s.activity.isUnread(row("s-1", lastActive: 1100), open: s.conversation, settings: s.settings),
                "listing it again doesn't read it")

        s.activity.markRead("s-1", conversation: s.conversation, settings: s.settings)
        #expect(!s.activity.isUnread(row("s-1", lastActive: 1100), open: s.conversation, settings: s.settings))
        s.activity.markUnread("s-1", conversation: s.conversation, settings: s.settings)
        #expect(s.activity.isUnread(row("s-1", lastActive: 1100), open: s.conversation, settings: s.settings))

        let relaunched = ChatActivity(defaults: s.defaults)
        #expect(relaunched.isUnread(row("s-1", lastActive: 1100), open: s.conversation, settings: s.settings), "kept across launches")
    }

    @Test func onTheDashboardTheHostKeepsUnread() {
        let s = setup(.hermesServe)
        s.activity.listed([row("s-1", lastActive: 1000)], settings: s.settings)
        #expect(!s.activity.isUnread(row("s-1", lastActive: 5000), open: s.conversation, settings: s.settings),
                "a row the host left unmarked isn't unread, whatever its time")
        #expect(s.activity.isUnread(row("s-1", lastActive: 5000, unread: true), open: s.conversation, settings: s.settings))
    }

    @Test func aTurnLeftOnTheHermesAPIIsWorkingAtOnceAndKept() {
        let s = setup(.hermesSessions)
        s.activity.noteLeft(sessionID: "s-1", runID: "run-1", settings: s.settings)
        #expect(s.activity.kind(of: "s-1", open: s.conversation, settings: s.settings) == .working)
        #expect(!s.activity.isUnread(row("s-1", lastActive: 9e9), open: s.conversation, settings: s.settings),
                "nor unread while it works")
        let other = Settings(defaults: UserDefaults(suiteName: "chat-activity-\(UUID().uuidString)")!)
        other.transport = .hermesSessions
        other.hermesProfile = "another"
        #expect(s.activity.kind(of: "s-1", open: s.conversation, settings: other) == nil, "only on its own connection")
    }

    @Test func theLastLookIsWhatARowShows() {
        let s = setup(.hermesServe)
        s.activity.showDemo(["s-1": .working], settings: s.settings)
        #expect(s.activity.kind(of: "s-1", open: s.conversation, settings: s.settings) == .working)
        #expect(s.activity.kind(of: "s-2", open: s.conversation, settings: s.settings) == nil)
    }

    @Test func theMarksAreReadOut() {
        #expect(ChatMarks(kind: nil, unread: false).spoken == "")
        #expect(ChatMarks(kind: .working, unread: true).spoken == "Unread, Agent working")
        #expect(ChatMarks(kind: .needsYou, unread: false).spoken == "Needs you")
    }
}
