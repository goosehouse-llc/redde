import Foundation
import Testing
@testable import Echo

/// The agent's task list as a reply's checklist: what the host says it is, and, where only the
/// to-do tool's calls are to be had, the list read back out of them, from each form a call's
/// text takes, replayed the way Hermes's own store keeps it. The shapes are what Hermes 0.21.0,
/// 0.21.3 and 0.21.5 sent the lab (`scripts/hermes-lab/lab.sh todos` checks the real thing).
struct TodoListTests {
    private func item(_ id: String, _ content: String, _ status: TodoItem.Status, parent: String? = nil) -> TodoItem {
        TodoItem(id: id, content: content, status: status, parent: parent)
    }

    private func json(_ text: String) throws -> JSONValue { try JSONValue.parse(Data(text.utf8)) }

    /// A finished step of another tool, or of the to-do tool under a name of its own.
    private func step(_ name: String, _ args: String?, output: String? = nil) -> ToolActivity {
        ToolActivity(name: name, preview: nil, status: .completed, args: args, output: output)
    }

    /// A finished call to the to-do tool.
    private func todo(_ args: String?, output: String? = nil, failed: Bool = false) -> ToolActivity {
        ToolActivity(name: "todo_list", preview: nil, status: failed ? .failed : .completed, args: args, output: output)
    }

    // MARK: Reading a call

    @Test func bothNamesAreTheToDoTool() {
        #expect(TodoList.isTool("todo_list"))
        #expect(TodoList.isTool("todo"))   // Hermes 0.21.0
        #expect(!TodoList.isTool("terminal") && !TodoList.isTool("tool_call") && !TodoList.isTool("todo_write"))
    }

    @Test func aCallIsReadFromTheTextAStepKeeps() throws {
        // What the app makes of a call's arguments, live and from a stored transcript alike: the
        // step's text. The reading depends on that form, so this goes the whole way round.
        let arguments = try json(#"""
        {"todos": [{"id": "1", "content": "Export the posts", "status": "in_progress"},
                   {"id": 2, "content": "Import: them\ninto the new site", "status": "pending", "parent": "1"}], "merge": false}
        """#)
        let text = try #require(ToolActivity.detail(arguments))
        let write = try #require(TodoList.write(step: "todo_list", input: text))
        #expect(!write.merge)
        #expect(write.entries.map(\.id) == ["1", "2"], "a number serves as an id")
        #expect(write.entries[0] == .init(id: "1", content: "Export the posts", status: .inProgress))
        #expect(write.entries[1].content == "Import: them\ninto the new site")
        #expect(write.entries[1].parent == "1" && write.entries[1].namesParent)

        // A stored call's arguments are JSON text; they become the same step text.
        let stored = try #require(ToolActivity.detail(json: #"{"merge": true, "todos": [{"id": "1", "status": "completed"}]}"#))
        let merge = try #require(TodoList.write(step: "todo", input: stored))
        #expect(merge.merge)
        #expect(merge.entries == [.init(id: "1", content: nil, status: .completed)])
        // Another tool's step is no to-do call, whatever its text.
        #expect(TodoList.write(step: "terminal", input: text) == nil)
    }

    @Test func aCallMadeThroughToolCallIsReadTheSame() throws {
        // From Hermes 0.21.3 the model reaches the tool through `tool_call`. A transcript saved
        // with the step under that name still gives up its list.
        let wrapped = try json(#"{"calls": [{"name": "todo_list", "arguments": {"todos": [{"id": "1", "content": "One", "status": "pending"}], "merge": true}}]}"#)
        let write = try #require(TodoList.write(step: "tool_call", input: ToolActivity.detail(wrapped)))
        #expect(write.merge && write.entries == [.init(id: "1", content: "One", status: .pending)])
        // A `tool_call` to something else is nothing here.
        let other = try json(#"{"calls": [{"name": "web_search", "arguments": {"query": "todos"}}]}"#)
        #expect(TodoList.write(step: "tool_call", input: ToolActivity.detail(other)) == nil)

        // Read back from a transcript, the step is named for the tool it called.
        #expect(ToolActivity.unwrapped(name: "tool_call", args: wrapped).name == "todo_list")
        #expect(ToolActivity.unwrapped(name: "tool_call", args: wrapped).args?["merge"]?.bool == true)
        #expect(ToolActivity.unwrapped(name: "terminal", args: wrapped).name == "terminal")
        let several = try json(#"{"calls": [{"name": "a", "arguments": {}}, {"name": "b", "arguments": {}}]}"#)
        #expect(ToolActivity.unwrapped(name: "tool_call", args: several).name == "tool_call", "several calls at once stay one step")
        #expect(ToolActivity.unwrapped(name: "tool_call", args: nil).name == "tool_call")
    }

    @Test func otherFormsACallCanTake() throws {
        // JSON as it came.
        let raw = try #require(TodoList.write(step: "todo_list", input: #"{"todos":[{"id":"a","content":"One","status":"pending"}]}"#))
        #expect(raw.entries.map(\.id) == ["a"] && !raw.merge)
        // The list sent as text inside the arguments, which models sometimes do.
        let asString = try json(#"{"todos": "[{\"id\":\"a\",\"content\":\"One\",\"status\":\"pending\"}]"}"#)
        #expect(TodoList.write(step: "todo_list", input: ToolActivity.detail(asString))?.entries.map(\.id) == ["a"])
        // A status Hermes doesn't have is no status; an item without an id is no item.
        let odd = try #require(TodoList.write(step: "todo_list", input: #"{"todos":[{"id":"a","content":"One","status":"DONE-ish"},{"content":"nameless"}]}"#))
        #expect(odd.entries == [.init(id: "a", content: "One", status: nil)])
    }

    @Test func whatIsNoListIsLeftAlone() {
        #expect(TodoList.write(step: "todo_list", input: nil) == nil)
        #expect(TodoList.write(step: "todo_list", input: "") == nil)
        #expect(TodoList.write(step: "todo_list", input: "merge: false") == nil, "a call that only reads the list wrote nothing")
        #expect(TodoList.write(step: "todo_list", input: "todos: []") == nil)
        // Cut short at the step's cap: not JSON any more, so not read.
        #expect(TodoList.write(step: "todo_list", input: #"todos: [{"id":"1","content":"A very long"# + "\n… (4000 more characters)") == nil)
        #expect(TodoList.list(fromOutput: "Error: TodoStore not initialized") == nil)
        #expect(TodoList.list(nil) == nil)
        #expect(TodoList.list(.object(["revision": .number(1)])) == nil)
    }

    @Test func aResultAndASnapshotAreTheWholeList() throws {
        // The Hermes API's stored tool row: the tool's JSON as text.
        let answer = #"{"todos": [{"id": "1", "content": "Export", "status": "completed"}, {"id": "2", "content": "Import", "status": "in_progress", "parent": "1"}], "revision": 3, "summary": {"total": 2, "pending": 0, "in_progress": 1, "completed": 1, "cancelled": 0}}"#
        let expected = [item("1", "Export", .completed), item("2", "Import", .inProgress, parent: "1")]
        #expect(TodoList.list(fromOutput: answer) == expected)
        // The same as an object turned into a step's text.
        let text = try #require(ToolActivity.detail(try json(answer)))
        #expect(text.contains("revision: 3"))
        #expect(TodoList.list(fromOutput: text) == expected)
        // What the Dashboard sends in `todo.updated`, and as `todo_state` when a session is resumed.
        #expect(TodoList.list(try json(#"{"todos": [{"id": "1", "content": "Export", "status": "completed"}, {"id": "2", "content": "Import", "status": "in_progress", "parent": "1"}], "revision": 3}"#)) == expected)
        // An empty list is a list.
        #expect(TodoList.list(fromOutput: #"{"todos": [], "revision": 4, "summary": {"total": 0}}"#) == [])
    }

    // MARK: Keeping the list

    @Test func aNewListReplacesTheOldOne() {
        let write = TodoList.Write(entries: [.init(id: "1", content: "One", status: .completed), .init(id: "2", content: "Two", status: nil),
                                             .init(id: "3", content: nil, status: .pending)])
        let list = TodoList.apply(write, to: [item("9", "Old", .pending)])
        #expect(list == [item("1", "One", .completed), item("2", "Two", .pending), item("3", "(no description)", .pending)])
    }

    @Test func aMergeChangesWhatItNamesAndAddsWhatIsNew() {
        let before = [item("1", "One", .inProgress), item("2", "Two", .pending), item("3", "Three", .pending)]
        let write = TodoList.Write(entries: [.init(id: "1", status: .completed), .init(id: "2", content: "Two, reworded", status: .inProgress),
                                             .init(id: "4", content: "Four", status: nil)], merge: true)
        #expect(TodoList.apply(write, to: before) == [item("1", "One", .completed), item("2", "Two, reworded", .inProgress),
                                                      item("3", "Three", .pending), item("4", "Four", .pending)])
        // A merge onto nothing is the list it names.
        #expect(TodoList.apply(write, to: []).map(\.id) == ["1", "2", "4"])
    }

    @Test func theListIsKeptAsHermesKeepsIt() {
        // Of two entries with one id the later counts.
        let twice = TodoList.Write(entries: [.init(id: "1", content: "First wording", status: .pending), .init(id: "2", content: "Two", status: .pending),
                                             .init(id: "1", content: "Second wording", status: .pending)])
        #expect(TodoList.apply(twice, to: []).map(\.content) == ["Two", "Second wording"])
        // The step in progress comes before an earlier one still waiting.
        let order = TodoList.Write(entries: [.init(id: "1", content: "One", status: .completed), .init(id: "2", content: "Two", status: .pending),
                                             .init(id: "3", content: "Three", status: .inProgress)])
        #expect(TodoList.apply(order, to: []).map(\.id) == ["1", "3", "2"])
        // With subtasks the written order stands.
        let nested = TodoList.Write(entries: [.init(id: "1", content: "One", status: .pending), .init(id: "1a", content: "Part", status: .inProgress, parent: "1", namesParent: true)])
        #expect(TodoList.apply(nested, to: []).map(\.id) == ["1", "1a"])
        // A parent that isn't there, or is the item itself, or leads round in a circle, is none.
        let parents = TodoList.Write(entries: [.init(id: "1", content: "One", status: .pending, parent: "ghost", namesParent: true),
                                               .init(id: "2", content: "Two", status: .pending, parent: "2", namesParent: true),
                                               .init(id: "3", content: "Three", status: .pending, parent: "4", namesParent: true),
                                               .init(id: "4", content: "Four", status: .pending, parent: "3", namesParent: true)])
        let cleaned = TodoList.apply(parents, to: [])
        #expect(cleaned[0].parent == nil && cleaned[1].parent == nil)
        #expect(cleaned[2].parent == nil || cleaned[3].parent == nil, "the circle is broken")
        // A merge can take a parent away.
        let free = TodoList.Write(entries: [.init(id: "1a", parent: nil, namesParent: true)], merge: true)
        #expect(TodoList.apply(free, to: [item("1", "One", .pending), item("1a", "Part", .pending, parent: "1")])[1].parent == nil)
        // No more items than Hermes keeps.
        let many = TodoList.Write(entries: (0 ..< 300).map { .init(id: "\($0)", content: "Item \($0)", status: .pending) })
        #expect(TodoList.apply(many, to: []).count == TodoList.mostItems)
    }

    @Test func aFinishedStepSaysWhatTheListIsNow() {
        let before = [item("1", "One", .inProgress), item("2", "Two", .pending)]
        let tick = "merge: true\n" + #"todos: [{"id":"1","content":"One","status":"completed"}]"#
        // No answer kept (the Hermes API's stream, the Dashboard's history): what was written counts.
        #expect(TodoList.after(step: todo(tick), previous: before)?.map(\.status) == [.completed, .pending])
        // The tool's own answer says more than the call: the server's list had a third item.
        let answer = #"{"todos":[{"id":"1","content":"One","status":"completed"},{"id":"2","content":"Two","status":"pending"},{"id":"3","content":"Three","status":"pending"}],"revision":5}"#
        #expect(TodoList.after(step: todo(tick, output: answer), previous: before)?.map(\.id) == ["1", "2", "3"])
        // A call Hermes turned down, as 0.21.3 and later do when the arguments don't fit: the list stands.
        let refusal = #"{"error": "tool_call to 'todo_list' failed argument validation at arguments.todos[1] (required): 'content' is a required property. The tool was NOT invoked."}"#
        #expect(TodoList.after(step: todo(tick, output: refusal), previous: before) == nil)
        #expect(TodoList.after(step: todo(tick, failed: true), previous: before) == nil, "a call that failed wrote nothing")
        // A call that only reads, another tool, and a wrapped call to another tool change nothing.
        #expect(TodoList.after(step: todo("merge: false"), previous: before) == nil)
        #expect(TodoList.after(step: step("terminal", "command: ls", output: "todos: []"), previous: before) == nil)
        #expect(TodoList.after(step: step("tool_call", #"calls: [{"name":"notes","arguments":{}}]"#, output: #"{"todos": []}"#), previous: before) == nil)
        // A read with the answer kept is the list.
        #expect(TodoList.after(step: todo(nil, output: answer), previous: [])?.count == 3)
    }

    @Test func aTranscriptsCallsAreReplayedInOrder() {
        var first = Message(role: .assistant, text: "Started.")
        first.tools = [todo(#"todos: [{"id":"1","content":"One","status":"in_progress"},{"id":"2","content":"Two","status":"pending"}]"#),
                       step("terminal", "command: ls"),
                       todo("merge: true\n" + #"todos: [{"id":"1","status":"completed"},{"id":"2","status":"in_progress"}]"#)]
        var second = Message(role: .assistant, text: "Done.")
        second.tools = [todo("merge: true\n" + #"todos: [{"id":"2","status":"completed"}]"#)]
        var unreadable = Message(role: .assistant, text: "Looked.")
        unreadable.tools = [todo("todos: [{\"id\":\"1\",\"conten\n… (9000 more characters)")]
        let plain = Message(role: .assistant, text: "Nothing to do with it.")
        var messages = [Message(role: .user, text: "Go."), first, Message(role: .user, text: "On."), second, unreadable, plain]
        TodoList.resolve(&messages)

        #expect(messages[1].todos?.map(\.status) == [.completed, .inProgress], "a reply shows the list as it left it")
        #expect(messages[3].todos == [item("1", "One", .completed), item("2", "Two", .completed)], "a merge in a later reply builds on the earlier one")
        #expect(messages[4].todos == nil, "a call that can't be read shows no list")
        #expect(messages[5].todos == nil, "a reply that didn't touch the list shows none")
        #expect(messages[0].todos == nil)
        #expect(TodoList.latest(in: messages) == messages[3].todos)
        #expect(TodoList.latest(in: []).isEmpty)
    }

    @Test func aListTheHostGaveIsKeptAndBuiltOn() {
        var kept = Message(role: .assistant, text: "Kept.")
        kept.tools = [todo("merge: true\n" + #"todos: [{"id":"x","content":"Not what the host had","status":"pending"}]"#)]
        kept.todos = [item("only", "What the host said while the turn ran", .inProgress)]
        var after = Message(role: .assistant, text: "After.")
        after.tools = [todo("merge: true\n" + #"todos: [{"id":"only","status":"completed"}]"#)]
        var messages = [kept, after]
        TodoList.resolve(&messages)
        #expect(messages[0].todos == [item("only", "What the host said while the turn ran", .inProgress)])
        #expect(messages[1].todos == [item("only", "What the host said while the turn ran", .completed)])
    }

    @Test func aTranscriptReadBackIsSetAgainstWhatTheHostSays() {
        var reply = Message(role: .assistant, text: "Ticked.")
        // The Dashboard's history has the call and not its answer: here the host had refused it.
        reply.tools = [todo(#"todos: [{"id":"1","content":"One","status":"completed"}]"#)]
        var messages = [Message(role: .user, text: "Go."), reply, Message(role: .assistant, text: "And more.")]
        TodoList.resolve(&messages)
        #expect(messages[1].todos?.first?.status == .completed)

        let host = [item("1", "One", .inProgress), item("2", "Two", .pending)]
        TodoList.reconcile(&messages, with: host)
        #expect(messages[1].todos == host, "the newest reply with a list takes the host's")
        #expect(messages[2].todos == nil)
        // Agreement, no word from the host, and an empty list change nothing.
        let same = messages
        TodoList.reconcile(&messages, with: host)
        TodoList.reconcile(&messages, with: nil)
        TodoList.reconcile(&messages, with: [])
        #expect(messages == same)
        // No reply has a list, and the host has one: the newest reply shows it.
        var bare = [Message(role: .user, text: "Go."), Message(role: .assistant, text: "One."), Message(role: .assistant, text: "Two.")]
        TodoList.reconcile(&bare, with: host)
        #expect(bare[1].todos == nil && bare[2].todos == host)
    }

    // MARK: Showing it

    @Test func theListSaysHowFarItIsAndHowDeepEachItemSits() {
        let items = [item("1", "One", .completed), item("2", "Two", .inProgress), item("2a", "Part", .pending, parent: "2"),
                     item("2a1", "Detail", .pending, parent: "2a"), item("3", "Dropped", .cancelled)]
        #expect(TodoList.summary(items) == "1 of 4 done", "a dropped item is neither done nor left to do")
        #expect(TodoList.summary([item("1", "One", .completed), item("2", "Two", .completed)]) == "All 2 done")
        #expect(TodoList.summary([item("1", "One", .cancelled)]) == "Nothing left")
        #expect(TodoList.depths(items) == ["1": 0, "2": 0, "2a": 1, "2a1": 2, "3": 0])
        #expect(TodoChecklist.spoken(.inProgress) == "In progress" && TodoChecklist.spoken(.cancelled) == "Dropped")
        let statuses: [TodoItem.Status] = [.pending, .inProgress, .completed, .cancelled]
        #expect(Set(statuses.map(TodoChecklist.symbol)).count == 4)
    }

    @Test func aSavedReplyKeepsItsListAndAnOlderOneIsGivenIt() throws {
        var reply = Message(role: .assistant, text: "Saved.")
        reply.todos = [item("1", "One", .pending)]
        #expect(try JSONDecoder().decode(Message.self, from: try JSONEncoder().encode(reply)).todos == [item("1", "One", .pending)])
        // A transcript saved before lists were kept: it decodes, and its replies get their lists on loading.
        let old = Data(#"""
        {"id":"11111111-1111-1111-1111-111111111111","role":"assistant","text":"Earlier.","createdAt":0,
         "tools":[{"id":"22222222-2222-2222-2222-222222222222","name":"todo_list","status":"completed","args":"todos: [{\"id\":\"1\",\"content\":\"One\",\"status\":\"in_progress\"}]"}]}
        """#.utf8)
        var messages = [try JSONDecoder().decode(Message.self, from: old)]
        #expect(messages[0].todos == nil)
        TodoList.resolve(&messages)
        #expect(messages[0].todos == [item("1", "One", .inProgress)])
    }

    // MARK: Transcripts from the server

    @Test func theDashboardsHistoryGivesAReplyTheToolsListedBeforeIt() throws {
        // What Hermes 0.21.5's `session.resume` sends for two turns in which the model called
        // the to-do tool without a word first: each call is listed before the reply it led to.
        let rows = (try json(#"""
        [{"role": "user", "text": "Move the blog."},
         {"role": "tool", "name": "tool_call", "context": "Updating tasks", "tool_call_id": "call_1",
          "args": {"calls": [{"name": "todo_list", "arguments": {"todos": [{"id": "1", "content": "Export", "status": "in_progress"}, {"id": "2", "content": "Import", "status": "pending"}]}}]}},
         {"role": "assistant", "text": "Started."},
         {"role": "user", "text": "Carry on."},
         {"role": "tool", "name": "tool_call", "context": "", "args": {"calls": [{"name": "todo_list", "arguments": {"todos": [{"id": "1", "content": "Export", "status": "completed"}, {"id": "2", "content": "Import", "status": "in_progress"}], "merge": true}}]}},
         {"role": "tool", "name": "terminal", "context": "ls", "args": {"command": "ls"}},
         {"role": "assistant", "text": "Imported."},
         {"role": "user", "text": "And?"},
         {"role": "tool", "name": "terminal", "context": "sleep", "args": {"command": "sleep 100"}}]
        """#)).array ?? []
        var messages = Conversation.messages(fromServeRows: rows)
        #expect(messages.map(\.role) == [.user, .assistant, .user, .assistant, .user])
        #expect(messages[1].tools.map(\.name) == ["todo_list"], "named for the tool it called")
        #expect(messages[1].tools[0].preview == "Updating tasks")
        #expect(messages[3].tools.map(\.name) == ["todo_list", "terminal"])
        #expect(messages[3].tools[0].preview == nil, "an empty context is no preview")
        TodoList.resolve(&messages)
        #expect(messages[1].todos?.map(\.status) == [.inProgress, .pending])
        #expect(messages[3].todos?.map(\.status) == [.completed, .inProgress])

        // A model that says something first: its tools follow that message, as before.
        let spoken = (try json(#"""
        [{"role": "user", "text": "Go."}, {"role": "assistant", "text": "Let me look."},
         {"role": "tool", "name": "terminal", "context": "ls", "args": {"command": "ls"}}, {"role": "assistant", "text": "Done."}]
        """#)).array ?? []
        let said = Conversation.messages(fromServeRows: spoken)
        #expect(said.map { $0.tools.count } == [0, 1, 0])
    }

    @Test func theHermesAPIsTranscriptNamesAWrappedCallForItsTool() throws {
        let stored = try JSONDecoder().decode([HermesSessionsAPI.StoredMessage].self, from: Data(#"""
        [{"role": "user", "content": "Move the blog."},
         {"role": "assistant", "content": "", "tool_calls": [{"id": "call_1", "type": "function", "function": {"name": "tool_call",
           "arguments": "{\"calls\": [{\"name\": \"todo_list\", \"arguments\": {\"todos\": [{\"id\": \"1\", \"content\": \"Export\", \"status\": \"in_progress\"}]}}]}"}}]},
         {"role": "tool", "tool_name": "tool_call", "content": "{\"todos\": [{\"id\": \"1\", \"content\": \"Export\", \"status\": \"in_progress\"}], \"revision\": 1}"},
         {"role": "assistant", "content": "Started."},
         {"role": "user", "content": "Carry on."},
         {"role": "assistant", "content": "", "tool_calls": [{"id": "call_2", "type": "function", "function": {"name": "tool_call",
           "arguments": "{\"calls\": [{\"name\": \"todo_list\", \"arguments\": {\"todos\": [{\"id\": \"1\", \"status\": \"completed\"}], \"merge\": true}}]}"}}]},
         {"role": "tool", "tool_name": "tool_call", "content": "{\"error\": \"tool_call to 'todo_list' failed argument validation. The tool was NOT invoked.\"}"},
         {"role": "assistant", "content": "It wouldn't take that."}]
        """#.utf8))
        var messages = Conversation.mapStored(stored)
        #expect(messages.filter { $0.role == .assistant }.map { $0.tools.map(\.name) } == [["todo_list"], ["todo_list"]])
        TodoList.resolve(&messages)
        let replies = messages.filter { $0.role == .assistant }
        #expect(replies[0].todos == [item("1", "Export", .inProgress)])
        #expect(replies[1].todos == nil, "a call the host turned down leaves the list, and the reply shows none")
        #expect(TodoList.latest(in: messages) == [item("1", "Export", .inProgress)])
    }

    // MARK: A live conversation

    private func conversation(_ events: [TurnEvent]) -> Conversation {
        let settings = Settings(defaults: UserDefaults(suiteName: "todo-\(UUID().uuidString)")!)
        settings.transport = .chatCompletions
        settings.fastLaneURL = "http://example.invalid:11500"
        settings.fastLaneModel = "test"
        return Conversation(settings: settings, store: ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "todo-\(UUID().uuidString)")),
                            transportOverride: ConversationLifecycleTests.ScriptedTransport(events))
    }

    private func reply(of conversation: Conversation, to text: String) async throws -> Message {
        _ = conversation.send(text)
        for _ in 0 ..< 300 where conversation.isStreaming { try await Task.sleep(for: .milliseconds(10)) }
        return try #require(conversation.messages.last)
    }

    @Test func theAnswerOfAReplysNewestCallIsTheList() {
        // After a turn over the Hermes API the transcript is asked what the tool answered. Hermes
        // 0.21.3 and 0.21.5 start a later turn there on an empty list, so this merge of two left
        // two, whatever the list was a turn before.
        let wrote = todo(#"todos: [{"id":"1","content":"One","status":"in_progress"},{"id":"2","content":"Two","status":"pending"},{"id":"3","content":"Three","status":"pending"}]"#,
                         output: #"{"todos":[{"id":"1","content":"One","status":"in_progress"},{"id":"2","content":"Two","status":"pending"},{"id":"3","content":"Three","status":"pending"}],"revision":1}"#)
        let merged = todo("merge: true\n" + #"todos: [{"id":"1","content":"One","status":"completed"},{"id":"2","content":"Two","status":"in_progress"}]"#,
                          output: #"{"todos":[{"id":"1","content":"One","status":"completed"},{"id":"2","content":"Two","status":"in_progress"}],"revision":1}"#)
        #expect(TodoList.answered(by: [step("terminal", "command: ls", output: "a\nb"), wrote, merged])
                == [item("1", "One", .completed), item("2", "Two", .inProgress)])

        // A call Hermes turned down changed nothing: the one before it still counts.
        let refused = step("tool_call", #"calls: [{"name":"todo_list","arguments":{"merge":true,"todos":[{"id":"2","status":"completed"}]}}]"#,
                           output: #"{"error": "Invalid arguments for todo_list. The tool was NOT invoked."}"#)
        #expect(TodoList.answered(by: [wrote, refused])?.map(\.status) == [.inProgress, .pending, .pending])

        // No answer to read: nothing to say, and the list worked out from the calls stays.
        #expect(TodoList.answered(by: [wrote, todo("merge: true\n" + #"todos: [{"id":"1","status":"completed"}]"#)]) == nil)
        #expect(TodoList.answered(by: [wrote, todo("merge: true\n" + #"todos: [{"id":"1","status":"completed"}]"#, output: #"{"todos":[{"id":"1","content":"On"#)]) == nil)
        #expect(TodoList.answered(by: [step("terminal", "command: ls", output: #"{"todos": []}"#)]) == nil)
        #expect(TodoList.answered(by: []) == nil)
    }

    @Test func overTheHermesAPITheListIsWhatTheFinishedCallsWrote() async throws {
        // The stream names a finished call without its result.
        let plan = #"todos: [{"id":"1","content":"One","status":"in_progress"},{"id":"2","content":"Two","status":"pending"}]"#
        let c = conversation([
            .toolStarted(name: "todo_list", preview: "2 tasks", args: plan),
            .toolFinished(name: "todo_list", failed: false),
            .toolStarted(name: "todo_list", preview: "1 update", args: "merge: true\n" + #"todos: [{"id":"1","status":"completed"},{"id":"2","status":"in_progress"}]"#),
            .toolFinished(name: "todo_list", failed: false),
            .toolStarted(name: "todo_list", preview: nil, args: "merge: true\n" + #"todos: [{"id":"2","status":"completed"}]"#),
            .toolFinished(name: "todo_list", failed: true),
            .textDelta("Working on it."), .done,
        ])
        let reply = try await reply(of: c, to: "Do the two things.")
        #expect(reply.tools.count == 3)
        #expect(reply.todos == [item("1", "One", .completed), item("2", "Two", .inProgress)], "the call that failed wrote nothing")
    }

    @Test func overTheDashboardTheListIsWhatTheHostSays() async throws {
        let c = conversation([
            .toolStarted(name: "todo_list", preview: "1 update", args: "merge: true\n" + #"todos: [{"id":"1","content":"One","status":"completed"}]"#),
            .toolFinished(name: "todo_list", failed: false, output: #"{"todos":[{"id":"1","content":"One","status":"completed"}],"revision":2}"#),
            // The host's own word on the list, which is longer than the call let on.
            .todos([item("1", "One", .completed), item("2", "Two", .inProgress)]),
            .textDelta("Ticked."), .done,
        ])
        let reply = try await reply(of: c, to: "Carry on.")
        #expect(reply.todos == [item("1", "One", .completed), item("2", "Two", .inProgress)])
    }
}
