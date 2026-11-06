import SwiftUI
import WebKit

/// An email as its sender laid it out, pictures and all (asked 2026-11-06: "have the full content
/// of the email show, including pictures"), in the reader. The page's own scripts never run, it
/// keeps no cookies, and it follows no link itself: a tap on a link opens it outside. A layout
/// wider than the screen (most newsletters are 600 points) is scaled down to fit, as Mail does.
/// Pictures on the web load as the email opens, which a sender can see.
struct EmailBody: View {
    let html: String
    @State private var height: CGFloat = 0
    @Environment(\.openURL) private var openURL

    var body: some View {
        EmailWebView(html: html, height: $height) { openURL($0) }
            .frame(height: max(height, 120))
            .opacity(height > 0 ? 1 : 0)
            .overlay { if height == 0 { ProgressView() } }
            .accessibilityLabel(Text("The email", comment: "VoiceOver: an email's body, as its sender laid it out"))
    }

    /// The email inside a page that fits it to the screen: light, as its sender drew it, pictures
    /// no wider than the page.
    static func page(_ html: String) -> String {
        """
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light only">
        <style>
        html { -webkit-text-size-adjust: 100%; }
        body { margin: 0; padding: 14px; background: #fff; color: #111; font: -apple-system-body; overflow-wrap: anywhere; }
        img { max-width: 100%; height: auto; }
        pre { white-space: pre-wrap; }
        </style>
        """ + html
    }

    /// Scales the page down to the view's own width when it's wider (a 600-point newsletter, or
    /// the page laid out at the screen's width in a card a little narrower), then gives its height.
    static func measure(width: CGFloat) -> String {
        """
        (() => {
          const root = document.documentElement, body = document.body;
          if (!body) { return root.scrollHeight; }
          body.style.zoom = 1;
          const pad = parseFloat(getComputedStyle(body).paddingRight) || 0;
          const wide = Math.max(root.scrollWidth + pad, window.innerWidth), view = \(Double(width));
          if (view > 0 && wide > view + 1) { body.style.zoom = view / wide; }
          return Math.ceil(root.scrollHeight);
        })()
        """
    }

    /// The schemes a tap opens: the web, an address to write to, a number to call.
    static func opens(_ url: URL) -> Bool { ["https", "http", "mailto", "tel"].contains(url.scheme?.lowercased() ?? "") }
}

#if os(iOS)
private struct EmailWebView: UIViewRepresentable {
    let html: String
    @Binding var height: CGFloat
    let open: (URL) -> Void

    func makeCoordinator() -> EmailWebCoordinator { EmailWebCoordinator(height: $height, open: open) }

    func makeUIView(context: Context) -> EmailWKWebView {
        let view = EmailWKWebView(frame: .zero, configuration: EmailWebCoordinator.configuration())
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.scrollView.bounces = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.navigationDelegate = context.coordinator
        view.onWidthChange = { [weak view, coordinator = context.coordinator] in
            if let view { coordinator.measure(view) }
        }
        context.coordinator.load(html, into: view)
        return view
    }

    func updateUIView(_ view: EmailWKWebView, context: Context) {
        context.coordinator.load(html, into: view)
    }
}
#else
private struct EmailWebView: NSViewRepresentable {
    let html: String
    @Binding var height: CGFloat
    let open: (URL) -> Void

    func makeCoordinator() -> EmailWebCoordinator { EmailWebCoordinator(height: $height, open: open) }

    func makeNSView(context: Context) -> EmailWKWebView {
        let view = EmailWKWebView(frame: .zero, configuration: EmailWebCoordinator.configuration())
        view.navigationDelegate = context.coordinator
        view.onWidthChange = { [weak view, coordinator = context.coordinator] in
            if let view { coordinator.measure(view) }
        }
        context.coordinator.load(html, into: view)
        return view
    }

    func updateNSView(_ view: EmailWKWebView, context: Context) {
        context.coordinator.load(html, into: view)
    }
}
#endif

/// Measures again when its width changes (a rotation, a wider window).
final class EmailWKWebView: WKWebView {
    var onWidthChange: (() -> Void)?
    private var lastWidth: CGFloat = 0

    #if os(iOS)
    override func layoutSubviews() {
        super.layoutSubviews()
        widthMayHaveChanged()
    }
    #else
    override func layout() {
        super.layout()
        widthMayHaveChanged()
    }

    /// The reader scrolls, not the email inside it.
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
    #endif

    private func widthMayHaveChanged() {
        guard bounds.width > 0, abs(bounds.width - lastWidth) > 0.5 else { return }
        let first = lastWidth == 0
        lastWidth = bounds.width
        if !first { onWidthChange?() }
    }
}

final class EmailWebCoordinator: NSObject, WKNavigationDelegate {
    private let height: Binding<CGFloat>
    private let open: (URL) -> Void
    private var loaded: String?

    init(height: Binding<CGFloat>, open: @escaping (URL) -> Void) {
        self.height = height
        self.open = open
    }

    /// No scripts of the page's own, nothing kept between emails (a tracker's cookie).
    static func configuration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        #if os(iOS)
        config.dataDetectorTypes = [.link, .phoneNumber]
        #endif
        return config
    }

    func load(_ html: String, into view: WKWebView) {
        guard html != loaded else { return }
        loaded = html
        view.loadHTMLString(EmailBody.page(html), baseURL: nil)
    }

    /// Fit and measure, in Redde's own world: the page's scripts are off, this isn't the page's.
    func measure(_ view: WKWebView) {
        guard view.bounds.width > 0 else { return }
        view.evaluateJavaScript(EmailBody.measure(width: view.bounds.width), in: nil, in: .defaultClient) { [weak self] result in
            guard let self, case let .success(value) = result, let tall = (value as? NSNumber)?.doubleValue, tall > 0 else { return }
            if abs(self.height.wrappedValue - tall) > 0.5 { self.height.wrappedValue = tall }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        measure(webView)
        // A picture that arrives after the page has: measured once more.
        Task { [weak self, weak webView] in
            try? await Task.sleep(for: .seconds(1.5))
            if let self, let webView { self.measure(webView) }
        }
    }

    /// Only the email itself loads here; a tapped link opens outside, and anything else (a form,
    /// a page sending itself on) goes nowhere.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let url = action.request.url
        if action.navigationType == .other, url?.absoluteString == "about:blank", action.targetFrame?.isMainFrame == true {
            decisionHandler(.allow)
            return
        }
        if action.navigationType == .linkActivated, let url, EmailBody.opens(url) { open(url) }
        decisionHandler(.cancel)
    }
}
