import Foundation

/// A group chat a live call speaks for (asked 2026-10-26: "group chats don't seem to use live
/// calls"): what the person says goes to the room (`send`), and each member's reply is said in
/// that member's own live voice, the call going on in it (`LiveVoice.roomReplied`). Made by
/// `GroupVoice` when group chats are calls (Settings → Voice → Voice mode).
@MainActor
struct LiveRoom {
    var name: String
    /// Its members, by profile, with the names they go by.
    var members: [(profile: String, name: String)]
    /// The room so far, newest last, for each session to know.
    var history: () -> [LiveLine]
    var send: (String) -> Void

    /// The room's messages as the voice is given them: the person's as theirs, a member's with its
    /// name before it; the newest 24, 6,000 characters at most, 1,200 of any one, as a chat's.
    static func history(_ events: [GroupEvent], name: (String?) -> String) -> [LiveLine] {
        var kept: [LiveLine] = []
        var budget = 6_000
        for event in events.reversed() where event.isMessage && !event.text.isEmpty {
            let fromPerson = event.kind == "message.user"
            let words = event.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let text = String((fromPerson ? words : "\(name(event.actorID)): \(words)").prefix(1_200))
            guard kept.count < 24, budget - text.count >= 0 else { break }
            budget -= text.count
            kept.append(LiveLine(fromPerson: fromPerson, text: text))
        }
        return kept.reversed()
    }
}
