import Foundation

/// ACP (the Agent Client Protocol, version 1) in Redde's words: one `session/update` as the turn
/// events the transcript already knows, a session's replayed history as messages, a permission
/// request as an approval card. Pure, so the shapes recorded off real agents can test it
/// (`EchoTests/AcpTests`). See docs/acp.md.
nonisolated struct AcpTurnMapper: Sendable {
    /// Tool calls started this turn, by id, with the name their card has.
    private var tools: [String: String] = [:]
    /// Calls announced with nothing to show yet (Claude Code's "Preparing file…" with no input):
    /// held until an update says what they do, so the step isn't named for the wait.
    private var held: [String: JSONValue] = [:]
    /// The last agent message's id: a new one is a new message, set apart from the one before.
    private var messageID: String?
    private var wroteText = false
    private var lastContext: (used: Int, size: Int)?
    /// The files each call changed, kept from the update that said so: the call's last update
    /// often comes with its content empty.
    private var changes = AcpChanges()

    init() {}

    mutating func events(for update: JSONValue) -> [TurnEvent] {
        changes.note(update)
        switch update["sessionUpdate"]?.string {
        case "agent_message_chunk":
            guard let text = Self.text(update["content"]), !text.isEmpty else { return [] }
            var out = text
            let id = update["messageId"]?.string
            if let id, id != messageID {
                // A second message in one turn (text, a tool, more text): a paragraph between.
                if messageID != nil, wroteText, !text.hasPrefix("\n") { out = "\n\n" + out }
                messageID = id
            }
            wroteText = true
            return [.textDelta(out)]
        case "agent_thought_chunk":
            guard let text = Self.text(update["content"]), !text.isEmpty else { return [] }
            return [.reasoningDelta(text)]
        case "tool_call":
            guard let id = update["toolCallId"]?.string else { return [] }
            if Self.isBare(update), Self.finished(update, name: "") == nil {
                held[id] = update
                return []
            }
            return start(id, update)
        case "tool_call_update":
            guard let id = update["toolCallId"]?.string else { return [] }
            if let waiting = held[id] {
                let merged = Self.merge(waiting, update)
                if Self.isBare(merged), Self.finished(merged, name: "") == nil {
                    held[id] = merged
                    return []
                }
                held[id] = nil
                return start(id, merged)
            }
            guard let name = tools[id] else { return [] }
            guard let finished = Self.finished(update, name: name) else { return [] }
            tools[id] = nil
            return [changes.output(of: finished, id: id)]
        case "plan":
            return [.todos(Self.todos(update))]
        case "usage_update":
            guard let used = update["used"]?.int, let size = update["size"]?.int else { return [] }
            lastContext = (used, size)
            return [.usage(TokenUsage(input: 0, output: 0, contextUsed: used, contextMax: size))]
        case "notice":
            guard let title = update["title"]?.string, !title.isEmpty else { return [] }
            return [.status(title)]
        case "session_info_update":
            guard let title = update["title"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return [] }
            return [.title(title)]
        default:
            // user_message_chunk (our own words), commands, modes, config, titles: not the reply.
            return []
        }
    }

    private mutating func start(_ id: String, _ call: JSONValue) -> [TurnEvent] {
        let (name, preview) = Self.name(call)
        tools[id] = name
        var events: [TurnEvent] = [.toolStarted(name: name, preview: preview, args: Self.args(call))]
        if let finished = Self.finished(call, name: name) {
            tools[id] = nil
            events.append(changes.output(of: finished, id: id))
        }
        return events
    }

    /// A call that says nothing yet about what it does: no input and no content.
    static func isBare(_ call: JSONValue) -> Bool {
        let input = call["rawInput"]
        let noInput = input == nil || input!.isNull || input!.object?.isEmpty == true
        let noContent = (call["content"]?.array ?? []).isEmpty
        return noInput && noContent
    }

    /// An update's fields over the call's: the later title, input and content win.
    static func merge(_ call: JSONValue, _ update: JSONValue) -> JSONValue {
        guard var fields = call.object, let changes = update.object else { return update }
        for (key, value) in changes where key != "sessionUpdate" && !value.isNull { fields[key] = value }
        return .object(fields)
    }

    /// The prompt's answer: its token counts, where the agent says (Hermes does, outside the
    /// spec's fields), with the context last reported.
    func usage(fromPromptResult result: JSONValue) -> TurnEvent? {
        guard let usage = result["usage"], let input = usage["inputTokens"]?.int else { return nil }
        return .usage(TokenUsage(input: input, output: usage["outputTokens"]?.int ?? 0,
                                 cached: usage["cachedReadTokens"]?.int,
                                 contextUsed: lastContext?.used, contextMax: lastContext?.size))
    }

    /// Why the turn stopped, when it wasn't the agent finishing: said under the reply.
    static func stopNote(_ reason: String?) -> String? {
        switch reason {
        case "max_tokens": String(localized: "The agent stopped: it reached its token limit.", comment: "Under a reply over ACP")
        case "max_turn_requests": String(localized: "The agent stopped: it reached its limit of steps for one turn.", comment: "Under a reply over ACP")
        case "refusal": String(localized: "The agent declined to answer.", comment: "Under a reply over ACP")
        case "agent_exited": String(localized: "The agent stopped running on the host.", comment: "Under a reply over ACP: its process ended")
        default: nil
        }
    }

    // MARK: Pieces

    /// The text of a content block, or of a list of tool-call contents.
    static func text(_ content: JSONValue?) -> String? {
        guard let content else { return nil }
        if let array = content.array {
            let parts = array.compactMap { item -> String? in
                if item["type"]?.string == "content" { return text(item["content"]) }
                if item["type"]?.string == "diff", let path = item["path"]?.string {
                    return String(localized: "Changed \(path)", comment: "A tool step's detail: a file the agent edited")
                }
                return text(item)
            }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        }
        switch content["type"]?.string {
        case "text": return content["text"]?.string
        case "resource_link": return content["title"]?.string ?? content["name"]?.string ?? content["uri"]?.string
        case "resource": return content["resource"]?["text"]?.string
        default: return nil
        }
    }

    /// A tool call's name and preview from its title. "terminal: rm -rf x" (Hermes) is the tool
    /// `terminal` running `rm -rf x`; a title that is a sentence ("Read Package.swift", Claude
    /// Code) is the name itself. The spec's own `name` field wins where an agent sends it.
    static func name(_ call: JSONValue) -> (name: String, preview: String?) {
        let title = (call["title"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let named = call["name"]?.string, !named.isEmpty {
            // "Write hello.txt" for the tool Write: the step reads Write · hello.txt.
            var preview = title
            for lead in [named + ": ", named + " "] where preview.hasPrefix(lead) { preview = String(preview.dropFirst(lead.count)); break }
            return (named, preview.isEmpty || preview == named ? nil : preview)
        }
        if let colon = title.range(of: ": "), !title[..<colon.lowerBound].contains(" "), !title[..<colon.lowerBound].isEmpty {
            return (String(title[..<colon.lowerBound]), String(title[colon.upperBound...]))
        }
        if !title.isEmpty { return (title, nil) }
        return (call["kind"]?.string ?? "tool", nil)
    }

    static func args(_ call: JSONValue) -> String? {
        if let raw = call["rawInput"], !raw.isNull { return ToolActivity.detail(raw) }
        return ToolActivity.detail(text(call["content"]))
    }

    /// `toolFinished` for a call whose status says it ended; nil while it runs.
    static func finished(_ call: JSONValue, name: String) -> TurnEvent? {
        switch call["status"]?.string {
        case "completed", "failed":
            let output: String? = {
                if let raw = call["rawOutput"], !raw.isNull { return ToolActivity.detail(raw) }
                return ToolActivity.detail(text(call["content"]))
            }()
            return .toolFinished(name: name, failed: call["status"]?.string == "failed", output: output)
        default:
            return nil
        }
    }

    static func todos(_ plan: JSONValue) -> [TodoItem] {
        (plan["entries"]?.array ?? []).enumerated().map { index, entry in
            let status: TodoItem.Status = switch entry["status"]?.string {
            case "in_progress": .inProgress
            case "completed": .completed
            default: .pending
            }
            return TodoItem(id: String(index + 1), content: entry["content"]?.string ?? "", status: status)
        }
    }
}

/// A session's history as ACP replays it on `session/load`, as messages.
nonisolated enum AcpHistory {
    static func messages(_ updates: [JSONValue]) -> [Message] {
        var out: [Message] = []
        var lastUserID: String?
        var lastAgentID: String?
        var toolIndex: [String: Int] = [:]
        var changes = AcpChanges()
        func reply() -> Int {
            if let last = out.indices.last, out[last].role == .assistant { return last }
            out.append(Message(role: .assistant, text: ""))
            toolIndex = [:]
            return out.count - 1
        }
        for update in updates {
            changes.note(update)
            switch update["sessionUpdate"]?.string {
            case "user_message_chunk":
                let text = AcpTurnMapper.text(update["content"]) ?? ""
                let id = update["messageId"]?.string
                if let last = out.indices.last, out[last].role == .user, id == nil || id == lastUserID {
                    out[last].text += text
                } else {
                    out.append(Message(role: .user, text: text))
                }
                lastUserID = id
                lastAgentID = nil
            case "agent_message_chunk":
                guard let text = AcpTurnMapper.text(update["content"]) else { continue }
                let at = reply()
                let id = update["messageId"]?.string
                if let id, let lastAgentID, id != lastAgentID, !out[at].text.isEmpty, !text.hasPrefix("\n") {
                    out[at].text += "\n\n"
                }
                out[at].text += text
                if let id { lastAgentID = id }
            case "agent_thought_chunk":
                guard let text = AcpTurnMapper.text(update["content"]) else { continue }
                out[reply()].reasoning += text
            case "tool_call":
                guard let id = update["toolCallId"]?.string else { continue }
                let at = reply()
                let (name, preview) = AcpTurnMapper.name(update)
                var tool = ToolActivity(name: name, preview: preview, status: .running)
                tool.args = AcpTurnMapper.args(update)
                apply(update, to: &tool)
                if let patch = changes.patch(id) { tool.output = patch }
                // A replayed call that never said it ended is over by now.
                if tool.status == .running { tool.status = .completed }
                toolIndex[id] = out[at].tools.count
                out[at].tools.append(tool)
            case "tool_call_update":
                guard let id = update["toolCallId"]?.string, let index = toolIndex[id],
                      let at = out.indices.last, out[at].role == .assistant, index < out[at].tools.count else { continue }
                apply(update, to: &out[at].tools[index])
                if let patch = changes.patch(id) { out[at].tools[index].output = patch }
            case "plan":
                out[reply()].todos = AcpTurnMapper.todos(update)
            default:
                continue
            }
        }
        // A reply that is all tools and no words still shows; a user row with no words doesn't, nor
        // Claude Code's note of a stop ("[Request interrupted by user for tool use]", after a "No").
        for i in out.indices where out[i].role == .user { out[i].text = CarBrevity.strip(out[i].text) }
        return out.filter {
            let text = $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return $0.role == .assistant || !(text.isEmpty || text.wholeMatch(of: /\[Request interrupted by user[^\]]*\]/) != nil)
        }
    }

    private static func apply(_ update: JSONValue, to tool: inout ToolActivity) {
        // A call announced bare and filled in later takes the later title and input.
        if update["sessionUpdate"]?.string == "tool_call_update" {
            if update["title"]?.string?.isEmpty == false {
                (tool.name, tool.preview) = AcpTurnMapper.name(update.object.map { var f = $0; f["name"] = f["name"] ?? .string(tool.name); return .object(f) } ?? update)
            }
            if let input = update["rawInput"], input.object?.isEmpty == false { tool.args = ToolActivity.detail(input) }
        }
        switch update["status"]?.string {
        case "completed": tool.status = .completed
        case "failed": tool.status = .failed
        default: break
        }
        if case let .toolFinished(_, _, output)? = AcpTurnMapper.finished(update, name: tool.name), let output {
            tool.output = output
        }
    }
}

/// An ACP permission request as Redde's approval card: what the agent wants to run, and its
/// options in the card's words (once, session, always, deny), each kept with the option id the
/// agent gave it.
nonisolated enum AcpPermission {
    static func approval(id: String, params: JSONValue) -> (request: ApprovalRequest, options: [String: String]) {
        let call = params["toolCall"] ?? .null
        let raw = call["rawInput"]
        let title = call["title"]?.string
        let command = raw?["command"]?.string ?? AcpTurnMapper.name(call).preview ?? title ?? String(localized: "A tool call", comment: "An approval card over ACP that names no command")
        var description = raw?["description"]?.string
        if description == nil, let title, title != command { description = title }
        var options: [String: String] = [:]
        var order: [String] = []
        for option in params["options"]?.array ?? [] {
            guard let optionID = option["optionId"]?.string else { continue }
            let words = "\(optionID) \(option["name"]?.string ?? "")".lowercased()
            let choice: String? = switch option["kind"]?.string {
            case "allow_once": "once"
            case "allow_always": words.contains("session") ? "session" : "always"
            case "reject_once": "deny"
            case "reject_always": options["deny"] == nil ? "deny" : nil
            default: nil
            }
            guard let choice, options[choice] == nil else { continue }
            options[choice] = optionID
            order.append(choice)
        }
        let ranked = ["once", "session", "always", "deny"].filter(order.contains)
        return (ApprovalRequest(id: id, command: command, description: description, choices: ranked), options)
    }

    /// The reply to the request for a choice: the option it stands for, else "cancelled".
    static func reply(choice: String, options: [String: String]) -> JSONValue {
        guard let optionID = options[choice] else { return .object(["outcome": .object(["outcome": .string("cancelled")])]) }
        return selected(optionID)
    }

    static func selected(_ optionID: String) -> JSONValue {
        .object(["outcome": .object(["outcome": .string("selected"), "optionId": .string(optionID)])])
    }
}

/// A permission request the approval card can't show whole, asked as a question in the agent's
/// own words instead: one that changes how the agent works (`switch_mode`, Claude Code's plan
/// with its plan above the options), or one with more options than once, session, always and
/// deny can tell apart ("Yes, and use auto mode", "Yes, clear context…"). Words typed instead of
/// a choice turn it down and go to the agent next, as "No, keep planning" and then what to
/// change does in Claude Code.
nonisolated struct AcpChoice: Sendable {
    var options: [(name: String, id: String)]
    /// The option that turns it down, which typed words go with.
    var reject: String?

    static func make(id: String, params: JSONValue) -> (card: ClarifyRequest, choice: AcpChoice)? {
        let call = params["toolCall"] ?? .null
        var options: [(name: String, id: String)] = []
        var reject: String?
        var allows = 0
        for option in params["options"]?.array ?? [] {
            guard let optionID = option["optionId"]?.string, let name = option["name"]?.string?.nilIfEmpty,
                  !options.contains(where: { $0.name == name }) else { continue }
            options.append((name, optionID))
            if option["kind"]?.string?.hasPrefix("allow") == true { allows += 1 }
            if reject == nil, option["kind"]?.string?.hasPrefix("reject") == true { reject = optionID }
        }
        // A second way to say no is fine to lose (the card has one); a way to say yes isn't.
        let kept = AcpPermission.approval(id: id, params: params).options.keys.filter { $0 != "deny" }.count
        let changesMode = call["kind"]?.string == "switch_mode"
        guard options.count >= 2, changesMode || kept < allows else { return nil }
        let shown = (call["content"]?.array ?? []).compactMap { $0["type"]?.string == "content" ? AcpTurnMapper.text($0["content"] ?? .null) : nil }
            .joined(separator: "\n\n")
        let detail = call["rawInput"]?["plan"]?.string?.nilIfEmpty ?? (changesMode ? shown.nilIfEmpty : nil)
        let asked = call["title"]?.string?.nilIfEmpty ?? AcpTurnMapper.name(call).preview
            ?? String(localized: "How should it go on?", comment: "A question card over ACP for an agent's request that names nothing")
        let question = ClarifyQuestion(id: "", question: asked, choices: options.map(\.name), multiSelect: false,
                                       detail: detail?.trimmingCharacters(in: .whitespacesAndNewlines))
        return (ClarifyRequest(id: id, questions: [question], isBatch: false), AcpChoice(options: options, reject: reject))
    }

    /// The reply for the card's answer, and the words to send the agent next when they weren't
    /// one of its options.
    func reply(_ answers: [String: String]) -> (result: JSONValue, next: String?) {
        let answer = (answers[""] ?? answers.values.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let picked = options.first(where: { $0.name == answer }) { return (AcpPermission.selected(picked.id), nil) }
        let next = answer.nilIfEmpty
        guard let reject else { return (.object(["outcome": .object(["outcome": .string("cancelled")])]), next) }
        return (AcpPermission.selected(reject), next)
    }

    /// The answer as the chat keeps it: typed words stand for the option that turned it down.
    func shown(_ answers: [String: String]) -> [String: String] {
        let answer = (answers[""] ?? answers.values.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !options.contains(where: { $0.name == answer }), let name = options.first(where: { $0.id == reject })?.name else { return answers }
        return ["": name]
    }
}

/// A model choice offered as an ACP session config option (category `model`), as the picker's.
nonisolated enum AcpModels {
    /// The option that picks the model, from a session's config options.
    static func option(_ configOptions: [JSONValue]) -> JSONValue? {
        configOptions.first { $0["category"]?.string == "model" && $0["type"]?.string != "boolean" }
            ?? configOptions.first { $0["id"]?.string == "model" }
    }

    static func choices(_ configOptions: [JSONValue]) -> [ModelChoice] {
        guard let option = option(configOptions) else { return [] }
        let current = option["currentValue"]?.string
        var out: [ModelChoice] = []
        func add(_ value: JSONValue, group: String?) {
            guard let id = value["value"]?.string else { return }
            let name = value["name"]?.string ?? id
            // Hermes names its rows "Anthropic · claude-opus-5-5": the provider before the dot.
            let parts = name.components(separatedBy: " · ")
            let provider = group ?? (parts.count > 1 ? parts[0] : "")
            let shown = parts.count > 1 ? parts.dropFirst().joined(separator: " · ") : name
            out.append(ModelChoice(provider: "acp", providerName: provider, model: id, name: shown, isCurrent: id == current))
        }
        for entry in option["options"]?.array ?? [] {
            if let grouped = entry["options"]?.array {
                for value in grouped { add(value, group: entry["name"]?.string) }
            } else {
                add(entry, group: nil)
            }
        }
        return out
    }
}

/// A session's other choices the picker shows beside the model: how it asks before acting (ACP's
/// `mode` category, Claude Code's Manual / Accept Edits / Plan / Auto; Codex keeps Plan apart as
/// `collaboration_mode`) and how hard it thinks
/// (`thought_level`).
nonisolated struct AcpOption: Identifiable, Equatable, Sendable {
    struct Value: Equatable, Sendable {
        var id: String
        var name: String
        var detail: String?
    }

    var id: String
    var name: String
    var category: String
    var current: String?
    var values: [Value]

    static let categories = ["mode", "collaboration_mode", "thought_level"]

    static func pickable(_ configOptions: [JSONValue]) -> [AcpOption] {
        let options = configOptions.compactMap { option -> AcpOption? in
            guard let id = option["id"]?.string, let category = option["category"]?.string,
                  categories.contains(category), option["type"]?.string != "boolean" else { return nil }
            var values: [Value] = []
            for entry in option["options"]?.array ?? [] {
                for value in entry["options"]?.array ?? [entry] {
                    guard let v = value["value"]?.string else { continue }
                    values.append(Value(id: v, name: value["name"]?.string ?? v, detail: value["description"]?.string?.nilIfEmpty))
                }
            }
            guard values.count > 1 else { return nil }
            return AcpOption(id: id, name: option["name"]?.string ?? id, category: category,
                             current: option["currentValue"]?.string, values: values)
        }
        return options.sorted { (categories.firstIndex(of: $0.category) ?? 9) < (categories.firstIndex(of: $1.category) ?? 9) }
    }
}

/// A session's `modes` and `models`, the older ACP way of offering them (Gemini CLI's), as config
/// options, so the picker shows them like Claude Code's and Codex's. Picked with `session/set_mode`
/// and `session/set_model` (`AcpClient.setOption`, `setModel`).
nonisolated enum AcpLegacyOptions {
    static let modeID = "_redde_mode"
    static let modelID = "_redde_model"

    /// Nil when the session offers neither.
    static func options(_ result: JSONValue) -> [JSONValue]? {
        var out: [JSONValue] = []
        if let modes = result["modes"], let list = modes["availableModes"]?.array, !list.isEmpty {
            out.append(option(id: modeID, name: String(localized: "Mode", comment: "ACP picker: how the agent asks before acting"),
                              category: "mode", current: modes["currentModeId"], values: list, key: "id"))
        }
        if let models = result["models"], let list = models["availableModels"]?.array, !list.isEmpty {
            out.append(option(id: modelID, name: String(localized: "Model"), category: "model",
                              current: models["currentModelId"], values: list, key: "modelId"))
        }
        return out.isEmpty ? nil : out
    }

    private static func option(id: String, name: String, category: String, current: JSONValue?, values: [JSONValue], key: String) -> JSONValue {
        .object(["id": .string(id), "name": .string(name), "category": .string(category), "type": .string("select"),
                 "currentValue": current ?? .null,
                 "options": .array(values.compactMap { value in
                     value[key]?.string.map { .object(["value": .string($0), "name": value["name"] ?? .string($0),
                                                       "description": value["description"] ?? .null]) }
                 })])
    }

    /// `options` with one of them set to `value`: the agent answers a pick with nothing.
    static func setting(_ options: [JSONValue], id: String, to value: String) -> [JSONValue] {
        options.map { option in
            guard option["id"]?.string == id, case .object(var fields) = option else { return option }
            fields["currentValue"] = .string(value)
            return .object(fields)
        }
    }

    /// Gemini CLI tells of a mode it moved to itself in words ("[MODE_UPDATE] plan"): that's
    /// `current_mode_update`, not a reply.
    static func normalize(_ update: JSONValue) -> JSONValue {
        guard update["sessionUpdate"]?.string == "agent_message_chunk", let text = update["content"]?["text"]?.string,
              text.hasPrefix("[MODE_UPDATE] ") else { return update }
        let mode = text.dropFirst("[MODE_UPDATE] ".count).trimmingCharacters(in: .whitespacesAndNewlines)
        return .object(["sessionUpdate": .string("current_mode_update"), "currentModeId": .string(mode)])
    }
}

/// `session/list` rows as the chat list's.
/// A slash command the agent offers (`available_commands_update`): typed as "/name" at the start
/// of a prompt, which is how ACP runs one (Claude Code's /compact, /review, a project's own).
nonisolated struct AcpCommand: Identifiable, Equatable, Sendable {
    var name: String
    var detail: String
    /// What goes after the name, when the command takes something.
    var hint: String?
    var id: String { name }

    static func list(_ update: JSONValue) -> [AcpCommand] {
        (update["availableCommands"]?.array ?? []).compactMap { command in
            guard var name = command["name"]?.string?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
            if name.hasPrefix("/") { name.removeFirst() }
            return AcpCommand(name: name, detail: command["description"]?.string ?? "",
                              hint: command["input"]?["hint"]?.string?.nilIfEmpty)
        }
    }

    /// The commands for a draft that is "/" and the start of a name: those starting so first,
    /// then those with it further in. Nothing once the name is done (a space typed).
    static func matching(_ draft: String, in commands: [AcpCommand]) -> [AcpCommand] {
        guard draft.hasPrefix("/"), !draft.contains(where: \.isWhitespace) else { return [] }
        let typed = draft.dropFirst().lowercased()
        guard !typed.isEmpty else { return commands }
        let starts = commands.filter { $0.name.lowercased().hasPrefix(typed) }
        let within = commands.filter { !$0.name.lowercased().hasPrefix(typed) && $0.name.lowercased().contains(typed) }
        return starts + within
    }
}

/// A file the agent changed (a tool call's `diff` content: `path`, `oldText`, null for a new file,
/// and `newText`) as a unified diff, which the step keeps as its output and `PatchView` reads.
/// Claude Code's own patch (`_meta.claudeCode.toolResponse.structuredPatch`) is taken where it
/// comes, since its line numbers are the file's; an edit's `oldText` and `newText` are only the
/// part that changed.
/// The files each tool call changed, by call id, as its updates said.
nonisolated struct AcpChanges: Sendable {
    private var files: [String: [(path: String, old: String?, new: String)]] = [:]
    private var meta: [String: JSONValue] = [:]

    mutating func note(_ update: JSONValue) {
        guard let id = update["toolCallId"]?.string else { return }
        let found = AcpDiff.changes(update)
        if !found.isEmpty { files[id] = found }
        if let extra = update["_meta"], extra["claudeCode"]?["toolResponse"]?["structuredPatch"] != nil { meta[id] = extra }
    }

    func patch(_ id: String) -> String? {
        files[id].flatMap { AcpDiff.patch($0, meta: meta[id]) }.flatMap { ToolActivity.detail($0 as String?) }
    }

    /// A finished call's event with the change as its output, when it changed a file.
    func output(of event: TurnEvent, id: String) -> TurnEvent {
        guard case let .toolFinished(name, failed, _) = event, let patch = patch(id) else { return event }
        return .toolFinished(name: name, failed: failed, output: patch)
    }
}

nonisolated enum AcpDiff {
    /// The diff contents of a call or update, as (path, old, new).
    static func changes(_ call: JSONValue) -> [(path: String, old: String?, new: String)] {
        (call["content"]?.array ?? []).compactMap { item in
            guard item["type"]?.string == "diff", let path = item["path"]?.string, let new = item["newText"]?.string else { return nil }
            return (path, item["oldText"]?.string, new)
        }
    }

    /// The unified diff of a call's changes; nil when it changed no file.
    static func patch(_ changes: [(path: String, old: String?, new: String)], meta: JSONValue? = nil) -> String? {
        guard !changes.isEmpty else { return nil }
        var out: [String] = []
        for (index, change) in changes.enumerated() {
            out.append(change.old == nil ? "--- /dev/null" : "--- \(change.path)")
            out.append("+++ \(change.path)")
            if index == 0, let hunks = structured(meta, path: change.path) {
                out += hunks
            } else {
                out += hunks(old: change.old ?? "", new: change.new)
            }
        }
        return out.joined(separator: "\n")
    }

    /// Claude Code's hunks for the file, as diff lines.
    private static func structured(_ meta: JSONValue?, path: String) -> [String]? {
        guard let response = meta?["claudeCode"]?["toolResponse"],
              response["filePath"]?.string == nil || response["filePath"]?.string == path,
              let hunks = response["structuredPatch"]?.array, !hunks.isEmpty else { return nil }
        var out: [String] = []
        for hunk in hunks {
            guard let lines = hunk["lines"]?.array?.compactMap(\.string) else { return nil }
            let a = hunk["oldStart"]?.int ?? 1, b = hunk["oldLines"]?.int ?? 0
            let c = hunk["newStart"]?.int ?? 1, d = hunk["newLines"]?.int ?? 0
            out.append("@@ -\(a),\(b) +\(c),\(d) @@")
            out += lines
        }
        return out
    }

    private static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }   // a final newline ends the last line
        return lines
    }

    /// Line-by-line hunks with three lines of context, numbered from the texts given.
    static func hunks(old: String, new: String, context: Int = 3) -> [String] {
        let a = lines(old), b = lines(new)
        let difference = b.difference(from: a)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }
        // The edit script, in order: (kind, text, old line, new line), lines counted from 0.
        var ops: [(kind: Character, text: String, i: Int, j: Int)] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) {
                ops.append(("-", a[i], i, j)); i += 1
            } else if j < b.count, inserted.contains(j) {
                ops.append(("+", b[j], i, j)); j += 1
            } else if i < a.count, j < b.count {
                ops.append((" ", a[i], i, j)); i += 1; j += 1
            } else {
                break
            }
        }
        let changed = ops.indices.filter { ops[$0].kind != " " }
        guard !changed.isEmpty else { return [] }
        // Runs of changes closer than twice the context share one hunk.
        var ranges: [ClosedRange<Int>] = []
        for k in changed {
            let range = max(0, k - context) ... min(ops.count - 1, k + context)
            if let last = ranges.last, range.lowerBound <= last.upperBound + 1 {
                ranges[ranges.count - 1] = last.lowerBound ... max(last.upperBound, range.upperBound)
            } else {
                ranges.append(range)
            }
        }
        var out: [String] = []
        for range in ranges {
            let slice = ops[range]
            let oldCount = slice.filter { $0.kind != "+" }.count, newCount = slice.filter { $0.kind != "-" }.count
            let first = slice.first!
            // An empty side is numbered by the line before it, as diff does.
            let oldStart = oldCount == 0 ? first.i : first.i + 1, newStart = newCount == 0 ? first.j : first.j + 1
            out.append("@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@")
            out += slice.map { String($0.kind) + $0.text }
        }
        return out
    }
}

/// A form the agent asks the person to fill in (`elicitation/create`, mode `form`), shown as
/// Redde's question card: one question per field, its choices as pills, and the card's own
/// "Something else…" box. Claude Code asks its AskUserQuestion this way, each question followed
/// by an optional free-text field (`question_0_custom`); that field becomes the question's box
/// rather than a question of its own.
nonisolated struct AcpForm: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// One of these (title → the value sent back).
        case choice([(title: String, value: String)])
        case multi([(title: String, value: String)])
        case text
        case number
        case integer
        case boolean

        static func == (a: Kind, b: Kind) -> Bool {
            switch (a, b) {
            case let (.choice(x), .choice(y)), let (.multi(x), .multi(y)): x.map(\.title) == y.map(\.title) && x.map(\.value) == y.map(\.value)
            case (.text, .text), (.number, .number), (.integer, .integer), (.boolean, .boolean): true
            default: false
            }
        }
    }

    struct Field: Equatable, Sendable {
        var key: String
        var kind: Kind
        /// The free-text field beside it, where a typed answer goes.
        var other: String?
    }

    var fields: [Field]

    static var yes: String { String(localized: "Yes", comment: "An agent's yes/no question: the answer yes") }
    static var no: String { String(localized: "No", comment: "An agent's yes/no question: the answer no") }

    /// The card and the form behind it; nil for a form Redde can't show (a URL to open, an
    /// unknown mode, or no fields).
    static func make(id: String, params: JSONValue) -> (card: ClarifyRequest, form: AcpForm)? {
        guard (params["mode"]?.string ?? "form") == "form",
              case let .object(properties)? = params["requestedSchema"]?["properties"], !properties.isEmpty else { return nil }
        let message = params["message"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // JSON objects carry no order here; field names sort the way they were written
        // (question_2 before question_10).
        let keys = properties.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var fields: [Field] = []
        var texts: [String: String] = [:]
        for key in keys {
            let schema = properties[key] ?? .null
            let kind = Self.kind(schema)
            if kind == .text, let last = fields.last, last.other == nil, key == last.key + "_custom", last.kind != .text {
                fields[fields.count - 1].other = key
                continue
            }
            fields.append(Field(key: key, kind: kind))
            let words = [schema["description"]?.string, schema["title"]?.string].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
            texts[key] = words
        }
        guard !fields.isEmpty else { return nil }
        let single = fields.count == 1
        let questions = fields.map { field -> ClarifyQuestion in
            // One field is the message's question; several have their own words.
            let asked = single && !message.isEmpty ? message : texts[field.key] ?? (message.isEmpty ? field.key : message)
            let choices: [String] = switch field.kind {
            case let .choice(options), let .multi(options): options.map(\.title)
            case .boolean: [yes, no]
            case .text, .number, .integer: []
            }
            if case .multi = field.kind { return ClarifyQuestion(id: field.key, question: asked, choices: choices, multiSelect: true) }
            return ClarifyQuestion(id: field.key, question: asked, choices: choices, multiSelect: false)
        }
        // With several fields, the message heads them as its own line when it says more than a field does.
        var card = ClarifyRequest(id: id, questions: questions, isBatch: true)
        if !single, !message.isEmpty, !texts.values.contains(message), var first = card.questions.first {
            first.question = message + "\n\n" + first.question
            card.questions[0] = first
        }
        return (card, AcpForm(fields: fields))
    }

    private static func kind(_ schema: JSONValue) -> Kind {
        func titled(_ list: [JSONValue]?) -> [(title: String, value: String)]? {
            let options = (list ?? []).compactMap { option -> (title: String, value: String)? in
                if let value = option.string { return (value, value) }
                guard let value = option["const"]?.string else { return nil }
                return (option["title"]?.string ?? value, value)
            }
            return options.isEmpty ? nil : options
        }
        switch schema["type"]?.string {
        case "string":
            if let options = titled(schema["oneOf"]?.array) ?? titled(schema["enum"]?.array) { return .choice(options) }
            return .text
        case "array":
            let items = schema["items"] ?? .null
            if let options = titled(items["anyOf"]?.array) ?? titled(items["enum"]?.array) { return .multi(options) }
            return .text
        case "number": return .number
        case "integer": return .integer
        case "boolean": return .boolean
        default: return .text
        }
    }

    /// What the agent is sent for the card's answers (one string per question, as the card gives
    /// them: a typed answer, or the picks joined with ", ").
    func reply(_ answers: [String: String]) -> JSONValue {
        var content: [String: JSONValue] = [:]
        for field in fields {
            let answer = (answers[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !answer.isEmpty else { continue }
            switch field.kind {
            case let .choice(options):
                if let option = options.first(where: { $0.title == answer }) {
                    content[field.key] = .string(option.value)
                } else if let other = field.other {
                    content[other] = .string(answer)
                } else {
                    content[field.key] = .string(answer)
                }
            case let .multi(options):
                let (picks, rest) = Self.picks(in: answer, options: options)
                if !picks.isEmpty { content[field.key] = .array(picks.map(JSONValue.string)) }
                if !rest.isEmpty {
                    if let other = field.other { content[other] = .string(rest) } else if picks.isEmpty { content[field.key] = .array([.string(rest)]) }
                }
            case .text:
                content[field.key] = .string(answer)
            case .number:
                content[field.key] = Double(answer.replacingOccurrences(of: ",", with: ".")).map(JSONValue.number) ?? .string(answer)
            case .integer:
                content[field.key] = Int(answer).map { .number(Double($0)) } ?? .string(answer)
            case .boolean:
                let said = answer.lowercased()
                content[field.key] = said == Self.yes.lowercased() || said == "yes" || said == "true" ? .bool(true)
                    : said == Self.no.lowercased() || said == "no" || said == "false" ? .bool(false) : .string(answer)
            }
        }
        return .object(["action": .string("accept"), "content": .object(content)])
    }

    /// The options named in a multi-select's answer ("A, B"), whose own titles may hold a comma;
    /// what isn't an option is typed text.
    static func picks(in answer: String, options: [(title: String, value: String)]) -> (values: [String], rest: String) {
        if let whole = options.first(where: { $0.title == answer }) { return ([whole.value], "") }
        let parts = answer.components(separatedBy: ", ")
        var values: [String] = [], rest: [String] = []
        var index = 0
        outer: while index < parts.count {
            // The longest run of parts that is an option's title.
            for end in stride(from: parts.count, to: index, by: -1) {
                let joined = parts[index ..< end].joined(separator: ", ")
                if let option = options.first(where: { $0.title == joined }) {
                    values.append(option.value)
                    index = end
                    continue outer
                }
            }
            rest.append(parts[index])
            index += 1
        }
        return (values, rest.joined(separator: ", "))
    }
}

nonisolated enum AcpSessions {
    static func summaries(_ rows: [JSONValue]) -> [HermesSessionsAPI.SessionSummary] {
        rows.compactMap(summary).sorted { ($0.last_active ?? 0) > ($1.last_active ?? 0) }
    }

    static func summary(_ row: JSONValue) -> HermesSessionsAPI.SessionSummary? {
        guard let id = row["sessionId"]?.string else { return nil }
        var fields: [String: JSONValue] = ["id": .string(id)]   // no source: the list tags only chats from elsewhere
        if let title = row["title"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { fields["title"] = .string(title) }
        // A name given on this device to a chat its agent keeps none for (`AcpTitles`).
        if let named = AcpTitles.title(for: id) { fields["title"] = .string(named) }
        if let cwd = row["cwd"]?.string { fields["cwd"] = .string(cwd) }
        if let at = row["updatedAt"]?.string.flatMap(date) {
            fields["last_active"] = .number(at.timeIntervalSince1970)
            fields["started_at"] = .number(at.timeIntervalSince1970)
        }
        guard let data = try? JSONEncoder().encode(JSONValue.object(fields)) else { return nil }
        return try? JSONDecoder().decode(HermesSessionsAPI.SessionSummary.self, from: data)
    }

    /// ACP's timestamps: ISO 8601, with or without fractions of a second.
    static func date(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// Names given on this device to bridge chats whose agent keeps none (Codex, and others before
/// bridge 0.9 kept names for them; asked 2026-11-14 "allow for renaming of the chat for ACP
/// chats"). By session id; a name the agent takes is dropped here once it has.
nonisolated enum AcpTitles {
    private static let key = "acpTitles"

    static func title(for session: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[session]
    }

    static func set(_ title: String?, for session: String) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        all[session] = title?.nilIfEmpty
        UserDefaults.standard.set(all, forKey: key)
    }
}

/// An ACP agent's chats by the folder each works in, as the chat list's projects: a folder Claude
/// Code worked in is a project, and a new chat can start there. Shown once there are two folders;
/// with one, the list is that folder already.
nonisolated enum AcpProjects {
    static func make(_ rows: [HermesSessionsAPI.SessionSummary]) -> [HermesServeClient.Project] {
        let byFolder = Dictionary(grouping: rows.filter { !($0.cwd ?? "").isEmpty }) { $0.cwd ?? "" }
        guard byFolder.count > 1 else { return [] }
        return byFolder.map { folder, chats in
            let sorted = chats.sorted { ($0.last_active ?? 0) > ($1.last_active ?? 0) }
            return HermesServeClient.Project(folder: folder, sessions: sorted)
        }
        .sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
    }
}

nonisolated extension HermesServeClient.Project {
    /// A folder's chats as one project (an ACP agent's: `AcpProjects`).
    init(folder: String, sessions: [HermesSessionsAPI.SessionSummary]) {
        id = "acp:" + folder
        label = (folder as NSString).lastPathComponent.nilIfEmpty ?? folder
        path = folder
        isHome = false
        isAuto = true
        sessionCount = sessions.count
        lastActive = sessions.first?.last_active.map { Date(timeIntervalSince1970: $0) }
        totalCost = 0
        lanes = [Lane(id: "main", label: "main", repoLabel: nil, sessions: sessions)]
    }
}

/// How much of a plan's usage limits the agent has used, each window with its share used and when
/// it starts again. Claude Code reports a 5-hour window and weekly ones on its usage updates
/// (`_meta["_claude/rateLimit"]`). Codex (codex-acp) keeps the ChatGPT plan's to itself; the
/// bridge reads them from Codex and sends them as `_redde/limits` (`codex(_:)`). Other agents say
/// nothing of the kind.
nonisolated struct AcpLimits: Equatable, Sendable {
    nonisolated struct Window: Equatable, Sendable, Identifiable {
        /// `five_hour`, `seven_day`, `seven_day_opus`, …; Codex's other windows are `<minutes>_min`,
        /// and a Codex limit besides the plan's own is `<limitId>/<kind>`.
        var id: String
        /// 0…1.
        var used: Double?
        var resetsAt: Date?
        /// `allowed`, `allowed_warning` or `rejected`.
        var status: String
        /// How long the window is, where the agent says (Codex).
        var minutes: Int? = nil
        /// The name of the limit this window is part of, when it isn't the plan's own (Codex).
        var scope: String? = nil

        var name: String {
            let base: String = switch id.split(separator: "/").last.map(String.init) ?? id {
            case "five_hour": String(localized: "5-hour limit", comment: "Claude Code: the plan's usage limit that resets every five hours")
            case "seven_day": String(localized: "Weekly limit", comment: "Claude Code: the plan's usage limit that resets every week")
            case "seven_day_opus": String(localized: "Weekly Opus limit", comment: "Claude Code: the plan's weekly limit for Opus models")
            case "seven_day_sonnet": String(localized: "Weekly Sonnet limit", comment: "Claude Code: the plan's weekly limit for Sonnet models")
            default: Self.durationName(minutes) ?? String(localized: "Usage limit", comment: "Claude Code: a plan usage limit of a kind Redde doesn't know by name")
            }
            return scope.map { "\($0) · \(base)" } ?? base
        }

        /// "3-hour limit", "30-day limit": a window known only by its length.
        static func durationName(_ minutes: Int?) -> String? {
            guard let minutes, minutes > 0 else { return nil }
            if minutes < 24 * 60 {
                let hours = max(1, Int((Double(minutes) / 60).rounded()))
                return String(localized: "\(hours)-hour limit", comment: "Codex: a plan usage limit by the length of its window, as 3-hour limit")
            }
            let days = Int((Double(minutes) / (24 * 60)).rounded())
            return String(localized: "\(days)-day limit", comment: "Codex: a plan usage limit by the length of its window, as 30-day limit")
        }

        var reached: Bool { status == "rejected" }
        var nearing: Bool { status == "allowed_warning" }
    }

    var windows: [Window]
    /// When the agent said it.
    var at: Date
    /// Said after a reply (Claude Code's come on its usage updates); Codex's are read by the
    /// bridge, also when a device connects.
    var fromReply = true

    /// Codex's limits as the bridge reads them from Codex's app-server
    /// (`account/rateLimits/read`): each limit's `primary` and `secondary` window, with
    /// `usedPercent`, `windowDurationMins` and `resetsAt`. A ChatGPT Plus or Pro plan has a 5-hour
    /// and a weekly window; the free plan one of 30 days.
    static func codex(_ payload: JSONValue) -> AcpLimits? {
        guard case .object = payload else { return nil }
        var snapshots: [JSONValue] = []
        if case .object(let byId)? = payload["rateLimitsByLimitId"] {
            // The plan's own limit first, then the others by id.
            func rank(_ id: String) -> Int { id == "codex" ? 0 : 1 }
            snapshots = byId.sorted { (rank($0.key), $0.key) < (rank($1.key), $1.key) }.map(\.value)
        }
        if snapshots.isEmpty, let one = payload["rateLimits"], case .object = one { snapshots = [one] }
        var windows: [Window] = []
        for snapshot in snapshots {
            let limit = snapshot["limitId"]?.string ?? "codex"
            let scope = limit == "codex" ? nil : snapshot["limitName"]?.string ?? limit
            var own: [Window] = []
            for slot in ["primary", "secondary"] {
                guard let window = snapshot[slot], let percent = window["usedPercent"]?.number else { continue }
                let minutes = window["windowDurationMins"]?.int
                let kind = switch minutes {
                case 300: "five_hour"
                case 7 * 24 * 60: "seven_day"
                case let minutes?: "\(minutes)_min"
                case nil: slot
                }
                own.append(Window(id: scope == nil ? kind : "\(limit)/\(kind)", used: percent / 100,
                                  resetsAt: window["resetsAt"]?.number.map { Date(timeIntervalSince1970: $0) },
                                  status: percent >= 100 ? "rejected" : "allowed", minutes: minutes, scope: scope))
            }
            windows += own.sorted { ($0.minutes ?? .max) < ($1.minutes ?? .max) }
        }
        guard !windows.isEmpty else { return nil }
        let at = payload["at"]?.number.map { Date(timeIntervalSince1970: $0) } ?? .now
        return AcpLimits(windows: windows, at: at, fromReply: false)
    }

    static func make(_ update: JSONValue, at: Date = .now) -> AcpLimits? {
        guard let info = update["_meta"]?["_claude/rateLimit"], case .object = info else { return nil }
        let order = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"]
        func date(_ value: JSONValue?) -> Date? { value?.number.map { Date(timeIntervalSince1970: $0) } }
        var windows: [Window] = []
        if case .object(let unified)? = info["unifiedWindows"] {
            for (id, window) in unified {
                windows.append(Window(id: id, used: window["utilization"]?.number, resetsAt: date(window["resetsAt"]),
                                      status: window["status"]?.string ?? "allowed"))
            }
        }
        if windows.isEmpty, let id = info["rateLimitType"]?.string {
            windows.append(Window(id: id, used: info["utilization"]?.number, resetsAt: date(info["resetsAt"]),
                                  status: info["status"]?.string ?? "allowed"))
        }
        guard !windows.isEmpty else { return nil }
        windows.sort { (order.firstIndex(of: $0.id) ?? order.count, $0.id) < (order.firstIndex(of: $1.id) ?? order.count, $1.id) }
        return AcpLimits(windows: windows, at: at)
    }

    /// "4% used · resets 4:30 PM", "12% used · resets Mon 9:00 AM", "1% used · resets Dec 12, 8:59 PM".
    static func line(_ window: Window, now: Date = .now) -> String {
        var parts: [String] = []
        if let used = window.used {
            parts.append(String(localized: "\(used.formatted(.percent.precision(.fractionLength(0)))) used",
                                comment: "Claude Code: how much of a plan limit is used, as 4% used"))
        }
        if let resets = window.resetsAt, resets > now {
            let ahead = resets.timeIntervalSince(now)
            // A weekday alone is wrong past a week (Codex's free plan has a 30-day window).
            let when = ahead < 20 * 3600
                ? resets.formatted(date: .omitted, time: .shortened)
                : ahead < 6 * 24 * 3600
                    ? resets.formatted(.dateTime.weekday(.abbreviated).hour().minute())
                    : resets.formatted(.dateTime.month(.abbreviated).day().hour().minute())
            parts.append(String(localized: "resets \(when)", comment: "Claude Code: when a plan limit starts again, as resets 4:30 PM or resets Mon 9:00 AM"))
        }
        return parts.joined(separator: " · ")
    }
}
