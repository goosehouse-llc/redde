import Foundation
import Testing
@testable import Echo

struct JSONValueTests {
    @Test func decodesAndNavigatesFrames() throws {
        let raw = #"{"jsonrpc":"2.0","method":"event","params":{"type":"reasoning.delta","session_id":"S","payload":{"text":"hmm","verbose":true}}}"#
        let v = try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
        #expect(v["method"]?.string == "event")
        #expect(v["params"]?["type"]?.string == "reasoning.delta")
        #expect(v["params"]?["payload"]?["verbose"]?.bool == true)
        #expect(v["params"]?["payload"]?["text"]?.string == "hmm")
        #expect(v["nope"] == nil)
    }

    @Test func encodesRequests() throws {
        let frame = JSONValue.object(["jsonrpc": .string("2.0"), "id": .string("echo-1"), "method": .string("gateway.ping"), "params": .object([:])])
        let data = try JSONEncoder().encode(frame)
        let back = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(back == frame)
        #expect(JSONValue.object(["a": .number(1)]).displayText == #"{"a":1}"#)
    }
}

struct ModelOptionsTests {
    @Test func parsesProvidersAndModels() throws {
        let raw = #"{"providers":[{"slug":"custom","name":"llama-swap","is_current":true,"models":[{"id":"gemma4-26b-a4b","name":"Gemma 4 26B","is_current":true},{"id":"qwen3-4b"}]},{"slug":"openrouter","name":"OpenRouter","models":[{"id":"x/y","name":"Y"}]}]}"#
        let choices = try HermesSessionsAPI.parseModelOptions(Data(raw.utf8))
        #expect(choices.count == 3)
        #expect(choices[0] == ModelChoice(provider: "custom", providerName: "llama-swap", model: "gemma4-26b-a4b", name: "Gemma 4 26B", isCurrent: true))
        #expect(choices[1].isCurrent == false && choices[1].name == "qwen3-4b")
        #expect(choices[2].provider == "openrouter")
    }

    /// The live gateway/serve payloads carry models as bare id strings, with the active
    /// selection named by top-level model/provider. This is what dchermes actually sends.
    @Test func parsesStringModelLists() throws {
        let raw = #"{"model":"gemma4-26b-a4b","provider":"custom:vision","providers":[{"slug":"custom:vision","name":"vision","is_current":true,"models":["gemma4-26b-a4b","qwen3-4b"]},{"slug":"anthropic","name":"Anthropic","models":["claude-fable-5"]}]}"#
        let choices = try HermesSessionsAPI.parseModelOptions(Data(raw.utf8))
        #expect(choices.map(\.model) == ["gemma4-26b-a4b", "qwen3-4b", "claude-fable-5"])
        #expect(choices[0].isCurrent)
        #expect(!choices[1].isCurrent && !choices[2].isCurrent)
    }

    /// Every custom endpoint serves the same llama-swap catalog, so the picker folds them into
    /// one deduped Local section keyed to the current endpoint, ahead of the cloud providers.
    @Test func localModelGroupsMerge() {
        let choices = [
            ModelChoice(provider: "anthropic", providerName: "Anthropic", model: "claude-fable-5", name: "claude-fable-5", isCurrent: false),
            ModelChoice(provider: "custom", providerName: "custom", model: "gemma4-26b-a4b", name: "gemma4-26b-a4b", isCurrent: false),
            ModelChoice(provider: "custom:vision", providerName: "vision", model: "gemma4-26b-a4b", name: "gemma4-26b-a4b", isCurrent: true),
            ModelChoice(provider: "custom:vision", providerName: "vision", model: "qwen3-4b", name: "qwen3-4b", isCurrent: false),
            ModelChoice(provider: "custom:primary", providerName: "primary", model: "qwen3-4b", name: "qwen3-4b", isCurrent: false),
        ]
        let groups = ModelPickerView.grouped(choices)
        #expect(groups.map(\.name) == ["Local", "Anthropic"])
        #expect(groups[0].provider == "custom:vision")
        #expect(groups[0].models.map(\.model) == ["gemma4-26b-a4b", "qwen3-4b"])
        #expect(groups[0].models.allSatisfy { $0.provider == "custom:vision" })
        #expect(groups[0].models[0].isCurrent, "the current endpoint's entry wins the dedupe")
    }
}

struct ClarifyParseTests {
    @Test func parsesSingleAndBatch() throws {
        let single = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"request_id":"r1","question":"Which?","choices":["a","b"]}"#.utf8))
        let s = HermesServeTransport.parseClarify(single)
        #expect(s.id == "r1" && !s.isBatch && s.questions.count == 1 && s.questions[0].choices == ["a", "b"] && !s.questions[0].multiSelect)
        let batch = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"request_id":"r2","questions":[{"qid":"q1","question":"A?","choices":[],"multi_select":false},{"qid":"q2","question":"B?","choices":["x","y"],"multi_select":true}]}"#.utf8))
        let b = HermesServeTransport.parseClarify(batch)
        #expect(b.isBatch && b.questions.map(\.id) == ["q1", "q2"] && b.questions[1].multiSelect)
    }
}
