import SwiftUI
import WebKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The Agent's Screen (asked 2026-11-02, after Nous's Hermes Mobile beta): the chat's agent's Bot
/// Desktop on Hermes, as a still first, then live, then yours to drive when it is stuck at a
/// login. Everything in it is the Dashboard's (`BotScreen`); on the Hermes API, or a Hermes that
/// can't have a screen, it says why in a line.
struct BotScreenView: View {
    /// The profile whose screen it is (a bot's, in its chat); nil for the main one.
    let profile: String?
    /// After Hand Back: tell the agent to go on.
    var onContinue: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.theme) private var theme
    @State private var session: BotScreenSession
    @State private var live: BotScreenLive?
    @State private var typing = ""
    @State private var showKeyboard = false
    /// Live when the app went to the background: it comes back live.
    @State private var resumeLive = false

    init(profile: String?, onContinue: (() -> Void)? = nil, session: BotScreenSession? = nil) {
        self.profile = profile
        self.onContinue = onContinue
        let isDashboard = Settings.shared.transport == .hermesServe
        var made = session ?? BotScreenSession(profile: profile, host: isDashboard ? HermesServeClient.shared : nil, isDashboard: isDashboard)
        #if DEBUG
        if session == nil, DevHooks.has("-echo.demoBotScreen") {
            let control: BotScreen.Control = switch DevHooks.value("-echo.demoBotScreen") {
            case "you": .you
            case "other": .someoneElse
            default: .agent
            }
            made = BotScreenSession.demo(thumbnail: BotScreenDemo.thumbnail(), control: control)
        }
        #endif
        _session = State(initialValue: made)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if session.control == .you { controlBar }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                bottomBar
            }
            .background(theme.pageColor)
            .navigationTitle(Text("Agent's Screen"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        // On the red bar while you drive, blue would barely read.
                        .tint(session.control == .you ? .white : nil)
                }
            }
        }
        .task { await session.open() }
        .task(id: thumbnailKey) { await refreshThumbnails() }
        .onDisappear {
            // Closing the screen while driving it hands it back (a clean close does).
            live?.stop(handBack: true)
            live = nil
            session.close()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                // Leaving the app (to copy a password, say) keeps a hold: the link is dropped, not closed.
                if let live {
                    resumeLive = true
                    live.stop(handBack: false)
                    self.live = nil
                }
            case .active:
                if resumeLive {
                    resumeLive = false
                    watchLive()
                }
            default: break
            }
        }
        .onChange(of: session.control) { _, control in
            live?.setViewOnly(control != .you)
            if control != .you { showKeyboard = false }
        }
    }

    /// Thumbnails only while the still is what shows, and the app is in front.
    private var thumbnailKey: String {
        "\(live == nil)-\(scenePhase == .active)-\(session.availability.status?.running ?? false)"
    }

    private func refreshThumbnails() async {
        guard live == nil, scenePhase == .active, case .ready = session.availability else { return }
        while !Task.isCancelled {
            await session.refreshThumbnail()
            try? await Task.sleep(for: .seconds(4))
        }
    }

    // MARK: The screen

    @ViewBuilder private var content: some View {
        switch session.availability {
        case .checking:
            ProgressView()
        case let .stopped(status):
            VStack(spacing: 14) {
                Image(systemName: "display").font(.system(size: 40)).foregroundStyle(.secondary)
                Text("The agent's screen isn't running.").font(.headline)
                Text(status.geometry.isEmpty ? "" : status.geometry).font(.caption).foregroundStyle(.secondary)
                Button {
                    Task { await session.start() }
                } label: {
                    if session.busy { ProgressView() } else { Text("Start the Screen") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.busy)
            }
            .padding()
        case .ready:
            screen
        default:
            VStack(spacing: 12) {
                Image(systemName: "display.trianglebadge.exclamationmark").font(.system(size: 40)).foregroundStyle(.secondary)
                Text(session.availability.explanation ?? "")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
    }

    private var screen: some View {
        ZStack {
            if let live {
                BotScreenWebView(live: live)
                    .overlay {
                        if !live.connected {
                            ProgressView().controlSize(.large)
                        }
                    }
                    .overlay { driveEdge }
            } else {
                still
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    /// You drive: a red edge around the picture, as Hermes Desktop draws it.
    @ViewBuilder private var driveEdge: some View {
        if session.control == .you {
            RoundedRectangle(cornerRadius: live == nil ? 8 : 0).strokeBorder(Color.red, lineWidth: 3).allowsHitTesting(false)
        }
    }

    @ViewBuilder private var still: some View {
        VStack(spacing: 14) {
            if session.thumbnailWithheld {
                Label("Someone is driving the screen. Its picture is hidden while they do.", systemImage: "hand.raised")
                    .foregroundStyle(.secondary)
                    .padding()
            } else if let data = session.thumbnail, let image = Self.image(data) {
                image
                    .resizable()
                    .scaledToFit()
                    .clipShape(.rect(cornerRadius: 8))
                    .overlay { driveEdge }
                    .accessibilityLabel("The agent's screen")
            } else {
                ProgressView()
            }
            Button {
                watchLive()
            } label: {
                Label("Watch Live", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: Bars

    private var controlBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.point.up.left.fill")
            Text("You have control. The agent waits until you hand back.")
                .font(.footnote.weight(.semibold))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.red)
    }

    @ViewBuilder private var bottomBar: some View {
        VStack(spacing: 10) {
            if let notice = session.notice {
                Text(notice).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if session.handedBack, let onContinue {
                Button {
                    onContinue()
                    session.dismissContinue()
                    dismiss()
                } label: {
                    Label("Continue", systemImage: "arrow.right.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Tells the agent to carry on")
            }
            if showKeyboard || (session.isDemo && session.control == .you), session.control == .you { keyboardBar }
            if case .ready = session.availability, live != nil || session.isDemo { controls }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 12) {
            switch session.control {
            case .you:
                Button {
                    Task { await session.handBack() }
                } label: {
                    Label("Hand Back", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                Button {
                    showKeyboard.toggle()
                } label: {
                    Label("Keyboard", systemImage: "keyboard")
                }
                .buttonStyle(.bordered)
                Button {
                    if let text = Self.pasteboardText(), !text.isEmpty { live?.type(text) }
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Types what you copied into the screen")
            case .agent:
                Button {
                    Task { await session.takeOver() }
                } label: {
                    Label("Take Over", systemImage: "hand.point.up.left")
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.busy || session.viewerID == nil)
                Text("You're watching. The agent drives.").font(.footnote).foregroundStyle(.secondary)
            case .someoneElse:
                Button {
                    Task { await session.takeOver() }
                } label: {
                    Label("Take Over", systemImage: "hand.point.up.left")
                }
                .buttonStyle(.bordered)
                .disabled(session.busy || session.viewerID == nil)
                Text("Someone else is driving.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.regular)
    }

    private var keyboardBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Type to the screen", text: $typing)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onSubmit { sendTyping(pressReturn: true) }
                Button("Send") { sendTyping(pressReturn: false) }
                    .disabled(typing.isEmpty)
            }
            HStack(spacing: 8) {
                keyButton("Return", "return")
                keyButton("BackSpace", "delete.left")
                keyButton("Tab", "arrow.right.to.line")
                keyButton("Escape", "escape")
                keyButton("Left", "arrow.left")
                keyButton("Up", "arrow.up")
                keyButton("Down", "arrow.down")
                keyButton("Right", "arrow.right")
            }
            Text("Keys are sent as a US keyboard types them.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func keyButton(_ name: String, _ symbol: String) -> some View {
        Button { live?.key(name) } label: { Image(systemName: symbol).frame(minWidth: 22) }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel(Text(verbatim: name))
    }

    private func sendTyping(pressReturn: Bool) {
        guard !typing.isEmpty || pressReturn else { return }
        live?.type(typing)
        if pressReturn { live?.key("Return") }
        typing = ""
    }

    private func watchLive() {
        guard live == nil, case .ready = session.availability else { return }
        let fresh = BotScreenLive(session: session)
        live = fresh
        Task { await fresh.start() }
    }

    // MARK: Platform

    private static func image(_ data: Data) -> Image? {
        #if canImport(UIKit)
        UIImage(data: data).map(Image.init(uiImage:))
        #else
        NSImage(data: data).map(Image.init(nsImage:))
        #endif
    }

    private static func pasteboardText() -> String? {
        #if canImport(UIKit)
        UIPasteboard.general.string
        #else
        NSPasteboard.general.string(forType: .string)
        #endif
    }
}

/// The live picture: a web view running noVNC, fed by `BotScreenStream`. Made when Watch Live is
/// tapped and gone when the screen closes or the app leaves the front.
@MainActor @Observable
final class BotScreenLive {
    private(set) var connected = false
    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private let stream = BotScreenStream()
    @ObservationIgnored private let session: BotScreenSession
    @ObservationIgnored private var ready = false
    @ObservationIgnored private var readyWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var cost: LinkCost?
    @ObservationIgnored private var expensive = false
    /// Re-attaches after an eviction, a few times at most.
    @ObservationIgnored private var reattaches = 0
    @ObservationIgnored private var stopped = false

    init(session: BotScreenSession) {
        self.session = session
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        #if os(iOS)
        config.dataDetectorTypes = []
        #endif
        webView = WKWebView(frame: .zero, configuration: config)
        #if os(iOS)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        #else
        webView.setValue(false, forKey: "drawsBackground")
        #endif
        #if DEBUG
        webView.isInspectable = true
        #endif
        config.userContentController.add(ScreenMessages(self), name: "screen")
        stream.onBytes = { [weak self] data in
            self?.run("reddeScreen.feed('\(data.base64EncodedString())')")
        }
        stream.onEnd = { [weak self] how in self?.ended(how) }
    }

    /// The page, the ticket, the socket; then noVNC on it.
    func start() async {
        if !ready { load() }
        await waitUntilReady()
        guard !stopped else { return }
        cost = cost ?? LinkCost { [weak self] expensive in
            guard let self else { return }
            self.expensive = expensive
            let q = BotScreen.quality(expensive: expensive)
            self.run("reddeScreen.setQuality(\(q.quality), \(q.compression))")
        }
        do {
            let (ticket, path) = try await session.observe()
            guard !stopped else { return }
            let socket = try HermesServeClient.shared.openDisplaySocket(path: path, ticket: ticket)
            stream.open(socket)
            let q = BotScreen.quality(expensive: expensive)
            let viewOnly = session.control != .you
            run("reddeScreen.open({quality: \(q.quality), compression: \(q.compression), viewOnly: \(viewOnly)})")
        } catch {
            session.notice = error.localizedDescription
        }
    }

    private func load() {
        guard let page = Bundle.main.url(forResource: "screen", withExtension: "html", subdirectory: "Web/screen"),
              let lib = Bundle.main.url(forResource: "novnc-rfb-1.7.0.min", withExtension: "mjs", subdirectory: "Web/screen"),
              let html = try? String(contentsOf: page, encoding: .utf8),
              let code = try? String(contentsOf: lib, encoding: .utf8) else {
            session.notice = String(localized: "The screen viewer is missing from this build.")
            return
        }
        // The library goes into the page's one module script: a file page can't import a module.
        webView.loadHTMLString(html.replacingOccurrences(of: "/*NOVNC*/", with: code), baseURL: page.deletingLastPathComponent())
    }

    private func waitUntilReady() async {
        guard !ready else { return }
        await withCheckedContinuation { readyWaiters.append($0) }
    }

    fileprivate func heard(_ body: Any) {
        guard let message = body as? [String: Any], let kind = message["t"] as? String else { return }
        switch kind {
        case "ready":
            ready = true
            readyWaiters.forEach { $0.resume() }
            readyWaiters = []
        case "send":
            if let b64 = message["b"] as? String, let data = Data(base64Encoded: b64) { stream.send(data) }
        case "close":
            stream.close(handBack: true)
        case "connected":
            connected = true
            reattaches = 0
        case "disconnected":
            connected = false
        default:
            break
        }
    }

    private func ended(_ how: BotScreen.Ended) {
        connected = false
        run("reddeScreen.closed(\(how == .controlTaken ? 4000 : 1006), '')")
        session.ended(how)
        guard !stopped else { return }
        // Evicted or a spent ticket: watch again on a fresh one, a few times at most.
        if how == .controlTaken || how == .badTicket || how == .dropped, reattaches < 3 {
            reattaches += 1
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                await self?.start()
            }
        }
    }

    /// A line of the page's script, its answer unwanted.
    private func run(_ script: String) {
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    func setViewOnly(_ on: Bool) {
        run("reddeScreen.setViewOnly(\(on))")
    }

    func type(_ text: String) {
        guard let json = try? JSONEncoder().encode(text), let literal = String(data: json, encoding: .utf8) else { return }
        run("reddeScreen.type(\(literal))")
    }

    func key(_ name: String) {
        run("reddeScreen.key('\(name)')")
    }

    func stop(handBack: Bool) {
        stopped = true
        cost?.stop()
        cost = nil
        stream.close(handBack: handBack)
        run("reddeScreen.disconnect && reddeScreen.disconnect()")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "screen")
        readyWaiters.forEach { $0.resume() }
        readyWaiters = []
    }
}

/// The page's messages, passed to the live screen without holding it (the content controller
/// keeps its handlers).
private final class ScreenMessages: NSObject, WKScriptMessageHandler {
    weak var live: BotScreenLive?
    init(_ live: BotScreenLive) { self.live = live }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        live?.heard(message.body)
    }
}

#if os(iOS)
struct BotScreenWebView: UIViewRepresentable {
    let live: BotScreenLive
    func makeUIView(context: Context) -> WKWebView { live.webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#else
struct BotScreenWebView: NSViewRepresentable {
    let live: BotScreenLive
    func makeNSView(context: Context) -> WKWebView { live.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#endif
