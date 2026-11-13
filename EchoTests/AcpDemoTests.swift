import Foundation
import Testing
@testable import Echo

/// Redde's demo agent (`AcpDemoAgent`), spoken to as the app speaks to it: JSON-RPC frames in,
/// frames out, with no pauses.
@Suite(.timeLimit(.minutes(1)))
struct AcpDemoTests {
    /// One side of a conversation with the demo: sends frames, reads them back.
    final class Line: @unchecked Sendable {
        let socket = AcpDemoSocket(pace: .zero, store: nil)
        private var next = 1

        func send(_ frame: JSONValue) {
            let data = try! JSONEncoder().encode(frame)
            socket.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
        }

        func read() async throws -> JSONValue {
            guard case let .string(text) = try await socket.receive() else { throw URLError(.cannotParseResponse) }
            return try JSONValue.parse(Data(text.utf8))
        }

        /// A call, and every frame up to its answer.
        func call(_ method: String, _ params: [String: JSONValue] = [:]) async throws -> (result: JSONValue, heard: [JSONValue]) {
            let id = "t-\(next)"
            next += 1
            send(.object(["jsonrpc": .string("2.0"), "id": .string(id), "method": .string(method), "params": .object(params)]))
            var heard: [JSONValue] = []
            while true {
                let frame = try await read()
                if frame["id"]?.string == id, frame["method"] == nil { return (frame["result"] ?? frame["error"] ?? .null, heard) }
                heard.append(frame)
            }
        }

        /// Frames until the agent asks the app something.
        func untilAsked() async throws -> (request: JSONValue, heard: [JSONValue]) {
            var heard: [JSONValue] = []
            while true {
                let frame = try await read()
                if frame["method"]?.string != "session/update", frame["id"] != nil { return (frame, heard) }
                heard.append(frame)
            }
        }

        func answer(_ request: JSONValue, _ result: JSONValue) {
            send(.object(["jsonrpc": .string("2.0"), "id": request["id"] ?? .null, "result": result]))
        }

        func prompt(_ session: String, _ words: String) {
            send(.object(["jsonrpc": .string("2.0"), "id": .string("prompt"), "method": .string("session/prompt"),
                          "params": .object(["sessionId": .string(session), "prompt": .array([.object(["type": .string("text"), "text": .string(words)])])])]))
        }

        /// Frames until the prompt's answer: its stop reason and the updates.
        func untilDone() async throws -> (stop: String?, updates: [JSONValue]) {
            var updates: [JSONValue] = []
            while true {
                let frame = try await read()
                if frame["id"]?.string == "prompt" { return (frame["result"]?["stopReason"]?.string, updates) }
                if let update = frame["params"]?["update"] { updates.append(update) }
            }
        }
    }

    private func kinds(_ updates: [JSONValue]) -> [String] { updates.compactMap { $0["sessionUpdate"]?.string } }

    private func newChat(_ line: Line) async throws -> String {
        let info = try await line.call("initialize", ["protocolVersion": .number(1)])
        #expect(AcpClient.info(info.result).name == "Demo Agent")
        #expect(AcpClient.info(info.result).canLoad)
        let made = try await line.call("session/new", ["cwd": .string("/")])
        let session = try #require(made.result["sessionId"]?.string)
        #expect(made.result["configOptions"]?.array?.first?["currentValue"]?.string == "ask")
        return session
    }

    @Test func theAddressDemoIsTheDemoAgent() {
        #expect(AcpEndpoint.make(address: " Demo ", agent: "", token: nil, folder: nil)?.isDemo == true)
        #expect(AcpEndpoint.make(address: "ws://demo:8765", agent: "", token: nil, folder: nil)?.isDemo == false)
    }

    @Test func theTourAsksBeforeItRunsACommand() async throws {
        let line = Line()
        let session = try await newChat(line)
        line.prompt(session, "Fix the notes")
        let (ask, before) = try await line.untilAsked()
        let updates = before.compactMap { $0["params"]?["update"] }
        #expect(kinds(updates).contains("agent_thought_chunk"))
        #expect(kinds(updates).contains("plan"))
        #expect(kinds(updates).contains("available_commands_update"))
        // The edit came with its diff.
        let edit = try #require(updates.first { $0["toolCallId"]?.string == "edit-1" && $0["status"]?.string == "completed" })
        #expect(edit["content"]?.array?.first?["type"]?.string == "diff")
        #expect(ask["method"]?.string == "session/request_permission")
        #expect(ask["params"]?["toolCall"]?["title"]?.string == "make check")
        line.answer(ask, .object(["outcome": .object(["outcome": .string("selected"), "optionId": .string("allow")])]))
        let (stop, after) = try await line.untilDone()
        #expect(stop == "end_turn")
        let run = try #require(after.last { $0["toolCallId"]?.string == "run-1" })
        #expect(run["status"]?.string == "completed")
        let said = after.filter { $0["sessionUpdate"]?.string == "agent_message_chunk" }.compactMap { $0["content"]?["text"]?.string }.joined()
        #expect(said.hasPrefix("Done: I fixed the typo"))
        #expect(said.contains("no AI wrote this"))
    }

    @Test func autoModeRunsTheCommandWithoutAsking() async throws {
        let line = Line()
        let session = try await newChat(line)
        let set = try await line.call("session/set_config_option", ["sessionId": .string(session), "configId": .string("mode"), "value": .string("auto")])
        #expect(set.result["configOptions"]?.array?.first?["currentValue"]?.string == "auto")
        line.prompt(session, "/tour")
        let (stop, updates) = try await line.untilDone()
        #expect(stop == "end_turn")
        #expect(updates.contains { $0["toolCallId"]?.string == "run-1" && $0["status"]?.string == "completed" })
    }

    @Test func aDeniedCommandIsNotRun() async throws {
        let line = Line()
        let session = try await newChat(line)
        line.prompt(session, "tour")
        let (ask, _) = try await line.untilAsked()
        line.answer(ask, .object(["outcome": .object(["outcome": .string("selected"), "optionId": .string("deny")])]))
        let (stop, updates) = try await line.untilDone()
        #expect(stop == "end_turn")
        #expect(updates.last { $0["toolCallId"]?.string == "run-1" }?["status"]?.string == "failed")
    }

    @Test func aPlanIsApprovedBeforeItIsDone() async throws {
        let line = Line()
        let session = try await newChat(line)
        line.prompt(session, "Show me a plan")
        let (ask, _) = try await line.untilAsked()
        #expect(ask["params"]?["toolCall"]?["kind"]?.string == "switch_mode")
        #expect(ask["params"]?["toolCall"]?["rawInput"]?["plan"]?.string?.contains("Tidy the notes") == true)
        line.answer(ask, .object(["outcome": .object(["outcome": .string("selected"), "optionId": .string("go")])]))
        let (stop, updates) = try await line.untilDone()
        #expect(stop == "end_turn")
        #expect(kinds(updates).contains("plan"))
    }

    @Test func aQuestionIsAForm() async throws {
        let line = Line()
        let session = try await newChat(line)
        line.prompt(session, "Ask me a question")
        let (ask, _) = try await line.untilAsked()
        #expect(ask["method"]?.string == "elicitation/create")
        let (card, form) = try #require(AcpForm.make(id: "q", params: ask["params"] ?? .null))
        #expect(form.fields.count == 1)
        #expect(card.questions.first?.choices.count == 3)
        line.answer(ask, .object(["action": .string("accept"), "content": .object(["pick": .string("Just a hello")])]))
        let (_, updates) = try await line.untilDone()
        let said = updates.compactMap { $0["sessionUpdate"]?.string == "agent_message_chunk" ? $0["content"]?["text"]?.string : nil }.joined()
        #expect(said.contains("Just a hello"))
    }

    @Test func cancellingEndsATurnThatWaits() async throws {
        let line = Line()
        let session = try await newChat(line)
        line.prompt(session, "Fix the notes")
        _ = try await line.untilAsked()
        line.send(.object(["jsonrpc": .string("2.0"), "method": .string("session/cancel"), "params": .object(["sessionId": .string(session)])]))
        let (stop, _) = try await line.untilDone()
        #expect(stop == "cancelled")
    }

    @Test func aChatIsListedAndReplayed() async throws {
        let line = Line()
        let session = try await newChat(line)
        // A first message is the tour, which asks first unless it's in Auto.
        _ = try await line.call("session/set_config_option", ["sessionId": .string(session), "configId": .string("mode"), "value": .string("auto")])
        line.prompt(session, "hello")
        _ = try await line.untilDone()
        let listed = try await line.call("session/list")
        #expect(listed.result["sessions"]?.array?.first?["title"]?.string == "hello")
        let loaded = try await line.call("session/load", ["sessionId": .string(session), "cwd": .string("/")])
        let replayed = loaded.heard.compactMap { $0["params"]?["update"] }
        #expect(kinds(replayed).first == "user_message_chunk")
        #expect(kinds(replayed).contains("agent_message_chunk"))
        _ = try await line.call("session/delete", ["sessionId": .string(session)])
        #expect(try await line.call("session/list").result["sessions"]?.array?.isEmpty == true)
    }

    @Test func anUnknownMethodIsAnError() async throws {
        let line = Line()
        let answer = try await line.call("session/fork", [:])
        #expect(answer.result["code"]?.int == -32601)
    }
}
