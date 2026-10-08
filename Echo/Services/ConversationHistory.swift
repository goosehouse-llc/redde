import Foundation

// Server transcript rows mapped into the app's Message model — kept beside the transport
// vocabulary rather than inside Conversation's turn logic. `fromServeRows` reads hermes
// serve's history rows; `mapStored` reads the sessions ledger's stored messages.
extension Conversation {
    nonisolated static func messages(fromServeRows rows: [JSONValue]) -> [Message] {
        var out: [Message] = []
        /// Tool rows that came before the reply they belong to.
        var waiting: [ToolActivity] = []
        for row in rows where row["display_kind"]?.string != "hidden" {
            let when = row["timestamp"]?.number.map { Date(timeIntervalSince1970: $0) } ?? .now
            let text = row["text"]?.string ?? row["content"]?.displayText ?? ""
            switch row["role"]?.string {
            case "user":
                waiting = []   // the tools of a turn that never got its reply
                let text = ReplyLanguage.stripNote(text)   // the Dashboard's reply-language note
                if !text.isEmpty { out.append(Message(role: .user, text: text, createdAt: when)) }
            case "assistant":
                var m = Message(role: .assistant, text: text, createdAt: when)
                m.reasoning = row["reasoning"]?.string ?? ""
                guard !m.text.isEmpty || !m.reasoning.isEmpty else { continue }
                m.tools = waiting
                waiting = []
                out.append(m)
            case "tool":
                guard let name = row["name"]?.string else { continue }
                // The row carries the call; its result only for the edit tools.
                let call = ToolActivity.unwrapped(name: name, args: row["args"])
                let tool = ToolActivity(name: call.name, preview: row["context"]?.string?.nilIfEmpty, status: .completed,
                                        args: ToolActivity.detail(call.args), output: ToolActivity.detail(row["content"]))
                if let last = out.indices.last, out[last].role == .assistant {
                    out[last].tools.append(tool)
                } else {
                    // A model that calls a tool without a word first: the host lists the call
                    // before the reply, and it belongs to that reply as it did while it ran.
                    waiting.append(tool)
                }
            default: continue
            }
        }
        return out
    }

    nonisolated static func mapStored(_ stored: [HermesSessionsAPI.StoredMessage]) -> [Message] {
        var out: [Message] = []
        for row in stored where row.display_kind != "hidden" {
            let when = row.timestamp.map { Date(timeIntervalSince1970: $0) } ?? .now
            switch row.role {
            case "user":
                let text = ReplyLanguage.stripNote(row.content?.text ?? "")   // a Dashboard turn's note
                guard !text.isEmpty else { continue }
                out.append(Message(role: .user, text: text, createdAt: when))
            case "assistant":
                var message = Message(role: .assistant, text: row.content?.text ?? "", createdAt: when)
                message.reasoning = row.reasoning ?? row.reasoning_content ?? ""
                message.tools = (row.tool_calls ?? []).compactMap { call in
                    call.function?.name.map {
                        // Stored arguments are JSON, usually as text.
                        let stored = call.function?.arguments
                        let arguments = stored?.string.flatMap { try? JSONValue.parse(Data($0.utf8)) } ?? stored
                        let inner = ToolActivity.unwrapped(name: $0, args: arguments)
                        return ToolActivity(name: inner.name, preview: nil, status: .completed, args: ToolActivity.detail(inner.args))
                    }
                }
                // Tool-call-only assistant rows fold into the next assistant text: one bubble with
                // its tool chips, as it looked live, not a chips-only bubble and then the answer.
                if let last = out.indices.last, out[last].role == .assistant, out[last].text.isEmpty, !out[last].tools.isEmpty {
                    out[last].tools += message.tools
                    out[last].text = message.text
                    if !message.reasoning.isEmpty { out[last].reasoning += (out[last].reasoning.isEmpty ? "" : "\n\n") + message.reasoning }
                } else if !message.text.isEmpty || !message.tools.isEmpty {
                    out.append(message)
                }
            case "tool":
                // A tool's result isn't a bubble; it belongs to the call that asked for it, the
                // first one in the reply above still without a result (they come back in order).
                guard let last = out.indices.last, out[last].role == .assistant,
                      let i = out[last].tools.firstIndex(where: { $0.output == nil && (row.tool_name == nil || $0.name == row.tool_name) })
                        ?? out[last].tools.firstIndex(where: { $0.output == nil }) else { continue }
                out[last].tools[i].output = ToolActivity.detail(row.content?.text)
            default:
                continue // system rows aren't transcript bubbles
            }
        }
        // Drop trailing tool-only assistant rows that never produced text (interrupted runs).
        return out.filter { !($0.role == .assistant && $0.text.isEmpty && $0.tools.isEmpty) }
    }
}

extension HermesSessionsAPI {
    /// The agent's task list as the newest reply's last to-do call answered it, read from the
    /// end of the transcript: the turn stream names such a call without its answer. Nil when
    /// that reply has no to-do call with an answer that can be read.
    func answeredTodos(sessionID: String) async -> [TodoItem]? {
        guard let rows = try? await newestMessages(sessionID: sessionID, limit: 60) else { return nil }
        return Conversation.mapStored(rows).last { $0.role == .assistant }.flatMap { TodoList.answered(by: $0.tools) }
    }
}
