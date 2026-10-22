import SwiftUI
import WebKit

/// `::preview{file="page.html"}`: a page the agent wrote, live in its reply as the Hermes desktop
/// app shows it (its `inline-preview-directive.tsx`). Scripts run and the page is interactive,
/// but it is kept apart from the app: its own web view, nothing stored between visits, links
/// opened outside. The app's colours reach it as CSS variables (`--foreground`,
/// `--muted-foreground`, `--accent`, `--border`, `--card`) before the page's own styles, so a
/// widget reads as part of the chat and a full page keeps its own look. It is as tall as its
/// content (120 to 1200 points, scrolling past that) and as wide as its content first measures.
/// A page talks back with `window.hermes.send(prompt)` or `data-hermes-send` on anything it can
/// tap: the agent gets the prompt as a turn of its own with no bubble for it
/// (`Conversation.sendFromPage`), answers by writing the page again, and the page is read again.
struct AgentPage: View {
    let attachment: Attachment
    /// The reply it is in, which the page's answers update.
    let messageID: UUID

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.lazyWebBlocks) private var lazy
    @Environment(\.sendFromPage) private var sendFromPage
    @Environment(Toaster.self) private var toaster: Toaster?
    @State private var height: CGFloat
    @State private var width: CGFloat?
    @State private var html = ""
    @State private var drawnScheme: ColorScheme?
    /// Booted once on screen (or at once without a remembered height), as diagrams are.
    @State private var nearViewport: Bool
    private let heightKey: String

    init(attachment: Attachment, messageID: UUID) {
        self.attachment = attachment
        self.messageID = messageID
        heightKey = WebBlockHeights.key(kind: "page", source: "\(messageID.uuidString) \(attachment.page ?? attachment.filename)")
        let remembered = WebBlockHeights.height(for: heightKey)
        _height = State(initialValue: remembered ?? PageChrome.startHeight)
        _nearViewport = State(initialValue: remembered == nil)
    }

    /// The page is made again only when one of these changes (a new file, the appearance).
    private struct Key: Equatable {
        let page: UUID
        let dark: Bool
        let theme: ResolvedTheme
    }

    private var key: Key { Key(page: attachment.id, dark: (drawnScheme ?? colorScheme) == .dark, theme: theme) }

    var body: some View {
        Group {
            if !lazy || nearViewport, !html.isEmpty {
                PageWebView(html: html, heightKey: heightKey, height: $height, width: $width, onSend: send)
            } else {
                RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04))
            }
        }
        .frame(maxWidth: width ?? .infinity, alignment: .leading)
        .frame(height: height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.2), value: height)
        .modifier(StableColorScheme(drawn: $drawnScheme))
        .onChange(of: key, initial: true) { html = page() }
        // Written again by the agent: measured again, as a new page.
        .onChange(of: attachment.id) { width = nil }
        .onScrollVisibilityChange(threshold: 0.01) { if $0 { nearViewport = true } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(attachment.filename)
    }

    private func page() -> String {
        let dark = (drawnScheme ?? colorScheme) == .dark
        let vars: [(String, String)] = [
            ("--foreground", PageChrome.css(theme.textColor, dark: dark)),
            ("--muted-foreground", PageChrome.css(.secondary, dark: dark)),
            ("--accent", PageChrome.css(theme.accent, dark: dark)),
            ("--border", PageChrome.css(Color(.separator), dark: dark)),
            ("--card", PageChrome.css(theme.surfaceColor, dark: dark)),
        ]
        let doc = String(decoding: attachment.data, as: UTF8.self)
        return PageChrome.framed(doc, prelude: PageChrome.prelude(vars: vars, dark: dark, monospaced: theme.palette.monoFontName != nil))
    }

    private func send(_ prompt: String) -> Bool {
        guard let sendFromPage, let page = attachment.page else { return false }
        switch sendFromPage.send(prompt, page, messageID) {
        case .sent: return true
        case .busy:
            toaster?.show("Wait for the reply, then try again")
            return false
        case .unavailable:
            toaster?.show("This page can't reach the agent from here")
            return false
        }
    }

    /// A fetched page as the reply keeps it: the page's path beside its bytes, to read it again from.
    static func attachment(_ fetched: Attachment, from path: String) -> Attachment {
        var page = Attachment(kind: .text, filename: fetched.filename, mimeType: "text/html", data: fetched.data)
        page.page = path
        return page
    }
}

/// What came of a page's message (`Conversation.sendFromPage`).
nonisolated enum PageSend: Sendable { case sent, busy, unavailable }

/// What a page may send, checked as the desktop app checks it (`evaluateIntent`): a sentence,
/// not a payload, at the speed of a hand. Anything else is refused back to the page with the
/// reason, never cut short or dropped behind its back.
nonisolated enum PageIntent {
    static let maxLength = 500
    static let interval: TimeInterval = 1

    /// What `hermes.send()` resolves to inside the page.
    struct Ack: Equatable {
        var error: String?
        var maxLength: Int?
        var retryAfterMs: Int?
        static let ok = Ack()
        static let undelivered = Ack(error: "undelivered")
        var object: [String: Any] {
            guard let error else { return ["ok": true] }
            var out: [String: Any] = ["ok": false, "error": error]
            if let maxLength { out["maxLength"] = maxLength }
            if let retryAfterMs { out["retryAfterMs"] = retryAfterMs }
            return out
        }
    }

    enum Decision: Equatable {
        case accept(String)
        case reject(Ack)
    }

    static func evaluate(_ body: Any?, now: Date, lastAccepted: Date?) -> Decision {
        let prompt = (body as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if prompt.isEmpty { return .reject(Ack(error: "invalid")) }
        if prompt.count > maxLength { return .reject(Ack(error: "too_long", maxLength: maxLength)) }
        if let lastAccepted, now.timeIntervalSince(lastAccepted) < interval {
            return .reject(Ack(error: "throttled", retryAfterMs: Int(((interval - now.timeIntervalSince(lastAccepted)) * 1000).rounded(.up))))
        }
        return .accept(prompt)
    }
}

/// The page around what the agent wrote: the app's look first, so the page's own styles win, and
/// the two scripts the desktop app adds, here in their own worlds.
nonisolated enum PageChrome {
    static let minHeight: CGFloat = 120
    static let maxHeight: CGFloat = 1200
    static let startHeight: CGFloat = 280
    /// Changes smaller than this are rounding, and a page sized by the screen would otherwise
    /// chase its own height.
    static let tolerance: CGFloat = 4

    static func prelude(vars: [(String, String)], dark: Bool, monospaced: Bool) -> String {
        let tokens = vars.map { "\($0.0):\($0.1)" }.joined(separator: ";")
        let font = monospaced ? "ui-monospace,Menlo,monospace" : "-apple-system,system-ui,sans-serif"
        return "<style>:root{color-scheme:\(dark ? "dark" : "light");\(tokens)}"
            + "html,body{margin:0;padding:0;background:transparent;color:var(--foreground,inherit);font-family:\(font);-webkit-text-size-adjust:100%}</style>"
    }

    /// The prelude goes after a doctype, so the page keeps the standards mode it asked for, and a
    /// page that doesn't say how wide it is drawn for the phone's width, not a desktop's.
    static func framed(_ doc: String, prelude: String) -> String {
        var head = prelude
        if doc.range(of: #"<meta[^>]+name\s*=\s*["']?viewport"#, options: [.regularExpression, .caseInsensitive]) == nil {
            head = #"<meta name="viewport" content="width=device-width, initial-scale=1">"# + head
        }
        if let doctype = doc.range(of: #"^\s*<!doctype[^>]*>"#, options: [.regularExpression, .caseInsensitive]) {
            return String(doc[..<doctype.upperBound]) + head + String(doc[doctype.upperBound...])
        }
        return head + doc
    }

    /// A colour as CSS, in the appearance the page is drawn in.
    static func css(_ color: Color, dark: Bool) -> String {
        let ui = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        let c = [r, g, b].map { Int((min(max($0, 0), 1) * 255).rounded()) }
        return a >= 0.999 ? String(format: "#%02X%02X%02X", c[0], c[1], c[2])
            : String(format: "rgba(%d,%d,%d,%.3f)", c[0], c[1], c[2], Double(a))
    }

    /// In the page's own world, so the page can call it: `hermes.send(prompt)` answers with the
    /// app's verdict, and a tap on anything with `data-hermes-send` sends that.
    static let bridge = """
    (function(){
      function send(p) {
        if (typeof p !== 'string' || !p.trim()) return Promise.resolve({ ok: false, error: 'invalid' });
        try {
          return window.webkit.messageHandlers.hermes.postMessage(p)
            .catch(function () { return { ok: false, error: 'undelivered' }; });
        } catch (e) { return Promise.resolve({ ok: false, error: 'undelivered' }); }
      }
      window.hermes = { send: send, maxLength: \(PageIntent.maxLength) };
      addEventListener('click', function (e) {
        var el = e.target && e.target.closest ? e.target.closest('[data-hermes-send]') : null;
        if (el) send(el.getAttribute('data-hermes-send') || '');
      }, true);
    })();
    """

    /// In a world of the app's own, out of the page's reach: the content's height (the body, not
    /// the screen it fills) and its width (the span of what the body holds).
    static let measure = """
    (function(){
      var lastH = 0, lastW = 0;
      function post() {
        var b = document.body;
        if (!b) return;
        var L = Infinity, R = 0, B = 0, kids = b.children;
        for (var i = 0; i < kids.length; i++) {
          var r = kids[i].getBoundingClientRect();
          if (r.width === 0 && r.height === 0) continue;
          if (r.left < L) L = r.left;
          if (r.right > R) R = r.right;
          if (r.bottom + window.scrollY > B) B = r.bottom + window.scrollY;
        }
        var s = getComputedStyle(b);
        var h = Math.ceil(Math.max(b.scrollHeight, B + parseFloat(s.paddingBottom || 0) + parseFloat(s.marginBottom || 0)));
        var w = R > L ? Math.ceil(R - L) : 0;
        if (Math.abs(h - lastH) > 1 || Math.abs(w - lastW) > 1) {
          lastH = h; lastW = w;
          window.webkit.messageHandlers.pageSize.postMessage({ height: h, width: w });
        }
      }
      window.__reddeMeasure = function () { lastH = 0; lastW = 0; post(); };
      if (typeof ResizeObserver === 'function') {
        var ro = new ResizeObserver(post);
        ro.observe(document.documentElement);
        if (document.body) ro.observe(document.body);
      }
      addEventListener('load', post);
      post();
    })();
    """
}

/// Sends what a page in a reply says to the agent (`Conversation.sendFromPage`): the prompt, the
/// page's path and the reply it is in. The same for as long as the conversation is.
struct PageSender: Equatable {
    let conversation: UUID
    let send: @MainActor (String, String, UUID) -> PageSend

    static func == (a: PageSender, b: PageSender) -> Bool { a.conversation == b.conversation }
}

extension EnvironmentValues {
    /// Unset where a page can't talk back.
    @Entry var sendFromPage: PageSender? = nil
}

/// The web view a page lives in.
struct PageWebView: UIViewRepresentable {
    let html: String
    let heightKey: String
    @Binding var height: CGFloat
    @Binding var width: CGFloat?
    let onSend: (String) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PageView {
        let config = WKWebViewConfiguration()
        // Nothing a page keeps outlives it.
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.dataDetectorTypes = []
        let content = config.userContentController
        content.addUserScript(WKUserScript(source: PageChrome.bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        content.addUserScript(WKUserScript(source: PageChrome.measure, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        content.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "hermes")
        content.add(context.coordinator, contentWorld: .defaultClient, name: "pageSize")
        let view = PageView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.bounces = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        #if DEBUG
        view.isInspectable = true
        #endif
        context.coordinator.view = view
        update(context.coordinator)
        view.show(html)
        return view
    }

    func updateUIView(_ view: PageView, context: Context) {
        update(context.coordinator)
        view.show(html)
    }

    private func update(_ coordinator: Coordinator) {
        coordinator.heightKey = heightKey
        coordinator.height = $height
        coordinator.width = $width
        coordinator.onSend = onSend
    }

    static func dismantleUIView(_ view: PageView, coordinator: Coordinator) {
        view.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    /// Loads only once it has a width: a page laid out at none measures as one tall column.
    final class PageView: WKWebView {
        private var shown = ""
        private var waiting: String?
        private var lastWidth: CGFloat = 0

        func show(_ html: String) {
            guard html != shown, html != waiting else { return }
            if bounds.width > 0 { load(html) } else { waiting = html }
        }

        private func load(_ html: String) {
            shown = html
            waiting = nil
            loadHTMLString(html, baseURL: nil)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard abs(bounds.width - lastWidth) > 0.5 else { return }
            lastWidth = bounds.width
            if let waiting, bounds.width > 0 { load(waiting); return }
            // Off screen a page gets no resize callbacks of its own; measure again.
            evaluateJavaScript("window.__reddeMeasure && window.__reddeMeasure()", in: nil, in: .defaultClient, completionHandler: nil)
        }
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKScriptMessageHandlerWithReply, WKNavigationDelegate, WKUIDelegate {
        weak var view: PageView?
        var heightKey = ""
        var height: Binding<CGFloat>?
        var width: Binding<CGFloat?>?
        var onSend: ((String) -> Bool)?
        private var lastAccepted: Date?

        // The page's size.
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "pageSize", let body = message.body as? [String: Any],
                  let reported = (body["height"] as? NSNumber).map({ CGFloat(truncating: $0) }), reported > 0,
                  let view, view.bounds.width > 0 else { return }
            let h = min(PageChrome.maxHeight, max(PageChrome.minHeight, reported.rounded()))
            if let height, abs(h - height.wrappedValue) > PageChrome.tolerance {
                height.wrappedValue = h
                WebBlockHeights.store(h, for: heightKey)
            }
            // Its width once, from the first report, at the reply's full width: a widget of a set
            // size sits to the left like a picture, a page that fills what it's given stays wide.
            // Following it after would shrink a page made of percentages a little each time.
            if let w = (body["width"] as? NSNumber).map({ CGFloat(truncating: $0) }), w > 0, let width, width.wrappedValue == nil {
                width.wrappedValue = w.rounded(.up)
            }
            view.scrollView.isScrollEnabled = reported > PageChrome.maxHeight || view.scrollView.contentSize.width > view.bounds.width + 1
        }

        // What the page sends.
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
            guard message.frameInfo.isMainFrame else { replyHandler(PageIntent.Ack.undelivered.object, nil); return }
            switch PageIntent.evaluate(message.body, now: .now, lastAccepted: lastAccepted) {
            case let .reject(ack):
                replyHandler(ack.object, nil)
            case let .accept(prompt):
                lastAccepted = .now
                replyHandler((onSend?(prompt) == true ? PageIntent.Ack.ok : .undelivered).object, nil)
            }
        }

        // Kept in place: links open outside, frames inside it load, and the page itself never
        // goes anywhere else.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated {
                if let url = action.request.url, ["http", "https", "mailto", "tel"].contains(url.scheme?.lowercased() ?? "") {
                    UIApplication.shared.open(url)
                }
                decisionHandler(.cancel)
                return
            }
            let blank = action.request.url?.absoluteString == "about:blank"
            decisionHandler(blank || action.targetFrame?.isMainFrame == false ? .allow : .cancel)
        }

        // `window.open` and `target="_blank"`: outside the app.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if action.navigationType == .linkActivated, let url = action.request.url,
               ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                UIApplication.shared.open(url)
            }
            return nil
        }
    }
}
