import Foundation

/// The agent's task list (Hermes's to-do tool), so a reply can show it as a checklist.
///
/// Hermes keeps the list. Over the Dashboard it also says what the list is after every change
/// (`todo.updated`, in 0.21.0, 0.21.3 and 0.21.5 alike), and that is taken as it comes
/// (`TurnEvent.todos`). Everywhere else a client only has the calls: what each one wrote and,
/// where the connection keeps it, what the tool answered. That is the Hermes API's live stream,
/// and every transcript that is read back, from the server or from disk.
///
/// Calls reach the app as a step's text (`ToolActivity.args` and `.output`), which is also what
/// a saved transcript holds, so that is what is read: JSON as it came, or the one-field-per-line
/// form `ToolActivity.detail` gives an object. A call that replaces the list names all of it; one
/// that merges names what changed and is applied to the list before it, the way Hermes's own
/// store does (`tools/todo_tool.py`). From 0.21.3 the model mostly reaches the tool through
/// `tool_call`, which names it and carries its arguments; that is read the same.
nonisolated enum TodoList {
    /// `todo_list` from Hermes 0.21.3; `todo` before.
    static func isTool(_ name: String) -> Bool { name == "todo_list" || name == "todo" }
    /// The tool through which a model calls one that isn't offered to it outright.
    static let wrapper = "tool_call"

    /// What one call wrote: the items it named, each with only the fields it gave.
    struct Write: Equatable, Sendable {
        struct Entry: Equatable, Sendable {
            var id: String
            var content: String?
            var status: TodoItem.Status?
            var parent: String?
            /// The call said something about the parent, if only to clear it.
            var namesParent = false
        }
        var entries: [Entry]
        /// Merge into the list by id; otherwise this is the whole new list.
        var merge = false
    }

    /// The most items Hermes keeps.
    static let mostItems = 256

    // MARK: Reading a call

    /// What a step wrote to the list. Nil when the step isn't a to-do call, names no items (a
    /// call that only reads the list), or can't be read (text cut short at the step's cap).
    static func write(step name: String, input text: String?) -> Write? {
        guard let fields = fields(of: text) else { return nil }
        if isTool(name) { return write(fields) }
        guard name == wrapper, let calls = array(fields["calls"]) else { return nil }
        // One call to a tool of the app's own kind per `tool_call`: the first to the to-do tool.
        guard let call = calls.first(where: { isTool($0["name"]?.string ?? "") }),
              let arguments = call["arguments"]?.object ?? (call["arguments"]?.string).flatMap({ (try? JSONValue.parse(Data($0.utf8)))?.object }) else { return nil }
        return write(arguments)
    }

    private static func write(_ fields: [String: JSONValue]) -> Write? {
        guard let listed = array(fields["todos"]) else { return nil }
        let entries = listed.compactMap(entry)
        return entries.isEmpty ? nil : Write(entries: entries, merge: flag(fields["merge"]))
    }

    /// The whole list a tool's answer gives back, when the connection kept the answer.
    static func list(fromOutput text: String?) -> [TodoItem]? {
        guard let fields = fields(of: text), let listed = array(fields["todos"]) else { return nil }
        return sanitized(listed.compactMap(entry).map(item))
    }

    /// The list out of a snapshot the host sends (`todo.updated`, or `todo_state` on a resume).
    static func list(_ snapshot: JSONValue?) -> [TodoItem]? {
        guard let listed = snapshot?["todos"]?.array else { return nil }
        return sanitized(listed.compactMap(entry).map(item))
    }

    private static let knownFields = ["todos", "merge", "revision", "summary", "calls"]

    /// A step's text as fields: a JSON object as it came, or `key: value` lines.
    private static func fields(of text: String?) -> [String: JSONValue]? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text.hasPrefix("{") { return (try? JSONValue.parse(Data(text.utf8)))?.object }
        var fields: [String: JSONValue] = [:]
        var key: String?
        var lines: [Substring] = []
        func close() {
            guard let key else { return }
            let value = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            fields[key] = (try? JSONValue.parse(Data(value.utf8))) ?? .string(value)
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let field = knownFields.first(where: { line.hasPrefix($0 + ":") }) {
                close()
                key = field
                lines = [line.dropFirst(field.count + 1)]
            } else {
                lines.append(line)
            }
        }
        close()
        return fields.isEmpty ? nil : fields
    }

    /// A list: an array, or one a model sent as text.
    private static func array(_ value: JSONValue?) -> [JSONValue]? {
        if let array = value?.array { return array }
        if let text = value?.string, let parsed = try? JSONValue.parse(Data(text.utf8)) { return parsed.array }
        return nil
    }

    private static func flag(_ value: JSONValue?) -> Bool {
        value?.bool ?? (value?.string?.lowercased() == "true")
    }

    private static func entry(_ value: JSONValue) -> Write.Entry? {
        guard let object = value.object else { return nil }
        let id = (object["id"]?.string ?? object["id"]?.int.map(String.init) ?? "").trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return nil }
        let content = object["content"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        let status = object["status"]?.string.flatMap { TodoItem.Status(rawValue: $0.trimmingCharacters(in: .whitespaces).lowercased()) }
        let parent = (object["parent"]?.string ?? object["parent"]?.int.map(String.init))?.trimmingCharacters(in: .whitespaces)
        return Write.Entry(id: id, content: content?.isEmpty == false ? content : nil, status: status,
                           parent: parent?.isEmpty == false ? parent : nil, namesParent: object["parent"] != nil)
    }

    /// An entry as a new item, with Hermes's placeholders for what it left out.
    private static func item(_ entry: Write.Entry) -> TodoItem {
        TodoItem(id: entry.id, content: entry.content ?? "(no description)", status: entry.status ?? .pending,
                 parent: entry.parent == entry.id ? nil : entry.parent)
    }

    // MARK: Keeping the list

    /// The list after a call, given the list before it.
    static func apply(_ write: Write, to previous: [TodoItem]) -> [TodoItem] {
        var items: [TodoItem]
        if write.merge {
            items = previous
            for entry in deduped(write.entries) {
                guard let i = items.firstIndex(where: { $0.id == entry.id }) else {
                    items.append(item(entry))
                    continue
                }
                if let content = entry.content { items[i].content = content }
                if let status = entry.status { items[i].status = status }
                if entry.namesParent { items[i].parent = entry.parent }
            }
        } else {
            items = deduped(write.entries).map(item)
        }
        return sanitized(normalized(Array(items.prefix(mostItems))))
    }

    /// The list after a finished step: the tool's own answer where there is one, else what the
    /// step wrote, applied to the list before. Nil when the step changed nothing: it isn't a
    /// to-do call, it only read the list, it couldn't be read, or its answer was a refusal
    /// (Hermes turns a call down without running the tool when its arguments don't fit).
    static func after(step tool: ToolActivity, previous: [TodoItem]) -> [TodoItem]? {
        guard tool.status != .failed, isTool(tool.name) || tool.name == wrapper else { return nil }
        if let listed = list(fromOutput: tool.output) {
            // A wrapped call to some other tool could answer with a field called "todos" too.
            return isTool(tool.name) || write(step: tool.name, input: tool.args) != nil ? listed : nil
        }
        guard tool.output == nil || !refused(tool.output), let write = write(step: tool.name, input: tool.args) else { return nil }
        return apply(write, to: previous)
    }

    /// The list as the newest to-do call among a reply's steps answered it. Nil when there is no
    /// such call, or its answer can't be read (the stream gave none, or it was cut short); a
    /// call Hermes turned down changed nothing, so the one before it counts.
    static func answered(by tools: [ToolActivity]) -> [TodoItem]? {
        for tool in tools.reversed() where tool.status != .failed {
            guard isTool(tool.name) || write(step: tool.name, input: tool.args) != nil, !refused(tool.output) else { continue }
            return list(fromOutput: tool.output)
        }
        return nil
    }

    /// The answer says the tool didn't run.
    private static func refused(_ output: String?) -> Bool {
        guard let output else { return false }
        return output.contains("NOT invoked") || output.hasPrefix("{\"error\"") || output.hasPrefix("error:") || output.hasPrefix("Error")
    }

    /// Of two entries with one id the later counts, where it stands.
    private static func deduped(_ entries: [Write.Entry]) -> [Write.Entry] {
        var last: [String: Int] = [:]
        for (i, entry) in entries.enumerated() { last[entry.id] = i }
        return last.values.sorted().map { entries[$0] }
    }

    /// The step in progress comes before any earlier one still waiting, in a list without
    /// subtasks: Hermes orders it so, and its own answer would say the same.
    private static func normalized(_ items: [TodoItem]) -> [TodoItem] {
        guard !items.contains(where: { $0.parent != nil }),
              let active = items.firstIndex(where: { $0.status == .inProgress }),
              let waiting = items.firstIndex(where: { $0.status == .pending }), waiting < active else { return items }
        var items = items
        items.insert(items.remove(at: active), at: waiting)
        return items
    }

    /// A parent that isn't in the list, or that leads back to the item itself, is no parent.
    private static func sanitized(_ items: [TodoItem]) -> [TodoItem] {
        var items = items
        let ids = Set(items.map(\.id))
        for i in items.indices where items[i].parent.map({ !ids.contains($0) || $0 == items[i].id }) == true { items[i].parent = nil }
        let parents = Dictionary(items.map { ($0.id, $0.parent) }) { first, _ in first }
        for i in items.indices {
            var seen: Set<String> = [items[i].id]
            var node = items[i].parent
            while let up = node {
                if !seen.insert(up).inserted { items[i].parent = nil; break }
                node = parents[up] ?? nil
            }
        }
        return items
    }

    /// Gives every reply in a transcript the list as it left it, by replaying the to-do calls in
    /// order. A reply that already has one keeps it (the host said so while the turn ran) and
    /// the replay carries on from there.
    static func resolve(_ messages: inout [Message]) {
        var current: [TodoItem] = []
        for m in messages.indices where messages[m].role == .assistant {
            if let known = messages[m].todos {
                current = known
                continue
            }
            var changed = false
            for tool in messages[m].tools {
                guard let next = after(step: tool, previous: current) else { continue }
                current = next
                changed = true
            }
            if changed { messages[m].todos = current }
        }
    }

    /// What the host says the list is now, set against a transcript that was read back. Where
    /// the replay came out differently (a call the host refused, a row that wasn't kept), the
    /// newest reply with a list takes the host's; where no reply has one, the newest reply does.
    static func reconcile(_ messages: inout [Message], with host: [TodoItem]?) {
        guard let host, !host.isEmpty, latest(in: messages) != host else { return }
        guard let m = messages.lastIndex(where: { $0.role == .assistant && $0.todos != nil })
                ?? messages.lastIndex(where: { $0.role == .assistant }) else { return }
        messages[m].todos = host
    }

    /// The list as the newest reply that has one left it: what a merge is applied to.
    static func latest(in messages: [Message]) -> [TodoItem] {
        messages.last { $0.todos != nil }?.todos ?? []
    }

    // MARK: Showing it

    /// How deep each item sits under its parents, by id.
    static func depths(_ items: [TodoItem]) -> [String: Int] {
        let parents = Dictionary(items.map { ($0.id, $0.parent) }) { first, _ in first }
        var depths: [String: Int] = [:]
        for item in items {
            var depth = 0
            var node = item.parent
            while let up = node, depth < 8 {
                depth += 1
                node = parents[up] ?? nil
            }
            depths[item.id] = depth
        }
        return depths
    }

    /// "2 of 5 done". Cancelled items are not work left to do, and not work done.
    static func summary(_ items: [TodoItem]) -> String {
        let live = items.filter { $0.status != .cancelled }
        let done = live.filter { $0.status == .completed }.count
        return live.isEmpty ? "Nothing left" : done == live.count ? "All \(live.count) done" : "\(done) of \(live.count) done"
    }
}
