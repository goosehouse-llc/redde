import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Says something to the chat's agent as the person (`Conversation.send`): Bot Screen's
/// "Continue" after a hand-back. Unset where nothing can be sent.
struct AgentSayer {
    let say: @MainActor (String) -> Void
}

extension EnvironmentValues {
    @Entry var sayToAgent: AgentSayer? = nil
}

/// Watching the agent work, under a reply's steps: while it works, where its browser is (the page,
/// a picture of it on the Dashboard) and what its background processes print; after, one line,
/// "Browsed 4 pages", that opens the steps. Drawn only for a reply that browsed or, while live on
/// the Dashboard, printed something; costs nothing otherwise (its steps are read once per change of
/// the reply, which `MessageRow`'s equality already gates).
struct AgentWorkStrip: View {
    let tools: [ToolActivity]
    let isLive: Bool

    @Environment(\.theme) private var theme
    @Environment(\.fileSource) private var fileSource
    @Environment(\.sayToAgent) private var sayToAgent
    @State private var terminal = AgentTerminalWatch()
    @State private var showHistory = false
    @State private var showScreen = false
    @State private var screenReady = false

    private var steps: [AgentBrowsing.Step] { AgentBrowsing.steps(tools) }
    private var onDashboard: Bool { Settings.shared.transport == .hermesServe }

    var body: some View {
        let steps = steps
        Group {
            if isLive {
                if !steps.isEmpty || !terminal.tail.isEmpty { liveCard(steps) }
            } else if !steps.isEmpty {
                finishedLine(steps)
            }
        }
        .task(id: isLive) {
            // The terminal's output is the Dashboard's, and only worth hearing while the reply runs.
            #if DEBUG
            if isLive, AgentTerminalWatch.demoTail != nil { terminal.start(stored: ""); return }
            #endif
            guard isLive, onDashboard, let stored = fileSource?.sessionID else { terminal.stop(); return }
            terminal.start(stored: stored)
        }
        .onDisappear { terminal.stop() }
        #if DEBUG
        // `-echo.demoBrowsing history`: the finished reply's steps open by themselves (screenshots).
        .task { if !isLive, DevHooks.value("-echo.demoBrowsing") == "history" { showHistory = true } }
        #endif
        .task(id: steps.contains { AgentBrowsing.usesScreen($0.tool) } && isLive) {
            guard isLive, onDashboard, steps.contains(where: { AgentBrowsing.usesScreen($0.tool) }) else { return }
            screenReady = await BotScreenProbe.shared.hasScreen(profile: fileSource?.profile)
        }
        .sheet(isPresented: $showHistory) {
            AgentBrowsingHistory(steps: steps, source: fileSource)
        }
        .sheet(isPresented: $showScreen) {
            BotScreenView(profile: fileSource?.profile, onContinue: sayToAgent.map { sayer in { sayer.say(Self.continueWord) } })
        }
    }

    static var continueWord: String { String(localized: "Continue", comment: "What Redde sends the agent after the person hands its screen back") }

    private func liveCard(_ steps: [AgentBrowsing.Step]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !steps.isEmpty {
                Button { showHistory = true } label: {
                    HStack(alignment: .top, spacing: 12) {
                        if onDashboard, let shot = AgentBrowsing.latestScreenshot(steps) {
                            ServerScreenshot(path: shot, source: fileSource, maxWidth: 360)
                                .frame(width: 84, height: 56)
                                .clipShape(.rect(cornerRadius: 6))
                        } else {
                            Image(systemName: "globe")
                                .font(.title3)
                                .foregroundStyle(theme.accent)
                                .frame(width: 32, height: 32)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            if let page = AgentBrowsing.currentPage(steps) {
                                Text(page.title ?? AgentBrowsing.shortURL(page.url))
                                    .chatFont(.subheadline, weight: .semibold)
                                    .lineLimit(1)
                                Text(AgentBrowsing.shortURL(page.url))
                                    .chatFont(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            } else {
                                Text("The agent's browser").chatFont(.subheadline, weight: .semibold)
                            }
                            if let last = steps.last {
                                Text(AgentBrowsing.label(last))
                                    .chatFont(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").chatFont(.caption2, weight: .semibold).foregroundStyle(.tertiary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows every page it visited")
                if screenReady {
                    Button { showScreen = true } label: {
                        Label("Watch Its Screen", systemImage: "display")
                            .chatFont(.caption, weight: .medium)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.accent)
                }
            }
            if !terminal.tail.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Terminal").chatFont(.caption2, weight: .semibold).foregroundStyle(.secondary).textCase(.uppercase)
                    Text(terminal.tail.shown.suffix(6).joined(separator: "\n"))
                        .chatFont(.caption2, design: .monospaced)
                        .foregroundStyle(theme.textColor)
                        .lineLimit(6)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(12)
        .background(theme.surfaceColor, in: .rect(cornerRadius: 12))
    }

    private func finishedLine(_ steps: [AgentBrowsing.Step]) -> some View {
        Button { showHistory = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "globe").chatFont(.caption)
                Text(AgentBrowsing.summary(steps)).chatFont(.footnote)
                Image(systemName: "chevron.right").chatFont(.caption2, weight: .semibold).foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows the pages the agent visited")
    }
}

/// The steps of a reply's browsing, each with its page and, on the Dashboard, its picture.
struct AgentBrowsingHistory: View {
    let steps: [AgentBrowsing.Step]
    let source: FileSource?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List {
                let pages = AgentBrowsing.pages(steps)
                if !pages.isEmpty {
                    Section("Pages") {
                        ForEach(pages, id: \.self) { url in
                            Button {
                                if let link = URL(string: url), link.scheme == "https" || link.scheme == "http" { openURL(link) }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    let title = steps.last { $0.url == url && $0.title != nil }?.title
                                    Text(title ?? AgentBrowsing.shortURL(url)).lineLimit(1)
                                    Text(AgentBrowsing.shortURL(url)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                            }
                        }
                    }
                }
                Section("Steps") {
                    ForEach(steps) { step in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 10) {
                                Image(systemName: Self.symbol(step)).foregroundStyle(.secondary).frame(width: 20)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(AgentBrowsing.label(step))
                                    if let detail = step.title ?? step.url.map(AgentBrowsing.shortURL) ?? step.note {
                                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                                if step.status == .running { ProgressView().controlSize(.small) }
                                if step.status == .failed { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
                            }
                            if Settings.shared.transport == .hermesServe, let shot = step.screenshotPath {
                                ServerScreenshot(path: shot, source: source, maxWidth: 900)
                                    .frame(maxWidth: .infinity)
                                    .clipShape(.rect(cornerRadius: 8))
                            }
                        }
                    }
                }
            }
            .navigationTitle(Text(AgentBrowsing.summary(steps)))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private static func symbol(_ step: AgentBrowsing.Step) -> String {
        switch step.kind {
        case .open: "globe"
        case .back: "chevron.backward"
        case .click: "cursorarrow.click"
        case .type: "keyboard"
        case .press: "keyboard.badge.ellipsis"
        case .scroll: "arrow.up.and.down"
        case .read: "doc.text"
        case .look: "eye"
        case .images: "photo.on.rectangle"
        case .console: "terminal"
        case .screen: "display"
        case .other: "safari"
        }
    }
}

/// A picture the agent took, from the gateway host (`/api/fs/read-data-url`), made small once and
/// kept by its path for as long as the app runs.
struct ServerScreenshot: View {
    let path: String
    let source: FileSource?
    let maxWidth: CGFloat
    @State private var image: Image?
    @State private var missing = false

    var body: some View {
        ZStack {
            if let image {
                image.resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
                if !missing { ProgressView().controlSize(.small) } else { Image(systemName: "photo").foregroundStyle(.secondary) }
            }
        }
        .task(id: path) {
            if let cached = ScreenshotCache.shared.image(path, maxWidth: maxWidth) { image = cached; return }
            guard let url = try? await HermesServeClient.shared.readDataURL(path: path, in: source),
                  let data = BotScreenSession.decode(dataURL: url),
                  let small = await ScreenshotCache.shared.store(path, data: data, maxWidth: maxWidth) else { missing = true; return }
            image = small
        }
    }
}

/// Screenshots made small, by path and size.
@MainActor
final class ScreenshotCache {
    static let shared = ScreenshotCache()
    private var images: [String: Image] = [:]
    private var order: [String] = []

    private static func key(_ path: String, _ width: CGFloat) -> String { "\(Int(width))|\(path)" }

    func image(_ path: String, maxWidth: CGFloat) -> Image? { images[Self.key(path, maxWidth)] }

    func store(_ path: String, data: Data, maxWidth: CGFloat) async -> Image? {
        let pixels = maxWidth * 2
        guard let cg = await Task.detached(priority: .utility, operation: { Self.downsample(data, maxPixels: pixels) }).value else { return nil }
        #if canImport(UIKit)
        let image = Image(uiImage: UIImage(cgImage: cg))
        #else
        let image = Image(nsImage: NSImage(cgImage: cg, size: .zero))
        #endif
        let key = Self.key(path, maxWidth)
        images[key] = image
        order.append(key)
        if order.count > 40 { images[order.removeFirst()] = nil }
        return image
    }

    nonisolated static func downsample(_ data: Data, maxPixels: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// `agent.terminal.output` for one chat, while its reply runs (the Dashboard only).
@MainActor @Observable
final class AgentTerminalWatch {
    private(set) var tail = TerminalTail()
    @ObservationIgnored private var listener: UUID?
    #if DEBUG
    /// `-echo.demoBrowsing`: what the live reply's terminal shows.
    static var demoTail: TerminalTail?
    #endif

    func start(stored: String) {
        guard listener == nil else { return }
        #if DEBUG
        if let demo = Self.demoTail { tail = demo; return }
        #endif
        let client = HermesServeClient.shared
        listener = client.addListener { [weak self] event in
            guard event.type == "agent.terminal.output", client.isSession(event.sessionID, stored: stored),
                  let chunk = event.payload["chunk"]?.string, !chunk.isEmpty else { return }
            self?.tail.append(chunk)
        }
    }

    func stop() {
        if let listener { HermesServeClient.shared.removeListener(listener) }
        listener = nil
    }
}

/// Whether a profile has a running Bot Screen, asked once per profile while the app runs: the
/// live strip offers "Watch Its Screen" only where there is one.
@MainActor
final class BotScreenProbe {
    static let shared = BotScreenProbe()
    private var known: [String: Bool] = [:]

    func hasScreen(profile: String?) async -> Bool {
        let key = profile ?? ""
        if let answer = known[key] { return answer }
        var params: [String: JSONValue] = [:]
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        guard let result = try? await HermesServeClient.shared.call("display.status", params: .object(params), timeout: 10) else {
            known[key] = false
            return false
        }
        let status = BotScreen.Status(result)
        let answer = status.supported && status.installed
        known[key] = answer
        return answer
    }
}
