import Foundation
import Testing
@testable import Echo

/// ACP in Redde's words, from frames recorded off `hermes acp` (Hermes 0.22.7, 2026-11-11) and
/// shapes from the ACP v1 schema.
struct AcpTests {
    private func json(_ text: String) -> JSONValue { try! JSONValue.parse(Data(text.utf8)) }

    @Test func aReplyStreamsAsText() {
        var mapper = AcpTurnMapper()
        let first = mapper.events(for: json(#"{"content": {"text": "[A:alpha]", "type": "text"}, "messageId": "m1", "sessionUpdate": "agent_message_chunk"}"#))
        #expect(first == [.textDelta("[A:alpha]")])
        // A second message in the same turn is a paragraph of its own.
        let second = mapper.events(for: json(#"{"content": {"text": "More.", "type": "text"}, "messageId": "m2", "sessionUpdate": "agent_message_chunk"}"#))
        #expect(second == [.textDelta("\n\nMore.")])
        let thought = mapper.events(for: json(#"{"content": {"text": "hmm", "type": "text"}, "sessionUpdate": "agent_thought_chunk"}"#))
        #expect(thought == [.reasoningDelta("hmm")])
    }

    @Test func aToolCallIsAStep() {
        var mapper = AcpTurnMapper()
        let started = mapper.events(for: json(#"""
            {"content": [{"content": {"text": "$ rm -rf /tmp/x", "type": "text"}, "type": "content"}], "kind": "execute", "locations": [],
             "title": "terminal: rm -rf /tmp/x", "toolCallId": "call_1", "sessionUpdate": "tool_call"}
            """#))
        #expect(started == [.toolStarted(name: "terminal", preview: "rm -rf /tmp/x", args: "$ rm -rf /tmp/x")])
        // An update for a call never started (Hermes's own permission check) is left out.
        #expect(mapper.events(for: json(#"{"status": "completed", "toolCallId": "perm-check-1", "sessionUpdate": "tool_call_update"}"#)).isEmpty)
        let finished = mapper.events(for: json(#"""
            {"content": [{"content": {"text": "terminal result\n- **exit_code:** 0", "type": "text"}, "type": "content"}], "kind": "execute",
             "status": "completed", "toolCallId": "call_1", "sessionUpdate": "tool_call_update"}
            """#))
        #expect(finished == [.toolFinished(name: "terminal", failed: false, output: "terminal result\n- **exit_code:** 0")])
    }

    /// Claude Code (claude-agent-acp 0.106.0, 2026-11-11) announces a call bare and fills it in.
    @Test func aBareCallWaitsForWhatItDoes() {
        var mapper = AcpTurnMapper()
        #expect(mapper.events(for: json(#"""
            {"toolCallId": "t1", "sessionUpdate": "tool_call", "name": "Write", "rawInput": {}, "status": "pending",
             "title": "Preparing file…", "kind": "edit", "content": [], "locations": []}
            """#)).isEmpty)
        let started = mapper.events(for: json(#"""
            {"toolCallId": "t1", "sessionUpdate": "tool_call_update", "rawInput": {"file_path": "/w/hello.txt"}, "title": "Write hello.txt"}
            """#))
        #expect(started.count == 1)
        if case let .toolStarted(name, preview, _)? = started.first {
            #expect(name == "Write")
            #expect(preview == "hello.txt")
        } else {
            Issue.record("no step started: \(started)")
        }
        let finished = mapper.events(for: json(#"""
            {"toolCallId": "t1", "sessionUpdate": "tool_call_update", "status": "completed", "rawOutput": "File created successfully at: /w/hello.txt"}
            """#))
        #expect(finished == [.toolFinished(name: "Write", failed: false, output: "File created successfully at: /w/hello.txt")])
        // One that ends before it says anything still shows, once.
        _ = mapper.events(for: json(#"{"toolCallId": "t2", "sessionUpdate": "tool_call", "name": "Read", "rawInput": {}, "title": "Read", "content": []}"#))
        let both = mapper.events(for: json(#"{"toolCallId": "t2", "sessionUpdate": "tool_call_update", "status": "failed"}"#))
        #expect(both.count == 2)
    }

    @Test func aSentenceTitleIsTheStepsName() {
        #expect(AcpTurnMapper.name(json(#"{"title": "Read Package.swift"}"#)) == ("Read Package.swift", nil))
        #expect(AcpTurnMapper.name(json(#"{"title": "Read file", "name": "read"}"#)) == ("read", "Read file"))
    }

    @Test func aPlanIsTheTaskList() {
        var mapper = AcpTurnMapper()
        let events = mapper.events(for: json(#"""
            {"entries": [{"content": "Export the posts", "priority": "medium", "status": "in_progress"},
                         {"content": "Import them", "priority": "medium", "status": "pending"}], "sessionUpdate": "plan"}
            """#))
        #expect(events == [.todos([TodoItem(id: "1", content: "Export the posts", status: .inProgress),
                                   TodoItem(id: "2", content: "Import them", status: .pending)])])
    }

    @Test func usageAndStopReasons() {
        var mapper = AcpTurnMapper()
        #expect(mapper.events(for: json(#"{"size": 256000, "used": 81, "sessionUpdate": "usage_update"}"#))
                == [.usage(TokenUsage(input: 0, output: 0, contextUsed: 81, contextMax: 256000))])
        #expect(mapper.usage(fromPromptResult: json(#"{"stopReason": "end_turn", "usage": {"inputTokens": 20, "outputTokens": 6}}"#))
                == .usage(TokenUsage(input: 20, output: 6, contextUsed: 81, contextMax: 256000)))
        #expect(AcpTurnMapper.stopNote("end_turn") == nil)
        #expect(AcpTurnMapper.stopNote("max_tokens") != nil)
    }

    @Test func hermesPermissionOptionsBecomeTheCardsChoices() {
        let params = json(#"""
            {"options": [{"kind": "allow_once", "name": "Allow once", "optionId": "allow_once"},
                         {"kind": "allow_always", "name": "Allow for session", "optionId": "allow_session"},
                         {"kind": "allow_always", "name": "Allow always", "optionId": "allow_always"},
                         {"kind": "reject_once", "name": "Deny", "optionId": "deny"},
                         {"kind": "reject_always", "name": "Deny always", "optionId": "deny_always"}],
             "sessionId": "s1",
             "toolCall": {"kind": "execute", "rawInput": {"command": "rm -rf /tmp/x", "description": "recursive delete"},
                          "status": "pending", "title": "terminal: rm -rf /tmp/x", "toolCallId": "call_1"}}
            """#)
        let (request, options) = AcpPermission.approval(id: "req-1", params: params)
        #expect(request.command == "rm -rf /tmp/x")
        #expect(request.description == "recursive delete")
        #expect(request.choices == ["once", "session", "always", "deny"])
        #expect(options == ["once": "allow_once", "session": "allow_session", "always": "allow_always", "deny": "deny"])
        #expect(AcpPermission.reply(choice: "session", options: options)
                == json(#"{"outcome": {"outcome": "selected", "optionId": "allow_session"}}"#))
        #expect(AcpPermission.reply(choice: "never offered", options: options) == json(#"{"outcome": {"outcome": "cancelled"}}"#))
    }

    @Test func aReplayedSessionIsItsMessages() {
        let updates = [
            #"{"content": {"text": "please do the danger thing", "type": "text"}, "sessionUpdate": "user_message_chunk"}"#,
            #"{"content": [{"content": {"text": "$ rm -rf x", "type": "text"}, "type": "content"}], "kind": "execute", "title": "terminal: rm -rf x", "toolCallId": "call_1", "sessionUpdate": "tool_call"}"#,
            #"{"content": [{"content": {"text": "exit 0", "type": "text"}, "type": "content"}], "status": "completed", "toolCallId": "call_1", "sessionUpdate": "tool_call_update"}"#,
            #"{"content": {"text": "[gone]", "type": "text"}, "sessionUpdate": "agent_message_chunk"}"#,
            #"{"content": {"text": "lab:todo", "type": "text"}, "sessionUpdate": "user_message_chunk"}"#,
            #"{"entries": [{"content": "Export", "priority": "medium", "status": "completed"}], "sessionUpdate": "plan"}"#,
            #"{"content": {"text": "done", "type": "text"}, "sessionUpdate": "agent_message_chunk"}"#,
        ].map(json)
        let messages = AcpHistory.messages(updates)
        #expect(messages.map(\.role) == [.user, .assistant, .user, .assistant])
        #expect(messages[0].text == "please do the danger thing")
        #expect(messages[1].text == "[gone]")
        #expect(messages[1].tools.map(\.name) == ["terminal"])
        #expect(messages[1].tools.first?.status == .completed)
        #expect(messages[1].tools.first?.output == "exit 0")
        #expect(messages[3].todos?.first?.status == .completed)
    }

    @Test func modelsComeFromTheModelConfigOption() {
        let options = json(#"""
            [{"currentValue": "ask", "options": [{"name": "Default", "value": "ask"}], "category": "mode", "id": "edit_approval_policy", "name": "Edits", "type": "select"},
             {"currentValue": "custom:my-local:alpha", "category": "model", "id": "model", "name": "Model", "type": "select",
              "options": [{"name": "Anthropic · claude-opus-5-5", "value": "anthropic:claude-opus-5-5"},
                          {"name": "My Local · alpha", "value": "custom:my-local:alpha"}]}]
            """#).array!
        let choices = AcpModels.choices(options)
        #expect(choices.map(\.model) == ["anthropic:claude-opus-5-5", "custom:my-local:alpha"])
        #expect(choices.map(\.providerName) == ["Anthropic", "My Local"])
        #expect(choices.map(\.name) == ["claude-opus-5-5", "alpha"])
        #expect(choices.last?.isCurrent == true)
    }

    @Test func modeAndThinkingAreTheirOwnMenus() {
        // Claude Code's options, as its adapter gave them; Hermes's one-value mode isn't a menu.
        let options = json(#"""
            [{"id": "mode", "name": "Mode", "category": "mode", "type": "select", "currentValue": "auto",
              "options": [{"value": "default", "name": "Manual", "description": "Asks before edits and commands"},
                          {"value": "plan", "name": "Plan"}, {"value": "auto", "name": "Auto"}]},
             {"id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": "default",
              "options": [{"value": "default", "name": "Default"}, {"value": "opus", "name": "Opus"}]},
             {"id": "fast", "name": "Fast", "category": "model_config", "type": "boolean", "currentValue": false},
             {"id": "effort", "name": "Effort", "category": "thought_level", "type": "select", "currentValue": "high",
              "options": [{"value": "low", "name": "Low"}, {"value": "high", "name": "High"}]},
             {"currentValue": "ask", "options": [{"name": "Default", "value": "ask"}], "category": "mode", "id": "edit_approval_policy", "name": "Edits", "type": "select"}]
            """#).array!
        let picked = AcpOption.pickable(options)
        #expect(picked.map(\.id) == ["mode", "effort"])
        #expect(picked[0].current == "auto")
        #expect(picked[0].values.map(\.name) == ["Manual", "Plan", "Auto"])
        #expect(picked[0].values[0].detail == "Asks before edits and commands")
        #expect(picked[1].values.map(\.id) == ["low", "high"])
    }

    @Test func addressesAreReadAsTheBridgesOrAServersOwn() {
        let bridge = AcpEndpoint.make(address: "  studio.local:8765 ", agent: "claude", token: "t", folder: "")
        #expect(bridge?.socketURL.absoluteString == "ws://studio.local:8765/acp/claude")
        #expect(bridge?.agentsURL?.absoluteString == "http://studio.local:8765/agents")
        #expect(bridge?.folder == nil)
        let tls = AcpEndpoint.make(address: "https://box.tail.ts.net/", agent: "", token: nil, folder: "~/Projects")
        #expect(tls?.socketURL.absoluteString == "wss://box.tail.ts.net/acp")
        #expect(tls?.agentsURL?.absoluteString == "https://box.tail.ts.net/agents")
        let goose = AcpEndpoint.make(address: "ws://127.0.0.1:3284/acp", agent: "ignored", token: "k", folder: nil)
        #expect(goose?.socketURL.absoluteString == "ws://127.0.0.1:3284/acp")
        #expect(goose?.agentsURL == nil)
        #expect(AcpEndpoint.make(address: "ftp://x", agent: "", token: nil, folder: nil) == nil)
    }

    @Test func sessionListRowsBecomeChatRows() {
        let rows = AcpSessions.summaries([
            json(#"{"cwd": "/w", "sessionId": "old", "title": "[A:alpha]", "updatedAt": "2026-11-12T01:37:35.199668+00:00"}"#),
            json(#"{"cwd": "/w", "sessionId": "new", "title": "Fix the build", "updatedAt": "2026-11-12T02:00:00Z"}"#),
        ])
        #expect(rows.map(\.id) == ["new", "old"])
        #expect(rows.first?.title == "Fix the build")
        #expect(rows.first?.cwd == "/w")
        #expect(rows.last?.last_active != nil)
    }

    @Test func initializeSaysWhatTheAgentCanDo() {
        let info = AcpClient.info(json(#"""
            {"agentCapabilities": {"loadSession": true, "promptCapabilities": {"image": true}, "sessionCapabilities": {"fork": {}, "list": {}, "resume": {}}},
             "agentInfo": {"name": "hermes-agent", "version": "0.0.0"}, "protocolVersion": 1,
             "_meta": {"redde": {"bridge": "0.1.0", "agent": "hermes", "name": "Hermes", "cwd": "/Users/x"}}}
            """#))
        #expect(info.name == "Hermes")   // the bridge's name for it, over the agent's own id
        #expect(info.bridge == "0.1.0")
        #expect(info.folder == "/Users/x")
        #expect(info.canLoad && info.canList && info.canResume && info.takesImages)
        #expect(!info.canDelete && !info.takesSystemPrompt)
    }
}
