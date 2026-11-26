import Foundation
import Testing
@testable import Echo

/// A reply that was only the plan, on real Hermes (scripts/hermes-lab/lab.sh planonly): the stub's
/// "lab:plan" answers with what Sol wrote on 2026-11-26, a plan and nothing else, and Hermes's word
/// to go on with "[answered after the plan]". Redde's plugin (1.49.0) hands the plan to Hermes's
/// stall guard, so the app has the plan as a working note and the answer as the reply, live and read
/// back, on both connections (`StreamedText`, `foldingContinuations`). Skips with no lab up.
@MainActor
struct HermesLabPlanOnlyTests {
    private static let api = URL(string: "http://127.0.0.1:18642")!
    private static let key = "labkey-labkey-labkey"
    private static let answer = "[answered after the plan]"
    private static let planStart = "Robin's letting me know they're going mini golfing today"

    private static func planNote(_ message: Message?) -> Bool {
        message?.notes.contains { $0.text.hasPrefix(planStart) && !$0.text.contains("Let me now do that.") } == true
    }

    @Test func aPlanOnlyReplyGoesOnToTheAnswerOnBothConnections() async throws {
        guard let client = await HermesLabApprovalTests.client() else { return }
        defer { client.disconnect() }
        guard (try? await PushService.command(over: client)("status"))?.hasPrefix("redde-push status") == true else {
            print("LAB SKIP: this lab's Hermes has no push plugin (scripts/hermes-lab/lab.sh up <tag> push)")
            return
        }

        // The Dashboard: live, then read back.
        let (_, stored) = try await client.openSession(stored: nil)
        var events: [TurnEvent] = []
        var reply = ""
        for try await event in HermesServeTransport(client: client).stream(TurnRequest(userText: "lab:plan", history: [], sessionID: stored, model: nil, instructions: nil)) {
            events.append(event)
            switch event {
            case let .textDelta(text): reply += text
            case let .textFinal(text): reply = text
            case .interim(_, true): reply = ""
            default: break
            }
        }
        let notes = events.compactMap { event -> (String, Bool)? in if case let .interim(text, streamed) = event { (text, streamed) } else { nil } }
        HermesLabApprovalTests.report(notes.count == 1 && notes[0].0.hasPrefix(Self.planStart) && notes[0].0.hasSuffix("Let me now do that.") && notes[0].1,
                                      "the Dashboard: the plan comes as working text, taken for what streamed", "\(notes)")
        HermesLabApprovalTests.report(reply == Self.answer, "and the reply is the answer after it", reply)
        let back = Conversation.messages(fromServeRows: try await client.history(stored: stored))
        HermesLabApprovalTests.report(back.last?.text == Self.answer && Self.planNote(back.last) && !back.contains { $0.text.hasPrefix("[System:") },
                                      "read back from the Dashboard: the plan a working note, Hermes's word to go on left out",
                                      "\(back.map { ($0.role, $0.text.prefix(50), $0.notes.map { $0.text.prefix(30) }) })")

        // The Hermes API, through the app's own conversation: live, then read back.
        let ledger = HermesSessionsAPI(baseURL: Self.api, apiKey: Self.key)
        let settings = Settings(defaults: UserDefaults(suiteName: "lab-planonly-\(UUID().uuidString)")!)
        settings.transport = .hermesSessions
        settings.gatewayURL = Self.api.absoluteString
        let account = Keychain.account(.gatewayAPIKey)
        let keyBefore = Keychain.read(account: account)
        Keychain.write(account: account, value: Self.key)
        defer { if let keyBefore { Keychain.write(account: account, value: keyBefore) } else { Keychain.delete(account: account) } }
        let conversation = Conversation(settings: settings, store: ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "lab-planonly-\(UUID().uuidString)")))
        _ = conversation.send("lab:plan")
        for _ in 0 ..< 600 where conversation.isStreaming { try await Task.sleep(for: .milliseconds(100)) }
        let live = conversation.messages.last
        HermesLabApprovalTests.report(live?.text == Self.answer && Self.planNote(live),
                                      "the Hermes API: the app's reply is the answer, the plan a working note",
                                      "\(live?.text.prefix(80) ?? "") notes: \(live?.notes.map(\.text) ?? [])")
        guard let session = conversation.serverSessionID else {
            HermesLabApprovalTests.report(false, "and the conversation has its session", "")
            return
        }
        let stored2 = Conversation.mapStored(try await ledger.messages(sessionID: session))
        HermesLabApprovalTests.report(stored2.last?.text == Self.answer && Self.planNote(stored2.last) && !stored2.contains { $0.text.hasPrefix("[System:") },
                                      "and read back from the Hermes API the same way",
                                      "\(stored2.map { ($0.role, $0.text.prefix(50), $0.notes.map { $0.text.prefix(30) }) })")
    }
}
