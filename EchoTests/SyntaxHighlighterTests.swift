import Testing
@testable import Echo

struct SyntaxHighlighterTests {
    private func tokens(_ code: String, _ lang: String) -> [(String, SyntaxHighlighter.Token)] {
        SyntaxHighlighter.tokenize(code, language: .resolve(lang))
    }

    @Test func swiftKeywordsStringsComments() {
        let t = tokens("let x = \"hi\" // note\nstruct Foo {}", "swift")
        #expect(t.contains { $0 == ("let", .keyword) })
        #expect(t.contains { $0 == ("\"hi\"", .string) })
        #expect(t.contains { $0 == ("// note", .comment) })
        #expect(t.contains { $0 == ("Foo", .type) })
    }

    @Test func pythonTripleQuoteSpansLines() {
        let t = tokens("s = \"\"\"a\nb\"\"\"\nprint(3)", "python")
        #expect(t.contains { $0 == ("\"\"\"a\nb\"\"\"", .string) })
        #expect(t.contains { $0 == ("3", .number) })
    }

    @Test func jsonKeysVersusValues() {
        let t = tokens("{\"name\": \"x\", \"n\": 2, \"ok\": true}", "json")
        #expect(t.contains { $0 == ("\"name\"", .key) })
        #expect(t.contains { $0 == ("\"x\"", .string) })
        #expect(t.contains { $0 == ("true", .keyword) })
    }

    @Test func shellCommentNotInsideWord() {
        let t = tokens("echo a#b # real", "bash")
        #expect(!t.contains { $0.0 == "#b # real" })
        #expect(t.contains { $0 == ("# real", .comment) })
        #expect(t.contains { $0 == ("echo", .keyword) })
    }

    @Test func roundTripsText() {
        let code = "fn main() { let s = \"x\"; /* c */ 42 }"
        let joined = tokens(code, "rust").map(\.0).joined()
        #expect(joined == code)
    }

    @Test func htmlTagsAndAttributes() {
        let t = tokens("<div class=\"a\">hi</div>", "html")
        #expect(t.contains { $0 == ("<div", .keyword) })
        #expect(t.contains { $0 == ("class", .attribute) })
        #expect(t.contains { $0 == ("\"a\"", .string) })
    }
}
