import Testing
@testable import Echo

struct MarkdownParserTests {
    @Test func parsesCommonBlocks() {
        let md = """
        # Title
        Some **bold** text
        continues here.

        - one
        - two
          more of two
        1. first
        2. second

        > quoted

        ```swift
        let x = 1
        ```

        | a | b |
        |---|---|
        | 1 | 2 |
        ---
        """
        let blocks = MarkdownParser.parse(md)
        #expect(blocks[0] == .heading(level: 1, text: "Title"))
        #expect(blocks[1] == .paragraph("Some **bold** text continues here."))
        guard case let .list(items) = blocks[2] else { Issue.record("expected list"); return }
        #expect(items.map(\.text) == ["one", "two more of two", "first", "second"])
        #expect(items[2].ordered && items[2].marker == "1.")
        #expect(blocks[3] == .quote([.paragraph("quoted")]))
        #expect(blocks[4] == .code(language: "swift", text: "let x = 1"))
        #expect(blocks[5] == .table(header: ["a", "b"], rows: [["1", "2"]], alignments: [.leading, .leading]))
        #expect(blocks[6] == .rule)
    }

    @Test func unterminatedFenceStreams() {
        let blocks = MarkdownParser.parse("Here:\n```python\nprint(1)")
        #expect(blocks == [.paragraph("Here:"), .code(language: "python", text: "print(1)")])
    }

    @Test func plainTextIsOneParagraph() {
        #expect(MarkdownParser.parse("just words") == [.paragraph("just words")])
        #expect(MarkdownParser.parse("").isEmpty)
    }

    @Test func taskListsImagesAlignmentsAndHardBreaks() {
        let blocks = MarkdownParser.parse("""
        - [ ] open
        - [x] done

        ![diagram](https://example.com/a.png)

        | Name | Qty | Price |
        |:-----|:---:|------:|
        | Tea  |  2  |  3.50 |

        line one  
        line two

        > quote with
        > - a list
        """)
        guard case let .list(items) = blocks[0] else { Issue.record("expected list"); return }
        #expect(items[0].checked == false && items[0].text == "open")
        #expect(items[1].checked == true && items[1].text == "done")
        #expect(blocks[1] == .image(alt: "diagram", url: "https://example.com/a.png"))
        guard case let .table(_, rows, alignments) = blocks[2] else { Issue.record("expected table"); return }
        #expect(alignments == [.leading, .center, .trailing] && rows == [["Tea", "2", "3.50"]])
        #expect(blocks[3] == .paragraph("line one\nline two"))
        #expect(blocks[4] == .quote([.paragraph("quote with"), .list(items: [.init(ordered: false, marker: "•", text: "a list", indent: 0)])]))
    }

    /// The API server inlines a picture the agent sends mid-sentence ("Here it is ![image](…)"),
    /// so an image inside a paragraph must split out and render, not show as raw markup.
    @Test func imageEmbeddedInAParagraph() {
        let blocks = MarkdownParser.parse("Here it is ![camera](data:image/jpeg;base64,/9j/4AAQ==) — fresh.")
        #expect(blocks == [.paragraph("Here it is"),
                           .image(alt: "camera", url: "data:image/jpeg;base64,/9j/4AAQ=="),
                           .paragraph("— fresh.")])
    }

    @Test func twoImagesInOneParagraph() {
        let blocks = MarkdownParser.parse("![a](https://example.com/a.png) and ![b](https://example.com/b.png)")
        #expect(blocks == [.image(alt: "a", url: "https://example.com/a.png"),
                           .paragraph("and"),
                           .image(alt: "b", url: "https://example.com/b.png")])
    }

    /// Wikipedia-style URLs carry balanced parentheses; the scanner must find the closing
    /// `)` of the destination, not the first `)` inside it.
    @Test func imageURLWithParenthesesDoesNotTruncate() {
        let url = "https://upload.example.org/wiki/Paris_(France).png"
        let blocks = MarkdownParser.parse("See ![map](\(url)) for the layout.")
        #expect(blocks == [.paragraph("See"),
                           .image(alt: "map", url: url),
                           .paragraph("for the layout.")])

        let alone = MarkdownParser.parse("![map](\(url))")
        #expect(alone == [.image(alt: "map", url: url)])
    }

    /// A command presented as a lone inline code span gets the copyable code window;
    /// inline code inside a sentence stays part of the paragraph.
    @Test func loneInlineCodePromotesToACodeBlock() {
        let blocks = MarkdownParser.parse("Run this:\n\n`ssh root@10.0.0.2 \"systemctl restart hermes\"`\n\nThen check the logs with `journalctl -u hermes`.")
        #expect(blocks == [.paragraph("Run this:"),
                           .code(language: nil, text: "ssh root@10.0.0.2 \"systemctl restart hermes\""),
                           .paragraph("Then check the logs with `journalctl -u hermes`.")])
        #expect(MarkdownParser.parse("`a` and `b`") == [.paragraph("`a` and `b`")])
    }

    @Test func bangBracketWithoutAnImageStaysText() {
        #expect(MarkdownParser.parse("array![0] is fine") == [.paragraph("array![0] is fine")])
        #expect(MarkdownParser.parse("wow ![just brackets]") == [.paragraph("wow ![just brackets]")])
    }

    @Test func setextHeadings() {
        let blocks = MarkdownParser.parse("Title\n=====\n\nSub\n---\n\ntext")
        #expect(blocks == [.heading(level: 1, text: "Title"), .heading(level: 2, text: "Sub"), .paragraph("text")])
    }

    @Test func displayMathBlocks() {
        let blocks = MarkdownParser.parse("""
        $$E = mc^2$$

        $$
        \\int_0^1 x\\,dx
        = \\tfrac12
        $$

        \\[ a^2 + b^2 = c^2 \\]

        price is $5 and $6
        """)
        #expect(blocks[0] == .math("E = mc^2"))
        #expect(blocks[1] == .math("\\int_0^1 x\\,dx\n= \\tfrac12"))
        #expect(blocks[2] == .math("a^2 + b^2 = c^2"))
        #expect(blocks[3] == .paragraph("price is $5 and $6"))
    }
}
