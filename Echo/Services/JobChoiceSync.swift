import Foundation

/// How each job's briefings reach the person, the same on all their devices (asked 2026-11-21:
/// "there still doesn't seem to be parity or sync between devices for today notifications").
/// Notify Me, Drawer Only and Off (`JobNotices`) were each device's own, so the iPad went on
/// notifying for a job turned off on the phone. Now a choice made here is said to the open
/// server's plugin (1.34: `job <choice> <profile>|<job id> <name>`), which keeps one per job,
/// sends nothing for a job turned off and marks a Drawer Only job's notes quiet everywhere; and
/// each device reads them all (`jobs`) when Redde comes forward. A choice that couldn't be said
/// waits here until it can; one this device made before the plugin kept them is said once.
@MainActor
final class JobChoiceSync {
    static let shared = JobChoiceSync()

    private let defaults: UserDefaults
    private let briefings: UserDefaults?
    private let command: @MainActor (String) async throws -> String
    private let settings: Settings
    /// A choice here changed from another device's: mutes said again, Today read again.
    private let changedHere: @MainActor () -> Void
    private var flushing: Task<Void, Never>?

    private static let pendingKey = "jobChoices.pending"

    init(defaults: UserDefaults = .standard, briefings: UserDefaults? = NeedsYou.shared, settings: Settings = .shared,
         command: (@MainActor (String) async throws -> String)? = nil,
         changedHere: (@MainActor () -> Void)? = nil) {
        self.defaults = defaults
        self.changedHere = changedHere ?? { Mutes.publish(); BriefingsInbox.shared.reload() }
        self.briefings = briefings
        self.settings = settings
        self.command = command ?? { arguments in try await PushService.command(over: settings)(arguments) }
    }

    /// The choices not yet said: job → [choice, name].
    var pending: [String: [String]] {
        get { (defaults.dictionary(forKey: Self.pendingKey) as? [String: [String]]) ?? [:] }
        set { defaults.set(newValue, forKey: Self.pendingKey) }
    }

    /// The plugin's command for a choice; nil for a job key it wouldn't take.
    nonisolated static func commandLine(_ choice: JobNotices.Choice, jobKey: String, title: String) -> String? {
        guard jobKey.contains("|"), !jobKey.contains(where: \.isWhitespace), jobKey.count <= 200 else { return nil }
        let name = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return ["job", choice.rawValue, jobKey, String(name.prefix(80))].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The plugin's answer to `jobs`: job → (choice, name). Nil for any other answer (an older
    /// plugin's).
    nonisolated static func choices(_ reply: String) -> [String: (choice: JobNotices.Choice, title: String)]? {
        let words = reply.split(separator: " ").map(String.init)
        guard words.count == 3, words[0] == "redde-push", words[1] == "jobs",
              let data = PushSeal.data(base64URL: words[2]),
              let found = try? JSONDecoder().decode([String: [String]].self, from: data) else { return nil }
        return found.reduce(into: [:]) { out, item in
            guard let raw = item.value.first, let choice = JobNotices.Choice(rawValue: raw) else { return }
            out[item.key] = (choice, item.value.count > 1 ? item.value[1] : "")
        }
    }

    /// A choice made here: said to the plugin shortly, or kept until it can be.
    func said(_ choice: JobNotices.Choice, jobKey: String, title: String) {
        guard Self.commandLine(choice, jobKey: jobKey, title: title) != nil else { return }
        var all = pending
        all[jobKey] = [choice.rawValue, title]
        pending = all
        flushing?.cancel()
        flushing = Task { [weak self] in await self?.flush() }
    }

    /// Says the choices waiting. Kept when the server can't be reached; dropped when its plugin is
    /// too old to know the command.
    func flush() async {
        guard settings.transport.isHermes else { return }
        for (job, said) in pending {
            guard let raw = said.first, let choice = JobNotices.Choice(rawValue: raw),
                  let line = Self.commandLine(choice, jobKey: job, title: said.count > 1 ? said[1] : "") else {
                pending[job] = nil
                continue
            }
            do {
                _ = try await command(line)
                pending[job] = nil
            } catch PushError.noPlugin {
                pending = [:]
                return
            } catch {
                return   // not reached now: said when Redde next comes forward
            }
        }
    }

    /// Back in front: what waits is said, then every job's choice read and taken here. One kept
    /// here that the plugin hasn't heard of (made before 1.34) is said to it. True when a choice
    /// here changed.
    @discardableResult
    func cameForward() async -> Bool {
        guard settings.transport.isHermes else { return false }
        await flush()
        guard pending.isEmpty, let reply = try? await command("jobs"), let there = Self.choices(reply) else { return false }
        var changed = false
        for (job, found) in there where JobNotices.choice(for: job, in: briefings) != found.choice {
            JobNotices.set(found.choice, for: job, title: found.title, in: briefings)
            if found.choice == .hidden { AgentBriefing.markJobRead(job, in: briefings) }
            changed = true
        }
        for (job, entry) in JobNotices.load(briefings) where there[job] == nil {
            said(entry.choice, jobKey: job, title: entry.title)
        }
        if changed { changedHere() }
        return changed
    }
}
