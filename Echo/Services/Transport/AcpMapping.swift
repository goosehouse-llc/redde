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

    init() {}

    mutating func events(for update: JSONValue) -> [TurnEvent] {
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
            return [finished]
        case "plan":
            return [.todos(Self.todos(update))]
        case "usage_update":
            guard let used = update["used"]?.int, let size = update["size"]?.int else { return [] }
            lastContext = (used, size)
            return [.usage(TokenUsage(input: 0, output: 0, contextUsed: used, contextMax: size))]
        case "notice":
            guard let title = update["title"]?.string, !title.isEmpty else { return [] }
            return [.status(title)]
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
            events.append(finished)
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
        func reply() -> Int {
            if let last = out.indices.last, out[last].role == .assistant { return last }
            out.append(Message(role: .assistant, text: ""))
            toolIndex = [:]
            return out.count - 1
        }
        for update in updates {
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
                // A replayed call that never said it ended is over by now.
                if tool.status == .running { tool.status = .completed }
                toolIndex[id] = out[at].tools.count
                out[at].tools.append(tool)
            case "tool_call_update":
                guard let id = update["toolCallId"]?.string, let index = toolIndex[id],
                      let at = out.indices.last, out[at].role == .assistant, index < out[at].tools.count else { continue }
                apply(update, to: &out[at].tools[index])
            case "plan":
                out[reply()].todos = AcpTurnMapper.todos(update)
            default:
                continue
            }
        }
        // A reply that is all tools and no words still shows; a user row with no words doesn't.
        return out.filter { $0.role == .assistant || !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
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
        return .object(["outcome": .object(["outcome": .string("selected"), "optionId": .string(optionID)])])
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
/// `mode` category, Claude Code's Manual / Accept Edits / Plan / Auto) and how hard it thinks
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

    static let categories = ["mode", "thought_level"]

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

/// `session/list` rows as the chat list's.
nonisolated enum AcpSessions {
    static func summaries(_ rows: [JSONValue]) -> [HermesSessionsAPI.SessionSummary] {
        rows.compactMap(summary).sorted { ($0.last_active ?? 0) > ($1.last_active ?? 0) }
    }

    static func summary(_ row: JSONValue) -> HermesSessionsAPI.SessionSummary? {
        guard let id = row["sessionId"]?.string else { return nil }
        var fields: [String: JSONValue] = ["id": .string(id)]   // no source: the list tags only chats from elsewhere
        if let title = row["title"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { fields["title"] = .string(title) }
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
