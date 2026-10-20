import Foundation
import Testing
import UserNotifications
@testable import Echo

/// Group chat notifications from a paired Hermes (the plugin's `rooms.py`): what they say, what a
/// tap or a button on one does, and which group chats the phone follows.
struct GroupNotesTests {
    private func content(_ note: PushNote) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Redde"
        note.fill(content)
        return content
    }

    @Test func aBotsMessageReadsAsAGroupChatsDoes() {
        let shown = content(PushNote(k: "group", t: "Weekend hike", b: "Falls Loop is **open**.", d: "Scout", g: "room-a"))
        #expect(shown.title == "Weekend hike" && shown.subtitle == "Scout" && shown.body == "Falls Loop is open.")
        #expect(shown.categoryIdentifier == PushNote.groupRepliedCategory, "Reply answers in the room")
        #expect(shown.threadIdentifier == "redde.group.room-a", "a group chat's stack together")
        #expect(shown.userInfo[PushNote.roomKey] as? String == "room-a" && shown.userInfo[PushNote.sessionKey] == nil)
    }

    @Test func aCommandABotWaitsOnCanBeAnsweredFromTheNotification() {
        let digest = PushNote.digest(of: "rm -rf build")
        let shown = content(PushNote(k: "group_wait", t: "Weekend hike", b: "rm -rf build", d: "Scout", h: digest, g: "room-a",
                                     w: "approval", r: "recursive delete"))
        #expect(shown.title == "Scout needs your approval" && shown.subtitle == "Weekend hike")
        #expect(shown.body == "recursive delete\nrm -rf build")
        #expect(shown.categoryIdentifier == PushNote.groupApprovalCategory)
        #expect(shown.userInfo[PushNote.approvalKey] as? String == digest)
        let retry = content(PushNote(k: "group_wait", t: "Garage project", g: "room-b", w: "retry", x: "t9"))
        #expect(retry.title == "A reply didn't finish" && retry.categoryIdentifier == PushNote.groupRetryCategory)
        #expect(retry.userInfo[PushNote.taskKey] as? String == "t9")
    }

    @Test func aGroupChatsNotesLeaveTheNeedsYouWidgetAlone() {
        let defaults = UserDefaults(suiteName: "group-notes-\(UUID().uuidString)")!
        #expect(!NeedsYou.take(PushNote(k: "group_wait", b: "rm -rf build", g: "room-a", w: "approval"), in: defaults))
    }

    // MARK: Taps and buttons

    final class Calls {
        var said: [String] = []
        var waiting: [GroupApproval] = []
    }

    private func harness(_ calls: Calls) -> NotifierTests.Harness {
        let h = NotifierTests.Harness()
        h.notifier.groupCalls = Notifier.GroupCalls(
            state: { _ in GroupState(approvals: calls.waiting) },
            approve: { room, approval, choice in calls.said.append("approve \(room) \(approval.request.id) \(choice)") },
            retry: { room, task in calls.said.append("retry \(room) \(task)") },
            send: { room, text in calls.said.append("send \(room) \(text)") })
        return h
    }

    private func approval(_ request: String, _ command: String) -> GroupApproval {
        GroupApproval(.object(["kind": .string("approval"), "member_id": .string("scout"), "task_id": .string("t1"),
                               "execution_generation": .number(1), "request_id": .string(request),
                               "approval": .object(["command": .string(command), "choices": .array([.string("once"), .string("deny")])])]))!
    }

    @Test func aTapOpensTheGroupChat() {
        let h = harness(Calls())
        _ = LaunchRouter.shared.consumeRoom()
        h.notifier.route(action: UNNotificationDefaultActionIdentifier, requestID: nil, questionID: nil, approve: nil, deny: nil,
                         userText: nil, room: "room-a")
        #expect(LaunchRouter.shared.consumeRoom() == "room-a")
        #expect(LaunchRouter.shared.consumeSession() == nil)
    }

    @Test func approveAnswersTheCommandTheNotificationShowed() async {
        let calls = Calls()
        calls.waiting = [approval("r0", "ls"), approval("r1", "rm -rf build")]
        let h = harness(calls)
        await h.notifier.route(action: "redde.approve", requestID: nil, questionID: nil, approve: nil, deny: nil, userText: nil,
                               approvalDigest: PushNote.digest(of: "rm -rf build"), room: "room-a")?.value
        await h.notifier.route(action: "redde.deny", requestID: nil, questionID: nil, approve: nil, deny: nil, userText: nil,
                               approvalDigest: PushNote.digest(of: "ls"), room: "room-a")?.value
        #expect(calls.said == ["approve room-a r1 once", "approve room-a r0 deny"])
        #expect(h.center.added.isEmpty)
    }

    @Test func anApprovalNoLongerWaitingSaysSoAndOpensTheGroupChat() async throws {
        let calls = Calls()
        let h = harness(calls)
        await h.notifier.route(action: "redde.approve", requestID: nil, questionID: nil, approve: nil, deny: nil, userText: nil,
                               approvalDigest: PushNote.digest(of: "rm -rf build"), room: "room-a")?.value
        #expect(calls.said.isEmpty)
        let said = try #require(h.center.added.first)
        #expect(said.content.title == "The approval wasn't answered" && said.content.body.contains("no longer waiting"))
        #expect(said.content.userInfo[PushNote.roomKey] as? String == "room-a", "a tap opens the group chat")
    }

    @Test func retryAndReplyGoToTheRoom() async {
        let calls = Calls()
        let h = harness(calls)
        await h.notifier.route(action: PushNote.retryAction, requestID: nil, questionID: nil, approve: nil, deny: nil, userText: nil,
                               room: "room-b", task: "t9")?.value
        await h.notifier.route(action: "redde.followup", requestID: nil, questionID: nil, approve: nil, deny: nil,
                               userText: "  Saturday works.  ", room: "room-a")?.value
        #expect(calls.said == ["retry room-b t9", "send room-a Saturday works."])
    }

    @Test func theButtonsWaitForAnUnlock() {
        let h = NotifierTests.Harness()
        h.notifier.registerCategories()
        for (category, titles) in [(PushNote.groupRepliedCategory, ["Reply"]), (PushNote.groupApprovalCategory, ["Approve", "Deny"]),
                                   (PushNote.groupRetryCategory, ["Retry"])] {
            let found = h.center.categories.first { $0.identifier == category }
            #expect(found?.actions.map(\.title) == titles)
            #expect(found?.actions.allSatisfy { $0.options.contains(.authenticationRequired) } == true)
        }
    }

    @Test func aNoteAboutTheGroupChatOnScreenIsntShownOverIt() {
        let h = NotifierTests.Harness(appActive: true)
        let groups = GroupDirectory.shared
        let before = groups.open
        defer { groups.open = before }
        groups.open = GroupRoom(.object(["room_id": .string("room-a"), "name": .string("Weekend hike")]))
        #expect(h.notifier.presentation(pushKind: "group", sessionID: nil, room: "room-a") == [])
        #expect(h.notifier.presentation(pushKind: "group", sessionID: nil, room: "room-b").contains(.banner))
    }

    // MARK: Which group chats

    @Test func thePhoneSaysWhichGroupChatsItFollowsWhenTheListChanges() {
        let pairing = PushPairing(id: "dev-1", sendKey: "s", key: Data(repeating: 1, count: 32), relay: "https://relay.example", confirmed: true)
        let service = PushService(defaults: UserDefaults(suiteName: "group-notes-\(UUID().uuidString)")!, session: RelayStub.session,
                                  vault: ({ [pairing] }, { _ in true }), askForToken: {}, allowed: { true })
        #expect(service.followRoomsCommand(["room-b", "room-a"], server: "A") == "rooms dev-1 room-a,room-b")
        #expect(service.followRoomsCommand(["room-a", "room-b"], server: "A") == nil, "said already")
        #expect(service.followRoomsCommand(["room-a"], server: "A") == "rooms dev-1 room-a")
        #expect(service.followRoomsCommand([], server: "A") == "rooms dev-1", "none: the plugin lets them all go")
        #expect(service.followRoomsCommand(["room-a"], server: "B") == "rooms dev-1 room-a", "each server its own")
        let unpaired = PushService(defaults: UserDefaults(suiteName: "group-notes-\(UUID().uuidString)")!, session: RelayStub.session,
                                   vault: ({ [] }, { _ in true }), askForToken: {}, allowed: { true })
        #expect(unpaired.followRoomsCommand(["room-a"], server: "A") == nil)
    }
}
