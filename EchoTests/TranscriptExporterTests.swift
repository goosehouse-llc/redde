import Foundation
import Testing
@testable import Echo

struct TranscriptExporterTests {
    @Test func rendersRolesReasoningToolsAndErrors() {
        var reply = Message(role: .assistant, text: "Two things.\n\n- a\n- b")
        reply.reasoning = "thinking about it"
        reply.tools = [ToolActivity(name: "calendar", preview: nil, status: .completed), ToolActivity(name: "web", preview: nil, status: .failed)]
        reply.error = "rate limited"
        let md = TranscriptExporter.markdown(title: "Plan", messages: [Message(role: .user, text: "What's up?"), reply])
        #expect(md.hasPrefix("# Plan\n"))
        #expect(md.contains("## You\n\nWhat's up?"))
        #expect(md.contains("<details><summary>Thinking</summary>\n\nthinking about it"))
        #expect(md.contains("_Tools: calendar, web (failed)_"))
        #expect(md.contains("Two things.\n\n- a\n- b"))
        #expect(md.contains("> ⚠️ rate limited"))
    }

    @Test func fileNameIsSafe() throws {
        let url = try TranscriptExporter.file(title: "Kitchen: remodel / phase 2?", messages: [Message(role: .user, text: "hi")])
        #expect(url.lastPathComponent == "Kitchen-remodel--phase-2.md")
        #expect((try? String(contentsOf: url, encoding: .utf8))?.contains("hi") == true)
    }
}
