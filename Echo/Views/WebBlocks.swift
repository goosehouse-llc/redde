import SwiftUI
import WebKit

/// Mermaid diagrams and KaTeX math render in a small WKWebView with the libraries bundled
/// (offline, no CDN). The page reports its height so the block sizes itself in the transcript.
@MainActor
enum WebBlockAssets {
    /// Pages load from this origin; the scheme handler maps paths onto the bundled Web folder.
    static let scheme = "redde-web"
    static let baseURL = URL(string: "\(scheme)://assets/")!
    static let handler = BundleSchemeHandler()

    /// Serves files under Resources/Web to the page. WebKit refuses file:// subresources from
    /// an HTML string, so a private scheme is the sandbox-friendly way to reach the bundle.
    final class BundleSchemeHandler: NSObject, WKURLSchemeHandler {
        private let root = Bundle.main.resourceURL?.appending(path: "Web")

        func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
            guard let root, let url = task.request.url else { task.didFailWithError(URLError(.badURL)); return }
            let relative = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let file = root.appending(path: relative).standardizedFileURL
            guard file.path.hasPrefix(root.standardizedFileURL.path), let data = try? Data(contentsOf: file) else {
                task.didFailWithError(URLError(.fileDoesNotExist)); return
            }
            let type: String
            switch file.pathExtension {
            case "js": type = "application/javascript"
            case "css": type = "text/css"
            case "woff2": type = "font/woff2"
            case "svg": type = "image/svg+xml"
            default: type = "application/octet-stream"
            }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": type, "Content-Length": String(data.count), "Cache-Control": "max-age=86400"])!
            task.didReceive(response)
            task.didReceive(data)
            task.didFinish()
        }

        func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
    }

    /// - layout: JavaScript that sizes the content itself (diagrams); without it, content wider
    ///   than the block is scaled down by `fit()` (formulas).
    /// - zoomable: a full-screen page the reader can pinch and pan, with no size reporting.
    static func page(body: String, script: String, dark: Bool, textColor: String,
                     layout: String? = nil, zoomable: Bool = false) -> String {
        let viewport = zoomable
            ? "width=device-width, initial-scale=1, minimum-scale=1, maximum-scale=6, user-scalable=yes"
            : "width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="\(viewport)">
        <link rel="stylesheet" href="katex.min.css">
        <style>
          :root { color-scheme: \(dark ? "dark" : "light"); }
          html, body { margin: 0; padding: 0; background: transparent; color: \(textColor);
            font: -apple-system-body; -webkit-text-size-adjust: none; }
          body { padding: \(zoomable ? "16px 12px" : "4px 2px"); overflow: \(zoomable ? "visible" : "hidden"); }
          #root { display: block; width: 100%; \(zoomable ? "text-align: center; min-height: calc(100vh - 32px); display: flex; align-items: center; justify-content: center;" : "") }
          #fit { display: inline-block; transform-origin: left top; }
          .err { font: 12px ui-monospace, monospace; color: #c0392b; white-space: pre-wrap; }
          .katex-display { margin: 0.2em 0; overflow: visible; }
          .katex-display > .katex { white-space: nowrap; display: inline-block; text-align: left; }
          svg { max-width: 100%; height: auto; }
        </style></head><body><div id="root"><div id="fit">\(body)</div></div>
        <script>
          // Shrink content wider than the bubble (long formulas) down to 55%, then let it scroll.
          function fit() {
            const root = document.getElementById('root'), el = document.getElementById('fit');
            el.style.transform = '';
            let w = el.scrollWidth;
            el.querySelectorAll('*').forEach(n => { const r = n.getBoundingClientRect(); w = Math.max(w, r.right - el.getBoundingClientRect().left); });
            const avail = root.clientWidth;
            if (w > avail && avail > 0) {
              const k = Math.max(0.55, avail / w);
              el.style.transform = 'scale(' + k + ')';
              root.style.height = Math.ceil(el.getBoundingClientRect().height) + 'px';
              root.style.overflowX = k <= 0.55 ? 'auto' : 'hidden';
            } else { root.style.height = ''; root.style.overflowX = 'hidden'; }
          }
          \(layout.map { "function layout() { \($0) }" } ?? "")
          function report() {
            if (typeof layout === 'function') layout(); else fit();
            const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.size;
            if (!handler) return;
            const h = Math.ceil(document.getElementById('root').getBoundingClientRect().height) + 8;
            handler.postMessage(h);
          }
          // Heights go out only once the content is drawn: an empty page mid-load would
          // collapse a block that opened at its remembered size.
          function drawn() { window.__drawn = true; report(); }
          window.addEventListener('load', () => { \(script) });
          new ResizeObserver(() => { if (window.__drawn) report(); }).observe(document.getElementById('root'));
          // A tap (not a drag) on an inline block asks the app to open it full screen.
          document.addEventListener('click', () => {
            const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.size;
            if (handler && window.__drawn) handler.postMessage('tap');
          });
        </script></body></html>
        """
    }
}

/// Last drawn height of each diagram and math block, kept across launches. A block opens at its
/// real size instead of a placeholder, so the transcript doesn't jump when drawing finishes.
@MainActor
enum WebBlockHeights {
    private static let defaultsKey = "webBlockHeights"
    private static let limit = 400
    private static var heights = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Double] ?? [:]
    private static var saveTask: Task<Void, Never>?

    /// A stable key for a block's source (Swift's own hash changes every launch).
    static func key(kind: String, source: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in source.utf8 { hash ^= UInt64(byte); hash &*= 0x0000_0100_0000_01b3 }
        return "\(kind)-\(String(hash, radix: 36))"
    }

    static func height(for key: String) -> CGFloat? { heights[key].map { CGFloat($0) } }

    static func store(_ height: CGFloat, for key: String) {
        if let old = heights[key], abs(old - Double(height)) <= 1 { return }
        if heights[key] == nil, heights.count >= limit { heights.removeAll(keepingCapacity: true) }
        heights[key] = Double(height)
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            UserDefaults.standard.set(heights, forKey: defaultsKey)
        }
    }

    /// Part of "Erase everything".
    static func clear() {
        saveTask?.cancel()
        heights = [:]
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}

/// UIKit bridge: transparent, non-scrolling, height reported by the page.
struct WebBlock: UIViewRepresentable {
    let html: String
    /// Where the drawn height is remembered (see WebBlockHeights); nil keeps it in the view only.
    var heightKey: String? = nil
    @Binding var height: CGFloat
    /// Called when the reader taps the drawn content.
    var onTap: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(height: $height, heightKey: heightKey) }

    func makeUIView(context: Context) -> BlockWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(WebBlockAssets.handler, forURLScheme: WebBlockAssets.scheme)
        config.userContentController.add(context.coordinator, name: "size")
        let view = BlockWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.scrollView.bounces = false
        // Inside the transcript the block can sit under the bars; safe-area insets applied to its
        // own scroll view shifted the drawing down, leaving the block blank.
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.navigationDelegate = context.coordinator
        view.isAccessibilityElement = false
        // A page drawn before the block had a width reports a wrong height and, off screen, gets
        // no resize callbacks; measure again whenever the width changes.
        view.onWidthChange = { [weak view] in
            view?.evaluateJavaScript("if (window.__drawn) report();", completionHandler: nil)
        }
        context.coordinator.onTap = onTap
        context.coordinator.load(html, into: view)
        return view
    }

    func updateUIView(_ view: BlockWebView, context: Context) {
        context.coordinator.heightKey = heightKey
        context.coordinator.onTap = onTap
        context.coordinator.load(html, into: view)
    }

    final class BlockWebView: WKWebView {
        var onWidthChange: (() -> Void)?
        private var lastWidth: CGFloat = 0

        override func layoutSubviews() {
            super.layoutSubviews()
            guard abs(bounds.width - lastWidth) > 0.5 else { return }
            lastWidth = bounds.width
            onWidthChange?()
        }
    }

    static func dismantleUIView(_ view: BlockWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "size")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private var height: Binding<CGFloat>
        var heightKey: String?
        var onTap: (() -> Void)?
        /// What the page is showing.
        private var loaded = ""
        /// What is waiting out the quiet period, if anything.
        private var queued: String?
        private var pending: Task<Void, Never>?

        init(height: Binding<CGFloat>, heightKey: String?) {
            self.height = height
            self.heightKey = heightKey
        }

        /// First load is immediate; later changes wait for 400 ms of quiet so a block that is
        /// still being edited (or streamed) doesn't reload the page on every change.
        func load(_ html: String, into view: WKWebView) {
            if html == loaded {
                // Back to what's showing: drop any redraw queued on the way.
                pending?.cancel(); pending = nil; queued = nil
                return
            }
            if loaded.isEmpty {
                loaded = html
                view.loadHTMLString(html, baseURL: WebBlockAssets.baseURL)
                return
            }
            guard html != queued else { return }
            pending?.cancel()
            queued = html
            pending = Task { [weak self, weak view] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, let self, let view else { return }
                self.queued = nil
                self.loaded = html
                view.loadHTMLString(html, baseURL: WebBlockAssets.baseURL)
            }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.body as? String == "tap" { onTap?(); return }
            guard let n = message.body as? NSNumber else { return }
            let h = max(24, CGFloat(truncating: n))
            if let heightKey { WebBlockHeights.store(h, for: heightKey) }
            if abs(h - height.wrappedValue) > 1 { height.wrappedValue = h }
        }

        // Keep the page sealed: links open outside, nothing else navigates.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if action.navigationType == .linkActivated, let url = action.request.url {
                await UIApplication.shared.open(url)
                return .cancel
            }
            return .allow
        }
    }
}

/// The appearance a diagram or math page is drawn in. Leaving the app, iOS flips the
/// appearance to light and dark to snapshot the app switcher; following that redrew every block
/// (sometimes leaving the wrong colours) and resized rows on return. While the scene isn't
/// active the last active appearance is kept.
private struct StableColorScheme: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Binding var drawn: ColorScheme?

    func body(content: Content) -> some View {
        content
            .onAppear { if drawn == nil || scenePhase == .active { drawn = colorScheme } }
            .onChange(of: colorScheme) { _, scheme in if scenePhase == .active { drawn = scheme } }
            .onChange(of: scenePhase) { _, phase in if phase == .active { drawn = colorScheme } }
    }
}

/// The inputs a block's page is built from. Built once per change, not per body pass: the page
/// string is multi-KB and a diagram above the streaming paragraph is re-evaluated 20x a second.
private struct PageKey: Equatable {
    let source: String
    let dark: Bool
    var theme: ResolvedTheme? = nil
}

extension EnvironmentValues {
    /// Set by the transcript scroll views: web blocks there boot only near the viewport. Off
    /// elsewhere (a Kanban card is a List, where `onScrollVisibilityChange` never fires).
    @Entry var lazyWebBlocks = false
}

/// ```mermaid``` fence: diagram with a Source toggle and copy.
struct MermaidBlock: View {
    let source: String
    private let heightKey: String
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @State private var height: CGFloat
    @State private var html = ""
    @State private var showSource = false
    @State private var copied = false
    @State private var drawnScheme: ColorScheme?
    @State private var expanded = false
    /// The web view boots only once the block has been on screen (and stays, so scrolling back
    /// doesn't reload it). The page isn't lazy, so without this every diagram in a session would
    /// load mermaid.js on open. A block with no remembered height boots at once instead: its
    /// first height report would otherwise shift the page under a finger scrolling back.
    @State private var nearViewport: Bool
    @Environment(\.lazyWebBlocks) private var lazy

    init(source: String) {
        self.source = source
        heightKey = WebBlockHeights.key(kind: "mermaid", source: source)
        let remembered = WebBlockHeights.height(for: heightKey)
        _height = State(initialValue: remembered ?? 80)
        _nearViewport = State(initialValue: remembered == nil)
    }

    /// Inline, a diagram keeps its natural size when it fits, shrinks to no less than 75% when
    /// it doesn't, and scrolls sideways past that, so its text stays readable. Full screen, it
    /// starts fitted to the width (up to 2x for small diagrams) and the reader zooms from there.
    private static let inlineLayout = """
      const root = document.getElementById('root'), svg = document.querySelector('#fit svg');
      if (!svg) { root.style.height = ''; return; }
      const vb = (svg.getAttribute('viewBox') || '').split(/[\\s,]+/).map(Number);
      const w = vb.length === 4 && vb[2] > 0 ? vb[2] : svg.getBBox().width;
      const h = vb.length === 4 && vb[3] > 0 ? vb[3] : svg.getBBox().height;
      const avail = root.clientWidth;
      const k = avail > 0 ? Math.max(0.75, Math.min(1, avail / w)) : 1;
      svg.removeAttribute('height'); svg.style.maxWidth = 'none';
      svg.style.width = (w * k) + 'px'; svg.style.height = (h * k) + 'px';
      root.style.height = ''; root.style.overflowX = w * k > avail + 1 ? 'auto' : 'hidden';
    """

    private static let zoomLayout = """
      const svg = document.querySelector('#fit svg');
      if (!svg) return;
      const vb = (svg.getAttribute('viewBox') || '').split(/[\\s,]+/).map(Number);
      const w = vb.length === 4 && vb[2] > 0 ? vb[2] : svg.getBBox().width;
      const h = vb.length === 4 && vb[3] > 0 ? vb[3] : svg.getBBox().height;
      const k = Math.min(2, (window.innerWidth - 24) / w);
      svg.removeAttribute('height'); svg.style.maxWidth = 'none';
      svg.style.width = (w * k) + 'px'; svg.style.height = (h * k) + 'px';
    """

    /// Diagram colours follow the app: node fills are a tint of the accent, borders the accent,
    /// text and lines chosen for contrast on the current background.
    private var themeVariables: String {
        let dark = (drawnScheme ?? colorScheme) == .dark
        let accent = UIColor(theme.accent)
        let ground = UIColor(theme.background ?? Color(.systemBackground))
        func hex(_ c: UIColor) -> String {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getRed(&r, green: &g, blue: &b, alpha: &a)
            return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
        }
        func mix(_ a: UIColor, _ b: UIColor, _ t: CGFloat) -> UIColor {
            var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
            var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
            a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa); b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
            return UIColor(red: ar + (br - ar) * t, green: ag + (bg - ag) * t, blue: ab + (bb - ab) * t, alpha: 1)
        }
        let text = dark ? UIColor(white: 0.95, alpha: 1) : UIColor(white: 0.11, alpha: 1)
        let fill = mix(ground, accent, dark ? 0.28 : 0.14)
        let alt = mix(ground, accent, dark ? 0.16 : 0.07)
        let line = dark ? UIColor(white: 0.66, alpha: 1) : UIColor(white: 0.40, alpha: 1)
        let vars: [(String, String)] = [
            ("background", "transparent"),
            ("primaryColor", hex(fill)), ("primaryTextColor", hex(text)), ("primaryBorderColor", hex(accent)),
            ("secondaryColor", hex(alt)), ("secondaryTextColor", hex(text)), ("secondaryBorderColor", hex(mix(accent, ground, 0.3))),
            ("tertiaryColor", hex(alt)), ("tertiaryTextColor", hex(text)), ("tertiaryBorderColor", hex(mix(accent, ground, 0.5))),
            ("lineColor", hex(line)), ("textColor", hex(text)),
            ("edgeLabelBackground", hex(mix(ground, accent, dark ? 0.10 : 0.05))),
            ("clusterBkg", hex(alt)), ("clusterBorder", hex(mix(accent, ground, 0.5))),
            ("noteBkgColor", hex(alt)), ("noteTextColor", hex(text)), ("noteBorderColor", hex(mix(accent, ground, 0.4))),
            ("actorBkg", hex(fill)), ("actorBorder", hex(accent)), ("actorTextColor", hex(text)),
            ("signalColor", hex(line)), ("signalTextColor", hex(text)),
            ("labelBoxBkgColor", hex(alt)), ("labelTextColor", hex(text)),
            ("pie1", hex(accent)), ("pie2", hex(mix(accent, ground, 0.35))), ("pie3", hex(mix(accent, ground, 0.6))),
            ("fontSize", "16px"),
        ]
        return "{ " + vars.map { "'\($0.0)': '\($0.1)'" }.joined(separator: ", ") + " }"
    }

    private var pageKey: PageKey { PageKey(source: source, dark: (drawnScheme ?? colorScheme) == .dark, theme: theme) }

    private func page(zoomable: Bool) -> String {
        let dark = (drawnScheme ?? colorScheme) == .dark
        let escaped = source.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "`", with: "\\`").replacingOccurrences(of: "$", with: "\\$")
        return WebBlockAssets.page(
            body: "",
            script: """
              const src = `\(escaped)`;
              const s = document.createElement('script'); s.src = 'mermaid.min.js';
              s.onload = async () => {
                try {
                  mermaid.initialize({ startOnLoad: false, theme: 'base', themeVariables: \(themeVariables), securityLevel: 'strict',
                    fontFamily: '-apple-system, system-ui, sans-serif' });
                  const { svg } = await mermaid.render('d' + Date.now(), src);
                  document.getElementById('fit').innerHTML = svg;
                } catch (e) {
                  document.getElementById('root').innerHTML = '<div class="err">' + String(e.message || e).replace(/</g,'&lt;') + '</div>';
                }
                drawn();
              };
              s.onerror = () => { document.getElementById('root').innerHTML = '<div class="err">mermaid.js failed to load</div>'; drawn(); };
              document.body.appendChild(s);
            """,
            dark: dark, textColor: dark ? "#f2f2f7" : "#1c1c1e",
            layout: zoomable ? Self.zoomLayout : Self.inlineLayout, zoomable: zoomable)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("DIAGRAM").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Button { expanded = true } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption2)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).padding(.trailing, 8)
                .accessibilityLabel("Open diagram full screen")
                Button(showSource ? "Diagram" : "Source") { showSource.toggle() }
                    .font(.caption2).buttonStyle(.plain).foregroundStyle(.secondary)
                Button {
                    UIPasteboard.general.string = source
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc").font(.caption2)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).padding(.leading, 8)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            if showSource {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(source).font(theme.codeFont).padding(.horizontal, 10).padding(.bottom, 10)
                }
            } else {
                Group {
                    if !lazy || nearViewport, !html.isEmpty {
                        WebBlock(html: html, heightKey: heightKey, height: $height, onTap: { expanded = true })
                    } else {
                        Color.clear
                    }
                }
                .frame(height: height)
                .padding(.horizontal, 6).padding(.bottom, 6)
            }
        }
        .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 10))
        .modifier(StableColorScheme(drawn: $drawnScheme))
        .onChange(of: pageKey, initial: true) { html = page(zoomable: false) }
        .onScrollVisibilityChange(threshold: 0.01) { if $0 { nearViewport = true } }
        .fullScreenCover(isPresented: $expanded) {
            DiagramViewer(html: page(zoomable: true), source: source)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mermaid diagram")
        .accessibilityHint("Open it full screen to zoom, or use the Source button to read the diagram text")
    }
}

/// A diagram full screen: pinch to zoom, drag to pan.
struct DiagramViewer: View {
    let html: String
    let source: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZoomableWebView(html: html)
                .ignoresSafeArea(edges: .bottom)
                .background(Color(.systemBackground))
                .navigationTitle("Diagram")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Copy source", systemImage: "doc.on.doc") { UIPasteboard.general.string = source }
                    }
                }
        }
    }
}

/// A web view that scrolls and zooms, for DiagramViewer.
struct ZoomableWebView: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(WebBlockAssets.handler, forURLScheme: WebBlockAssets.scheme)
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.minimumZoomScale = 1
        view.scrollView.maximumZoomScale = 6
        view.accessibilityLabel = "Diagram"
        view.loadHTMLString(html, baseURL: WebBlockAssets.baseURL)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}
}

/// `$$ … $$` block rendered with KaTeX.
struct MathBlock: View {
    let source: String
    private let heightKey: String
    @Environment(\.colorScheme) private var colorScheme
    @State private var height: CGFloat
    @State private var html = ""
    @State private var drawnScheme: ColorScheme?
    /// See MermaidBlock.nearViewport.
    @State private var nearViewport: Bool
    @Environment(\.lazyWebBlocks) private var lazy

    init(source: String) {
        self.source = source
        heightKey = WebBlockHeights.key(kind: "math", source: source)
        let remembered = WebBlockHeights.height(for: heightKey)
        _height = State(initialValue: remembered ?? 40)
        _nearViewport = State(initialValue: remembered == nil)
    }

    private var pageKey: PageKey { PageKey(source: source, dark: (drawnScheme ?? colorScheme) == .dark) }

    private func page() -> String {
        let dark = (drawnScheme ?? colorScheme) == .dark
        let escaped = source.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "`", with: "\\`").replacingOccurrences(of: "$", with: "\\$")
        return WebBlockAssets.page(
            body: "",
            script: """
              const s = document.createElement('script'); s.src = 'katex.min.js';
              s.onload = () => {
                try {
                  katex.render(`\(escaped)`, document.getElementById('fit'), { displayMode: true, throwOnError: false, output: 'html' });
                } catch (e) {
                  document.getElementById('root').innerHTML = '<div class="err">' + String(e.message || e).replace(/</g,'&lt;') + '</div>';
                }
                drawn();
              };
              s.onerror = () => { document.getElementById('fit').textContent = `\(escaped)`; drawn(); };
              document.body.appendChild(s);
            """,
            dark: dark, textColor: dark ? "#f2f2f7" : "#1c1c1e")
    }

    var body: some View {
        Group {
            if !lazy || nearViewport, !html.isEmpty {
                WebBlock(html: html, heightKey: heightKey, height: $height)
            } else {
                Color.clear
            }
        }
        .frame(height: height)
        .modifier(StableColorScheme(drawn: $drawnScheme))
        .onChange(of: pageKey, initial: true) { html = page() }
        .onScrollVisibilityChange(threshold: 0.01) { if $0 { nearViewport = true } }
        .contextMenu { Button("Copy LaTeX", systemImage: "doc.on.doc") { UIPasteboard.general.string = source } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Math: \(source)")
    }
}
