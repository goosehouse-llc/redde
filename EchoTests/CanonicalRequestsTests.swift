import Foundation
import Testing
@testable import Echo

/// The Dashboard's requests built for Hermes's canonical session owner, and left as they were for
/// `hermes serve` (GitHub issue 81). The shapes were read from 0.23.1's contracts and tried on the
/// lab's (`HermesLabCanonicalTests`); these keep them from drifting.
struct CanonicalRequestsTests {
    @Test func aNewChatIsAskedForInEachOwnersWords() {
        let serve = CanonicalRequests.create(model: "alpha", provider: "custom:lab", reasoningEffort: "high", folder: "/srv/p",
                                             hidden: true, profile: "scout", canonical: false)
        #expect(serve == ["source": .string("desktop"), "close_on_disconnect": .bool(false), "model": .string("alpha"),
                          "provider": .string("custom:lab"), "reasoning_effort": .string("high"), "cwd": .string("/srv/p"),
                          "hidden": .bool(true), "profile": .string("scout")])
        let canonical = CanonicalRequests.create(model: "alpha", provider: "custom:lab", reasoningEffort: "high", folder: "/srv/p",
                                                 hidden: true, profile: "scout", canonical: true)
        #expect(canonical == ["source": .string("gui"), "model": .string("alpha"), "provider": .string("custom:lab"),
                              "reasoning": .string("high"), "cwd": .string("/srv/p"), "hidden": .bool(true), "profile": .string("scout")])
        // Nothing asked for, nothing sent.
        #expect(CanonicalRequests.create(model: "", provider: nil, reasoningEffort: "", folder: nil, hidden: false, profile: nil, canonical: true)
                == ["source": .string("gui")])
    }

    @Test func aMessageIsNamedOnlyWhereItHasToBe() {
        let params: [String: JSONValue] = ["session_id": .string("s"), "text": .string("hi")]
        #expect(CanonicalRequests.submit(params, key: "turn-1", canonical: false) == params)
        #expect(CanonicalRequests.submit(params, key: "turn-1", canonical: true)["submission_id"] == .string("turn-1"))
        // No id of its own: one made up, never an empty one.
        let made = CanonicalRequests.submit(params, key: nil, canonical: true)["submission_id"]?.string ?? ""
        #expect(UUID(uuidString: made) != nil)
        #expect(CanonicalRequests.submit(params, key: "", canonical: true)["submission_id"]?.string?.isEmpty == false)
    }

    @Test func everyMessageThereIsQueuedSoItSaysNothing() {
        let queued: JSONValue = .object(["status": .string("queued")])
        #expect(CanonicalRequests.waitsBehindATurn(queued, canonical: false))
        #expect(!CanonicalRequests.waitsBehindATurn(queued, canonical: true))
        #expect(!CanonicalRequests.waitsBehindATurn(.object(["status": .string("started")]), canonical: false))
    }

    @Test func watchingASessionAsksNoAgentOnlyOnServe() {
        #expect(CanonicalRequests.resumeToWatch(stored: "s", canonical: false)["lazy"] == .bool(true))
        #expect(CanonicalRequests.resumeToWatch(stored: "s", canonical: true)["lazy"] == nil)
    }

    @Test func aSnapshotSaysWhichRunIsCurrentAndWhetherOneWaits() {
        let idle = JSONValue.object(["execution_generation": .number(3), "running": .bool(false), "pending": .array([])])
        #expect(CanonicalRequests.turn(idle) == .init(generation: 3, running: false, waiting: false))
        // Sent, not started: nothing runs yet, but a message waits to start one.
        let sent = JSONValue.object(["execution_generation": .number(3), "running": .bool(false),
                                     "pending": .array([.object(["status": .string("queued"), "text": .string("lab:slow")])])])
        #expect(CanonicalRequests.turn(sent) == .init(generation: 3, running: false, waiting: true))
        let running = JSONValue.object(["execution_generation": .number(4), "running": .bool(true),
                                        "pending": .array([.object(["status": .string("started"), "text": .string("lab:slow")])])])
        #expect(CanonicalRequests.turn(running) == .init(generation: 4, running: true, waiting: true))
        #expect(CanonicalRequests.answering(running) == "lab:slow")
        #expect(CanonicalRequests.answering(sent) == nil)
    }

    @Test func anEditIsFencedByTheRevisionAndWhereItHasToBeByTheRun() {
        let snapshot = JSONValue.object(["revision": .number(7), "execution_generation": .number(2)])
        let rename = CanonicalRequests.mutation(stored: "s", operation: "rename", payload: ["title": .string("T")],
                                                snapshot: snapshot, requestID: "r", profile: nil)
        #expect(rename == ["session_id": .string("s"), "request_id": .string("r"), "operation": .string("rename"),
                           "expected_revision": .number(7), "payload": .object(["title": .string("T")])])
        for operation in ["delete", "branch", "model", "workspace", "rewind"] {
            let edit = CanonicalRequests.mutation(stored: "s", operation: operation, payload: [:], snapshot: snapshot, requestID: "r", profile: "scout")
            #expect(edit["expected_generation"] == .number(2), "\(operation)")
            #expect(edit["profile"] == .string("scout"))
        }
        #expect(CanonicalRequests.mutation(stored: "s", operation: "archive", payload: [:], snapshot: snapshot, requestID: "r", profile: "")["profile"] == nil)
    }

    @Test func takingBackMessagesGoesBackToTheEarliestOfThem() {
        let rows: [JSONValue] = [
            .object(["role": .string("user"), "row_id": .number(11)]), .object(["role": .string("assistant"), "row_id": .number(12)]),
            .object(["role": .string("user"), "row_id": .number(13)]), .object(["role": .string("assistant"), "row_id": .number(14)])]
        #expect(CanonicalRequests.rewindTarget(rows, turns: 1) == 13)
        #expect(CanonicalRequests.rewindTarget(rows, turns: 2) == 11)
        #expect(CanonicalRequests.rewindTarget(rows, turns: 3) == nil)
        #expect(CanonicalRequests.rewindTarget(rows, turns: 0) == nil)
    }

    @Test func anAnswerNamesThePromptAndItsRun() {
        let prompt = JSONValue.object(["prompt_id": .string("p1"), "execution_generation": .number(5), "kind": .string("approval")])
        #expect(CanonicalRequests.promptAnswer(runtime: "s", prompt: prompt, ["choice": .string("once")])
                == ["session_id": .string("s"), "prompt_id": .string("p1"), "execution_generation": .number(5), "choice": .string("once")])
        // A prompt read as an approval card or a question keeps its id.
        #expect(ApprovalRequest(payload: prompt).id == "p1")
        #expect(HermesServeTransport.parseClarify(.object(["prompt_id": .string("q1"), "question": .string("Which?")])).id == "q1")
    }

    @Test func fastModeRefusedThereIsSaidPlainly() {
        #expect(ChatControls.fastRefusal("fast_unavailable (4001)") == "This model has no fast mode.")
    }
}
