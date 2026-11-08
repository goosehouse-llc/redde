import Foundation

/// OpenRouter's public model list, for finding a model Hermes's own short list leaves out (Hermes
/// offers about 70 of OpenRouter's 400-odd). Read only when someone searches the model picker on a
/// server with OpenRouter set up; the request carries no key and nothing about the person. Hermes
/// checks a picked model against this same list, so anything found here runs.
@MainActor
final class OpenRouterCatalog {
    static let shared = OpenRouterCatalog()

    nonisolated struct Model: Sendable, Hashable {
        let id: String
        let name: String
        let context: Int?
        var price: ModelPrice? = nil
    }

    private var cached: [Model]?
    private var fetchedAt: Date?
    private var loading: Task<[Model], Error>?

    /// The list, from memory when it was read in the last six hours.
    func models() async throws -> [Model] {
        if let cached, let fetchedAt, Date.now.timeIntervalSince(fetchedAt) < 6 * 3600 { return cached }
        if let loading { return try await loading.value }
        let task = Task { try await Self.fetch() }
        loading = task
        defer { loading = nil }
        let list = try await task.value
        cached = list
        fetchedAt = .now
        return list
    }

    nonisolated static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 12
        return URLSession(configuration: configuration)
    }()

    @concurrent nonisolated static func fetch() async throws -> [Model] {
        let url = URL(string: "https://openrouter.ai/api/v1/models")!
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
        return parse(data)
    }

    /// Models that read and write text and can call tools: an agent needs both.
    nonisolated static func parse(_ data: Data) -> [Model] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["data"] as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
            let architecture = entry["architecture"] as? [String: Any]
            let output = architecture?["output_modalities"] as? [String] ?? ["text"]
            let input = architecture?["input_modalities"] as? [String] ?? ["text"]
            let parameters = entry["supported_parameters"] as? [String]
            guard output.contains("text"), input.contains("text"), parameters?.contains("tools") ?? true else { return nil }
            // OpenRouter prices per token, as strings.
            let pricing = entry["pricing"] as? [String: Any]
            func perMillion(_ key: String) -> Double? {
                (pricing?[key] as? String).flatMap(Double.init).map { ($0 * 1_000_000 * 10_000).rounded() / 10_000 }
            }
            let price = perMillion("prompt").map { ModelPrice(input: $0, output: perMillion("completion") ?? 0, cacheRead: perMillion("input_cache_read")) }
            return Model(id: id, name: (entry["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id,
                         context: entry["context_length"] as? Int, price: price)
        }
    }

    /// The models whose id or name holds every word typed ("qwen 27b" finds qwen/qwen3.8-27b): a
    /// word at the start of the model's own name first, then in OpenRouter's order, newest first.
    nonisolated static func search(_ query: String, in models: [Model], limit: Int = 40) -> [Model] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = words.first else { return [] }
        let found = models.enumerated().filter { _, model in
            let text = (model.id + " " + model.name).lowercased()
            return words.allSatisfy { holds($0, in: text) }
        }
        func rank(_ model: Model) -> Int {
            let bare = model.id.split(separator: "/").last.map { $0.lowercased() } ?? model.id.lowercased()
            return bare.hasPrefix(first) ? 0 : 1
        }
        return Array(found.sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.prefix(limit).map(\.element))
    }

    /// A search word in a model's id or name, dots, dashes and the like aside: "3.8" finds Venice's
    /// `qwen-3-8-flash` and "qwen3.8" OpenRouter's `qwen/qwen3.8-flash` (2026-11-07). Both lowercased.
    nonisolated static func holds(_ word: String, in text: String) -> Bool {
        if text.contains(word) { return true }
        let bare = String(word.unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
        return !bare.isEmpty && String(text.unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init)).contains(bare)
    }

    /// How many tokens a model reads, for the row under its name: "1M", "262K".
    nonisolated static func contextLabel(_ tokens: Int?) -> String? {
        guard let tokens, tokens > 0 else { return nil }
        if tokens >= 1_000_000 {
            let millions = (Double(tokens) / 100_000).rounded() / 10
            return millions.rounded() == millions ? "\(Int(millions))M" : String(format: "%.1fM", millions)
        }
        return "\(tokens / 1000)K"
    }
}

/// Venice's prices and context sizes, from its public model list (Hermes has no prices for a
/// custom endpoint). Read once in six hours.
actor VenicePrices {
    static let shared = VenicePrices()
    private var cached: [String: (price: ModelPrice, context: Int?)]?
    private var fetchedAt: Date?

    func all() async -> [String: (price: ModelPrice, context: Int?)] {
        if let cached, let fetchedAt, Date.now.timeIntervalSince(fetchedAt) < 6 * 3600 { return cached }
        guard let (data, response) = try? await OpenRouterCatalog.session.data(from: URL(string: "https://api.venice.ai/api/v1/models")!),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return cached ?? [:] }
        let found = Self.parse(data)
        cached = found
        fetchedAt = .now
        return found
    }

    /// `data[].model_spec.pricing.{input,output,cache_input}.usd`, already per million tokens.
    nonisolated static func parse(_ data: Data) -> [String: (price: ModelPrice, context: Int?)] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["data"] as? [[String: Any]] else { return [:] }
        var out: [String: (price: ModelPrice, context: Int?)] = [:]
        for entry in entries {
            guard let id = entry["id"] as? String, let spec = entry["model_spec"] as? [String: Any],
                  let pricing = spec["pricing"] as? [String: Any] else { continue }
            func usd(_ key: String) -> Double? { ((pricing[key] as? [String: Any])?["usd"] as? NSNumber)?.doubleValue }
            guard let input = usd("input") else { continue }
            out[id] = (ModelPrice(input: input, output: usd("output") ?? 0, cacheRead: usd("cache_input")),
                       (spec["availableContextTokens"] as? NSNumber)?.intValue)
        }
        return out
    }

    /// A provider that is Venice, by its slug or name ("venice", "custom:venice").
    nonisolated static func isVenice(_ choice: ModelChoice) -> Bool {
        (choice.provider + " " + choice.providerName).lowercased().contains("venice")
    }
}
