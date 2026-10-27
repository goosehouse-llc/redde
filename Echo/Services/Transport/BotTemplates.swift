import Foundation

/// A toolset a bot can be given (`profiles.describe`): Hermes's name for it, what it says it does,
/// and whether the bot has it.
nonisolated struct BotToolset: Equatable, Identifiable, Sendable {
    var name: String
    var description: String
    var enabled: Bool

    var id: String { name }

    init(name: String, description: String = "", enabled: Bool = true) {
        self.name = name
        self.description = description
        self.enabled = enabled
    }

    init?(_ json: JSONValue) {
        guard let name = json["name"]?.string?.nilIfEmpty else { return nil }
        self.init(name: name, description: json["description"]?.string ?? "", enabled: json["enabled"]?.bool ?? true)
    }

    /// What the person reads for it. A toolset this build has no words for keeps Hermes's name.
    var title: String { Self.titles[name] ?? name.replacingOccurrences(of: "_", with: " ").capitalized }

    static let titles: [String: String] = [
        "web": String(localized: "Web search", comment: "A set of tools an agent can be given"),
        "browser": String(localized: "Browser", comment: "A set of tools an agent can be given"),
        "terminal": String(localized: "Terminal", comment: "A set of tools an agent can be given"),
        "file": String(localized: "Files", comment: "A set of tools an agent can be given"),
        "code_execution": String(localized: "Run code", comment: "A set of tools an agent can be given"),
        "vision": String(localized: "Look at pictures", comment: "A set of tools an agent can be given"),
        "image_gen": String(localized: "Make pictures", comment: "A set of tools an agent can be given"),
        "tts": String(localized: "Speak aloud", comment: "A set of tools an agent can be given"),
        "stt": String(localized: "Transcribe audio", comment: "A set of tools an agent can be given"),
        "skills": String(localized: "Skills", comment: "A set of tools an agent can be given"),
        "todo": String(localized: "To-do list", comment: "A set of tools an agent can be given"),
        "memory": String(localized: "Memory", comment: "A set of tools an agent can be given"),
        "context_engine": String(localized: "Context engine", comment: "A set of tools an agent can be given"),
        "session_search": String(localized: "Search past chats", comment: "A set of tools an agent can be given"),
        "connections": String(localized: "Connections", comment: "A set of tools an agent can be given"),
        "clarify": String(localized: "Ask you questions", comment: "A set of tools an agent can be given"),
        "delegation": String(localized: "Hand off tasks", comment: "A set of tools an agent can be given"),
        "cronjob": String(localized: "Schedules", comment: "A set of tools an agent can be given"),
        "computer_use": String(localized: "Use the computer", comment: "A set of tools an agent can be given"),
        "homeassistant": "Home Assistant",
        "kanban": "Kanban",
        "video": String(localized: "Watch video", comment: "A set of tools an agent can be given"),
        "video_gen": String(localized: "Make video", comment: "A set of tools an agent can be given"),
        "x_search": String(localized: "Search X", comment: "A set of tools an agent can be given"),
        "search": String(localized: "Search", comment: "A set of tools an agent can be given"),
        "spotify": "Spotify",
    ]
}

/// A starting point for New Bot: a name, what it does, a personality, a face and the toolsets it
/// needs, all of it changeable before the bot is made. Its toolsets are kept to those the server
/// has; nil, every one the person's agent has (Blank).
nonisolated struct BotTemplate: Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var about: String
    var soul: String
    var face: BotFace
    var toolsets: [String]?

    /// The template's toolsets that this server has, or nil for all of them.
    func toolsets(offered: [BotToolset]) -> [String]? {
        guard let toolsets else { return nil }
        let names = Set(offered.map(\.name))
        return toolsets.filter(names.contains)
    }

    static let blank = BotTemplate(id: "blank", title: "", about: "", soul: "",
                                   face: BotFace(shape: .round, eyes: .round, mouth: .none, mark: .none, glance: 0, tilt: 0, color: 0),
                                   toolsets: nil)

    static let all: [BotTemplate] = [
        BotTemplate(
            id: "researcher", title: String(localized: "Researcher", comment: "A kind of bot to start from (New Bot), and the name it gets"),
            about: String(localized: "Looks things up on the web and comes back with what it found, and where it found it."),
            soul: """
            # Researcher

            **Mission:** Find things out, and say how you know.

            You look things up for the person: on the web, in the pages you open, and in what was said in earlier chats. You come back with the answer first, then the few facts that carry it, each with where it came from. When sources disagree, you say so and say which you trust more and why. When you can't find something, you say that plainly rather than guess.

            You are curious and careful. You keep answers short unless asked for more, and you ask one question when a request could mean two different things.
            """,
            face: BotFace(shape: .round, eyes: .sparkle, mouth: .smile, mark: .antenna, glance: 2, tilt: -4, color: 8),
            toolsets: ["web", "browser", "memory", "session_search", "clarify", "todo"]),
        BotTemplate(
            id: "writer", title: String(localized: "Writer", comment: "A kind of bot to start from (New Bot), and the name it gets"),
            about: String(localized: "Drafts, edits and tightens writing, in your voice."),
            soul: """
            # Writer

            **Mission:** Help the person say what they mean, well.

            You draft, edit and tighten writing: messages, posts, letters, notes, stories. You keep the person's own voice and say what they mean in fewer words. You give the new version first, then, only when it helps, a line on what you changed and why.

            You write plainly. You cut what doesn't earn its place, prefer short words to long ones, and never pad. You ask who it is for when that would change how it reads.
            """,
            face: BotFace(shape: .egg, eyes: .happy, mouth: .none, mark: .blush, glance: 1, tilt: 3, color: 5),
            toolsets: ["file", "memory", "clarify", "web", "todo"]),
        BotTemplate(
            id: "coder", title: String(localized: "Coder", comment: "A kind of bot to start from (New Bot), and the name it gets"),
            about: String(localized: "Reads and changes code, runs it, and says what it did."),
            soul: """
            # Coder

            **Mission:** Make the change the person asked for, and show it works.

            You read code before you change it, change only what the task needs, and run what you changed to see it work. You say what you did in a few lines: what changed, where, and how you checked it. When something fails, you show the error and what you tried.

            You ask before anything that can't be undone: deleting files, rewriting history, touching anything outside the project.
            """,
            face: BotFace(shape: .hex, eyes: .round, mouth: .grin, mark: .spark, glance: 3, tilt: -2, color: 6),
            toolsets: ["terminal", "file", "code_execution", "web", "memory", "clarify", "todo", "delegation", "skills"]),
        BotTemplate(
            id: "home", title: String(localized: "Home", comment: "A kind of bot to start from (New Bot), and the name it gets: one that looks after the house"),
            about: String(localized: "Looks after the house: lights, heating, sensors and routines."),
            soul: """
            # Home

            **Mission:** Keep the house running the way the person likes it.

            You look after the home: lights, heating, sensors, locks and the routines that tie them together. You check how things stand before you change them, and say what you changed in a line. You remember how the person likes things and when.

            You ask before anything that affects safety or security, such as locks, alarms or the heating left on while nobody is home.
            """,
            face: BotFace(shape: .capsule, eyes: .sleepy, mouth: .smile, mark: .none, glance: 0, tilt: 2, color: 1),
            toolsets: ["homeassistant", "memory", "clarify", "cronjob", "todo"]),
        BotTemplate(
            id: "planner", title: String(localized: "Planner", comment: "A kind of bot to start from (New Bot), and the name it gets"),
            about: String(localized: "Keeps your plans, lists and reminders, and nudges you on time."),
            soul: """
            # Planner

            **Mission:** Keep track of what the person means to do, and remind them in time.

            You keep lists, plans and reminders. You turn "I should" into a task with a when, put repeating things on a schedule, and nudge the person before something is due, not after. When asked what is next, you give the next few things in order, nothing more.

            You are brief and calm. You never add a task the person didn't ask for; you suggest it.
            """,
            face: BotFace(shape: .burst, eyes: .mismatched, mouth: .oh, mark: .freckles, glance: 1, tilt: -5, color: 9),
            toolsets: ["todo", "cronjob", "memory", "session_search", "clarify", "web"]),
    ]
}
