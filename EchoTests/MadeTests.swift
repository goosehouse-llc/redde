import Foundation
import Testing
@testable import Echo

/// The Made tab (asked 2026-10-28): what the agents made, from their replies: pages they wrote,
/// pictures and documents they sent, files they named on the server; never the person's own.
struct MadeTests {
    @Test func whatTheAgentMadeIsFoundAndThePersonsIsnt() {
        var mine = Message(role: .user, text: "Here's the plan: ~/notes/plan.md")
        mine.attachments = [Attachment(kind: .image, filename: "my-photo.jpg", mimeType: "image/jpeg", data: Data([1]))]
        var reply = Message(role: .assistant, text: "I wrote it up: MEDIA:/home/hermes/out/report.pdf and a chart.")
        var page = Attachment(kind: .other, filename: "trip.html", mimeType: "text/html", data: Data([1]))
        page.page = "/home/hermes/pages/trip.html"
        reply.attachments = [page, Attachment(kind: .image, filename: "chart.png", mimeType: "image/png", data: Data([1]))]
        let later = Message(role: .assistant, text: "Saved: MEDIA:/home/hermes/out/summary.csv", createdAt: .now.addingTimeInterval(60))
        let record = ConversationRecord(id: UUID(), title: "Trip", createdAt: .now, updatedAt: .now, transport: .hermesServe,
                                        serverSessionID: nil, messages: [mine, reply, later])
        let found = MadeItem.found(in: record, agent: "Sol")
        #expect(found.map(\.name) == ["summary.csv", "report.pdf", "chart.png", "trip.html"], "newest first")
        #expect(found.map(\.kind) == [.serverFile, .serverFile, .picture, .page])
        #expect(found.allSatisfy { $0.chat == "Trip" && $0.agent == "Sol" })
        #expect(!found.contains { $0.name == "my-photo.jpg" || $0.name == "plan.md" }, "the person's are theirs")
    }

    @Test func aFileNamedAndAttachedIsListedOnce() {
        var reply = Message(role: .assistant, text: "Here: MEDIA:/home/hermes/out/chart.png")
        reply.attachments = [Attachment(kind: .image, filename: "chart.png", mimeType: "image/png", data: Data([1]))]
        let record = ConversationRecord(id: UUID(), title: "Chart", createdAt: .now, updatedAt: .now, transport: .hermesServe,
                                        serverSessionID: nil, messages: [reply])
        #expect(MadeItem.found(in: record, agent: nil).map(\.kind) == [.picture])
    }
}
