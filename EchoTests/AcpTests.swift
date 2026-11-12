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

    /// Claude Code's note of a stop isn't read back as something the person said.
    @Test func aStopNoteIsntAMessage() {
        let frames = [
            json(#"{"sessionUpdate": "user_message_chunk", "content": {"type": "text", "text": "Plan it"}, "messageId": "u1"}"#),
            json(#"{"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "Here it is."}}"#),
            json(#"{"sessionUpdate": "user_message_chunk", "content": {"type": "text", "text": "[Request interrupted by user for tool use]"}, "messageId": "u2"}"#),
            json(#"{"sessionUpdate": "user_message_chunk", "content": {"type": "text", "text": "Use capitals"}, "messageId": "u3"}"#),
        ]
        #expect(AcpHistory.messages(frames).map(\.text) == ["Plan it", "Here it is.", "Use capitals"])
    }

    /// Claude Code's plan (as it sent it, 2026-11-12): the plan above the agent's own options, each
    /// answering with its id; words typed instead say no and go next. An ordinary approval, or
    /// Hermes's with a second way to say no, stays the approval card.
    @Test func aPlanToApproveIsAskedInTheAgentsWords() throws {
        let params = json(#"""
            {"toolCall": {"toolCallId": "toolu_1", "name": "ExitPlanMode", "status": "pending", "title": "Approve Plan", "kind": "switch_mode",
                          "rawInput": {"plan": "# Add a line\n\n- **Edit:** append `four`.\n", "planFilePath": "/p/plan.md"},
                          "content": [{"type": "content", "content": {"type": "text", "text": "# Add a line\n\n- **Edit:** append `four`.\n"}}]},
             "options": [{"optionId": "exit-plan-default", "name": "Yes, manually approve edits", "kind": "allow_once"},
                         {"optionId": "exit-plan-clear-auto", "name": "Yes, clear context (8% used) and use auto mode", "kind": "allow_always"},
                         {"optionId": "exit-plan-auto", "name": "Yes, and use auto mode", "kind": "allow_always"},
                         {"optionId": "exit-plan-bypass", "name": "Yes, and bypass permissions", "kind": "allow_always"},
                         {"optionId": "reject", "name": "No, keep planning", "kind": "reject_once"}],
             "sessionId": "s1"}
            """#)
        let (card, choice) = try #require(AcpChoice.make(id: "req-2", params: params))
        let q = try #require(card.questions.first)
        #expect(card.id == "req-2" && card.questions.count == 1 && !card.isBatch)
        #expect(q.question == "Approve Plan")
        #expect(q.detail == "# Add a line\n\n- **Edit:** append `four`.")
        #expect(q.choices == ["Yes, manually approve edits", "Yes, clear context (8% used) and use auto mode",
                              "Yes, and use auto mode", "Yes, and bypass permissions", "No, keep planning"])
        let auto = choice.reply(["": "Yes, and use auto mode"])
        #expect(auto.result == json(#"{"outcome": {"outcome": "selected", "optionId": "exit-plan-auto"}}"#) && auto.next == nil)
        let typed = choice.reply(["": "  Put it at the top instead "])
        #expect(typed.result == json(#"{"outcome": {"outcome": "selected", "optionId": "reject"}}"#))
        #expect(typed.next == "Put it at the top instead")
        #expect(choice.shown(["": "Put it at the top instead"]) == ["": "No, keep planning"])
        #expect(choice.shown(["": "Yes, and use auto mode"]) == ["": "Yes, and use auto mode"])

        let bash = json(#"""
            {"toolCall": {"toolCallId": "t", "kind": "execute", "title": "git status", "rawInput": {"command": "git status"}},
             "options": [{"optionId": "allow", "name": "Yes", "kind": "allow_once"},
                         {"optionId": "allow-with-updates", "name": "Yes, and don't ask again for git commands", "kind": "allow_always"},
                         {"optionId": "reject", "name": "No", "kind": "reject_once"}], "sessionId": "s1"}
            """#)
        #expect(AcpChoice.make(id: "req-3", params: bash) == nil)
        let hermes = json(#"""
            {"toolCall": {"kind": "execute", "rawInput": {"command": "rm x"}, "title": "terminal: rm x", "toolCallId": "c"},
             "options": [{"kind": "allow_once", "name": "Allow once", "optionId": "allow_once"},
                         {"kind": "allow_always", "name": "Allow for session", "optionId": "allow_session"},
                         {"kind": "allow_always", "name": "Allow always", "optionId": "allow_always"},
                         {"kind": "reject_once", "name": "Deny", "optionId": "deny"},
                         {"kind": "reject_always", "name": "Deny always", "optionId": "deny_always"}], "sessionId": "s1"}
            """#)
        #expect(AcpChoice.make(id: "req-4", params: hermes) == nil)
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

    @Test func connectionsAreGroupedByWhatTheyReach() {
        #expect(Transport.Kind.hermes.transports == [.hermesServe, .hermesSessions])
        #expect(Transport.Kind.agent.transports == [.acp])
        #expect(Transport.Kind.model.transports == [.chatCompletions])
        var claude = HermesServer(id: UUID(), name: "Claude")
        claude.transport = .acp
        let home = HermesServer(id: UUID(), name: "Home")
        var office = HermesServer(id: UUID(), name: "Office")
        office.transport = .hermesSessions
        let groups = ServersView.grouped([claude, home, office])
        #expect(groups.map(\.kind) == [.hermes, .agent])
        #expect(groups[0].servers.map(\.name) == ["Home", "Office"])
        #expect(groups[1].servers.map(\.name) == ["Claude"])
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

    /// Chats by their folder: a project per folder, newest first, once there are two folders.
    @Test func foldersAreTheChatListsProjects() {
        let rows = AcpSessions.summaries([
            json(#"{"sessionId": "a", "cwd": "/w/redde", "title": "One", "updatedAt": "2026-11-12T10:00:00Z"}"#),
            json(#"{"sessionId": "b", "cwd": "/w/site", "title": "Two", "updatedAt": "2026-11-12T12:00:00Z"}"#),
            json(#"{"sessionId": "c", "cwd": "/w/redde", "title": "Three", "updatedAt": "2026-11-12T11:00:00Z"}"#),
            json(#"{"sessionId": "d", "title": "Nowhere", "updatedAt": "2026-11-12T13:00:00Z"}"#),
        ])
        let projects = AcpProjects.make(rows)
        #expect(projects.map(\.label) == ["site", "redde"])
        #expect(projects.last?.path == "/w/redde" && projects.last?.sessionCount == 2 && !(projects.last?.isHome ?? true))
        #expect(projects.last?.lanes.first?.sessions.map(\.id) == ["c", "a"])
        #expect(AcpProjects.make(Array(rows.filter { $0.cwd == "/w/redde" })).isEmpty)
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
        #expect(!info.canDelete && !info.takesSystemPrompt && !info.steers)
        // Claude Code says words can join a reply under way.
        let claude = AcpClient.info(json(#"{"agentInfo": {"name": "@agentclientprotocol/claude-agent-acp", "title": "Claude Agent"}, "_meta": {"steering": {"supported": true}}}"#))
        #expect(claude.steers && claude.name == "Claude Agent")
        #expect(!info.canTitle)
        #expect(AcpClient.info(json(#"{"agentCapabilities": {"sessionCapabilities": {"title": {}}}}"#)).canTitle)
    }

    /// Claude Code's commands as it announces them, offered as "/…" is typed.
    @Test func slashCommandsAreOfferedAsTheNameIsTyped() {
        let update = json(#"{"sessionUpdate":"available_commands_update","availableCommands":[{"name":"compact","description":"Clear history but keep a summary","input":{"hint":"<optional instructions>"}},{"name":"review","description":"Review a pull request"},{"name":"/init","description":"Write CLAUDE.md"},{"description":"no name"}]}"#)
        let commands = AcpCommand.list(update)
        #expect(commands.map(\.name) == ["compact", "review", "init"])
        #expect(commands[0].hint == "<optional instructions>" && commands[1].hint == nil)
        #expect(AcpCommand.matching("/", in: commands).count == 3)
        #expect(AcpCommand.matching("/re", in: commands).map(\.name) == ["review"])
        #expect(AcpCommand.matching("/i", in: commands).map(\.name) == ["init", "review"])   // starts first, then within
        #expect(AcpCommand.matching("/compact now", in: commands).isEmpty)
        #expect(AcpCommand.matching("hello", in: commands).isEmpty)
        // The bridge says the commands it last heard on initialize, for a chat with none yet.
        let info = AcpClient.info(json(#"{"agentInfo":{"name":"claude-agent-acp"},"_meta":{"redde":{"bridge":"0.2.0","commands":[{"name":"compact","description":"Summarise"}]}}}"#))
        #expect(info.commands.map(\.name) == ["compact"])
        #expect(AcpClient.info(json(#"{"agentInfo":{"name":"x"}}"#)).commands.isEmpty)
    }

    /// Claude Code's AskUserQuestion with one question, as `claude-agent-acp` 0.106.0 sends it:
    /// a pill per option, its "Other" field as the card's own box.
    @Test func aFormWithOneQuestionIsAQuestionCard() throws {
        let params = json(#"{"sessionId":"s1","mode":"form","toolCallId":"t1","message":"Which database?","requestedSchema":{"type":"object","properties":{"question_0":{"type":"string","title":"Database","oneOf":[{"const":"Postgres","title":"Postgres","description":"The usual"},{"const":"SQLite","title":"SQLite"}]},"question_0_custom":{"type":"string","title":"Other","description":"Type your own answer, or add a note to the option you chose above (optional)."}}}}"#)
        let (card, form) = try #require(AcpForm.make(id: "req-1", params: params))
        #expect(card.id == "req-1" && card.isBatch)
        #expect(card.questions == [ClarifyQuestion(id: "question_0", question: "Which database?", choices: ["Postgres", "SQLite"], multiSelect: false)])
        #expect(form.reply(["question_0": "SQLite"]) == json(#"{"action":"accept","content":{"question_0":"SQLite"}}"#))
        // Typed instead of picked: into the "Other" field.
        #expect(form.reply(["question_0": "MySQL, sadly"]) == json(#"{"action":"accept","content":{"question_0_custom":"MySQL, sadly"}}"#))
    }

    /// Several questions, one of them multi-select, in field order (question_10 after question_2).
    @Test func aFormWithSeveralQuestionsKeepsTheirOrder() throws {
        var properties: [String] = []
        for index in 0 ... 10 {
            let multi = index == 1
            let options = #"[{"const":"A, with comma","title":"A, with comma"},{"const":"B","title":"B"}]"#
            properties.append(multi
                ? #""question_\#(index)":{"type":"array","description":"Q\#(index)?","items":{"anyOf":\#(options)}}"#
                : #""question_\#(index)":{"type":"string","description":"Q\#(index)?","oneOf":\#(options)}"#)
            properties.append(#""question_\#(index)_custom":{"type":"string","title":"Other"}"#)
        }
        let params = json(#"{"sessionId":"s1","mode":"form","message":"Please answer the following questions.","requestedSchema":{"type":"object","properties":{\#(properties.joined(separator: ","))}}}"#)
        let (card, form) = try #require(AcpForm.make(id: "req-2", params: params))
        #expect(card.questions.map(\.id) == (0 ... 10).map { "question_\($0)" })
        #expect(card.questions[0].question == "Please answer the following questions.\n\nQ0?")
        #expect(card.questions[2].question == "Q2?")
        #expect(card.questions[1].multiSelect && !card.questions[0].multiSelect)
        // The card joins picks with ", ": an option holding a comma still reads as one pick.
        let reply = form.reply(["question_0": "B", "question_1": "A, with comma, B, and C"])
        #expect(reply["content"]?["question_1"] == json(#"["A, with comma","B"]"#))
        #expect(reply["content"]?["question_1_custom"]?.string == "and C")
        #expect(reply["content"]?["question_0"]?.string == "B")
        #expect(reply["content"]?["question_2"] == nil)
    }

    /// An MCP server's form: plain text, a number, a yes/no; and what Redde can't show.
    @Test func otherFieldsAndFormsReddeCantShow() throws {
        let params = json(#"{"sessionId":"s1","mode":"form","message":"Sign-up","requestedSchema":{"type":"object","properties":{"age":{"type":"integer","title":"Age"},"name":{"type":"string","title":"Your name"},"news":{"type":"boolean","description":"Send news?"}}}}"#)
        let (card, form) = try #require(AcpForm.make(id: "r", params: params))
        #expect(card.questions.map(\.question) == ["Sign-up\n\nAge", "Your name", "Send news?"])
        #expect(card.questions[2].choices == [AcpForm.yes, AcpForm.no])
        #expect(form.reply(["age": "42", "name": "Ada", "news": AcpForm.yes]) == json(#"{"action":"accept","content":{"age":42,"name":"Ada","news":true}}"#))
        #expect(AcpForm.make(id: "u", params: json(#"{"sessionId":"s1","mode":"url","message":"Sign in","url":"https://example.com","elicitationId":"e"}"#)) == nil)
        #expect(AcpForm.make(id: "e", params: json(#"{"sessionId":"s1","mode":"form","message":"x","requestedSchema":{"type":"object","properties":{}}}"#)) == nil)
    }

    /// Claude Code's Edit, as `claude-agent-acp` 0.106.0 sent it (2026-11-12): its change comes in an
    /// update before the last, whose content is empty; the step keeps it as a diff, with Claude
    /// Code's own line numbers.
    @Test func aFileChangeIsTheStepsDiff() throws {
        let frames = try #require(json(#"[{"_meta": {"claudeCode": {"toolName": "Edit"}}, "toolCallId": "toolu_013qUF5CQJTJwBP5de116iDF", "sessionUpdate": "tool_call", "name": "Edit", "rawInput": {}, "status": "pending", "title": "Edit", "kind": "edit", "content": [], "locations": []}, {"_meta": {"claudeCode": {"toolName": "Edit"}}, "toolCallId": "toolu_013qUF5CQJTJwBP5de116iDF", "sessionUpdate": "tool_call_update", "rawInput": {"file_path": "/work/notes.txt"}, "title": "Edit notes.txt", "locations": [{"path": "/work/notes.txt"}]}, {"_meta": {"claudeCode": {"toolName": "Edit"}}, "toolCallId": "toolu_013qUF5CQJTJwBP5de116iDF", "sessionUpdate": "tool_call_update", "rawInput": {"file_path": "/work/notes.txt", "old_string": "two"}}, {"_meta": {"claudeCode": {"toolName": "Edit"}}, "toolCallId": "toolu_013qUF5CQJTJwBP5de116iDF", "sessionUpdate": "tool_call_update", "rawInput": {"replace_all": false, "file_path": "/work/notes.txt", "old_string": "two", "new_string": "TWO"}, "content": [{"type": "diff", "path": "/work/notes.txt", "oldText": "two", "newText": "TWO"}]}, {"_meta": {"claudeCode": {"toolResponse": {"filePath": "/work/notes.txt", "oldString": "two", "newString": "TWO", "originalFile": "one\ntwo\nthree\n", "structuredPatch": [{"oldStart": 1, "oldLines": 3, "newStart": 1, "newLines": 3, "lines": [" one", "-two", "+TWO", " three"]}], "userModified": false, "replaceAll": false}, "toolName": "Edit"}}, "toolCallId": "toolu_013qUF5CQJTJwBP5de116iDF", "sessionUpdate": "tool_call_update", "content": [{"type": "diff", "path": "/work/notes.txt", "oldText": "one\ntwo\nthree", "newText": "one\nTWO\nthree"}], "locations": [{"path": "/work/notes.txt", "line": 1}]}, {"_meta": {"claudeCode": {"toolName": "Edit"}}, "toolCallId": "toolu_013qUF5CQJTJwBP5de116iDF", "sessionUpdate": "tool_call_update", "status": "completed", "rawOutput": "The file /work/notes.txt has been updated successfully. (file state is current in your context — no need to Read it back)"}]"#).array)
        var mapper = AcpTurnMapper()
        let events = frames.flatMap { mapper.events(for: $0) }
        let patch = "--- /work/notes.txt\n+++ /work/notes.txt\n@@ -1,3 +1,3 @@\n one\n-two\n+TWO\n three"
        #expect(events.last == .toolFinished(name: "Edit", failed: false, output: patch))
        #expect(Patch.isPatch(patch))
        let file = try #require(Patch.files(patch).first)
        #expect(file.path == "/work/notes.txt" && file.added == 1 && file.removed == 1)
        // Read back with the chat: the same.
        let replayed = AcpHistory.messages(frames)
        #expect(replayed.first?.tools.first?.output == patch)
    }

    /// Without the agent's own patch: a new file, and an edit numbered from the texts given.
    @Test func aDiffIsMadeFromTheTexts() {
        #expect(AcpDiff.patch([("/w/a.txt", nil, "one\ntwo\n")]) == "--- /dev/null\n+++ /w/a.txt\n@@ -0,0 +1,2 @@\n+one\n+two")
        let old = (1 ... 20).map { "line \($0)" }.joined(separator: "\n")
        var new = old.replacingOccurrences(of: "line 3\n", with: "line three\n")
        new = new.replacingOccurrences(of: "line 18\n", with: "")
        #expect(AcpDiff.hunks(old: old, new: new) == [
            "@@ -1,6 +1,6 @@", " line 1", " line 2", "-line 3", "+line three", " line 4", " line 5", " line 6",
            "@@ -15,6 +15,5 @@", " line 15", " line 16", " line 17", "-line 18", " line 19", " line 20",
        ])
        #expect(AcpDiff.hunks(old: "same", new: "same").isEmpty)
        #expect(AcpDiff.patch([]) == nil)
    }
}
