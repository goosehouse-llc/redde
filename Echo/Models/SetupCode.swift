import Foundation

/// A connection handed over as a link, or as a QR code of that link, so nobody has to type an
/// address and a key on a phone keyboard:
///
///     redde://connect?name=Home&dashboard=http://hermes.home.example:9119&user=redde&password=…
///
/// Every parameter is optional, but a code has to carry at least one address:
///
/// - `name`: what the server is called in Settings › Servers.
/// - `dashboard`, `user`, `password`: the Hermes Dashboard (`hermes serve`).
/// - `api`, `key`: the Hermes API server. `profile` names a Hermes profile, `profile-key` is that
///   profile's own API key when it has one.
/// - `access-id`, `access-secret`: a Cloudflare Access service token for a server behind Access.
/// - `model-url`, `model-key`, `model`: an OpenAI-compatible endpoint.
/// - `use`: `dashboard`, `api` or `model`, the connection the app should talk to. Left out, it is
///   the first of those the code carries.
/// - `v`: the format's version, 1 today. A higher one is refused instead of half understood.
///
/// A link is untrusted input. It is shown for confirmation and saved only once the person agrees
/// (`SetupCodeSheet`); nothing here is applied on arrival.
nonisolated struct SetupCode: Equatable, Sendable {
    var name = ""
    /// The connection asked for with `use`; `transport` is the one that will be used.
    var use: Transport?
    var dashboardURL = ""
    var dashboardUser = ""
    var dashboardPassword = ""
    var apiURL = ""
    var apiKey = ""
    var profile = ""
    var profileKey = ""
    var accessID = ""
    var accessSecret = ""
    var modelURL = ""
    var modelKey = ""
    var model = ""

    static let scheme = "redde"
    static let host = "connect"
    static let version = 1
    /// Longer than any real code, short enough to fit a QR code a phone can read off a screen.
    static let maximumLength = 2_500

    enum ParseError: Error, Equatable {
        /// Made by a newer version of the app.
        case newerVersion
        /// No Dashboard, Hermes API or model address in it.
        case noAddress
        /// An address that isn't an http or https URL (the text is what was given).
        case badAddress(String)
        case tooLong

        var message: String {
            switch self {
            case .newerVersion: "This setup code was made by a newer version of Redde. Update the app, then try again."
            case .noAddress: "This setup code has no server address in it."
            case .badAddress(let text): "This setup code has an address Redde can't use: \(text.prefix(80))"
            case .tooLong: "This setup code is too long to be one of Redde's."
            }
        }
    }

    init() {}

    /// Whether `url` is a setup link at all; the rest of the app's links aren't.
    static func isSetupLink(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme && url.host()?.lowercased() == host
    }

    /// Reads a setup link. Nil when `url` isn't one; throws when it is one that can't be used.
    static func read(_ url: URL) throws(ParseError) -> SetupCode? {
        guard isSetupLink(url) else { return nil }
        guard url.absoluteString.utf8.count <= maximumLength else { throw .tooLong }
        var fields: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            let value = (item.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // The first of a repeated parameter counts, as it does for the person reading the link.
            if !value.isEmpty, fields[item.name.lowercased()] == nil { fields[item.name.lowercased()] = value }
        }
        if let version = fields["v"], (Int(version) ?? .max) > Self.version { throw .newerVersion }

        var code = SetupCode()
        code.name = String((fields["name"] ?? "").prefix(60))
        code.dashboardURL = try address(fields["dashboard"])
        code.dashboardUser = fields["user"] ?? ""
        code.dashboardPassword = fields["password"] ?? ""
        code.apiURL = try address(fields["api"])
        code.apiKey = fields["key"] ?? ""
        code.profile = fields["profile"] ?? ""
        code.profileKey = fields["profile-key"] ?? ""
        code.accessID = fields["access-id"] ?? ""
        code.accessSecret = fields["access-secret"] ?? ""
        code.modelURL = try address(fields["model-url"])
        code.modelKey = fields["model-key"] ?? ""
        code.model = fields["model"] ?? ""
        code.use = switch fields["use"]?.lowercased() {
        case "dashboard": .hermesServe
        case "api": .hermesSessions
        case "model": .chatCompletions
        default: nil
        }
        guard code.transport != nil else { throw .noAddress }
        return code
    }

    /// An address as Setup would accept it typed: http or https, with a host. One with a user
    /// name in it is refused: "http://my-server@elsewhere.example" reads like the wrong host.
    private static func address(_ raw: String?) throws(ParseError) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        guard let url = Settings.normalizedBase(raw), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host(), !host.isEmpty,
              url.user() == nil, url.password() == nil else {
            throw .badAddress(raw)
        }
        return url.absoluteString
    }

    /// The first setup link in a piece of text: what a QR code holds, or what was pasted.
    static func link(in text: String) -> URL? {
        guard let start = text.range(of: "\(scheme)://\(host)", options: .caseInsensitive) else { return nil }
        let rest = text[start.lowerBound...]
        let end = rest.firstIndex { $0.isWhitespace || $0 == "<" || $0 == ">" || $0 == "\"" } ?? rest.endIndex
        return URL(string: String(rest[..<end]))
    }

    /// The link for this code.
    var url: URL {
        var items: [URLQueryItem] = []
        func add(_ name: String, _ value: String) {
            if !value.isEmpty { items.append(URLQueryItem(name: name, value: value)) }
        }
        add("name", name)
        add("dashboard", dashboardURL)
        add("user", dashboardUser)
        add("password", dashboardPassword)
        add("api", apiURL)
        add("key", apiKey)
        add("profile", profile)
        add("profile-key", profileKey)
        add("access-id", accessID)
        add("access-secret", accessSecret)
        add("model-url", modelURL)
        add("model-key", modelKey)
        add("model", model)
        if let use {
            let word = switch use {
            case .hermesServe: "dashboard"
            case .hermesSessions: "api"
            case .chatCompletions: "model"
            }
            add("use", word)
        }
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.queryItems = items
        // URLComponents leaves "+" as it is in a query, and other readers take it for a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    /// The connection the app will talk to: the one asked for when the code carries it, else the
    /// first it does carry. Nil for a code with no address.
    var transport: Transport? {
        var carried: [Transport] = []
        if !dashboardURL.isEmpty { carried.append(.hermesServe) }
        if !apiURL.isEmpty { carried.append(.hermesSessions) }
        if !modelURL.isEmpty { carried.append(.chatCompletions) }
        if let use, carried.contains(use) { return use }
        return carried.first
    }

    /// Carries a Hermes server (the model endpoint isn't one: it is the app's, not a server's).
    var hasServer: Bool { !dashboardURL.isEmpty || !apiURL.isEmpty }

    var hasSecrets: Bool {
        !(dashboardPassword.isEmpty && apiKey.isEmpty && profileKey.isEmpty && accessSecret.isEmpty && modelKey.isEmpty)
    }

    /// The same code with addresses and names only, for showing where a password shouldn't be.
    var withoutSecrets: SetupCode {
        var code = self
        code.dashboardPassword = ""
        code.apiKey = ""
        code.profileKey = ""
        code.accessSecret = ""
        code.modelKey = ""
        return code
    }
}

/// A setup link that arrived (opened, scanned or pasted): the code in it, or why it can't be used.
nonisolated struct SetupCodeOffer: Identifiable, Equatable, Sendable {
    let id = UUID()
    var result: Result<SetupCode, SetupCode.ParseError>

    /// Nil when `url` isn't a setup link.
    init?(url: URL) {
        do {
            guard let code = try SetupCode.read(url) else { return nil }
            result = .success(code)
        } catch {
            result = .failure(error)
        }
    }

    /// Nil when there is no setup link in `text`.
    init?(text: String) {
        guard let url = SetupCode.link(in: text) else { return nil }
        self.init(url: url)
    }
}
