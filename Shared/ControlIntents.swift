import AppIntents
import Foundation

/// Intents that run outside the app (Control Center, Lock Screen, Action Button via a control).
/// They leave a note in the App Group and ask the system to open the app, which picks the note
/// up on activation and starts listening. No URL hop, so it works regardless of scene setup.
/// Compiled into both the app and the controls extension.
struct StartListeningIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Redde"
    static let description = IntentDescription("Opens Redde and starts listening.")
    static let openAppWhenRun = true
    /// The Siri App Shortcut with the same title lives in the app target; hide this one from the
    /// Shortcuts and Spotlight lists so the pair doesn't show twice.
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        LaunchFlag.requestVoice(handsFree: false)
        return .result()
    }
}

struct StartHandsFreeIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk with Redde"
    static let description = IntentDescription("Opens Redde in hands-free conversation mode.")
    static let openAppWhenRun = true
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        LaunchFlag.requestVoice(handsFree: true)
        return .result()
    }
}

/// Quick capture from a control: Redde opens listening for a note, files it and says nothing back.
struct StartCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Take a Note with Redde"
    static let description = IntentDescription("Opens Redde and listens for a note to file. Nothing is sent back.")
    static let openAppWhenRun = true
    /// The Siri App Shortcut for notes lives in the app target and needs no screen; this is the
    /// control's.
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        LaunchFlag.requestCapture()
        return .result()
    }
}

/// `echo://listen` and `echo://listen?handsfree=1`.
nonisolated enum EchoURL {
    static let scheme = "echo"
    /// Just bring the app forward (widget tap on the last reply).
    static let open = URL(string: "echo://open")!
    /// A new chat with the main agent, the keyboard up: Your Agents' Ask bar (a widget can't hold
    /// a text field, so this is as close as typing on the Home Screen comes).
    static let compose = URL(string: "echo://compose")!

    static func listen(handsFree: Bool) -> URL {
        var comps = URLComponents()
        comps.scheme = scheme
        comps.host = "listen"
        if handsFree { comps.queryItems = [URLQueryItem(name: "handsfree", value: "1")] }
        return comps.url!
    }

    /// Open the conversation a Hermes session id names (the "Needs you" widget).
    static func session(_ id: String) -> URL {
        var comps = URLComponents()
        comps.scheme = scheme
        comps.host = "session"
        comps.queryItems = [URLQueryItem(name: "id", value: id)]
        return comps.url ?? open
    }

    /// The session id when the URL asks for a conversation, nil otherwise.
    static func parseSession(_ url: URL) -> String? {
        guard url.scheme == scheme, url.host == "session" else { return nil }
        let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value
        return id?.isEmpty == false ? id : nil
    }

    /// The Home Screen widgets' links (2026-11-24): a bot's chat, a list, an idea to do, words
    /// to start a new conversation with.
    static func bot(_ profile: String) -> URL { link("bot", "profile", profile) }
    static func list(_ id: String) -> URL { link("list", "id", id) }
    static func idea(_ id: String) -> URL { link("idea", "id", id) }
    static func ask(_ text: String) -> URL { link("ask", "text", text) }

    private static func link(_ host: String, _ name: String, _ value: String) -> URL {
        var comps = URLComponents()
        comps.scheme = scheme
        comps.host = host
        comps.queryItems = [URLQueryItem(name: name, value: value)]
        return comps.url ?? open
    }

    /// What a widget's link carries: `value(of: url, "list", "id")`.
    static func value(of url: URL, _ host: String, _ name: String) -> String? {
        guard url.scheme == scheme, url.host == host else { return nil }
        let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
        return value?.isEmpty == false ? value : nil
    }

    /// Returns hands-free flag when the URL is a listen request, nil otherwise.
    static func parseListen(_ url: URL) -> Bool? {
        guard url.scheme == scheme, url.host == "listen" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.contains { $0.name == "handsfree" && $0.value == "1" }
    }
}
