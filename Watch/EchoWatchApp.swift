import SwiftUI

/// Redde on the wrist: ask one question by dictation, read the answer, hear it. The watch talks
/// to Hermes itself with a connection the iPhone hands over (`WatchConnection`); approvals and
/// questions reach the wrist as the phone's notifications.
@main
struct EchoWatchApp: App {
    private let store = WatchStore.shared

    init() {
        PhoneLink.shared.attach(store)
    }

    var body: some Scene {
        WindowGroup {
            AskView()
                .environment(store)
                #if DEBUG
                // Simulator hooks. `-echo.connection <hermesAPI|fastLane> <url> <key>` stands in
                // for the phone (paired simulators don't hand the connection over); `-echo.ask
                // "text"` asks at launch, since the simulator can't dictate; `-echo.preview
                // <idle|thinking|speaking|waiting|approval|question|failed>` shows an exchange in that state.
                .task {
                    let args = CommandLine.arguments
                    if let p = args.firstIndex(of: "-echo.preview") { return store.preview(p + 1 < args.count ? args[p + 1] : "") }
                    if let c = args.firstIndex(of: "-echo.connection"), c + 3 < args.count, let kind = WatchConnection.Kind(rawValue: args[c + 1]) {
                        store.apply(WatchConnection(kind: kind, url: args[c + 2], apiKey: args[c + 3], model: "", provider: "",
                                                    reasoningEffort: "", replyLanguage: "", agentName: "Redde"))
                    }
                    guard let i = args.firstIndex(of: "-echo.ask"), i + 1 < args.count else { return }
                    for _ in 0..<40 where store.connection == nil { try? await Task.sleep(for: .milliseconds(500)) }
                    store.ask(args[i + 1])
                }
                #endif
        }
    }
}
