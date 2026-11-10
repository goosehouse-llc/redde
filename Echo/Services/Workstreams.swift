import Foundation
import Observation

/// One of an agent's workstreams (Redde's plugin 1.22, `work.py`): a job the main agent or a bot
/// handed to a hidden chat of its own (W1, W2…) that works on it by itself, while the chat that
/// started it goes on (asked 2026-11-10: "bot work streams for all bots"). The plugin keeps them;
/// Redde lists them over the Dashboard (`/redde-push work list <profile> [chat]`).
nonisolated struct Workstream: Equatable, Identifiable, Sendable {
    enum Status: String, Sendable {
        case starting, working, needsYou = "needs_you", done, failed, stopped
    }

    /// "W3".
    var id: String
    var title: String
    var status: Status
    /// Its own chat: the hidden session it runs in.
    var session: String
    /// The chat that started it.
    var chat: String
    /// What it said last, once it ended.
    var last: String
    /// What it waits on while it needs the person: the command to approve.
    var asked: String
    var created: Date
    var updated: Date
    var ended: Date?

    var isOpen: Bool { status == .starting || status == .working || status == .needsYou }

    /// The plugin's `work list` answer ("redde-push work {…}"); nil for anything else (a plugin
    /// older than 1.22 answers with its usage).
    static func parse(_ output: String) -> (profile: String, work: [Workstream])? {
        guard output.hasPrefix(prefix), let start = output.firstIndex(of: "{"),
              let json = try? JSONDecoder().decode(JSONValue.self, from: Data(output[start...].utf8)),
              let rows = json["work"]?.array else { return nil }
        let work = rows.compactMap { row -> Workstream? in
            guard let id = row["id"]?.string, !id.isEmpty, let session = row["session"]?.string, !session.isEmpty else { return nil }
            func date(_ key: String) -> Date? { row[key]?.number.map(Date.init(timeIntervalSince1970:)) }
            return Workstream(id: id, title: row["title"]?.string ?? "", status: Status(rawValue: row["status"]?.string ?? "") ?? .working,
                              session: session, chat: row["chat"]?.string ?? "", last: row["last"]?.string ?? "",
                              asked: row["asked"]?.string ?? "", created: date("created") ?? .now, updated: date("updated") ?? .now,
                              ended: date("ended"))
        }
        return (json["profile"]?.string ?? "", work)
    }

    static let prefix = "redde-push work "

    /// The plugin's report of one that ended, as the chat that started it got it (a hidden turn,
    /// `work.report_text`): `[Workstream W1 "title" finished. …]`, then its last words. As a
    /// notice: what came of it, without the plugin's instructions to the agent (which hold a
    /// bracket of their own, "[SILENT]": the head ends at the one before the blank line).
    static func notice(_ text: String) -> (Delivered, String)? {
        guard text.hasPrefix("[Workstream "),
              let head = text.firstMatch(of: /^\[Workstream (W\d+) "(.*?)" (finished|ended with an error|was stopped)\.[\s\S]*?\](?:\n\n|\s*$)/) else { return nil }
        let (ref, title) = (String(head.output.1), String(head.output.2))
        let line = switch head.output.3 {
        case "finished": String(localized: "\(ref) finished: \(title)", comment: "In a chat: a workstream (W1, a job the agent handed to a chat of its own) is done, and its title")
        case "was stopped": String(localized: "\(ref) was stopped: \(title)", comment: "In a chat: a workstream (W1) the agent started was stopped, and its title")
        default: String(localized: "\(ref) didn't finish: \(title)", comment: "In a chat: a workstream (W1) the agent started ended with an error, and its title")
        }
        return (Delivered(kind: .task, title: line), String(text[head.range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A `redde_work` call as a step's name: "Started a workstream: Fix the build".
    static func stepName(_ tool: ToolActivity) -> String? {
        guard tool.name == "redde_work", let args = tool.args else { return nil }
        let action = args.firstMatch(of: /(?m)^action: ([a-z]+)/)?.output.1
        let title = args.firstMatch(of: /(?m)^title: (.+)$/)?.output.1.trimmingCharacters(in: .whitespaces)
        let ref = args.firstMatch(of: /(?m)^id: (\S+)/)?.output.1.uppercased()
        switch action {
        case "start": return title.map { String(localized: "Started a workstream: \($0)", comment: "A step in a reply: the agent handed a job to a chat of its own, by its title") }
        case "stop": return ref.map { String(localized: "Stopped \($0)", comment: "A step in a reply: the agent stopped one of its workstreams (W1)") }
        case "send": return ref.map { String(localized: "Gave \($0) more to do", comment: "A step in a reply: the agent sent one of its workstreams (W1) more to do") }
        case "list", "read": return String(localized: "Checked on its workstreams", comment: "A step in a reply: the agent looked at how its workstreams stand")
        default: return nil
        }
    }
}

/// The workstreams of the agents whose chats are open, as last read: asked of the plugin when a
/// chat shows, when one of its turns ends and when a note about one comes, and every few seconds
/// while one is running. Only over the Dashboard, where they run.
@MainActor
@Observable
final class Workstreams {
    static let shared = Workstreams()

    /// By server and profile ("<connection>|scout").
    private(set) var lists: [String: [Workstream]] = [:]
    /// The plugin answered for workstreams on this server (1.22 or later).
    private(set) var available: Set<String> = []

    @ObservationIgnored var plugin: PushService.PluginCommand = PushService.command(over: .shared)
    @ObservationIgnored var reachable: () async -> Bool = { await HermesServeClient.shared.canUse() }
    @ObservationIgnored var connection: () -> String = { Settings.shared.connectionKey }
    /// How often an agent with a running workstream is read again.
    @ObservationIgnored var interval: Duration = .seconds(5)
    @ObservationIgnored private var followers: [String: Int] = [:]
    @ObservationIgnored private var following: [String: Task<Void, Never>] = [:]

    func key(_ profile: String) -> String { connection() + "|" + profile }

    /// Those an agent started from one of its chats: open ones first, then those ended in the last day.
    func of(_ profile: String, chat: String?) -> [Workstream] {
        #if DEBUG
        if Self.demo { return Self.demoWork }
        #endif
        let all = lists[key(profile)] ?? []
        let mine = chat.map { chat in all.filter { $0.chat == chat } } ?? all
        let day = Date.now.addingTimeInterval(-86_400)
        return mine.filter { $0.isOpen || ($0.ended ?? $0.updated) > day }
            .sorted { ($0.isOpen ? 0 : 1, $1.created) < ($1.isOpen ? 0 : 1, $0.created) }
    }

    func refresh(_ profile: String) async {
        #if DEBUG
        if Self.demo { return }
        #endif
        let key = key(profile)
        guard await reachable(), let output = try? await plugin("work list \(profile)") else { return }
        guard let parsed = Workstream.parse(output) else { available.remove(key); lists[key] = nil; return }
        available.insert(key)
        if lists[key] != parsed.work { lists[key] = parsed.work }
    }

    /// Stops one mid-turn. What the plugin said when it couldn't, else nil.
    func stop(_ ref: String, of profile: String) async -> String? {
        guard let output = try? await plugin("work stop \(profile) \(ref)"), output.hasPrefix(Workstream.prefix),
              let start = output.firstIndex(of: "{"),
              let json = try? JSONDecoder().decode(JSONValue.self, from: Data(output[start...].utf8)) else {
            return String(localized: "Hermes didn't answer. Try again in a moment.", comment: "A workstream couldn't be stopped: no answer from the server")
        }
        await refresh(profile)
        return json["stopped"] == nil ? (json["error"]?.string ?? "") : nil
    }

    /// Read now and while anything of the agent's runs, for as long as something shows them.
    func follow(_ profile: String) {
        followers[profile, default: 0] += 1
        guard following[profile] == nil else { return }
        following[profile] = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh(profile)
                let busy = (self.lists[self.key(profile)] ?? []).contains(where: \.isOpen)
                try? await Task.sleep(for: busy ? self.interval : self.interval * 6)
            }
        }
    }

    func unfollow(_ profile: String) {
        followers[profile, default: 1] -= 1
        guard followers[profile] ?? 0 <= 0 else { return }
        followers[profile] = nil
        following.removeValue(forKey: profile)?.cancel()
    }

    /// A note about one came (`PushNote.Kind.work`): its agent read again, when shown.
    func heard(_ note: PushNote) {
        guard note.kind == .work, let profile = note.p else { return }
        heard(profile: profile)
    }

    func heard(profile: String) {
        guard following[profile] != nil else { return }
        Task { await refresh(profile) }
    }
}

#if DEBUG
extension Workstreams {
    /// `-echo.demoWork`: the strip over any chat, and three in its sheet.
    static var demo: Bool { DevHooks.has("-echo.demoWork") }

    static let demoWork: [Workstream] = [
        Workstream(id: "W3", title: "Compare the three quotes for the roof", status: .working, session: "demo-w3", chat: "", last: "", asked: "",
                   created: .now.addingTimeInterval(-240), updated: .now, ended: nil),
        Workstream(id: "W2", title: "Clean out old build folders", status: .needsYou, session: "demo-w2", chat: "", last: "",
                   asked: "rm -rf ~/Projects/old-builds", created: .now.addingTimeInterval(-900), updated: .now.addingTimeInterval(-60), ended: nil),
        Workstream(id: "W1", title: "Find a dentist open on Saturdays", status: .done, session: "demo-w1", chat: "",
                   last: "Two are open Saturday mornings: **Bright Smile** (9–1) and **Elm Street Dental** (8–12). Both take new patients.",
                   asked: "", created: .now.addingTimeInterval(-3000), updated: .now.addingTimeInterval(-1800), ended: .now.addingTimeInterval(-1800)),
    ]
}
#endif
