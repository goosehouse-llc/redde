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
                if !text.isEmpty { out.append(Message(role: .user, text: text, createdAt: when)) }
            case "assistant":
                var m = Message(role: .assistant, text: text, createdAt: when)
                m.reasoning = row["reasoning"]?.string ?? ""
                if !m.text.isEmpty || !m.reasoning.isEmpty { out.append(m) }
            case "tool":
                if let name = row["name"]?.string, let last = out.indices.last, out[last].role == .assistant {
                    out[last].tools.append(ToolActivity(name: name, preview: row["context"]?.string, status: .completed))
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
                let text = row.content?.text ?? ""
                guard !text.isEmpty else { continue }
                out.append(Message(role: .user, text: text, createdAt: when))
            case "assistant":
                var message = Message(role: .assistant, text: row.content?.text ?? "", createdAt: when)
                message.reasoning = row.reasoning ?? row.reasoning_content ?? ""
                message.tools = (row.tool_calls ?? []).compactMap { call in
                    call.function?.name.map { ToolActivity(name: $0, preview: nil, status: .completed) }
                }
                // Tool-call-only assistant rows fold into the next assistant text.
                if message.text.isEmpty, !message.tools.isEmpty, let last = out.indices.last, out[last].role == .assistant, out[last].text.isEmpty {
                    out[last].tools += message.tools
                } else if !message.text.isEmpty || !message.tools.isEmpty {
                    out.append(message)
                }
            default:
                continue // tool results / system rows aren't transcript bubbles
            }
        }
        // Drop trailing tool-only assistant rows that never produced text (interrupted runs).
        return out.filter { !($0.role == .assistant && $0.text.isEmpty && $0.tools.isEmpty) }
    }
}
