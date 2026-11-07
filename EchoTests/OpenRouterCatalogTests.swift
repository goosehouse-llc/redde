import Foundation
import Testing
@testable import Echo

/// The model picker's search over OpenRouter's full list (built 2026-11-06): a model Hermes's own
/// short list leaves out, found by the words typed and picked under the server's OpenRouter.
struct OpenRouterCatalogTests {
    private let list = """
    {"data": [
      {"id": "qwen/qwen3.8-27b", "name": "Qwen: Qwen3.8 27B", "context_length": 1024000,
       "architecture": {"input_modalities": ["text", "image"], "output_modalities": ["text"]}, "supported_parameters": ["tools", "reasoning"]},
      {"id": "qwen/qwen3.6-27b", "name": "Qwen: Qwen3.6 27B", "context_length": 262144,
       "architecture": {"input_modalities": ["text"], "output_modalities": ["text"]}, "supported_parameters": ["tools"]},
      {"id": "google/gemma-3-27b-it", "name": "Google: Gemma 3 27B", "context_length": 131072,
       "architecture": {"input_modalities": ["text"], "output_modalities": ["text"]}, "supported_parameters": ["temperature"]},
      {"id": "openai/gpt-image-2", "name": "OpenAI: GPT Image 2",
       "architecture": {"input_modalities": ["text"], "output_modalities": ["image"]}, "supported_parameters": ["tools"]},
      {"id": "prism-ml/ternary-bonsai-2-27b", "name": "Bonsai 2 27B", "context_length": 262144}
    ]}
    """

    private var models: [OpenRouterCatalog.Model] { OpenRouterCatalog.parse(Data(list.utf8)) }

    @Test func onlyTextModelsThatUseToolsAreKept() {
        // Gemma here can't call tools, the image model doesn't write text; an entry that doesn't
        // say is kept.
        #expect(models.map(\.id) == ["qwen/qwen3.8-27b", "qwen/qwen3.6-27b", "prism-ml/ternary-bonsai-2-27b"])
        #expect(models[0].name == "Qwen: Qwen3.8 27B")
        #expect(models[0].context == 1_024_000)
    }

    @Test func everyWordTypedMustMatch() {
        #expect(OpenRouterCatalog.search("qwen 27b", in: models).map(\.id) == ["qwen/qwen3.8-27b", "qwen/qwen3.6-27b"])
        #expect(OpenRouterCatalog.search("3.8 27B", in: models).map(\.id) == ["qwen/qwen3.8-27b"])
        #expect(OpenRouterCatalog.search("   ", in: models).isEmpty)
        #expect(OpenRouterCatalog.search("llama", in: models).isEmpty)
    }

    @Test func aModelWhoseNameStartsWithTheFirstWordComesFirst() {
        // "27b" starts no model's name: OpenRouter's order (newest first) stands.
        #expect(OpenRouterCatalog.search("27b", in: models).map(\.id) == ["qwen/qwen3.8-27b", "qwen/qwen3.6-27b", "prism-ml/ternary-bonsai-2-27b"])
        // "qwen" starts the second's own name (after the maker's slash), so it comes ahead.
        let two = [OpenRouterCatalog.Model(id: "acme/tuned-qwen-9b", name: "Acme Tuned Qwen", context: nil),
                   OpenRouterCatalog.Model(id: "qwen/qwen3.8-flash", name: "Qwen3.8 Flash", context: nil)]
        #expect(OpenRouterCatalog.search("qwen", in: two).map(\.id) == ["qwen/qwen3.8-flash", "acme/tuned-qwen-9b"])
    }

    @Test func contextIsShortened() {
        #expect(OpenRouterCatalog.contextLabel(1_000_000) == "1M")
        #expect(OpenRouterCatalog.contextLabel(1_048_576) == "1M")
        #expect(OpenRouterCatalog.contextLabel(1_500_000) == "1.5M")
        #expect(OpenRouterCatalog.contextLabel(262_144) == "262K")
        #expect(OpenRouterCatalog.contextLabel(nil) == nil)
    }

    @Test @MainActor func aPickFromTheFullListKeepsARowInItsSection() {
        let listed = [ModelChoice(provider: "openrouter", providerName: "OpenRouter", model: "qwen/qwen3.8-flash", name: "Qwen3.8 Flash", isCurrent: false),
                      ModelChoice(provider: "custom:local", providerName: "Local", model: "qwen36-splash", name: "qwen36-splash", isCurrent: true)]
        let kept = ModelPickerView.keepingPick(.init(model: "qwen/qwen3.8-27b", provider: "openrouter"), in: listed)
        #expect(kept.count == 3)
        #expect(kept.last?.provider == "openrouter")
        #expect(kept.last?.providerName == "OpenRouter")
        // Already listed, a local pick, or no OpenRouter on the server: nothing added.
        #expect(ModelPickerView.keepingPick(.init(model: "qwen/qwen3.8-flash", provider: "openrouter"), in: listed).count == 2)
        #expect(ModelPickerView.keepingPick(.init(model: "other", provider: "custom:local"), in: listed).count == 2)
        #expect(ModelPickerView.keepingPick(.init(model: "qwen/qwen3.8-27b", provider: "openrouter"), in: [listed[1]]).count == 1)
    }

    @Test func dotsAndDashesDontKeepAModelFromASearch() {
        #expect(OpenRouterCatalog.holds("3.8", in: "qwen-3-8-flash"), "Venice's names use dashes")
        #expect(OpenRouterCatalog.holds("qwen3.8", in: "qwen/qwen3.8-flash"))
        #expect(OpenRouterCatalog.holds("v4.1", in: "deepseek-v4-1-flash"))
        #expect(!OpenRouterCatalog.holds("3.7", in: "qwen-3-8-flash"))
        #expect(!OpenRouterCatalog.holds("...", in: "qwen-3-8-flash"), "nothing left to find")
    }

    @Test func pricesAreReadFromHermesOpenRouterAndVenice() throws {
        #expect(ModelPrice.hermes("$0.30") == 0.3 && ModelPrice.hermes("free") == 0 && ModelPrice.hermes("?") == nil)
        let hermes = try JSONValue.parse(Data(#"{"providers":[{"slug":"openrouter","name":"OpenRouter","models":["a/b","c/d"],"pricing":{"a/b":{"input":"$0.30","output":"$2.50","cache":"$0.03","free":false}}}]}"#.utf8))
        let choices = HermesSessionsAPI.parseModelOptions(hermes)
        #expect(choices.first?.price == ModelPrice(input: 0.3, output: 2.5, cacheRead: 0.03))
        #expect(choices.last?.price == nil, "a model with no price has none")

        let openRouter = OpenRouterCatalog.parse(Data(#"{"data":[{"id":"q/f","name":"F","context_length":1000,"pricing":{"prompt":"0.00000015","completion":"0.0000006"}}]}"#.utf8))
        #expect(openRouter.first?.price == ModelPrice(input: 0.15, output: 0.6, cacheRead: nil))

        let venice = VenicePrices.parse(Data(#"{"data":[{"id":"qwen-3-8-flash","model_spec":{"availableContextTokens":1000000,"pricing":{"input":{"usd":0.14},"cache_input":{"usd":0.014},"output":{"usd":0.49}}}}]}"#.utf8))
        #expect(venice["qwen-3-8-flash"]?.price == ModelPrice(input: 0.14, output: 0.49, cacheRead: 0.014))
        #expect(venice["qwen-3-8-flash"]?.context == 1_000_000)
        #expect(ModelPrice(input: 0.14, output: 0.49).summary.contains("$0.14"))
        #expect(ModelPrice.dollars(0.014) == "$0.014")
    }

    @Test func aCustomEndpointOnTheInternetIsntLocal() {
        #expect(ModelChoice.isOnThisNetwork("http://paloma:11500/v1") == true)
        #expect(ModelChoice.isOnThisNetwork("http://192.168.1.20:8080") == true)
        #expect(ModelChoice.isOnThisNetwork("http://100.101.1.2:11500/v1") == true)
        #expect(ModelChoice.isOnThisNetwork("https://api.venice.ai/api/v1") == false)
        let local = ModelChoice(provider: "custom:local", providerName: "Local", model: "qwen36-splash", name: "qwen36-splash", isCurrent: true, onThisNetwork: true)
        let venice = ModelChoice(provider: "custom:venice", providerName: "venice", model: "qwen-3-8-flash", name: "qwen-3-8-flash", isCurrent: false, onThisNetwork: false)
        let groups = ModelPickerView.grouped([local, venice])
        #expect(groups.map(\.name) == ["Local", "venice"])
        #expect(groups[1].models.first?.provider == "custom:venice", "Venice's models keep Venice")
    }
}
