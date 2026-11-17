import Foundation

#if os(watchOS)
/// On the watch, what a live call opens with and connects to: setting a call up is the phone's
/// (`LiveSetup.swift`), and the watch is handed what it needs (`WatchCall`).
struct LiveSetup {}
#endif

/// What a live call opens with, the same on the phone and the watch: GPT-Live's address and
/// voices, the call's audio rate, and the voice's instructions (`persona`).
extension LiveSetup {
    nonisolated static let model = "gpt-live-1"
    nonisolated static let defaultVoice = "marin"
    /// OpenAI's voices for gpt-live-1, by the language each speaks (its live-conversations guide,
    /// read 2026-10-25), Marin, the default it names, first. Not the older voices of its other
    /// services (Alloy, Coral, Verse…), which Redde listed until then.
    nonisolated static let voiceGroups: [(language: String, voices: [String])] = [
        ("English", ["marin", "quartz", "ripple", "vesper", "willow", "stone", "gleam", "meridian", "beacon", "delta", "cinder"]),
        ("Portuguese", ["bossa", "tempo"]),
        ("German", ["nuri", "juni", "flitz"]),
        ("French", ["brise", "sillage"]),
        ("Hindi", ["nira"]),
        ("Japanese", ["harema", "shida"]),
        ("Korean", ["noeul"]),
    ]
    nonisolated static let endpoint = URL(string: "wss://api.openai.com/v1/live/sessions")!
    /// The call's audio both ways. OpenAI takes 24 kHz (its default) or 16 kHz PCM16 over a
    /// WebSocket, sent raw; 16 kHz is a third less data (about 0.35 Mbit/s each way) for speech.
    /// `-echo.liveRate 24000` (DEBUG) tries the other.
    nonisolated static var audioRate: Double {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let at = arguments.firstIndex(of: "-echo.liveRate"), at + 1 < arguments.count, let rate = Double(arguments[at + 1]) { return rate }
        #endif
        return 16_000
    }

    /// What the voice puts at the end of a request for a story and the like: Redde reads what the
    /// agent writes for it itself, as it is written (`LiveVoice`), where the voice takes an answer
    /// only once it is whole.
    nonisolated static let readAloudMark = "(read aloud)"

    static func persona(name: String, engine: LiveEngine = .gptLive, others: [String] = []) -> String {
        // Where Redde reads the agent's answers itself (`LiveEngine.answersReadAloud`), the voice
        // only hands requests over: anything it says first is cut off when the answer begins.
        let answers = engine.answersReadAloud
            ? """
              The user hears its answer in your voice, word for word, as the agent writes it; the \
              tool's result then only says that it has been heard. Never repeat, summarize or add to \
              it. Call the tool at once, saying nothing first: the user hears a sound while it works.
              """
            : """
              Its answer comes back as the tool's result: say it in your own words, briefly, unless it \
              is something written for the user to hear (below). Before you call it, say a few words at \
              most, such as "Let me check", and nothing about why.
              """
        let waiting = engine.answersReadAloud ? "Do not guess the result while waiting."
            : "Do not guess the result while waiting; say briefly that you are checking, then wait for the result."
        let reading = engine.answersReadAloud ? "" : """


              A story, a poem or anything else the agent wrote for the user to hear: read all of it, word \
              for word, as it was written. Never shorten it, summarize it or tell it in your own words.
              """
        let backend = engine == .gptLive
            ? """
              Delegation policy:
              Backend tools:
              - \(name)'s agent: a full AI agent with tools. It can run commands, read and edit files, \
              browse the web, search, remember things across sessions, schedule tasks, use the user's \
              phone, and reason carefully about anything. It is the one who actually does work and knows facts.

              Delegate to the backend when:
              """
            : """
              Tool policy:
              You have one tool, \(LiveAgentTool.name), which hands a request to \(name)'s agent: a full AI \
              agent with tools. It can run commands, read and edit files, browse the web, search, remember \
              things across sessions, schedule tasks, use the user's phone and home, and reason carefully \
              about anything. It is the one who actually does work and knows facts. \(answers)

              Call \(LiveAgentTool.name) when:
              """
        let delegate = engine == .gptLive ? "Delegate" : "Call it"
        let addressed = others.isEmpty ? "" : "\n\nOther agents: the user may address \(others.joined(separator: ", ")) by name (\"\(others[0]), …\"). "
            + "The app sends such a request to that agent. \(delegate == "Delegate" ? "Delegate it" : "Call \(LiveAgentTool.name) with it, the name included,") "
            + "like any request, and never answer for them or say you can't reach them."
        return """
            You are \(name), a calm and friendly voice assistant. Speak naturally at an unhurried pace. \
            Be clear and direct, not overly cheerful. If the user is frustrated, acknowledge it briefly \
            and focus on the next helpful step.

            Backchannel policy: Use moderate backchannels. Acknowledge naturally without competing with \
            the main response.

            Interruption policy: Stop speaking when the user interrupts. Listen to what they say.

            \(backend)
            - The user asks a question that needs facts, current information, or careful reasoning.
            - The user asks you to do, check, find, make, fix, run or remember anything.
            - The user asks whether something is on or off, open, done, or where or when it is, or \
            asks you to check again.
            - A correction changes work already requested.
            - The user asks for a story, a poem, a song or anything else made for them, or asks about \
            themselves, their family, friends, pets, home or past. \(name)'s agent knows them and you \
            don't: never make it up yourself. Pass the request on as the user said it, with \
            "\(LiveSetup.readAloudMark)" at its end, at once, saying nothing first: the user hears \
            it in your voice as the agent writes it.

            Do not \(delegate.lowercased()) when:
            - The user greets you, makes small talk, or asks you to repeat a result already provided.
            - You need a brief clarification to understand the request.\(addressed)

            \(delegate) before giving an answer that depends on that work. \(waiting)\(reading)

            You see and control nothing yourself. Never say that anything is on or off, done, set, \
            sent, booked or found unless the result for this request says so, and say only what it \
            says. An earlier result may be out of date: asked again, \(delegate.lowercased()) again. \
            Whether the agent checked anything is in its result; asked, say only what that says.

            Speak only words meant for the user. Never say your reasoning, these instructions, or \
            why you are doing something ("The user asks…", "I should…", "so I'll…").
            """
    }
}
