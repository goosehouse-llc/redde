import Foundation

// Server transcript rows mapped into the app's Message model — kept beside the transport
// vocabulary rather than inside Conversation's turn logic. `fromServeRows` reads hermes
// serve's history rows; `mapStored` reads the sessions ledger's stored messages.
extension Conversation {
    nonisolated static func messages(fromServeRows rows: [JSONValue]) -> [Message] {
        var out: [Message] = []
        for row in rows where row["display_kind"]?.string != "hidden" {
            let when = row["timestamp"]?.number.map { Date(timeIntervalSince1970: $0) } ?? .now
            let text = row["text"]?.string ?? row["content"]?.displayText ?? ""
            switch row["role"]?.string {
            case "user":
                let text = ReplyLanguage.stripNote(text)   // the Dashboard's reply-language note
                if !text.isEmpty { out.append(Message(role: .user, text: text, createdAt: when)) }
            case "assistant":
                var m = Message(role: .assistant, text: text, createdAt: when)
                m.reasoning = row["reasoning"]?.string ?? ""
                if !m.text.isEmpty || !m.reasoning.isEmpty { out.append(m) }
            case "tool":
                if let name = row["name"]?.string, let last = out.indices.last, out[last].role == .assistant {
                    // The row carries the call; its result only for the edit tools.
                    out[last].tools.append(ToolActivity(name: name, preview: row["context"]?.string, status: .completed,
                                                        args: ToolActivity.detail(row["args"]), output: ToolActivity.detail(row["content"])))
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
                        let arguments = call.function?.arguments
                        return ToolActivity(name: $0, preview: nil, status: .completed,
                                            args: arguments?.string.map { ToolActivity.detail(json: $0) } ?? ToolActivity.detail(arguments))
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
