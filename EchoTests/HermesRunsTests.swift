import Foundation
import Testing
import UIKit
@testable import Echo

/// Hermes API turns as runs (`HermesRuns`): what a run is started with, and its events and status
/// as Hermes 0.21 (no numbers) and 0.22 (numbered, `id:` lines) send them. Leaving a run, taking
/// it up again and stopping it are checked against real Hermes in `HermesLabRunsTests`.
struct HermesRunsTests {
    /// A run's event as it arrives: no `event:` line, the name inside; 0.22 adds `id:` and `seq`.
    private func ev(_ json: String, id: String? = nil) -> SSEEvent { SSEEvent(event: nil, data: json, id: id) }

    private func decode(_ json: String, id: String? = nil) throws -> HermesRuns.Decoded {
        try #require(HermesRuns.decode(ev(json, id: id), run: "run_1"))
    }

    @Test func wordsThinkingAndToolsAsTheyCome() throws {
        #expect(try decode(#"{"event":"message.delta","run_id":"run_1","delta":"Hel"}"#).events == [.textDelta("Hel")])
        #expect(try decode(#"{"event":"reasoning.available","run_id":"run_1","text":"hmm"}"#).events == [.reasoningDelta("hmm")])
        #expect(try decode(#"{"event":"tool.started","tool":"memory","preview":"add"}"#).events == [.toolStarted(name: "memory", preview: "add")])
        #expect(try decode(#"{"event":"tool.completed","tool":"memory","duration":0.2,"error":false,"preview":"saved"}"#).events
                == [.toolFinished(name: "memory", failed: false, output: "saved")])
        #expect(try decode(#"{"event":"tool.completed","tool":"terminal","error":true}"#).events == [.toolFinished(name: "terminal", failed: true)])
        #expect(try decode(#"{"event":"message.interim","text":"x","already_streamed":true}"#).events.isEmpty)
        #expect(try decode(#"{"event":"run.steered","accepted":true}"#).events.isEmpty)
    }

    @Test func eventsAreNumberedOnHermes022() throws {
        #expect(try decode(#"{"event":"message.delta","delta":"a","seq":7}"#, id: "7").seq == 7)
        #expect(try decode(#"{"event":"message.delta","delta":"a"}"#, id: "12").seq == 12, "the id line alone")
        #expect(try decode(#"{"event":"message.delta","delta":"a"}"#).seq == nil, "0.21 numbers nothing")
        #expect(HermesRuns.decode(ev("not json"), run: "run_1") == nil)
    }

    @Test func theRunsEndSaysHowItEnded() throws {
        let done = try decode(#"{"event":"run.completed","output":"All done. MEDIA:/tmp/chart.png","usage":{"input_tokens":50,"output_tokens":9,"total_tokens":59}}"#)
        #expect(done.ending == .completed)
        #expect(done.events == [.textFinal("All done. MEDIA:/tmp/chart.png"), .usage(TokenUsage(input: 50, output: 9, cached: nil))])
        #expect(try decode(#"{"event":"run.failed","error":"No LLM provider configured"}"#).ending == .failed("No LLM provider configured"))
        #expect(try decode(#"{"event":"run.cancelled"}"#).ending == .stopped)
        #expect(try decode(#"{"event":"run.interrupted"}"#).ending == .stopped)
        let named = "confirmed model lock runtime mismatch: expected provider=custom:lab model=m; actual provider=custom model=m"
        let mismatch = try decode(#"{"event":"run.failed","error":"\#(named)","output":"[A:m]"}"#)
        #expect(mismatch.ending == .completed && mismatch.events == [.textFinal("[A:m]")], "the pre-0.21.4 check, wrong about a turn that ran right")
    }

    @Test func approvalsAndSubagentsAsTheRunSaysThem() throws {
        let asked = try decode(#"{"event":"approval.request","request_id":"req1","command":"rm -rf /tmp/x","allow_session":true,"allow_permanent":false}"#)
        #expect(asked.events == [.interrupt(.approval(ApprovalRequest(id: "req1", command: "rm -rf /tmp/x", description: nil,
                                                                      choices: ["once", "session", "deny"])), runtimeSession: "run_1")])
        let started = try decode(#"{"event":"subagent.start","subagent_id":"sa1","goal":"Check the feed","task_index":0,"task_count":2}"#)
        #expect(started.events == [.subagent(SubagentUpdate(id: "sa1", goal: "Check the feed", taskIndex: 0, taskCount: 2, phase: .started))])
        let ended = try decode(#"{"event":"subagent.complete","subagent_id":"sa1","goal":"Check the feed","status":"success","summary":"Fine"}"#)
        #expect(ended.events.count == 1)
    }

    @Test func aRunsStatusWhenItsEventsAreGone() {
        func status(_ json: String) -> HermesRuns.Decoded {
            HermesRuns.decode(status: try! JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)), run: "run_1")
        }
        #expect(status(#"{"status":"running"}"#) == HermesRuns.Decoded())
        #expect(status(#"{"status":"completed","output":"Hi"}"#).events == [.textFinal("Hi")])
        #expect(status(#"{"status":"completed","output":"Hi"}"#).ending == .completed)
        #expect(status(#"{"status":"failed","error":"boom"}"#).ending == .failed("boom"))
        #expect(status(#"{"status":"cancelled"}"#).ending == .stopped)
        let waiting = status(#"{"status":"waiting_for_approval","approval":{"event":"approval.request","request_id":"r2","command":"sudo x","choices":["once","deny"]}}"#)
        #expect(waiting.events == [.interrupt(.approval(ApprovalRequest(id: "r2", command: "sudo x", description: nil, choices: ["once", "deny"])),
                                              runtimeSession: "run_1")])
        #expect(waiting.ending == nil)
    }

    @Test func aRunStartsWithOneMessageInItsSession() throws {
        var request = TurnRequest(userText: "What's this?", history: [], sessionID: "s1", model: "beta", provider: "custom:lab",
                                  reasoningEffort: "high", instructions: nil, replyLanguage: "nl", brief: true)
        let body = try HermesSessionsTransport.runBody(request, sessionID: "s1")
        #expect(body.session_id == "s1" && body.model == "beta" && body.provider == "custom:lab" && body.model_options?.reasoning_effort == "high")
        #expect(body.input == .string("What's this?"))
        let instructions = try #require(body.instructions)
        #expect(instructions.hasPrefix(HermesSessionsTransport.clientHint) && instructions.contains("Dutch") && instructions.contains("driving"))

        let picture = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { $0.fill(CGRect(x: 0, y: 0, width: 40, height: 30)) }
        request.attachments = [try #require(Attachment.image(picture))]
        let withPicture = try HermesSessionsTransport.runBody(request, sessionID: "s1").input
        let messages = try #require(withPicture.array)
        #expect(messages.count == 1, "one message: more would stand in for the session's history")
        #expect(messages[0]["role"]?.string == "user")
        let parts = try #require(messages[0]["content"]?.array)
        #expect(parts.first?["type"]?.string == "text" && parts.first?["text"]?.string == "What's this?")
        #expect(parts.last?["type"]?.string == "image_url" && parts.last?["image_url"]?["url"]?.string?.hasPrefix("data:image/") == true)

        request.model = ""
        request.reasoningEffort = ""
        let plain = try HermesSessionsTransport.runBody(request, sessionID: "s1")
        #expect(plain.model == nil && plain.model_options == nil, "nothing picked: the host's default")
    }

    @Test func troubleThatPassesIsWaitedOut() {
        #expect(HermesRuns.isTransient(URLError(.networkConnectionLost)))
        #expect(HermesRuns.isTransient(URLError(.timedOut)))
        #expect(HermesRuns.isTransient(TransportError.http(status: 502, body: "")))
        #expect(HermesRuns.isTransient(TransportError.streamLost("x")))
        #expect(!HermesRuns.isTransient(TransportError.http(status: 401, body: "")))
        #expect(!HermesRuns.isTransient(TransportError.malformed("x")))
    }
}

/// What the Hermes API connection does that only the Dashboard did: a conversation's fast mode,
/// asked for on each run; files other than pictures, put on the server through the Dashboard's
/// login and named in the message.
@MainActor
struct APIConnectionTests {
    @Test func fastModeIsTheConversationsAndRidesOnEachRun() async throws {
        let defaults = UserDefaults(suiteName: "run-controls-\(UUID().uuidString)")!
        let settings = Settings(defaults: defaults)
        settings.transport = .hermesSessions
        let controls = RunChatControls(defaults: defaults, settings: settings)
        #expect(try await controls.chatControls(stored: "s1").fast == false)
        _ = try await controls.setFast(true, stored: "s1")
        #expect(controls.isFast("s1") && !controls.isFast("s2"))
        #expect(RunChatControls(defaults: defaults, settings: settings).isFast("s1"), "kept across launches")
        await #expect(throws: (any Error).self) { try await controls.setAutoApprove(true, stored: "s1") }
        _ = try await controls.setFast(false, stored: "s1")
        #expect(!controls.isFast("s1"))

        var request = TurnRequest(userText: "hi", history: [], sessionID: "s1", model: nil, instructions: nil)
        request.fast = true
        #expect(try HermesSessionsTransport.runBody(request, sessionID: "s1").model_options?.fast == true)
        request.fast = false
        #expect(try HermesSessionsTransport.runBody(request, sessionID: "s1").model_options == nil)
    }

    @Test func aFileGoesToTheServerAndTheMessageSaysWhere() async throws {
        let files = DemoServerFiles()
        let pdf = Attachment(kind: .pdf, filename: "lease.pdf", mimeType: "application/pdf", data: Data(count: 1200))
        let picture = Attachment(kind: .image, filename: "a.jpg", mimeType: "image/jpeg", data: Data(count: 10))
        let request = TurnRequest(userText: "What does the lease say about pets?", history: [], sessionID: "s1", model: nil,
                                  instructions: nil, attachments: [pdf, picture])
        let placed = try await Conversation.placingFiles(request, client: files)
        #expect(placed.attachments.map(\.kind) == [.image], "a picture still goes in the message itself")
        #expect(placed.userText.hasPrefix("What does the lease say about pets?" + AttachedFileNote.opening))
        #expect(placed.userText.contains(DemoServerFiles.home + "/Redde attachments/") && placed.userText.contains("lease.pdf"))
        let folder = try await files.folder(at: DemoServerFiles.home + "/Redde attachments")
        #expect(folder.entries.contains { $0.name.hasSuffix("lease.pdf") })
        #expect(ReplyLanguage.stripNote(placed.userText) == "What does the lease say about pets?", "the note comes off what the app shows")
        let again = try await Conversation.placingFiles(request, client: files)
        #expect(again.userText.contains("lease.pdf"), "the folder there already is used as it is")
    }
}
