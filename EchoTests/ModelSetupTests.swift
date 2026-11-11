import Foundation
import Testing
@testable import Echo

/// Models & Providers: reading what the Dashboard's routes (and the plugin's, in the same shapes)
/// answer.
struct ModelSetupTests {
    private func json(_ text: String) throws -> JSONValue { try JSONValue.parse(Data(text.utf8)) }

    @Test func readsTheSetupAsHermesGivesIt() throws {
        let options = try json("""
        {"model":"deepseek-v4","provider":"openrouter","providers":[
          {"slug":"openrouter","name":"OpenRouter","models":["deepseek-v4","qwen3"],"is_current":true,"authenticated":true,"key_env":"OPENROUTER_API_KEY"},
          {"slug":"anthropic","name":"Anthropic","models":[],"authenticated":false,"auth_type":"api_key","key_env":"ANTHROPIC_API_KEY","warning":"paste ANTHROPIC_API_KEY to activate"},
          {"slug":"custom:box","name":"Box","models":["splash"],"is_user_defined":true,"key_env":"HERMES_CUSTOM_BOX_API_KEY"}]}
        """)
        let env = try json("""
        {"OPENROUTER_API_KEY":{"is_set":true,"redacted_value":"«redacted:sk-o...7890»","provider":"openrouter","provider_label":"OpenRouter","provider_primary":true},
         "ANTHROPIC_API_KEY":{"is_set":false,"provider":"anthropic","provider_label":"Anthropic","provider_primary":true},
         "ANTHROPIC_TOKEN":{"is_set":false,"provider":"anthropic","provider_label":"Anthropic"},
         "MY_OWN_THING":{"is_set":true,"custom":true,"redacted_value":"«redacted:abc...xyz»"},
         "TELEGRAM_BOT_TOKEN":{"is_set":true,"redacted_value":"«redacted:123...abc»"},
         "HERMES_CUSTOM_BOX_API_KEY":{"is_set":true,"custom":true}}
        """)
        let endpoints = try json("""
        {"endpoints":[{"id":"box","name":"Box","base_url":"http://10.0.0.2:8080/v1","model":"splash","models":["splash"],"has_api_key":true,"is_current":false}]}
        """)
        let auxiliary = try json("""
        {"tasks":[{"task":"vision","provider":"auto","model":""},{"task":"title_generation","provider":"openrouter","model":"qwen3"}],"main":{"provider":"openrouter","model":"deepseek-v4"}}
        """)
        let fallbacks = try json("""
        [{"provider":"anthropic","model":"claude-haiku"},{"provider":"","model":"x"},{"provider":"custom:box","model":"splash","base_url":"http://10.0.0.2:8080/v1"}]
        """)
        let setup = ModelSetup.parse(options: options, env: env, endpoints: endpoints, auxiliary: auxiliary, fallbacks: fallbacks)

        #expect(setup.mainProvider == "openrouter")
        #expect(setup.mainModel == "deepseek-v4")
        // Only provider keys, and the preview without Hermes's wrapping.
        #expect(setup.keys["TELEGRAM_BOT_TOKEN"] == nil)
        #expect(setup.keys["MY_OWN_THING"] == nil)
        #expect(setup.keys["OPENROUTER_API_KEY"] == ModelSetup.Key(isSet: true, preview: "sk-o...7890"))
        #expect(setup.keys["HERMES_CUSTOM_BOX_API_KEY"]?.isSet == true)
        // The key list leaves endpoints to their own section; added ones first.
        #expect(setup.addedKeys.map(\.env) == ["OPENROUTER_API_KEY"])
        #expect(setup.missingKeys.map(\.env) == ["ANTHROPIC_API_KEY"])
        #expect(setup.addedKeys.first?.preview == "sk-o...7890")
        #expect(setup.providers.first { $0.slug == "anthropic" }?.ready == false)
        #expect(setup.endpoints.map(\.provider) == ["custom:box"])
        #expect(setup.endpoints.first?.isCurrent == false)
        // Hermes leaves an older entry unmarked; the default model's provider marks it.
        let older = ModelSetup.parse(options: try json(#"{"model":"splash","provider":"custom:box","providers":[]}"#), env: .null,
                                     endpoints: endpoints, auxiliary: .null, fallbacks: .null)
        #expect(older.endpoints.first?.isCurrent == true)
        #expect(setup.providerName("custom:box") == "Box")
        #expect(setup.helpers.map(\.followsMain) == [true, false])
        // An entry with no provider is dropped, as Hermes drops it.
        #expect(setup.fallbacks.map(\.id) == ["anthropic/claude-haiku", "custom:box/splash"])
        #expect(setup.choices.count == 3)
    }

    @Test func theOlderOneModelFallbackIsReadToo() {
        let one = JSONValue.object(["provider": .string("openrouter"), "model": .string("qwen3")])
        #expect(ModelSetup.fallbacks(one).map(\.model) == ["qwen3"])
        #expect(ModelSetup.fallbacks(.null).isEmpty)
    }

    @Test func aModelHermesWantsAYesForIsAsked() throws {
        let asked = try DashboardModelSetup.mainOutcome(try json(#"{"ok":false,"confirm_required":true,"confirm_message":"It costs $15 per million."}"#))
        #expect(asked == .confirm("It costs $15 per million."))
        let done = try DashboardModelSetup.mainOutcome(try json(#"{"ok":true,"stale_aux":[{"task":"vision","provider":"x","model":"y"}]}"#))
        #expect(done == .done(staleHelpers: ["vision"]))
        #expect(throws: ModelSetupProblem.self) { try DashboardModelSetup.mainOutcome(try json(#"{"ok":false,"error":"Unknown provider"}"#)) }
    }

    @Test func anEndpointKeepsItsKeyUnlessOneIsGivenOrTakenAway() {
        let keep = DashboardModelSetup.endpointBody(EndpointDraft(id: "box", name: "Box", baseURL: "http://b/v1", model: "m", apiKey: nil))
        #expect(keep["api_key"] == nil)
        #expect(keep["id"]?.string == "box")
        let clear = DashboardModelSetup.endpointBody(EndpointDraft(name: "Box", baseURL: "http://b/v1", model: "m", apiKey: ""))
        #expect(clear["api_key"]?.string == "")
    }
}
