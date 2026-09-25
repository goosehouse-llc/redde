import Foundation
import os

/// Asks llama.cpp (through llama-swap) how big the loaded model's context is, once per model,
/// so the footer can show real percentages instead of a guess.
nonisolated enum ContextWindowProbe {
    private static let log = Logger(subsystem: "com.goosehouse.echo", category: "ctx")
    /// Cached per base+model. A miss is cached too (as 0) so a backend that never reports a
    /// window is asked once, not on every turn.
    private static let cache = OSAllocatedUnfairLock(initialState: [String: Int]())

    static func window(fastLaneBase: URL, model: String, apiKey: String? = nil) async -> Int? {
        let key = fastLaneBase.absoluteString + "#" + model
        if let hit = cache.withLock({ $0[key] }) { return hit == 0 ? nil : hit }
        var n = await llamaSwapWindow(base: fastLaneBase, model: model)
        if n == nil { n = await modelListWindow(base: fastLaneBase, model: model, apiKey: apiKey) }
        let resolved = n
        cache.withLock { $0[key] = resolved ?? 0 }
        if let n { log.info("context window for \(model): \(n)") }
        else { log.info("no context window from \(fastLaneBase.host() ?? "?") for \(model); not asking again") }
        return n
    }

    /// llama-swap / llama.cpp: the configured n_ctx.
    private static func llamaSwapWindow(base: URL, model: String) async -> Int? {
        struct Props: Decodable {
            var default_generation_settings: Gen?
            struct Gen: Decodable { var n_ctx: Int? }
        }
        var request = URLRequest(url: base.appending(path: "upstream/\(model)/props"))
        request.timeoutInterval = 4
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let props = try? JSONDecoder().decode(Props.self, from: data),
              let n = props.default_generation_settings?.n_ctx, n > 0 else { return nil }
        return n
    }

    /// Hosted providers (OpenRouter, Groq, vLLM…): `context_length` / `max_model_len` on /v1/models.
    private static func modelListWindow(base: URL, model: String, apiKey: String?) async -> Int? {
        var request = URLRequest(url: base.appending(path: "v1/models"))
        request.timeoutInterval = 6
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        guard let entry = json["data"]?.array?.first(where: { $0["id"]?.string == model }) else { return nil }
        let n = entry["context_length"]?.int ?? entry["max_model_len"]?.int ?? entry["context_window"]?.int
        return (n ?? 0) > 0 ? n : nil
    }
}
