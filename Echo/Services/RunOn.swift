import Foundation

/// A scheduled job's own model (Run On, asked 2026-10-30, built 2026-11-03): Heads-Ups, the Evening
/// Wrap-up and the Week Ahead can run on a small model that stays loaded, so they don't wait behind a
/// chat or swap the main model out; the rest stay on the main model unless the person picks one.
/// Hermes keeps `model` and `provider` on the job and runs it on them (else `cron.model`, else the
/// main model). The Dashboard's job update sets them; the Hermes API's PATCH api/jobs takes neither,
/// so there the job's name carries ` [redde-model:<model>|<provider>]` (` [redde-model:|]`: the main
/// model again) and the Redde plugin moves it into the job and takes the mark off within half a
/// minute (`routines.py`, `models_due`).
nonisolated enum RunOn {
    static let tag = "[redde-model:"
    /// The Redde plugin that takes the mark up and answers `job-model`.
    static let pluginVersion = "1.17.0"
    /// How long a mark may wait for the plugin before the page says it isn't being taken up.
    static let markUnheardAfter: TimeInterval = 120

    /// What a job runs on: the main model (`model` empty), or a model on a provider (its full slug,
    /// as the model list gives it).
    struct Pick: Hashable, Sendable, Codable {
        var model: String
        var provider: String
        static let main = Pick(model: "", provider: "")
        var isMain: Bool { model.isEmpty }
    }

    /// The daily jobs a "quick jobs" choice moves (their names, as `HeadsUps`, `EveningWrapUp` and
    /// `WeekAhead` set them; a test keeps them the same). Morning Ideas, the heads-up planner's own
    /// reading of the day aside, and watches stay on the main model.
    static let quickJobs = ["[redde] Heads-ups", "[redde-notify] Evening wrap-up", "[redde-notify] Week ahead"]

    // MARK: The mark

    /// A job's name less a model mark, wherever it is, and what the mark asks for.
    static func unmarked(_ name: String) -> (name: String, asked: Pick?) {
        guard name.contains(tag), let found = name.firstMatch(of: /\s*\[redde-model:([^\]|]*)\|([^\]]*)\]/) else { return (name, nil) }
        let pick = Pick(model: String(found.output.1).trimmingCharacters(in: .whitespaces),
                        provider: String(found.output.2).trimmingCharacters(in: .whitespaces))
        var rest = name
        rest.removeSubrange(found.range)
        while rest.hasSuffix(" ") { rest.removeLast() }
        return (rest, pick)
    }

    /// `name` with the mark asking for `pick` at its end (any older one taken off). Nil when a model
    /// or provider holds a character the mark can't carry.
    static func marked(_ name: String, _ pick: Pick) -> String? {
        let bad: (String) -> Bool = { $0.contains("]") || $0.contains("|") || $0.contains("\n") }
        guard !bad(pick.model), !bad(pick.provider) else { return nil }
        let body = pick.isMain ? "|" : pick.model + "|" + pick.provider
        return unmarked(name).name + " " + tag + body + "]"
    }

    // MARK: Choosing

    /// What a job runs on as Hermes has it (`CronJob.model`, `.provider`); a mark still waiting for
    /// the plugin wins, being the person's latest choice.
    static func current(_ job: CronJob) -> Pick {
        if let asked = job.askedModel { return asked }
        guard let model = job.model?.nilIfEmpty else { return .main }
        return Pick(model: model, provider: job.provider ?? "")
    }

    /// The model list's entry for a pick: the same model, and the provider too when both have one.
    static func choice(for pick: Pick, in choices: [ModelChoice]) -> ModelChoice? {
        guard !pick.isMain else { return nil }
        return choices.first { $0.model == pick.model && (pick.provider.isEmpty || $0.provider == pick.provider) }
            ?? choices.first { $0.model == pick.model }
    }

    /// A small model on the server, for the quick jobs: one the person picked for one before, else the
    /// smallest whose name gives its size as under 10 billion parameters ("qwen3-4b", "llama-3.2-3b",
    /// "gemma-2b-it"), or says it is small ("mini", "nano", "tiny", "small"). A mixture-of-experts
    /// name ("35b-a3b") goes by its whole size, not its active part. Nil when none is.
    static func smallModel(in choices: [ModelChoice], remembered: Pick? = rememberedQuick) -> ModelChoice? {
        if let remembered, let chosen = choice(for: remembered, in: choices) { return chosen }
        let sized = choices.compactMap { choice -> (ModelChoice, Double)? in
            guard let size = billions(choice.model) ?? billions(choice.name) else {
                let lower = (choice.model + " " + choice.name).lowercased()
                return ["mini", "nano", "tiny", "small"].contains(where: { word in
                    lower.split(whereSeparator: { !$0.isLetter }).contains { $0 == word }
                }) ? (choice, 5) : nil
            }
            return size < 10 ? (choice, size) : nil
        }
        return sized.min { $0.1 < $1.1 }?.0
    }

    /// The largest "<n>b" in a model's name ("qwen36-35b-a3b" → 35, "qwen3-4b" → 4); nil when none.
    static func billions(_ name: String) -> Double? {
        // Parts between dashes, underscores, colons, slashes and spaces: "35b" is a size, "a3b"
        // (a mixture of experts' active part) and "qwen3" aren't.
        let parts = name.lowercased().split(whereSeparator: { "-_:/ ".contains($0) })
        let sizes = parts.compactMap { part -> Double? in
            guard let found = part.wholeMatch(of: /(\d+(?:\.\d+)?)b/) else { return nil }
            return Double(found.output.1)
        }
        return sizes.max()
    }

    /// The jobs a "quick jobs" choice moves: the quick daily jobs that are on and still run on the
    /// main model (one the person gave a model of its own keeps it).
    static func quickTargets(in jobs: [CronJob]) -> [CronJob] {
        jobs.filter { quickJobs.contains($0.name) && current($0).isMain }
    }

    // MARK: Remembered

    private static let quickKey = "runOnQuickModel"
    private static let offeredKey = "runOnQuickOffered"

    /// The model the person ran the quick jobs on (Ahead of Your Day's offer, or a quick job's picker).
    static var rememberedQuick: Pick? {
        get { UserDefaults.standard.data(forKey: quickKey).flatMap { try? JSONDecoder().decode(Pick.self, from: $0) } }
        set {
            if let newValue, !newValue.isMain, let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: quickKey)
            } else {
                UserDefaults.standard.removeObject(forKey: quickKey)
            }
        }
    }

    /// Ahead of Your Day offers the quick jobs' model once: taken or turned down, it isn't again.
    static var quickOffered: Bool {
        get { UserDefaults.standard.bool(forKey: offeredKey) }
        set { UserDefaults.standard.set(newValue, forKey: offeredKey) }
    }
}
