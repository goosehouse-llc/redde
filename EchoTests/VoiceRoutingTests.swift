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
}
