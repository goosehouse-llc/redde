#if DEBUG
import Foundation

/// Debug-only launch hooks for screenshots, demos and live tests; none of this exists in release
/// builds. Every flag the app reads is listed here, and only here.
///
/// Launch arguments (`xcrun simctl launch <device> com.goosehouse.echo <flags>`):
/// - `-echo.demo`: seed the demo conversation. `-echo.demoShort` keeps its first exchange,
///   `-echo.demoTwo` its first two (ending on the checklist and table), `-echo.demoLong` seeds a
///   transcript many screens long, `-echo.demoLibrary` adds a few local conversations.
/// - `-echo.demoProjects`: fill the conversation list's Projects from a fixture (Dashboard connection).
/// - `-echo.demoHosts`: replace any real endpoints with example hosts.
/// - `-echo.demoKanban`: a sample Kanban board instead of the server's.
/// - `-echo.screen settings|sessions|setup|profiles|servers`: open that screen at launch.
/// - `-echo.section cron|kanban`: open the conversation list on that tab.
/// - `-echo.settingsAnchor`: scroll Settings to the context and memory files.
/// - `-echo.expandAppIcons`: open Settings' app icon grid.
/// - `-echo.draft "text"`: type a question into a focused composer (keyboard screenshots).
/// - `-echo.voiceView`: open voice mode without listening. `-echo.voiceDemo` poses it mid-listen;
///   `-echo.autoVoice` opens it and starts listening.
/// - `-echo.whatsNew`: show this version's "What's New" sheet (any other `-echo.` flag hides it).
/// - `-echo.switchProfile <name>`: switch profile five seconds after launch.
/// - `-echo.testServer <name> <Dashboard URL> <username>`: add a server with that name if there's
///   none (its password from `ECHO_TEST_SERVER_PASSWORD`). `-echo.switchServer <name>` switches to
///   a server by name five seconds after launch.
///
/// Environment (`SIMCTL_CHILD_<NAME>=value`, so secrets stay out of arguments and logs; an empty
/// value deletes): `ECHO_TEST_SERVE_PASSWORD`, `ECHO_TEST_GATEWAY_KEY`, `ECHO_TEST_PROFILE_KEY`
/// (the selected profile's Hermes API key).
///
/// Settings can also be set for one launch with their UserDefaults keys, e.g. `-transport hermesServe`.
enum DevHooks {
    private static let args = CommandLine.arguments

    static func has(_ flag: String) -> Bool { args.contains(flag) }

    /// The argument after `flag`, if there is one.
    static func value(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// Any demo or screen flag: an App Store capture or a test, which the "What's New" sheet
    /// must not cover (`-echo.whatsNew` shows it on purpose).
    static var screenshotRun: Bool { args.contains { $0.hasPrefix("-echo.") } }

    static var demoKanban: Bool { has("-echo.demoKanban") }
    static var demoProjects: Bool { has("-echo.demoProjects") }
    static var expandAppIcons: Bool { has("-echo.expandAppIcons") }
    static var voiceDemo: Bool { has("-echo.voiceDemo") }
    static var settingsAnchor: Bool { has("-echo.settingsAnchor") }

    /// The launch-time hooks that don't touch a view's own state: demo content, example hosts,
    /// test credentials and the delayed profile switch.
    @MainActor
    static func applyAtLaunch(conversation: Conversation, settings: Settings) {
        if has("-echo.demo") { conversation.seedDemo() }
        if has("-echo.demoShort") { conversation.keepFirstMessages(2) }
        if has("-echo.demoTwo") { conversation.keepFirstMessages(4) }
        if has("-echo.demoLibrary") { conversation.seedDemoLibrary() }
        // The Projects section only shows on the Dashboard connection.
        if demoProjects { settings.transport = .hermesServe }
        if has("-echo.demoLong") { conversation.seedLongDemo() }
        if has("-echo.demoHosts") {
            settings.gatewayURL = "https://redde.home.example:8642"
            settings.serveURL = "http://redde.home.example:9119"
            settings.serveUsername = "redde"
            settings.fastLaneURL = "http://llama.home.example:11500"
            settings.fastLaneModel = "qwen36-35b-a3b"
        }

        let env = ProcessInfo.processInfo.environment
        if let v = env["ECHO_TEST_SERVE_PASSWORD"] { Keychain.write(.serveDashboardPassword, value: v) }
        if let v = env["ECHO_TEST_GATEWAY_KEY"] { Keychain.write(.gatewayAPIKey, value: v) }
        if let v = env["ECHO_TEST_PROFILE_KEY"], let profile = settings.profileName {
            Keychain.write(account: Keychain.profileAccount(profile), value: v)
        }

        if let i = args.firstIndex(of: "-echo.testServer"), i + 3 < args.count {
            let name = args[i + 1]
            if !settings.servers.contains(where: { $0.name == name }) {
                let id = settings.addServer(name: name)
                let original = settings.activeServerID
                settings.activateServer(id)
                settings.transport = .hermesServe
                settings.serveURL = args[i + 2]
                settings.serveUsername = args[i + 3]
                if let password = env["ECHO_TEST_SERVER_PASSWORD"] { Keychain.write(.serveDashboardPassword, value: password) }
                settings.activateServer(original)
            }
        }
        if let name = value("-echo.switchServer") {
            Task {
                try? await Task.sleep(for: .seconds(5))
                if let target = settings.servers.first(where: { $0.name == name || $0.title == name }) {
                    ServerSwitcher.switchTo(target.id, conversation: conversation)
                }
            }
        }

        // The simulator can't tap the picker, so this checks that open screens follow a switch.
        if let name = value("-echo.switchProfile") {
            Task {
                try? await Task.sleep(for: .seconds(5))
                settings.hermesProfile = name == "default" ? "" : name
                conversation.reset()
            }
        }
    }
}
#endif
