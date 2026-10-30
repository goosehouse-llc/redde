import Foundation

/// A Hermes Dashboard with no sign-in (asked 2026-10-30, after Hermex): one bound to 127.0.0.1
/// with no `dashboard.public_url`, which a phone reaches through something on that machine
/// forwarding to it (`tailscale serve`, Caddy, cloudflared). Its `api/status` says
/// `auth_required: false`, and the page at `/` hands its session token to whoever loads it, the
/// way the desktop app gets in: the whole Dashboard page carries
/// `window.__HERMES_SESSION_TOKEN__="…"`, the headless `hermes serve` a page of just that and
/// `window.__HERMES_AUTH_REQUIRED__=false`. A Dashboard with a sign-in never puts it there.
///
/// The token goes on REST calls as `X-Hermes-Session-Token` (not `Authorization`, which a proxy's
/// own basic auth may be using) and on a WebSocket upgrade as `?token=`
/// (`HermesServeClient.SocketPass`). `HermesServeClient` holds it in memory only.
nonisolated enum SessionPage {
    /// The header REST calls carry the token in (Hermes's `_SESSION_HEADER_NAME`).
    static let header = "X-Hermes-Session-Token"

    /// The session token in the Dashboard's page, either shape; nil when there is none.
    static func token(in page: Data) -> String? {
        token(in: String(decoding: page.prefix(512 * 1024), as: UTF8.self))
    }

    static func token(in page: String) -> String? {
        guard let name = page.range(of: "__HERMES_SESSION_TOKEN__") else { return nil }
        var rest = page[name.upperBound...].drop { $0 == " " || $0 == "\t" }
        guard rest.first == "=" else { return nil }
        rest = rest.dropFirst().drop { $0 == " " || $0 == "\t" }
        guard let quote = rest.first, quote == "\"" || quote == "'" else { return nil }
        // Up to the closing quote, stepping over an escaped one (the headless page is json.dumps').
        var raw = ""
        var escaped = false
        for character in rest.dropFirst() {
            if escaped { raw.append(character); escaped = false; continue }
            if character == "\\" { raw.append(character); escaped = true; continue }
            if character == quote { return decoded(raw) }
            if character.isNewline { return nil }
            raw.append(character)
        }
        return nil
    }

    /// A JavaScript string's contents as the text they stand for.
    private static func decoded(_ raw: String) -> String? {
        let text: String
        if raw.contains("\\") {
            guard let data = "\"\(raw.replacingOccurrences(of: "\\'", with: "'"))\"".data(using: .utf8),
                  let value = try? JSONDecoder().decode(String.self, from: data) else { return nil }
            text = value
        } else {
            text = raw
        }
        let token = text.trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }

    /// `request` with the token on it, in its own header.
    static func apply(_ token: String, to request: URLRequest) -> URLRequest {
        var request = request
        request.setValue(token, forHTTPHeaderField: header)
        return request
    }

    /// Whether two addresses are the same origin (scheme, host and port): where a login may follow
    /// a redirect.
    static func sameOrigin(_ a: URL?, _ b: URL?) -> Bool {
        guard let a, let b, let schemeA = a.scheme?.lowercased(), let schemeB = b.scheme?.lowercased() else { return false }
        func port(_ url: URL, _ scheme: String) -> Int? { url.port ?? (scheme == "https" || scheme == "wss" ? 443 : scheme == "http" || scheme == "ws" ? 80 : nil) }
        return schemeA == schemeB && a.host()?.lowercased() == b.host()?.lowercased() && port(a, schemeA) == port(b, schemeB)
    }

    /// Hermes's answer to a request made at a name it doesn't answer to: on a 127.0.0.1 bind with
    /// no public address it takes only 127.0.0.1 and localhost in the Host header (a guard against
    /// DNS rebinding), so a proxy that passes its own name on is turned away. Nil for anything else.
    static func hostRefusal(status: Int, body: Data) -> DashboardSignInChange? {
        guard status == 400, String(decoding: body.prefix(400), as: UTF8.self).contains("Invalid Host header") else { return nil }
        return .addressRefused
    }
}

/// The Dashboard's sign-in isn't what the server was saved with, said in plain words with the way
/// to fix it (asked 2026-10-30). `ConnectionProblemCard` knows each by its words.
nonisolated enum DashboardSignInChange: LocalizedError, Equatable {
    /// Set up with no sign-in, and the Dashboard asks for a login now.
    case nowAsksForLogin
    /// Saved with a login, and the Dashboard no longer asks for one.
    case noLongerAsks
    /// With no sign-in, the Dashboard turned away the name it was reached at.
    case addressRefused

    var errorDescription: String? {
        switch self {
        case .nowAsksForLogin: Self.nowAsksText
        case .noLongerAsks: Self.noLongerAsksText
        case .addressRefused: Self.addressRefusedText
        }
    }

    static var nowAsksText: String {
        String(localized: "This Hermes Dashboard asks for a login now. It had no sign-in when this server was set up. Add its username and password, or sign in with a browser, under Settings › Connection details.",
               comment: "A Dashboard set up with no sign-in has turned its login on")
    }
    static var noLongerAsksText: String {
        String(localized: "This Hermes Dashboard doesn't ask for a login any more, so the saved login can't be used. Without one, anyone who can reach its address can use your agent.",
               comment: "A Dashboard saved with a username and password has no sign-in now")
    }
    static var addressRefusedText: String {
        String(localized: "This Hermes Dashboard has no sign-in, so it only answers requests addressed to 127.0.0.1 or localhost. Have the proxy in front of it send the Host header as 127.0.0.1.",
               comment: "A Dashboard with no sign-in refused the host name a proxy passed on (Hermes's \"Invalid Host header\")")
    }
}

/// What the Dashboard's form shows (Setup, Settings › Connection details), by what the address
/// says about signing in and what the server's record holds (asked 2026-10-30).
nonisolated enum DashboardFormMode: Equatable, Sendable {
    /// Username and password, or Sign in with a browser.
    case login
    /// No sign-in: no fields, Connect on, and the warning (`openWarning`).
    case open
    /// The record holds a login the Dashboard no longer asks for.
    case loginNoLongerAsked
    /// Set up with no sign-in, and the Dashboard asks for a login now.
    case loginNowAsked

    /// `asksForLogin`: the address's `auth_required`, nil when it hasn't answered. `hasLogin`: a
    /// username and password, or a browser sign-in. `savedOpen`: set up as one with no sign-in.
    static func decide(asksForLogin: Bool?, hasLogin: Bool, savedOpen: Bool) -> DashboardFormMode {
        switch asksForLogin {
        case false?: hasLogin ? .loginNoLongerAsked : .open
        case true?: !hasLogin && savedOpen ? .loginNowAsked : .login
        case nil: !hasLogin && savedOpen ? .open : .login
        }
    }

    /// Whether the username and password fields show.
    var asksForLogin: Bool { self == .login || self == .loginNowAsked }

    static var openWarning: String {
        String(localized: "Anyone who can reach this address can use your agent. Only use it over a private network like Tailscale.",
               comment: "Warning shown for a Hermes Dashboard with no sign-in")
    }
}
