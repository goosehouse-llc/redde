import Foundation

/// Why Hermes stopped a turn on its own (asked 2026-11-06: "Add a stopped trying because…").
/// Hermes 0.22 ends a turn once one tool has failed 8 times and says only "I stopped retrying
/// because I kept running <tool> 8 times without making progress. The last result above shows
/// what blocked it.": the result is folded away in the steps, and it may not have failed at all
/// (Hermes counts an answer with "error" or "failed" near its start as a failure). The line under
/// the reply says what the last call of that tool answered.
nonisolated enum ToolStop {
    /// `message`: the reply. `earlier`: the turn's replies before it, oldest first (back to the
    /// person's message). Nil for any other reply.
    static func reason(_ message: Message, earlier: [Message]) -> String? {
        guard message.role == .assistant,
              let m = message.text.firstMatch(of: /^I stopped retrying because I kept running (\S+) (\d+) times without making progress/)
        else { return nil }
        let tool = String(m.output.1)
        let count = Int(m.output.2) ?? 8
        let rule = String(localized: "Hermes ends a turn once a tool has failed \(count) times.", comment: "Under a reply Hermes stopped: why it stops; the count")
        let last = ([message] + earlier.reversed()).lazy.flatMap { $0.tools.reversed() }.first { $0.name == tool }
        guard let output = last?.output?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty else { return rule }
        if let said = complaint(output) {
            return rule + " " + String(localized: "The last \(tool) call said: \(said)", comment: "Under a reply Hermes stopped: the tool's last error; the tool, its words")
        }
        return rule + " " + String(localized: "The last \(tool) call didn't fail, though: Hermes took a word in its answer for a failure. Send “continue” to go on.", comment: "Under a reply Hermes stopped over answers that weren't failures; the tool")
    }

    /// The error in a tool's answer, in words, or nil when it isn't one.
    static func complaint(_ output: String) -> String? {
        if let json = try? JSONValue.parse(Data(output.utf8)), json.object != nil {
            let failed = json["success"]?.bool == false || json["error"] != nil
            guard failed else { return nil }
            let words = json["message"]?.string ?? json["error"]?.string ?? String(localized: "an error", comment: "A tool's error with no words")
            return clipped(words)
        }
        let lower = output.lowercased()
        return lower.hasPrefix("error") || lower.contains("\"error\"") ? clipped(output) : nil
    }

    private static func clipped(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return line.count <= 200 ? line : String(line.prefix(199)) + "…"
    }
}
