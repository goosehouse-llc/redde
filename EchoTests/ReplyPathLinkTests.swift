import Foundation
import Testing
@testable import Echo

/// A file a reply names only by its path opens from it (a Reddit report, 2026-10-22: an agent
/// said where it had left the sound files instead of sending them).
struct ReplyPathLinkTests {
    /// The paths made links, in order, as their links open them.
    private func linked(_ text: String) -> [String] {
        ServeMedia.linkingPaths(text).matches(of: /\]\((redde-file:[^)]*)\)/)
            .compactMap { URL(string: String($0.output.1)).flatMap(ServeMedia.linkedPath) }
    }

    @Test func pathsAReplyNamesAreLinks() {
        #expect(linked("I left it at /home/hermes/voices/af_heart.wav.") == ["/home/hermes/voices/af_heart.wav"])
        #expect(linked("Saved to ~/briefings/today.md, and a copy in ./out/today.pdf") == ["~/briefings/today.md", "./out/today.pdf"])
        #expect(linked("In the chat's folder: samples/bm_lewis.wav") == ["samples/bm_lewis.wav"])
        #expect(linked("**/tmp/report.pdf**") == ["/tmp/report.pdf"])
        #expect(linked("(/tmp/a.tar.gz)") == ["/tmp/a.tar.gz"])
        #expect(linked("Here: `/home/hermes/My Voices/af heart.wav`") == ["/home/hermes/My Voices/af heart.wav"], "in backticks a name can have spaces")
    }

    @Test func notWhatOnlyLooksLikeOne() {
        for text in ["https://example.com/a/b.png", "example.com/b.png", "www.example.com/b.pdf",
                     "[the chart](/tmp/chart.png)", "![x](/tmp/x.png)", "<https://x.org/a.pdf>",
                     "/home/hermes/run.py", "/etc/hosts", "report.md", "`cat /tmp/a.wav`", "`/tmp/a.wav --loud`",
                     "/tmp/a.wav.bak", "/tmp/a.wav-old", "and/or", "a\\/tmp/b.wav"] {
            #expect(ServeMedia.linkingPaths(text) == text, "\(text)")
        }
    }

    @Test func shownAsWrittenAndOpensWhatItNames() throws {
        let path = "/home/hermes/_drafts_/a&b.md"
        let attributed = try AttributedString(markdown: ServeMedia.linkingPaths("Left at \(path) for you"),
                                              options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        #expect(String(attributed.characters) == "Left at \(path) for you", "nothing in it read as emphasis or an entity")
        let url = try #require(attributed.runs.compactMap(\.link).first)
        #expect(ServeMedia.linkedPath(url) == path)
        #expect(ServeMedia.linkedPath(URL(string: "https://example.com/a.png")!) == nil)

        let code = try AttributedString(markdown: ServeMedia.linkingPaths("`~/My Voices/af heart.wav`"),
                                        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        #expect(String(code.characters) == "~/My Voices/af heart.wav")
        #expect(code.runs.compactMap(\.link).first.flatMap(ServeMedia.linkedPath) == "~/My Voices/af heart.wav")
    }

    @Test func inWhatIsReadNotInCode() {
        let blocks = MarkdownView.blocks("Saved /tmp/a.wav\n\n```\nplay /tmp/a.wav\n```\n\n- /tmp/b.pdf\n\n| file |\n|---|\n| /tmp/c.csv |", linkPaths: true)
        #expect(blocks.first == .paragraph("Saved [/tmp/a.wav](redde-file:/tmp/a.wav)"))
        if case let .code(_, code) = blocks[1] { #expect(code == "play /tmp/a.wav") } else { Issue.record("no code block: \(blocks)") }
        if case let .list(items) = blocks[2] { #expect(items.first?.text.contains("redde-file:/tmp/b.pdf") == true) } else { Issue.record("no list: \(blocks)") }
        if case let .table(_, rows, _) = blocks.last { #expect(rows.first?.first?.contains("redde-file:/tmp/c.csv") == true) } else { Issue.record("no table: \(blocks)") }
        #expect(MarkdownView.blocks("Saved /tmp/a.wav", linkPaths: false) == [.paragraph("Saved /tmp/a.wav")], "not while a reply is still coming")
    }
}
