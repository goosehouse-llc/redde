import Foundation

/// Watching the agent work (asked 2026-11-02, after Nous's Hermes Mobile beta): what the agent's
/// browser and screen did in a reply, read from the reply's own tool steps. Nothing new is asked
/// of the host for this: a step already keeps what its tool was called with and, on the
/// Dashboard, what it returned (`ToolActivity.args` / `.output`, each as `key: value` lines,
/// `ToolActivity.detail`). So it works on both connections, live and read back; the Hermes API
/// sends no results, so there a page is known by the address it was asked for.
///
/// Hermes's browser tools (0.21–0.22, `tools/browser_tool.py`): `browser_navigate` returns
/// `{url, title}`, `browser_back` `{url}`, `browser_vision` an analysis and a `screenshot_path`,
/// `computer_use` (Bot Desktop) a `screenshot_path` with each capture.
nonisolated enum AgentBrowsing {
    struct Step: Identifiable, Equatable, Sendable {
        enum Kind: String, Equatable, Sendable {
            case open, back, click, type, press, scroll, read, look, images, console, screen, other
        }
        var id: UUID
        var kind: Kind
        var tool: String
        /// The page this step was on or went to, as far as the step says.
        var url: String?
        var title: String?
        /// A picture of the page or screen, on the gateway host (Dashboard only).
        var screenshotPath: String?
        /// A word about the step that isn't the page: the key pressed, the way scrolled, the
        /// question asked of a picture. Never what was typed: it may be a password.
        var note: String?
        var status: ToolActivity.Status
        var startedAt: Date?
    }

    /// The tools that are the agent's browser or screen.
    static func isBrowsing(_ name: String) -> Bool {
        name.hasPrefix("browser_") || name == "computer_use"
    }

    /// The tools that draw on Bot Desktop's screen (the browser does when Hermes runs it headed).
    static func usesScreen(_ name: String) -> Bool {
        name == "computer_use" || name.hasPrefix("browser_")
    }

    /// A reply's browsing, in order.
    static func steps(_ tools: [ToolActivity]) -> [Step] {
        tools.compactMap(step)
    }

    static func step(_ tool: ToolActivity) -> Step? {
        guard isBrowsing(tool.name) else { return nil }
        let args = fields(in: tool.args)
        let out = fields(in: tool.output)
        var step = Step(id: tool.id, kind: kind(tool.name), tool: tool.name, status: tool.status, startedAt: tool.startedAt)
        // The page: where it ended up (a redirect), else where it was sent.
        step.url = (out["url"] ?? out["final_url"] ?? args["url"]).flatMap(cleanURL)
        step.title = (out["title"] ?? out["page_title"])?.nilIfEmpty
        step.screenshotPath = (out["screenshot_path"] ?? out["screenshot"]).flatMap(cleanPath)
        switch step.kind {
        case .press: step.note = args["key"]?.nilIfEmpty
        case .scroll: step.note = args["direction"]?.nilIfEmpty
        case .look: step.note = args["question"]?.nilIfEmpty
        case .screen: step.note = args["action"]?.nilIfEmpty
        default: break
        }
        return step
    }

    private static func kind(_ name: String) -> Step.Kind {
        switch name {
        case "browser_navigate": .open
        case "browser_back": .back
        case "browser_click": .click
        case "browser_type": .type
        case "browser_press": .press
        case "browser_scroll": .scroll
        case "browser_snapshot": .read
        case "browser_vision": .look
        case "browser_get_images": .images
        case "browser_console": .console
        case "computer_use": .screen
        default: .other
        }
    }

    /// The `key: value` lines `ToolActivity.detail` writes an object as. A value written over
    /// several lines (`key:` then the text) is left out: no field read here is one.
    static func fields(in text: String?) -> [String: String] {
        guard let text, !text.isEmpty else { return [:] }
        var out: [String: String] = [:]
        // A step's text is capped at 12,000 characters; the fields wanted are short and sorted
        // among the first, but a long snapshot could come before them, so read every line.
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon]
            guard !key.isEmpty, key.count <= 32, key.allSatisfy({ $0.isLetter || $0 == "_" }) else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, out[String(key)] == nil else { continue }
            out[String(key)] = value
        }
        return out
    }

    private static func cleanURL(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        guard !text.isEmpty, text != "about:blank" else { return nil }
        return text
    }

    private static func cleanPath(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        return text.hasPrefix("/") || text.hasPrefix("~") ? text : nil
    }

    // MARK: What a reply's browsing comes to

    /// Where the agent's browser is now: the last page a step named, with the title the last
    /// step on that page gave it.
    static func currentPage(_ steps: [Step]) -> (url: String, title: String?)? {
        guard let last = steps.last(where: { $0.url != nil }), let url = last.url else { return nil }
        let title = steps.last(where: { $0.url == url && $0.title != nil })?.title
        return (url, title)
    }

    /// The newest picture of the page or screen.
    static func latestScreenshot(_ steps: [Step]) -> String? {
        steps.last(where: { $0.screenshotPath != nil })?.screenshotPath
    }

    /// The pages visited, each once, in the order first seen.
    static func pages(_ steps: [Step]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for url in steps.compactMap(\.url) where seen.insert(url).inserted { out.append(url) }
        return out
    }

    /// "Browsed 4 pages", "Browsed a page", or the screen's own line when no page was named.
    static func summary(_ steps: [Step]) -> String {
        let count = pages(steps).count
        if count == 0 {
            return steps.contains { $0.kind == .screen }
                ? String(localized: "Used its screen", comment: "A reply's line when the agent drove its Bot Desktop screen")
                : String(localized: "Used its browser", comment: "A reply's line when the agent used its browser without naming a page")
        }
        return String(localized: "Browsed \(count) pages", comment: "A reply's line: how many web pages the agent visited")
    }

    /// A page's address the way a person reads it: the host and path, no scheme or `www.`.
    static func shortURL(_ url: String) -> String {
        guard let comps = URLComponents(string: url), let host = comps.host, !host.isEmpty else { return url }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let path = comps.path == "/" ? "" : comps.path
        return bare + path
    }

    /// What the step did, in a few words.
    static func label(_ step: Step) -> String {
        switch step.kind {
        case .open: String(localized: "Opened", comment: "A browser step: the agent opened a page")
        case .back: String(localized: "Went back", comment: "A browser step")
        case .click: String(localized: "Clicked", comment: "A browser step")
        case .type: String(localized: "Typed into the page", comment: "A browser step; what was typed is never shown")
        case .press: String(localized: "Pressed a key", comment: "A browser step")
        case .scroll: String(localized: "Scrolled", comment: "A browser step")
        case .read: String(localized: "Read the page", comment: "A browser step: the agent took the page's text")
        case .look: String(localized: "Looked at the page", comment: "A browser step: the agent took a picture of the page")
        case .images: String(localized: "Listed the page's pictures", comment: "A browser step")
        case .console: String(localized: "Read the page's console", comment: "A browser step")
        case .screen: String(localized: "Used its screen", comment: "A Bot Desktop step")
        case .other: String(localized: "Used its browser", comment: "A browser step of a kind Redde doesn't name")
        }
    }
}

/// The output of the agent's background processes (`agent.terminal.output`, the Dashboard only),
/// kept to the last lines: what a long build or a server it started is printing while it works.
nonisolated struct TerminalTail: Equatable, Sendable {
    static let keep = 40
    private(set) var lines: [String] = []
    private var partial = ""

    var isEmpty: Bool { lines.isEmpty && partial.isEmpty }

    /// The lines to show, the unfinished one last.
    var shown: [String] { partial.isEmpty ? lines : lines + [partial] }

    mutating func append(_ chunk: String) {
        let clean = Self.stripControl(chunk)
        var text = partial + clean
        partial = ""
        // A carriage return without a newline rewrites the line (a progress bar): keep the last.
        let pieces = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, piece) in pieces.enumerated() {
            let line = String(piece.split(separator: "\r", omittingEmptySubsequences: false).last ?? "")
            if index == pieces.count - 1 { partial = line } else { lines.append(line) }
        }
        if lines.count > Self.keep { lines.removeFirst(lines.count - Self.keep) }
        if partial.count > 400 { partial = String(partial.suffix(400)) }
        text = ""
    }

    /// Terminal colour and cursor codes (`ESC [ … letter`, `ESC ] … BEL`) taken out.
    static func stripControl(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        var out = String.UnicodeScalarView()
        var scalars = text.unicodeScalars.makeIterator()
        while let c = scalars.next() {
            guard c == "\u{1B}" else { out.append(c); continue }
            guard let next = scalars.next() else { break }
            if next == "[" {
                while let n = scalars.next(), !(0x40...0x7E).contains(n.value) {}
            } else if next == "]" {
                while let n = scalars.next(), n != "\u{07}", n != "\u{1B}" {}
            }
        }
        return String(out)
    }
}
