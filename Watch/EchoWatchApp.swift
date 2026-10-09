import SwiftUI

/// Redde on the wrist: ask one question by dictation, read the answer, hear it. The watch talks
/// to Hermes itself with a connection the iPhone hands over (`WatchConnection`); approvals and
/// questions reach the wrist as the phone's notifications.
@main
struct EchoWatchApp: App {
    private let store = WatchStore.shared

    init() {
        #if DEBUG
        // `-echo.connection` stands in for the phone: a paired simulator's phone, which may hand
        // over a connection of its own, is then not listened to.
        if CommandLine.arguments.contains("-echo.connection") { return }
        #endif
        PhoneLink.shared.attach(store)
    }

    /// A link the app was opened with. The one there is: the complication's, which listens.
    private func open(_ url: URL) {
        if AskComplication.asks(url) { store.requestDictation() }
    }

    @ViewBuilder
    private var root: some View {
        #if DEBUG
        if CommandLine.arguments.contains("-echo.complications") {
            ComplicationGallery()
        } else if CommandLine.arguments.contains("-echo.chatList") {
            NavigationStack { ChatsView() }
        } else {
            AskView()
        }
        #else
        AskView()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            root
                .environment(store)
                // A tap on the Ask Redde complication: listen, as the Ask button does.
                .onOpenURL(perform: open)
                #if DEBUG
                // Simulator hooks. `-echo.connection <hermesAPI|fastLane> <url> <key>` stands in
                // for the phone (paired simulators don't hand the connection over); `-echo.ask
                // "text"` asks at launch, since the simulator can't dictate; `-echo.preview
                // <idle|thinking|speaking|waiting|approval|question|failed>` shows an exchange in that state;
                // `-echo.chatList` shows the list of conversations in place of the app, and
                // `-echo.openChat <n>` opens the nth of them, as picking it from the list does;
                // `-echo.complications` shows the complication's sizes, and `-echo.link <url>` opens a
                // link as a tap on the complication does.
                .task {
                    let args = CommandLine.arguments
                    if let p = args.firstIndex(of: "-echo.preview") { return store.preview(p + 1 < args.count ? args[p + 1] : "") }
                    if let c = args.firstIndex(of: "-echo.connection"), c + 3 < args.count, let kind = WatchConnection.Kind(rawValue: args[c + 1]) {
                        store.apply(WatchConnection(kind: kind, url: args[c + 2], apiKey: args[c + 3], model: "", provider: "",
                                                    reasoningEffort: "", replyLanguage: "", agentName: "Redde"))
                    }
                    if let l = args.firstIndex(of: "-echo.link"), l + 1 < args.count, let url = URL(string: args[l + 1]) {
                        try? await Task.sleep(for: .seconds(1))
                        return open(url)
                    }
                    if let o = args.firstIndex(of: "-echo.openChat"), o + 1 < args.count {
                        await store.loadChats()
                        if let n = Int(args[o + 1]), store.chats.indices.contains(n) { store.open(store.chats[n]) }
                        return
                    }
                    guard let i = args.firstIndex(of: "-echo.ask"), i + 1 < args.count else { return }
                    for _ in 0..<40 where store.connection == nil { try? await Task.sleep(for: .milliseconds(500)) }
                    store.ask(args[i + 1])
                }
                #endif
        }
    }
}
