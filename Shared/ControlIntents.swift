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

/// `echo://listen` and `echo://listen?handsfree=1`.
nonisolated enum EchoURL {
    static let scheme = "echo"
    /// Just bring the app forward (widget tap on the last reply).
    static let open = URL(string: "echo://open")!

    static func listen(handsFree: Bool) -> URL {
        var comps = URLComponents()
        comps.scheme = scheme
        comps.host = "listen"
        if handsFree { comps.queryItems = [URLQueryItem(name: "handsfree", value: "1")] }
        return comps.url!
    }

    /// Returns hands-free flag when the URL is a listen request, nil otherwise.
    static func parseListen(_ url: URL) -> Bool? {
        guard url.scheme == scheme, url.host == "listen" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.contains { $0.name == "handsfree" && $0.value == "1" }
    }
}
