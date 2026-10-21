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
            // after any warnings and bookkeeping Hermes's command line prints. What is left of the
            // message itself (echoed back in a steer's frame) isn't an answer either.
            if let json = try? JSONValue.parse(Data(output.utf8)), let reply = json["reply"]?.string {
                output = reply
            }
            output = cliNoise(output.replacing(/\[OUT-OF-BAND USER MESSAGE[^\]]*\][\s\S]*?(\[\/OUT-OF-BAND USER MESSAGE\]|$)/, with: "\n"))
            // With nothing left, or a run that failed, the bot didn't answer.
            let status = String(match.output.2)
            if !status.contains("exit code 0") { output = "" }
            let bot = roster.first { $0.name == String(profile) }
            return (Delivered(kind: .reply, profile: String(profile), name: bot?.label() ?? String(profile)), output)
        }
        let line = title?.nilIfEmpty ?? "Background process \(match.output.2)"
        return (Delivered(kind: .process, title: line), output)
    }

    /// What Hermes's command line prints besides a bot's words, on every run: warnings first
    /// ("⚠ …", Hermes 0.21.0), and its session bookkeeping ("Session … found but has no messages.
    /// Starting fresh.", "session_id: …"). Taken out of a relayed reply.
    static func cliNoise(_ output: String) -> String {
        output.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let line = line.trimmingCharacters(in: .whitespaces)
                return !line.hasPrefix("⚠") && line.wholeMatch(of: /session_id: \S+/) == nil
                    && line.wholeMatch(of: /Session \S+ found but has no messages\. Starting fresh\./) == nil
                    && line.wholeMatch(of: /Resum(ed|ing) session \S+.*/) == nil
            }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A steer (a message sent into a turn under way), as Hermes keeps it: the person's words in
    /// its own frame. The words alone, or nil when the row is no steer.
    static func steer(_ text: String) -> String? {
        guard let match = text.wholeMatch(of: /\s*\[OUT-OF-BAND USER MESSAGE[^\]]*\]\s*([\s\S]*?)\s*(?:\[\/OUT-OF-BAND USER MESSAGE\])?\s*/) else { return nil }
        return String(match.output.1)
    }

    /// What one of a bot's schedules came up with, as Hermes puts it into the bot's chat
    /// (`deliver: bot-chat`): its name (less Hermes Desktop's tag) and the output.
    static func routine(_ text: String) -> (title: String, output: String)? {
        guard let match = text.wholeMatch(of: /\[Cronjob "([^"\n]*)" output[^\]\n]*\]\s*([\s\S]*)/) else { return nil }
        return (BotRoutines.untagged(String(match.output.1)), String(match.output.2).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A reply that goes on to write a message as if from the person (a model carrying on past
    /// its answer: "Q\n\n[Out-of-band message from Alex, delivered as a new user message]\n\nTurn
    /// the office", 2026-10-20): what it said before that, and the made-up rest, or nil for an
    /// ordinary reply. Starts at Hermes's frames for a message sent in, in any case. A lone letter
    /// left before it is part of the same slip.
    static func inventedTurn(in text: String) -> (said: String, invented: String)? {
        // A byte scan first: the streaming reply is asked on every update, and most have no "[".
        guard text.utf8.contains(UInt8(ascii: "[")),
              let start = text.range(of: "[out-of-band", options: .caseInsensitive) else { return nil }
        var said = String(text[..<start.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        if VoiceSession.isLoneLetter(said.components(separatedBy: .newlines).last ?? "") {
            said = said.components(separatedBy: .newlines).dropLast().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (said, String(text[start.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A user row as it should show: the person's own, or one delivered (its text the message
    /// alone, its sender kept beside it).
    static func userMessage(text: String, displayKind: String?, displayText: String?, roster: [HermesBot] = [], at when: Date) -> Message? {
        if let (title, output) = routine(text) {
            var message = Message(role: .user, text: output, createdAt: when)
            message.delivered = Delivered(kind: .routine, title: title)
            return message
        }
        if displayKind == "process_complete" || text.hasPrefix("[IMPORTANT: Background process") {
            if let (delivered, body) = processNotice(text, title: displayText, roster: roster) {
                var message = Message(role: .user, text: body, createdAt: when)
                message.delivered = delivered
                return message
            }
        }
        if let words = steer(text) {
            var message = Message(role: .user, text: words, createdAt: when)
            message.isSteer = true
            return words.isEmpty ? nil : message
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
        if let (title, _) = routine(preview) { return "\(title) ran" }
        if let (said, _) = inventedTurn(in: preview) { return said.nilIfEmpty ?? "…" }
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
