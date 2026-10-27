import Foundation
import Testing
import UserNotifications
@testable import Echo

/// Calls from agents (`AgentCalls`): what a call's push comes to, what the plugin is told, the
/// note the agent gets with the person's first words, and a missed call's notification. CallKit
/// and PushKit themselves are tried on a phone.
@MainActor
struct AgentCallsTests {
    /// A call sealed by the plugin's own code (`core.call_note`, `core.sealed`) for the pairing in
    /// `PushTests`' vectors:
    /// {"v":1,"k":"call","at":1793050000,"n":"studio","p":"ops","d":"Home","s":"20261026_180000_ab12cd","i":"4ddc1e9570a3491e","b":"The garage door has been open for an hour."}
    static let sealedCall = "riAr7rohLAyfDgRsfqK3EEAHX6VhpzrgP3mhBvdLv81sdJ0z20ixZCaTBqs+onde7Ig+TMaiEQCJcAgAsNmuaz+mHXdMov2ECVVHHXHVGrCnLE6cQDeFavwGKEXSmx0f3ynYVzRFULC9V5ABhRWEp8Inojl8LMGWtH+XPcos2jZivxvUrTq01P2t7LrH4z7lvD4FcAzpSed3eu4/ASPkzfAmj/vXROEE6izcNd08x+k04o7RCmRKFEL8Rqc1TdwXrLFWXYLXbb6Y"
    static let pairing = PushPairing(id: "dev-test-0001", sendKey: "send-key",
                                     key: Data(hexPairs: "cad4112e909263b723613b895715fabcce5c9d1f2a55284ecccfd66d5abd4c51"),
                                     relay: "https://relay.test")
    static let at = Date(timeIntervalSince1970: 1_793_050_000)

    private func call(_ note: PushNote?, on: Bool = true, busy: Bool = false, now: Date = at, names: [String: String] = [:]) -> AgentCallPlan {
        AgentCallPlan.decide(note, callsOn: on, busy: busy, now: now, id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!) { names[$0] }
    }

    @Test func thePluginsCallOpensAndRingsAsTheBotThisPhoneKnows() throws {
        let opened = try #require(PushSeal.note(from: Self.sealedCall, pairings: [Self.pairing]))
        #expect(opened.note.kind == .call && opened.note.i == "4ddc1e9570a3491e")
        guard case let .ring(ringing) = call(opened.note, names: ["ops": "Home Base"]) else { Issue.record("didn't ring"); return }
        #expect(ringing.profile == "ops" && ringing.name == "Home Base", "the phone's own name for the bot")
        #expect(ringing.line == "The garage door has been open for an hour." && ringing.session == "20261026_180000_ab12cd")
        guard case let .ring(unnamed) = call(opened.note) else { Issue.record("didn't ring"); return }
        #expect(unnamed.name == "Home", "else the name it came with")
    }

    @Test func aPushThatShouldntRingIsRefused() throws {
        let note = try #require(PushSeal.note(from: Self.sealedCall, pairings: [Self.pairing])).note
        #expect(call(nil) == .refuse("a call this iPhone couldn't open"))
        #expect(call(note, on: false) == .refuse("calls are off"))
        #expect(call(note, busy: true) == .refuse("on a call already"))
        #expect(call(note, now: Self.at.addingTimeInterval(121)) == .refuse("too late to ring"))
        var reply = note
        reply.k = "reply"
        #expect(call(reply) == .refuse("not a call: reply"))
        var bare = note
        bare.p = nil
        bare.d = nil
        guard case let .ring(main) = call(bare) else { Issue.record("didn't ring"); return }
        #expect(main.profile == "default" && main.name == "Your agent")
    }

    @Test func anAnsweredCallIsToldByItsID() throws {
        let note = try #require(PushSeal.note(from: Self.sealedCall, pairings: [Self.pairing])).note
        #expect(AgentCallPlan.answeredCommand(note) == "calls answered 4ddc1e9570a3491e")
        var odd = note
        odd.i = "not an id"
        #expect(AgentCallPlan.answeredCommand(odd) == nil)
        odd.i = nil
        #expect(AgentCallPlan.answeredCommand(odd) == nil)
    }

    @Test func thePluginIsToldEveryPairingAndTheAgentsOrNone() {
        #expect(AgentCallPlan.command(pairings: [], callers: ["default"]) == nil)
        #expect(AgentCallPlan.command(pairings: ["a", "b"], callers: ["default", "ops"]) == "calls a,b default,ops")
        #expect(AgentCallPlan.command(pairings: ["a"], callers: []) == "calls a none")
        #expect(AgentCallPlan.command(pairings: ["a"], callers: ["", "x y", "p,q", "scout"]) == "calls a scout")
    }

    @Test func theFirstWordsAfterAnsweringTellTheAgentAndReddeHidesIt() {
        let line = "The garage door has been open for an hour."
        let sent = "Close it, please." + CallNote.note(line)
        #expect(sent.hasSuffix("You opened with: \"The garage door has been open for an hour.\"]"))
        #expect(CallNote.strip(sent) == "Close it, please.")
        #expect(ReplyLanguage.stripNote(sent) == "Close it, please.")
        #expect(CallNote.strip("Close it [and] \"this\"]") == "Close it [and] \"this\"]", "only its own note")
        #expect(CallNote.instruction(line).contains(line) && CallNote.instruction(line).contains("answered your phone call"))
        #expect(CallNote.note("one\ntwo").contains("one two"), "on one line, so it can be found again")
    }

    @Test func aMissedCallSaysWhatItWasAboutAndOpensItsChat() throws {
        let note = try #require(PushSeal.note(from: Self.sealedCall, pairings: [Self.pairing])).note
        let content = UNMutableNotificationContent()
        #expect(note.fill(content))
        #expect(content.title == "Missed call from Home" && content.body == "The garage door has been open for an hour.")
        #expect(content.userInfo[PushNote.botKey] as? String == "ops")
        #expect(content.userInfo[PushNote.sessionKey] as? String == "20261026_180000_ab12cd")
        var main = note
        main.p = "default"
        let mainContent = UNMutableNotificationContent()
        main.fill(mainContent)
        #expect(mainContent.userInfo[PushNote.botKey] == nil, "the main agent's opens the conversation it called from")
    }

    /// Talk While Locked (asked 2026-10-26): off, a call answered on a locked iPhone waits for the
    /// unlock before it listens; Redde's own lock always waits.
    @Test func aLockedPhoneListensOnlyWithTalkWhileLocked() {
        #expect(AgentCallPlan.listens(appLocked: false, phoneLocked: false, whileLocked: false))
        #expect(!AgentCallPlan.listens(appLocked: false, phoneLocked: true, whileLocked: false))
        #expect(AgentCallPlan.listens(appLocked: false, phoneLocked: true, whileLocked: true))
        #expect(!AgentCallPlan.listens(appLocked: true, phoneLocked: false, whileLocked: true), "Redde's lock always waits")
        #expect(AgentCallPlan.untilUnlocked(appLocked: false) == "Unlock your iPhone to answer.")
        #expect(AgentCallPlan.untilUnlocked(appLocked: true) == "Unlock Redde to answer.")
    }

    @Test func callsAreThisPhonesAloneAndKeptPerServer() {
        let settings = Settings(defaults: UserDefaults(suiteName: "calls-\(UUID().uuidString)")!)
        #expect(!settings.agentCalls && settings.callersHere.isEmpty && !settings.callsWhileLocked)
        settings.callsWhileLocked = true
        settings.agentCalls = true
        settings.callersHere = ["default", "ops"]
        #expect(settings.callers[settings.activeServerID.uuidString] == ["default", "ops"])
        #expect(!Settings.syncedKeys.contains("agentCalls") && !Settings.syncedKeys.contains("callers")
                && !Settings.syncedKeys.contains("callsWhileLocked"))
        settings.reset()
        #expect(!settings.agentCalls && settings.callers.isEmpty && !settings.callsWhileLocked)
    }
}

private extension Data {
    init(hexPairs hex: String) {
        var bytes = [UInt8]()
        var rest = Substring(hex)
        while rest.count >= 2 {
            bytes.append(UInt8(rest.prefix(2), radix: 16)!)
            rest = rest.dropFirst(2)
        }
        self.init(bytes)
    }
}
