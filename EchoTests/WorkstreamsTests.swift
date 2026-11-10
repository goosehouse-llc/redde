import Foundation
import Testing
import UserNotifications
@testable import Echo

/// Workstreams (2026-11-10, plugin 1.22's `work.py`): the plugin's list read, a report to the chat
/// that started one shown as a notice, its steps named, its notes said and tapped through.
@MainActor
struct WorkstreamsTests {
    static let answer = """
    redde-push work {"profile": "coder", "engine": "serve", "work": [
      {"id": "W2", "title": "Write the notes", "status": "needs_you", "session": "s2", "chat": "c1", "last": "",
       "asked": "git push origin main", "created": 2000, "updated": 2010, "ended": null},
      {"id": "W1", "title": "Fix the build", "status": "done", "session": "s1", "chat": "c1",
       "last": "Fixed: a missing import.", "asked": "", "created": 1000, "updated": 1500, "ended": 1500}]}
    """

    @Test func readsThePluginsList() throws {
        let parsed = try #require(Workstream.parse(Self.answer))
        #expect(parsed.profile == "coder")
        #expect(parsed.work.map(\.id) == ["W2", "W1"])
        #expect(parsed.work[0].status == .needsYou && parsed.work[0].isOpen && parsed.work[0].asked == "git push origin main")
        #expect(parsed.work[1].status == .done && !parsed.work[1].isOpen && parsed.work[1].ended == Date(timeIntervalSince1970: 1500))
        #expect(Workstream.parse("redde-push: this command is for the Redde app.") == nil, "a plugin older than 1.22")
    }

    @Test func listsAnAgentsFromOneChatOpenFirst() async {
        let store = Workstreams()
        store.connection = { "lab" }
        store.reachable = { true }
        var asked: [String] = []
        let fresh = Self.answer.replacingOccurrences(of: "\"created\": 2000, \"updated\": 2010", with: "\"created\": \(Int(Date.now.timeIntervalSince1970)), \"updated\": \(Int(Date.now.timeIntervalSince1970))")
            .replacingOccurrences(of: "\"updated\": 1500, \"ended\": 1500", with: "\"updated\": \(Int(Date.now.timeIntervalSince1970)), \"ended\": \(Int(Date.now.timeIntervalSince1970))")
        store.plugin = { asked.append($0); return fresh }
        await store.refresh("coder")
        #expect(asked == ["work list coder"])
        #expect(store.of("coder", chat: "c1").map(\.id) == ["W2", "W1"])
        #expect(store.of("coder", chat: "elsewhere").isEmpty)
        #expect(store.of("scout", chat: "c1").isEmpty)
    }

    @Test func stopsOneAndSaysWhyNot() async {
        let store = Workstreams()
        store.reachable = { true }
        var asked: [String] = []
        store.plugin = { command in
            asked.append(command)
            if command.hasPrefix("work stop") {
                return command.hasSuffix("W2") ? #"redde-push work {"stopped": "W2"}"# : #"redde-push work {"error": "W1 isn't running."}"#
            }
            return Self.answer
        }
        #expect(await store.stop("W2", of: "coder") == nil)
        #expect(await store.stop("W1", of: "coder") == "W1 isn't running.")
        #expect(asked.contains("work stop coder W2"))
    }

    @Test func aReportIsANotice() throws {
        let text = "[Workstream W1 \"Fix the build\" finished. This is a report from your own workstream, not the user's words. Tell the user briefly what came of it, or answer exactly [SILENT] if there is nothing they need to hear.]\n\nFixed: a missing import."
        let (delivered, body) = try #require(Workstream.notice(text))
        #expect(delivered.kind == .task)
        #expect(delivered.title == "W1 finished: Fix the build")
        #expect(body == "Fixed: a missing import.")
        let stopped = try #require(Workstream.notice("[Workstream W3 \"Lab slow job\" was stopped. This is a report…]"))
        #expect(stopped.0.title == "W3 was stopped: Lab slow job" && stopped.1.isEmpty)
        #expect(Workstream.notice("[Workstream nonsense") == nil)
    }

    /// Hermes's apps leave a hidden turn out; Redde shows a workstream's report as its notice,
    /// folded once the agent answered, and an answer of [SILENT] not at all.
    @Test func theHiddenReportShowsInTheChat() async throws {
        let report = "[Workstream W1 \"Fix the build\" finished. This is a report from your own workstream, not the user's words.]\n\nFixed."
        let raw: [[String: Any]] = [
            ["role": "user", "text": "Fix the build in the background", "timestamp": 1000],
            ["role": "assistant", "text": "Started W1.", "timestamp": 1001],
            ["role": "user", "text": report, "display_kind": "hidden", "timestamp": 1500],
            ["role": "assistant", "text": "W1 is done: it was a missing import.", "timestamp": 1501],
            ["role": "user", "text": "[Workstream W2 \"Quiet\" finished. …]\n\nNothing.", "display_kind": "hidden", "timestamp": 1600],
            ["role": "assistant", "text": "[SILENT]", "timestamp": 1601],
            ["role": "user", "text": "Some other hidden turn", "display_kind": "hidden", "timestamp": 1700],
        ]
        let rows = try #require(JSONValue.parse(JSONSerialization.data(withJSONObject: raw)).array)
        let messages = await Conversation.readied(serveRows: rows)
        #expect(messages.map(\.text) == ["Fix the build in the background", "Started W1.", "Fixed.", "W1 is done: it was a missing import.", "Nothing."])
        #expect(messages[2].delivered?.title == "W1 finished: Fix the build" && messages[2].delivered?.noted == true)
        #expect(messages[4].delivered?.noted == false)
    }

    @Test func itsStepsAreNamed() {
        func step(_ args: [String: Any]) -> String? {
            let value = try? JSONValue.parse(JSONSerialization.data(withJSONObject: args))
            return BotMessages.stepName(ToolActivity(name: "redde_work", preview: nil, status: .completed, args: ToolActivity.args("redde_work", value)))
        }
        #expect(step(["action": "start", "title": "Fix the build", "brief": "Long\nbrief"]) == "Started a workstream: Fix the build")
        #expect(step(["action": "stop", "id": "w2"]) == "Stopped W2")
        #expect(step(["action": "send", "id": "W2", "text": "more"]) == "Gave W2 more to do")
        #expect(step(["action": "list"]) == "Checked on its workstreams")
    }

    @Test func itsNoteSaysWhatCameOfIt() {
        let done = UNMutableNotificationContent()
        #expect(PushNote(k: "work", s: "s1", t: "Fix the build", b: "Fixed: a missing import.", d: "Coder", w: "done", x: "W1", p: "coder").fill(done))
        #expect(done.title == "Fix the build" && done.subtitle == "Coder" && done.body == "Fixed: a missing import.")
        #expect(done.userInfo[PushNote.sessionKey] as? String == "s1")
        #expect(done.userInfo[PushNote.profileKey] as? String == "coder")
        #expect(done.userInfo[PushNote.titleKey] as? String == "W1 · Fix the build")
        #expect(done.userInfo[PushNote.botKey] == nil, "a tap opens the workstream, not the bot's chat")
        #expect(done.userInfo[PushNote.taskKey] == nil)

        let needs = UNMutableNotificationContent()
        #expect(PushNote(k: "work", s: "s2", t: "Write the notes", b: "git push origin main", d: "Coder", w: "needs", x: "W2", p: "coder").fill(needs))
        #expect(needs.title == "Coder needs your approval" && needs.subtitle == "W2 · Write the notes" && needs.body == "git push origin main")

        let mine = UNMutableNotificationContent()
        #expect(PushNote(k: "work", s: "s3", t: "Tidy", d: "default", w: "needs", x: "W3", p: "default").fill(mine))
        #expect(mine.title == "Redde needs your approval")
    }

    @Test func aTapOpensTheWorkstreamInItsProfile() {
        let router = LaunchRouter.shared
        router.requestSession("s2", profile: "coder", title: "W2 · Write the notes")
        #expect(router.consumeSession() == "s2")
        let place = router.consumeSessionPlace()
        #expect(place.profile == "coder" && place.title == "W2 · Write the notes")
        router.requestSession("s3", profile: "default")
        _ = router.consumeSession()
        #expect(router.consumeSessionPlace().profile == nil, "the main agent's is no other profile")
    }
}
