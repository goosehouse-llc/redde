import Foundation

/// Models & Providers (asked 2026-11-11, "build models and providers for both connections"): a
/// profile's provider keys, its own endpoints, its default model, the models it falls back to and
/// its helper models, as Hermes Desktop's settings have them.
///
/// Over the Dashboard it is the REST routes Desktop uses, each with `?profile=`. The Hermes API has
/// no such routes, so Redde's plugin (1.26) adds one, `/v1/redde/models`, that answers in the same
/// shapes. Keys are write-only both ways: Hermes shows a masked preview and nothing reads one back.
nonisolated struct ModelSetup: Equatable, Sendable {
    /// One of Hermes's providers: a catalog one (OpenRouter, Anthropic…) or an endpoint of the
    /// person's own.
    struct Provider: Identifiable, Equatable, Sendable {
        var id: String { slug }
        var slug: String
        var name: String
        /// It has what it needs to answer: a key, a sign-in, or nothing needed (a local server).
        var ready: Bool
        /// The `.env` variable its key goes in, for one that takes a pasted key.
        var keyEnv: String?
        /// "api_key", "oauth"…, as Hermes says.
        var authType: String?
        var isCurrent: Bool
        var isOwn: Bool
        var models: [String]
        var warning: String?
    }

    /// An OpenAI-compatible endpoint of the person's own (`custom:<id>` to Hermes).
    struct Endpoint: Identifiable, Equatable, Sendable {
        var id: String
        var name: String
        var baseURL: String
        var model: String
        var models: [String]
        var apiMode: String
        var hasKey: Bool
        var isCurrent: Bool
        /// How Hermes names it as a provider.
        var provider: String { "custom:" + id }
    }

    /// A key's state: set or not, and Hermes's masked preview of it.
    struct Key: Equatable, Sendable {
        var isSet: Bool
        var preview: String?
    }

    /// A provider's own key, as Hermes's list of keys groups them: the variable it goes in and the
    /// provider's name. (The model list names the variable only while a provider has no key.)
    struct ProviderKey: Identifiable, Equatable, Sendable {
        var id: String { env }
        var env: String
        var provider: String
        var name: String
        var isSet: Bool
        var preview: String?
    }

    /// A helper model: what one of Hermes's side jobs (titles, pictures, summing up a long chat…)
    /// runs on. No provider, or "auto", is the main model.
    struct Helper: Identifiable, Equatable, Sendable {
        var id: String { task }
        var task: String
        var provider: String
        var model: String
        var label: String?
        var hint: String?

        var followsMain: Bool { provider.isEmpty || provider == "auto" || provider == "main" }
    }

    /// One model of the chain Hermes tries when the main one fails.
    struct Fallback: Identifiable, Hashable, Sendable {
        var id: String { provider + "/" + model }
        var provider: String
        var model: String
        var baseURL: String?
    }

    var mainProvider: String
    var mainModel: String
    var providers: [Provider]
    var endpoints: [Endpoint]
    var keys: [String: Key]
    /// Each catalog provider's main key, by its name.
    var providerKeys: [ProviderKey] = []
    var helpers: [Helper]
    var fallbacks: [Fallback]
    /// Every model Hermes offers, as the pickers group them.
    var choices: [ModelChoice]

    static let empty = ModelSetup(mainProvider: "", mainModel: "", providers: [], endpoints: [], keys: [:], helpers: [], fallbacks: [], choices: [])

    /// The parts as the Dashboard's routes (and the plugin's, in the same shapes) give them.
    static func parse(options: JSONValue, env: JSONValue, endpoints: JSONValue, auxiliary: JSONValue, fallbacks: JSONValue) -> ModelSetup {
        var keys: [String: Key] = [:]
        var byProvider: [String: ProviderKey] = [:]
        for (name, row) in env.object ?? [:] {
            // Only provider keys: the rest of .env (bots' tokens, mail passwords) isn't this page's.
            let provider = row["provider"]?.string ?? ""
            guard !provider.isEmpty || name.hasPrefix("HERMES_CUSTOM_") else { continue }
            let key = Key(isSet: row["is_set"]?.bool ?? false, preview: row["redacted_value"]?.string?.nilIfEmpty.map(Self.unwrapped))
            keys[name] = key
            guard !provider.isEmpty, !name.hasPrefix("HERMES_CUSTOM_") else { continue }
            // The provider's main variable; another it also reads only stands in until one is found,
            // or when it is the one that is set.
            let primary = row["provider_primary"]?.bool ?? false
            let entry = ProviderKey(env: name, provider: provider, name: row["provider_label"]?.string?.nilIfEmpty ?? provider,
                                    isSet: key.isSet, preview: key.preview)
            if let held = byProvider[provider] {
                let heldPrimary = env[held.env]?["provider_primary"]?.bool ?? false
                if (primary && !heldPrimary && !held.isSet) || (key.isSet && !held.isSet) { byProvider[provider] = entry }
            } else {
                byProvider[provider] = entry
            }
        }
        let providers: [Provider] = (options["providers"]?.array ?? []).compactMap { row in
            guard let slug = row["slug"]?.string ?? row["id"]?.string, !slug.isEmpty else { return nil }
            let keyEnv = row["key_env"]?.string?.nilIfEmpty
            return Provider(slug: slug, name: row["name"]?.string ?? slug,
                            ready: row["authenticated"]?.bool ?? keyEnv.flatMap { keys[$0]?.isSet } ?? true,
                            keyEnv: keyEnv, authType: row["auth_type"]?.string,
                            isCurrent: row["is_current"]?.bool ?? false,
                            isOwn: row["is_user_defined"]?.bool ?? slug.hasPrefix("custom"),
                            models: (row["models"]?.array ?? []).compactMap { $0.string ?? $0["id"]?.string },
                            warning: row["warning"]?.string?.nilIfEmpty)
        }
        let mainProvider = options["provider"]?.string ?? auxiliary["main"]?["provider"]?.string ?? ""
        // Hermes marks an endpoint current by its address, and an older entry has none stored: the
        // default model's provider names it too (its endpoint mustn't be deletable).
        let currentEndpoint = endpoints["current"]?["provider"]?.string ?? mainProvider
        let own: [Endpoint] = (endpoints["endpoints"]?.array ?? []).compactMap { row in
            guard let id = row["id"]?.string, !id.isEmpty else { return nil }
            return Endpoint(id: id, name: row["name"]?.string ?? id, baseURL: row["base_url"]?.string ?? "",
                            model: row["model"]?.string ?? "",
                            models: (row["models"]?.array ?? []).compactMap { $0.string ?? $0["id"]?.string },
                            apiMode: row["api_mode"]?.string ?? "", hasKey: row["has_api_key"]?.bool ?? false,
                            isCurrent: row["is_current"]?.bool == true || currentEndpoint == "custom:" + id || mainProvider == "custom:" + id)
        }
        let helpers: [Helper] = (auxiliary["tasks"]?.array ?? []).compactMap { row in
            guard let task = row["task"]?.string, !task.isEmpty else { return nil }
            return Helper(task: task, provider: row["provider"]?.string ?? "auto", model: row["model"]?.string ?? "",
                          label: row["label"]?.string?.nilIfEmpty, hint: row["hint"]?.string?.nilIfEmpty)
        }
        return ModelSetup(mainProvider: mainProvider,
                          mainModel: options["model"]?.string ?? auxiliary["main"]?["model"]?.string ?? "",
                          providers: providers, endpoints: own, keys: keys,
                          providerKeys: byProvider.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
                          helpers: helpers,
                          fallbacks: Self.fallbacks(fallbacks),
                          choices: HermesSessionsAPI.parseModelOptions(options))
    }

    /// `fallback_providers` as config.yaml has it (entries without a provider or a model dropped,
    /// as Hermes drops them).
    static func fallbacks(_ list: JSONValue) -> [Fallback] {
        let rows = list.array ?? (list.object != nil ? [list] : [])
        return rows.compactMap { row in
            guard let provider = row["provider"]?.string?.nilIfEmpty, let model = row["model"]?.string?.nilIfEmpty else { return nil }
            return Fallback(provider: provider, model: model, baseURL: row["base_url"]?.string?.nilIfEmpty)
        }
    }

    /// "«redacted:sk-p...7890»" → "sk-p...7890".
    static func unwrapped(_ preview: String) -> String {
        var text = preview
        if text.hasPrefix("«redacted:") { text.removeFirst("«redacted:".count) }
        if text.hasSuffix("»") { text.removeLast() }
        return text
    }

    /// The name a provider slug goes by here.
    func providerName(_ slug: String) -> String {
        if let endpoint = endpoints.first(where: { $0.provider == slug }) { return endpoint.name }
        return providers.first { $0.slug == slug }?.name ?? choices.first { $0.provider == slug }?.providerName ?? slug
    }

    /// The keys added so far, and the providers that could have one.
    var addedKeys: [ProviderKey] { providerKeys.filter(\.isSet) }
    var missingKeys: [ProviderKey] { providerKeys.filter { !$0.isSet } }
}

/// What setting the default model came to.
nonisolated enum MainModelOutcome: Equatable, Sendable {
    case done(staleHelpers: [String])
    /// Hermes wants a yes first (an expensive model, or one that trains on what it is sent).
    case confirm(String)
}

/// What testing an endpoint found.
nonisolated struct EndpointTest: Equatable, Sendable {
    var reachable: Bool
    var message: String
    var models: [String]
    var resolvedBaseURL: String?
}

/// A new or changed endpoint.
nonisolated struct EndpointDraft: Equatable, Sendable {
    var id: String?
    var name: String
    var baseURL: String
    var model: String
    /// Nil keeps the key it has; "" takes it away.
    var apiKey: String?
    var apiMode: String = ""
    var makeDefault = false
}

/// A provider signed in to rather than given a key (ChatGPT, Nous, xAI, MiniMax): the Dashboard's.
nonisolated struct ProviderSignIn: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    /// "device_code": signs in from here. "external": only from the server (`command`).
    var flow: String
    var command: String?
    var signedIn: Bool
    var account: String?

    static func parse(_ json: JSONValue) -> [ProviderSignIn] {
        (json["providers"]?.array ?? []).compactMap { row in
            guard let id = row["id"]?.string else { return nil }
            let status = row["status"]
            return ProviderSignIn(id: id, name: row["name"]?.string ?? id, flow: row["flow"]?.string ?? "external",
                                  command: row["cli_command"]?.string?.nilIfEmpty,
                                  signedIn: status?["logged_in"]?.bool ?? false,
                                  account: status?["account_email"]?.string?.nilIfEmpty ?? status?["source_label"]?.string?.nilIfEmpty)
        }
    }
}

/// A sign-in under way: the code to type at the address.
nonisolated struct SignInCode: Equatable, Sendable {
    var session: String
    var code: String
    var url: URL
    var interval: Int
}

nonisolated enum SignInState: Equatable, Sendable {
    case pending, approved, failed(String)
}

nonisolated enum ModelSetupProblem: LocalizedError, Equatable {
    /// The Hermes API with an older plugin, or none.
    case needsPlugin
    case hermes(String)

    var errorDescription: String? {
        switch self {
        case .needsPlugin:
            String(localized: "Over the Hermes API, this needs Redde's plugin 1.26 or later on your server. Update the plugin, restart Hermes, then look again.")
        case let .hermes(message): message
        }
    }
}

/// One profile's models and providers, over whichever connection.
protocol ModelSetupService: Sendable {
    var profile: String { get }
    /// Sign-ins happen in the Dashboard's process; the Hermes API can't run them.
    var canSignIn: Bool { get }
    func load(refresh: Bool) async throws -> ModelSetup
    func setKey(_ env: String, value: String) async throws
    func removeKey(_ env: String) async throws
    func setMain(provider: String, model: String, confirmed: Bool) async throws -> MainModelOutcome
    func setHelper(task: String, provider: String, model: String) async throws
    func setFallbacks(_ list: [ModelSetup.Fallback]) async throws
    func saveEndpoint(_ draft: EndpointDraft) async throws
    func deleteEndpoint(_ id: String) async throws
    func testEndpoint(baseURL: String, apiKey: String?, apiMode: String) async throws -> EndpointTest
    func signIns() async throws -> [ProviderSignIn]
    func startSignIn(_ provider: String) async throws -> SignInCode
    func pollSignIn(_ provider: String, session: String) async throws -> SignInState
    func signOut(_ provider: String) async throws
}

extension ModelSetupService {
    /// The answers both connections share.
    static func mainOutcome(_ result: JSONValue) throws -> MainModelOutcome {
        if result["confirm_required"]?.bool == true {
            return .confirm(result["confirm_message"]?.string ?? String(localized: "Hermes wants a yes before it uses this model."))
        }
        if result["ok"]?.bool == false {
            throw ModelSetupProblem.hermes(result["error"]?.string ?? result["message"]?.string ?? String(localized: "Hermes didn't take the model."))
        }
        let stale = (result["stale_aux"]?.array ?? []).compactMap { $0["task"]?.string }
        return .done(staleHelpers: stale)
    }

    static func endpointTest(_ result: JSONValue) -> EndpointTest {
        EndpointTest(reachable: result["reachable"]?.bool ?? result["ok"]?.bool ?? false,
                     message: result["message"]?.string ?? "",
                     models: (result["models"]?.array ?? []).compactMap { $0.string ?? $0["id"]?.string },
                     resolvedBaseURL: result["resolved_base_url"]?.string?.nilIfEmpty)
    }

    static func endpointBody(_ draft: EndpointDraft) -> JSONValue {
        var body: [String: JSONValue] = ["name": .string(draft.name), "base_url": .string(draft.baseURL),
                                         "model": .string(draft.model), "api_mode": .string(draft.apiMode),
                                         "make_default": .bool(draft.makeDefault), "discover_models": .bool(true)]
        if let id = draft.id { body["id"] = .string(id) }
        if let key = draft.apiKey { body["api_key"] = .string(key) }
        return .object(body)
    }

    static func fallbackList(_ list: [ModelSetup.Fallback]) -> JSONValue {
        .array(list.map { entry in
            var row: [String: JSONValue] = ["provider": .string(entry.provider), "model": .string(entry.model)]
            if let base = entry.baseURL { row["base_url"] = .string(base) }
            return .object(row)
        })
    }
}

// MARK: - Over the Dashboard

/// The REST routes Hermes Desktop's Models settings use, each for the profile.
struct DashboardModelSetup: ModelSetupService {
    let profile: String
    var client: HermesServeClient = .shared
    var canSignIn: Bool { true }

    private func path(_ route: String) -> String { HermesServeClient.naming(route, profile: profile) }

    private func call(_ method: String, _ route: String, _ body: JSONValue? = nil, timeout: TimeInterval = 30) async throws -> JSONValue {
        do {
            return try await client.restJSON(method, path(route), body: body, timeout: timeout)
        } catch let TransportError.http(_, body) where !body.isEmpty {
            throw ModelSetupProblem.hermes(body)
        }
    }

    func load(refresh: Bool) async throws -> ModelSetup {
        async let options = call("GET", "api/model/options?explicit_only=1&include_unconfigured=1" + (refresh ? "&refresh=1" : ""), timeout: refresh ? 90 : 30)
        async let env = call("GET", "api/env")
        async let endpoints = call("GET", "api/providers/custom-endpoints")
        async let auxiliary = call("GET", "api/model/auxiliary")
        async let config = call("GET", "api/config?include_defaults=false")
        let raw = try await config
        // The list, then the older one-model key Hermes still reads after it.
        var chain = raw["fallback_providers"]?.array ?? []
        if let legacy = raw["fallback_model"] { chain += legacy.array ?? [legacy] }
        return ModelSetup.parse(options: try await options, env: try await env, endpoints: try await endpoints,
                                auxiliary: try await auxiliary, fallbacks: .array(chain))
    }

    func setKey(_ env: String, value: String) async throws {
        _ = try await call("PUT", "api/env", .object(["key": .string(env), "value": .string(value), "provider_setup": .bool(true)]))
    }

    func removeKey(_ env: String) async throws {
        _ = try await call("DELETE", "api/env", .object(["key": .string(env)]))
    }

    func setMain(provider: String, model: String, confirmed: Bool) async throws -> MainModelOutcome {
        var body: [String: JSONValue] = ["scope": .string("main"), "provider": .string(provider), "model": .string(model)]
        if confirmed { body["confirm_expensive_model"] = .bool(true) }
        return try Self.mainOutcome(try await call("POST", "api/model/set", .object(body)))
    }

    func setHelper(task: String, provider: String, model: String) async throws {
        let result = try await call("POST", "api/model/set", .object(["scope": .string("auxiliary"), "task": .string(task),
                                                                      "provider": .string(provider), "model": .string(model)]))
        if result["ok"]?.bool == false { throw ModelSetupProblem.hermes(result["error"]?.string ?? String(localized: "Hermes didn't take the model.")) }
    }

    func setFallbacks(_ list: [ModelSetup.Fallback]) async throws {
        // Lists are replaced whole. Fields an entry had beyond these (its key's variable, its
        // wire format) stay with it; the older one-model key is emptied so the list is the chain.
        let raw = try await call("GET", "api/config?include_defaults=false")
        let before = raw["fallback_providers"]?.array ?? []
        let merged: [JSONValue] = list.map { entry in
            var row = before.first { $0["provider"]?.string == entry.provider && $0["model"]?.string == entry.model }?.object ?? [:]
            row["provider"] = .string(entry.provider)
            row["model"] = .string(entry.model)
            if let base = entry.baseURL { row["base_url"] = .string(base) }
            row["api_key"] = nil
            return .object(row)
        }
        var config: [String: JSONValue] = ["fallback_providers": .array(merged)]
        if raw["fallback_model"] != nil { config["fallback_model"] = .null }
        _ = try await call("PUT", "api/config", .object(["config": .object(config)]))
    }

    func saveEndpoint(_ draft: EndpointDraft) async throws {
        _ = try await call("POST", "api/providers/custom-endpoints", Self.endpointBody(draft), timeout: 60)
    }

    func deleteEndpoint(_ id: String) async throws {
        _ = try await call("DELETE", "api/providers/custom-endpoints/\(HermesServeClient.pathPart(id))")
    }

    func testEndpoint(baseURL: String, apiKey: String?, apiMode: String) async throws -> EndpointTest {
        var body: [String: JSONValue] = ["base_url": .string(baseURL), "api_mode": .string(apiMode), "name": .string("test"), "model": .string("")]
        if let apiKey { body["api_key"] = .string(apiKey) }
        return Self.endpointTest(try await call("POST", "api/providers/custom-endpoints/validate", .object(body), timeout: 60))
    }

    func signIns() async throws -> [ProviderSignIn] {
        ProviderSignIn.parse(try await call("GET", "api/providers/oauth"))
    }

    func startSignIn(_ provider: String) async throws -> SignInCode {
        let result = try await call("POST", "api/providers/oauth/\(HermesServeClient.pathPart(provider))/start", timeout: 60)
        guard let session = result["session_id"]?.string, let code = result["user_code"]?.string,
              let url = result["verification_url"]?.string.flatMap(URL.init(string:)) else {
            throw ModelSetupProblem.hermes(result["error"]?.string ?? String(localized: "Hermes didn't start the sign-in."))
        }
        return SignInCode(session: session, code: code, url: url, interval: result["poll_interval"]?.int ?? 5)
    }

    func pollSignIn(_ provider: String, session: String) async throws -> SignInState {
        let result = try await call("GET", "api/providers/oauth/\(HermesServeClient.pathPart(provider))/poll/\(HermesServeClient.pathPart(session))?wait=25", timeout: 40)
        switch result["status"]?.string {
        case "approved": return .approved
        case "pending", nil: return .pending
        case let other?:
            return .failed(result["error_message"]?.string?.nilIfEmpty ?? result["reason"]?.string?.nilIfEmpty ?? other)
        }
    }

    func signOut(_ provider: String) async throws {
        _ = try await call("DELETE", "api/providers/oauth/\(HermesServeClient.pathPart(provider))")
    }
}

// MARK: - Over the Hermes API

/// The plugin's `/v1/redde/models`, with the main API key: the body names the profile.
struct APIModelSetup: ModelSetupService {
    let profile: String
    var settings: Settings = .shared
    var canSignIn: Bool { false }

    private func send(_ action: String, _ fields: [String: JSONValue] = [:], timeout: TimeInterval = 30) async throws -> JSONValue {
        guard let endpoint = await MainActor.run(body: { settings.gatewayEndpoint(profile: "default") }) else {
            throw ModelSetupProblem.hermes(SessionBackend.notConfiguredMessage)
        }
        let headers = await MainActor.run { settings.apiHeaders }
        var request = URLRequest(url: endpoint.url.appending(path: "v1/redde/models"))
        request.httpMethod = "POST"
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("Bearer \(endpoint.key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        var body = fields
        body["action"] = .string(action)
        body["profile"] = .string(profile)
        request.httpBody = try JSONEncoder().encode(JSONValue.object(body))
        let (data, response) = try await StreamingHTTP.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONValue.parse(data)) ?? .null
        // No such route: no plugin, or one before 1.26.
        if status == 404, json["error"]?["message"]?.string == nil { throw ModelSetupProblem.needsPlugin }
        guard (200 ..< 300).contains(status) else {
            throw ModelSetupProblem.hermes(json["error"]?["message"]?.string ?? String(localized: "The server answered \(status)."))
        }
        return json
    }

    func load(refresh: Bool) async throws -> ModelSetup {
        let result = try await send("load", ["refresh": .bool(refresh)], timeout: refresh ? 90 : 30)
        return ModelSetup.parse(options: result["options"] ?? .null, env: result["env"] ?? .null, endpoints: result["endpoints"] ?? .null,
                                auxiliary: result["auxiliary"] ?? .null, fallbacks: result["fallback_providers"] ?? .null)
    }

    func setKey(_ env: String, value: String) async throws {
        _ = try await send("set_key", ["key": .string(env), "value": .string(value)])
    }

    func removeKey(_ env: String) async throws {
        _ = try await send("remove_key", ["key": .string(env)])
    }

    func setMain(provider: String, model: String, confirmed: Bool) async throws -> MainModelOutcome {
        var fields: [String: JSONValue] = ["provider": .string(provider), "model": .string(model)]
        if confirmed { fields["confirm_expensive_model"] = .bool(true) }
        return try Self.mainOutcome(try await send("set_main", fields))
    }

    func setHelper(task: String, provider: String, model: String) async throws {
        _ = try await send("set_helper", ["task": .string(task), "provider": .string(provider), "model": .string(model)])
    }

    func setFallbacks(_ list: [ModelSetup.Fallback]) async throws {
        _ = try await send("set_fallbacks", ["fallback_providers": Self.fallbackList(list)])
    }

    func saveEndpoint(_ draft: EndpointDraft) async throws {
        _ = try await send("save_endpoint", Self.endpointBody(draft).object ?? [:], timeout: 60)
    }

    func deleteEndpoint(_ id: String) async throws {
        _ = try await send("delete_endpoint", ["id": .string(id)])
    }

    func testEndpoint(baseURL: String, apiKey: String?, apiMode: String) async throws -> EndpointTest {
        var fields: [String: JSONValue] = ["base_url": .string(baseURL), "api_mode": .string(apiMode)]
        if let apiKey { fields["api_key"] = .string(apiKey) }
        return Self.endpointTest(try await send("test_endpoint", fields, timeout: 60))
    }

    func signIns() async throws -> [ProviderSignIn] { [] }
    func startSignIn(_ provider: String) async throws -> SignInCode { throw ModelSetupProblem.hermes(Self.signInElsewhere) }
    func pollSignIn(_ provider: String, session: String) async throws -> SignInState { .failed(Self.signInElsewhere) }
    func signOut(_ provider: String) async throws { throw ModelSetupProblem.hermes(Self.signInElsewhere) }

    static var signInElsewhere: String {
        String(localized: "Sign-ins happen over the Dashboard connection, or on your server with hermes auth add.")
    }
}

extension ModelSetup {
    /// The service for a profile over the app's connection now.
    @MainActor
    static func service(profile: String, settings: Settings = .shared) -> any ModelSetupService {
        settings.transport == .hermesServe ? DashboardModelSetup(profile: profile) : APIModelSetup(profile: profile, settings: settings)
    }
}
