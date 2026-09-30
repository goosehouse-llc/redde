import Foundation
import Testing
@testable import Echo

struct VoiceRoutingTests {
    private let claude = SpokenPrefix(word: "Claude", aliases: ["Klaud", "Clod"], prefix: "C ")

    @Test func noRulesChangeNothing() {
        #expect(VoiceRouting.routed("Claude, what's using port 8880?", rules: []) == nil)
    }

    @Test func aLeadingWordBecomesItsPrefix() {
        #expect(VoiceRouting.routed("Claude, what's using port 8880?", rules: [claude]) == "C what's using port 8880?")
        #expect(VoiceRouting.routed("Hey Claude check the soak report", rules: [claude]) == "C check the soak report")
    }

    @Test func theWordMustLead() {
        #expect(VoiceRouting.routed("What did Claude say earlier?", rules: [claude]) == nil)
    }

    @Test func nothingLeftMeansNothingSent() {
        #expect(VoiceRouting.routed("Claude.", rules: [claude]) == nil)
        #expect(VoiceRouting.routed("Claude", rules: [claude]) == nil)
    }

    @Test func caseDoesNotMatter() {
        #expect(VoiceRouting.routed("claude, list the containers", rules: [claude]) == "C list the containers")
        #expect(VoiceRouting.routed("CLAUDE list the containers", rules: [claude]) == "C list the containers")
    }

    @Test func aliasesMatchToo() {
        #expect(VoiceRouting.routed("Klaud, restart the server", rules: [claude]) == "C restart the server")
        #expect(VoiceRouting.routed("clod restart the server", rules: [claude]) == "C restart the server")
    }

    @Test func okAndOkayLeadInsAreDropped() {
        #expect(VoiceRouting.routed("ok claude, how's the build?", rules: [claude]) == "C how's the build?")
        #expect(VoiceRouting.routed("Okay, Claude, how's the build?", rules: [claude]) == "C how's the build?")
    }

    @Test func aRuleWithoutAPrefixIsSkipped() {
        let empty = SpokenPrefix(word: "Claude", prefix: "")
        #expect(VoiceRouting.routed("Claude, hello", rules: [empty]) == nil)
        #expect(VoiceRouting.routed("Claude, hello", rules: [empty, claude]) == "C hello")
    }

    @Test func theFirstMatchingRuleWins() {
        let broad = SpokenPrefix(word: "Claude", prefix: "X ")
        #expect(VoiceRouting.routed("Claude, hello", rules: [broad, claude]) == "X hello")
        #expect(VoiceRouting.routed("Claude, hello", rules: [claude, broad]) == "C hello")
    }

    @Test func aMultiLineTranscriptKeepsItsNewlines() {
        #expect(VoiceRouting.routed("Claude, first line\nsecond line", rules: [claude]) == "C first line\nsecond line")
    }

    @Test func wordBoundaryStopsPartialMatches() {
        #expect(VoiceRouting.routed("Claudette, are you there?", rules: [claude]) == nil)
    }

    @Test func contextualStringsAreTheWords() {
        let blank = SpokenPrefix(word: "", prefix: "Z ")
        #expect(VoiceRouting.contextualStrings(for: [claude, blank]) == ["Claude"])
    }

    // MARK: Model routing

    private let opus = SpokenPrefix(word: "Opus", prefix: "", model: "claude-opus-5-5", provider: "anthropic")

    @Test func aRuleWithAModelStripsTheWordAndNamesTheModel() {
        let route = VoiceRouting.route("Opus, review the diff", rules: [opus])
        #expect(route == VoiceRouting.Route(text: "review the diff", model: "claude-opus-5-5", provider: "anthropic"))
    }

    @Test func aRuleWithPrefixAndModelDoesBoth() {
        let both = SpokenPrefix(word: "Claude", prefix: "C ", model: "claude-opus-5-5", provider: "anthropic")
        let route = VoiceRouting.route("Claude, hello", rules: [both])
        #expect(route?.text == "C hello")
        #expect(route?.model == "claude-opus-5-5")
    }

    @Test func aTextOnlyRuleNamesNoModel() {
        let route = VoiceRouting.route("Claude, hello", rules: [claude])
        #expect(route?.model == nil)
        #expect(route?.provider == nil)
    }

    @Test func anEmptyModelCountsAsNone() {
        let blank = SpokenPrefix(word: "Claude", prefix: "", model: "", provider: "anthropic")
        #expect(VoiceRouting.route("Claude, hello", rules: [blank]) == nil)
        #expect(!blank.isActive)
        #expect(opus.isActive)
    }

    @Test func rulesSavedWithoutAModelStillDecode() throws {
        let json = Data(#"[{"id":"6B1B7E63-0C1C-4E5C-9F0E-2A1C4D5E6F70","word":"Claude","aliases":["Klaud"],"prefix":"C "}]"#.utf8)
        let rules = try JSONDecoder().decode([SpokenPrefix].self, from: json)
        #expect(rules.first?.model == nil)
        #expect(VoiceRouting.routed("Klaud, hi", rules: rules) == "C hi")
    }
}
