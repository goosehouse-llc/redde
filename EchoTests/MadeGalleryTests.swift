import Foundation
import Testing
@testable import Echo

/// The Made page as a gallery (2026-11-13): each thing's look by its type, the counts at the
/// top, and the layout: the newest on its own, then each day's pictures in grid rows and its
/// pages and files as cards.
@MainActor
struct MadeGalleryTests {
    /// Midday, so nothing an hour either side crosses into another day.
    private let now = Calendar.current.date(from: DateComponents(year: 2027, month: 1, day: 15, hour: 12)) ?? .now

    private func item(_ kind: MadeItem.Kind, _ name: String, ago hours: Double, id: String? = nil) -> MadeItem {
        MadeItem(id: id ?? name, kind: kind, name: name, conversationID: UUID(), chat: "Chat", agent: nil,
                 at: now.addingTimeInterval(-hours * 3600))
    }

    @Test func aFilesLookComesFromItsType() {
        #expect(MadeLook.of(kind: .document, filename: "report.PDF") == .pdf)
        #expect(MadeLook.of(kind: .serverFile, filename: "Q4 budget.xlsx") == .sheet)
        #expect(MadeLook.of(kind: .serverFile, filename: "costs.csv") == .sheet)
        #expect(MadeLook.of(kind: .serverFile, filename: "deploy.py") == .code)
        #expect(MadeLook.of(kind: .document, filename: "notes.md") == .text)
        #expect(MadeLook.of(kind: .serverFile, filename: "deck.key") == .slides)
        #expect(MadeLook.of(kind: .serverFile, filename: "photos.zip") == .archive)
        #expect(MadeLook.of(kind: .serverFile, filename: "site.html") == .page)
        // A page or a picture is that, whatever it's called; no extension goes by the type.
        #expect(MadeLook.of(kind: .page, filename: "index.txt") == .page)
        #expect(MadeLook.of(kind: .picture, filename: "chart") == .picture)
        #expect(MadeLook.of(kind: .document, filename: "clip", mimeType: "video/mp4") == .video)
        #expect(MadeLook.of(kind: .document, filename: "speech", mimeType: "audio/mpeg") == .audio)
        #expect(MadeLook.of(kind: .serverFile, filename: "README") == .other)
    }

    @Test func theBadgeIsAShortExtension() {
        #expect(MadeLook.badge(for: "report.pdf") == "PDF")
        #expect(MadeLook.badge(for: "Q4 budget.xlsx") == "XLSX")
        #expect(MadeLook.badge(for: "README") == nil)
        #expect(MadeLook.badge(for: "archive.verylongext") == nil)
    }

    @Test func theCountsAreByKindAndByWhen() {
        let items = [
            item(.picture, "a.png", ago: 1), item(.picture, "b.png", ago: 30),
            item(.page, "p.html", ago: 2), item(.document, "d.pdf", ago: 24 * 3),
            item(.serverFile, "s.sh", ago: 24 * 20),
        ]
        let calendar = Calendar(identifier: .gregorian)
        let counts = MadeCounts(items, now: now, calendar: calendar)
        #expect(counts.pictures == 2 && counts.pages == 1 && counts.documents == 1 && counts.onServer == 1)
        #expect(counts.files == 2)
        #expect(counts.total == 5)
        #expect(counts.count(nil) == 5 && counts.count(.picture) == 2 && counts.count(.serverFile) == 1)
        #expect(counts.week == 4)
        let today = items.filter { calendar.isDate($0.at, inSameDayAs: now) }.count
        #expect(counts.today == today)
    }

    @Test func theSummarySaysOnlyWhatIsNew() {
        let none = MadeCounts([], now: now)
        #expect(none.summary == String(localized: "\(0) in all", comment: "Made page: how many things the agents made altogether, as “14 in all”"))
        // Everything this week and none today: the week alone, not "in all" too.
        let week = MadeCounts([item(.picture, "a.png", ago: 24 * 2), item(.page, "b.html", ago: 24 * 3)], now: now)
        #expect(week.summary == String(localized: "\(2) this week", comment: "Made page: how many things the agents made in the last seven days, as “9 this week”"))
    }

    @Test func theNewestStandsAloneAndPicturesGoInRows() {
        let items = [
            item(.page, "newest.html", ago: 0.1),
            item(.picture, "1.png", ago: 0.2), item(.document, "doc.pdf", ago: 0.3), item(.picture, "2.png", ago: 0.4),
            item(.picture, "3.png", ago: 0.5), item(.picture, "4.png", ago: 0.6),
            item(.serverFile, "old.sh", ago: 24 * 40),
        ]
        let layout = MadeLayout.rows(items, columns: 3, now: now)
        #expect(layout.featured?.name == "newest.html")
        let shapes: [String] = layout.rows.map {
            switch $0 {
            case .day: "day"
            case .pictures(let row): "pics\(row.count)"
            case .card(let item): item.name
            }
        }
        #expect(shapes == ["day", "pics3", "pics1", "doc.pdf", "day", "old.sh"])
        #expect(!layout.rows.contains { if case .card(let item) = $0 { item.name == "newest.html" } else { false } })
        #expect(Set(layout.rows.map(\.id)).count == layout.rows.count, "every row its own id")
    }

    @Test func nothingMadeLaysOutNothing() {
        let layout = MadeLayout.rows([], columns: 3, now: now)
        #expect(layout.featured == nil && layout.rows.isEmpty)
        #expect(MadeLayout.chunks([1, 2, 3, 4, 5], of: 2) == [[1, 2], [3, 4], [5]])
    }

    @Test func theBotsProfileIsKeptForItsFace() {
        var reply = Message(role: .assistant, text: "Saved: MEDIA:/home/hermes/out/summary.csv")
        reply.attachments = []
        let record = ConversationRecord(id: UUID(), title: "Trip", createdAt: .now, updatedAt: .now, transport: .hermesServe,
                                        serverSessionID: nil, messages: [reply])
        let found = MadeItem.found(in: record, agent: "Scout", profile: "scout")
        #expect(found.map(\.profile) == ["scout"])
        #expect(found.first?.look == .sheet)
        #expect(found.first?.opensHere == false, "a file on the server opens its chat")
    }

    #if DEBUG
    @Test func theSampleGalleryHasEveryKind() {
        let demo = MadeItem.demo(chats: [], now: now)
        #expect(Set(demo.map(\.kind)) == Set(MadeItem.Kind.allCases))
        #expect(demo == demo.sorted { $0.at > $1.at })
        #expect(demo.filter { $0.kind == .picture }.allSatisfy { $0.attachment.map { !$0.data.isEmpty } ?? false })
    }
    #endif
}
