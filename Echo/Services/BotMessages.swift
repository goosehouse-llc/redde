import Foundation

/// Reading bots' messages to each other out of a transcript, as Hermes Desktop does.
nonisolated enum BotMessages {
    /// "Message from 🤖 Research Buddy (@research-buddy): …" (0.21.5 and later name the bot;
    /// 0.21.0 and 0.21.3 give its handle twice), and the older "[Message from agent 'scout'] …":
    /// Hermes Desktop's pattern (`AGENT_MESSAGE_RE`).
    nonisolated struct Inbound: Equatable, Sendable {
        var name: String
        var handle: String?
        var body: String
    }

    static func inbound(_ text: String) -> Inbound? {
        if let match = text.wholeMatch(of: /Message from (?:🤖\s*)?([^:\n(]{1,64}?)(?:\s*\(@([a-z0-9][a-z0-9_-]{0,63})(?:@[A-Za-z0-9][A-Za-z0-9_-]{0,63})?\))?:\s*([\s\S]*)/) {
            return Inbound(name: String(match.output.1).trimmingCharacters(in: .whitespaces), handle: match.output.2.map(String.init),
                           body: String(match.output.3))
        }
        if let match = text.wholeMatch(of: /\[Message from agent '([^']{1,64})'\]\s*([\s\S]*)/) {
            return Inbound(name: String(match.output.1), handle: nil, body: String(match.output.2))
        }
        return nil
    }

    /// The bot a message names: by its handle ("hermes" is the main profile), else by what it is
    /// called; what it called itself when it isn't on the roster (or none is given: the
    /// transcript is read off the main actor, and the row looks the bot up when it is drawn).
    static func sender(name: String, handle: String?, roster: [HermesBot]) -> BotRef {
        let wanted = (handle ?? name).lowercased()
        let bot = roster.first { BotMentions.forms(of: $0).contains(wanted) }
            ?? roster.first { $0.label().lowercased() == name.lowercased() }
        let profile = bot?.name ?? (handle == "hermes" ? "default" : handle ?? BotMentions.nameForms(name).first ?? name.lowercased())
        return BotRef(profile: profile, name: name)
    }

    /// A finished background process's notice ("[IMPORTANT: Background process proc_… exited (exit
    /// code 0).\nCommand: …\nOutput:\n…]"): a bot's reply when the command delivered a message to
    /// it (`bot_mode_dm.py --run-delivery … -p <bot> chat …`), the reply alone; else the process.
    static func processNotice(_ text: String, title: String?, roster: [HermesBot]) -> (Delivered, String)? {
        guard let match = text.wholeMatch(of: /\[(?:IMPORTANT: )?Background process (\S+) ([^\n]*?)\.?\n(?:[^\n]*\n)?Command: ([^\n]*)\nOutput:\n([\s\S]*)\]/) else {
            return nil
        }
        let command = String(match.output.3)
        var output = String(match.output.4).trimmingCharacters(in: .whitespacesAndNewlines)
        if command.contains("bot_mode_dm.py"), let profile = command.firstMatch(of: /(?:^|\s)-p\s+'?([A-Za-z0-9][A-Za-z0-9_-]*)/)?.output.1 {
            // The bot's chat open in the gateway answers as JSON; one run on its own, as its words,
            // after any warnings Hermes's command line prints first ("⚠ …", Hermes 0.21.0).
            if let json = try? JSONValue.parse(Data(output.utf8)), let reply = json["reply"]?.string {
                output = reply
            } else {
                output = output.split(separator: "\n", omittingEmptySubsequences: false).drop { $0.hasPrefix("⚠") }
                    .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let bot = roster.first { $0.name == String(profile) }
            return (Delivered(kind: .reply, profile: String(profile), name: bot?.label() ?? String(profile)), output)
        }
        let line = title?.nilIfEmpty ?? "Background process \(match.output.2)"
        return (Delivered(kind: .process, title: line), output)
    }

    /// A user row as it should show: the person's own, or one delivered (its text the message
    /// alone, its sender kept beside it).
    static func userMessage(text: String, displayKind: String?, displayText: String?, roster: [HermesBot] = [], at when: Date) -> Message? {
        if displayKind == "process_complete" || text.hasPrefix("[IMPORTANT: Background process") {
            if let (delivered, body) = processNotice(text, title: displayText, roster: roster) {
                var message = Message(role: .user, text: body, createdAt: when)
                message.delivered = delivered
                return message
            }
        }
        if let inbound = inbound(text) {
            var message = Message(role: .user, text: inbound.body, createdAt: when)
            let bot = sender(name: inbound.name, handle: inbound.handle, roster: roster)
            message.delivered = Delivered(kind: .message, profile: bot.profile, name: bot.name)
            return message
        }
        guard !text.isEmpty else { return nil }
        return Message(role: .user, text: text, createdAt: when)
    }

    /// A bot row's last line: a message from another bot as "Scout: …", a process's notice as
    /// what it is; anything else as it came.
    static func rowPreview(_ preview: String?, roster: [HermesBot], mainName: String) -> String? {
        guard let preview = preview?.nilIfEmpty else { return nil }
        if preview.hasPrefix("[IMPORTANT: Background process") { return "A background task finished" }
        guard let inbound = inbound(preview) else { return preview }
        let ref = sender(name: inbound.name, handle: inbound.handle, roster: roster)
        let name = roster.first { $0.name == ref.profile }?.label(mainName: mainName) ?? inbound.name
        return "\(name): \(inbound.body)"
    }

    /// A message_agent call as a step's name: "Messaged @scout".
    static func stepName(_ tool: ToolActivity) -> String? {
        guard tool.name == "message_agent", let target = tool.args?.firstMatch(of: /(?m)^target: @?([^\s]+)/)?.output.1 else { return nil }
        return "Messaged @\(target)"
    }
}
