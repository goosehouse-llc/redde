import Foundation
import SwiftUI
import Testing
import WidgetKit
@testable import Echo

/// The "Needs you" and Context widgets: the list of what waits, kept in the App Group by the app
/// and the notification extension both; the reading of how full the context is; the timelines the
/// widgets are given; and the conversation's own hand in each.
@MainActor
struct StatusWidgetTests {
    private func suite() -> UserDefaults { UserDefaults(suiteName: "widgets-\(UUID().uuidString)")! }

    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func request(_ id: String, _ kind: WaitingRequest.Kind = .approval, _ text: String = "rm -rf build", title: String? = "Tidy up",
                         at since: Date? = nil) -> WaitingRequest {
        let since = since ?? start
        return WaitingRequest(id: id, kind: kind, title: title, text: text, session: id, since: since, until: since.addingTimeInterval(NeedsYou.lifetime(kind)))
    }

    private func note(_ kind: String, session: String? = "s-1", _ body: String? = "rm -rf build", at: Date? = nil) -> PushNote {
        PushNote(k: kind, s: session, t: "Tidy up", b: body, at: (at ?? start).timeIntervalSince1970)
    }

    // MARK: What waits

    @Test func aRequestWaitsUntilItIsSettledOrItsTimeIsUp() {
        let defaults = suite()
        #expect(NeedsYou.note(request("s-1"), at: start, in: defaults))
        #expect(NeedsYou.note(request("s-2", .question, "Which branch?"), at: start, in: defaults))
        // The one that runs out first comes first: the approval, five minutes against an hour.
        #expect(NeedsYou.waiting(at: start, in: defaults).map(\.id) == ["s-1", "s-2"])
        #expect(NeedsYou.waiting(at: start.addingTimeInterval(301), in: defaults).map(\.id) == ["s-2"], "Hermes gave up on the approval")
        #expect(NeedsYou.waiting(at: start.addingTimeInterval(3601), in: defaults).isEmpty)

        #expect(NeedsYou.settle("s-2", at: start, in: defaults))
        #expect(!NeedsYou.settle("s-2", at: start, in: defaults), "nothing left to settle")
        #expect(NeedsYou.waiting(at: start, in: defaults).map(\.id) == ["s-1"])
        NeedsYou.clear(in: defaults)
        #expect(NeedsYou.waiting(at: start, in: defaults).isEmpty)
    }

    @Test func aConversationWaitsOnOneThing() {
        let defaults = suite()
        NeedsYou.note(request("s-1"), at: start, in: defaults)
        // The same request heard of again, a few seconds on: nothing new, and its clock stands.
        #expect(!NeedsYou.note(request("s-1", at: start.addingTimeInterval(4)), at: start.addingTimeInterval(4), in: defaults))
        #expect(NeedsYou.waiting(at: start, in: defaults).first?.since == start)
        // Another command in that conversation takes its place.
        #expect(NeedsYou.note(request("s-1", .approval, "git push --force", at: start.addingTimeInterval(20)), at: start.addingTimeInterval(20), in: defaults))
        #expect(NeedsYou.waiting(at: start, in: defaults).map(\.text) == ["git push --force"])
        // The same command asked again long after is a new request.
        #expect(NeedsYou.note(request("s-1", .approval, "git push --force", at: start.addingTimeInterval(200)), at: start.addingTimeInterval(200), in: defaults))
    }

    @Test func hermesWaitsAsLongAsItsDefaultsSay() {
        #expect(NeedsYou.lifetime(.approval) == 300)   // approvals.timeout
        #expect(NeedsYou.lifetime(.question) == 3600)  // clarify_timeout
        #expect(NeedsYou.lifetime(.sudo) == 120)
        #expect(NeedsYou.lifetime(.secret) == 300)
        let id = UUID()
        #expect(NeedsYou.key(session: "s-1", conversation: id) == "s-1")
        #expect(NeedsYou.key(session: nil, conversation: id) == "c:\(id.uuidString)")
    }

    // MARK: Notes from a paired Hermes

    @Test func aNoteAboutARequestPutsItOnTheListAndALaterOneTakesItOff() throws {
        let defaults = suite()
        #expect(NeedsYou.take(note("approval"), at: start.addingTimeInterval(2), in: defaults))
        let waiting = try #require(NeedsYou.waiting(at: start, in: defaults).first)
        #expect(waiting == WaitingRequest(id: "s-1", kind: .approval, title: "Tidy up", text: "rm -rf build", session: "s-1",
                                         since: start, until: start.addingTimeInterval(300)))
        // The same note delivered twice changes nothing.
        #expect(!NeedsYou.take(note("approval"), at: start.addingTimeInterval(3), in: defaults))
        // The turn went on and ended: the conversation waits on nothing.
        #expect(NeedsYou.take(note("reply", "Done."), at: start.addingTimeInterval(60), in: defaults))
        #expect(NeedsYou.waiting(at: start, in: defaults).isEmpty)

        #expect(NeedsYou.take(note("question", "Which branch?"), at: start, in: defaults))
        #expect(NeedsYou.take(note("failed", "The model stopped answering."), at: start, in: defaults))
        #expect(NeedsYou.waiting(at: start, in: defaults).isEmpty)
        for (kind, expected) in [("sudo", WaitingRequest.Kind.sudo), ("secret", .secret)] {
            NeedsYou.take(note(kind, session: kind), at: start, in: defaults)
            #expect(NeedsYou.waiting(at: start, in: defaults).first { $0.id == kind }?.kind == expected)
        }
    }

    @Test func notesThatSayNothingAboutWaitingLeaveTheListAlone() {
        let defaults = suite()
        NeedsYou.note(request("s-1"), at: start, in: defaults)
        for kind in ["task", "paired", "test", "something-newer"] {
            #expect(!NeedsYou.take(note(kind), at: start, in: defaults), "\(kind)")
        }
        #expect(!NeedsYou.take(note("approval", session: nil), at: start, in: defaults), "no session to file it under")
        #expect(!NeedsYou.take(note("reply", session: "another"), at: start, in: defaults))
        // A note that reached the phone after Hermes had given up on its request.
        #expect(!NeedsYou.take(note("approval", session: "late"), at: start.addingTimeInterval(400), in: defaults))
        #expect(NeedsYou.waiting(at: start, in: defaults).map(\.id) == ["s-1"])
    }

    @Test func aNoteThatArrivesAfterItsRequestWasAnsweredDoesNotBringItBack() {
        let defaults = suite()
        // The app showed the card and it was answered there; Hermes's note about the same
        // command is still on its way, and the plugin has cut a long command short.
        let command = "find . -name '*.log' -mtime +30 -delete && echo done with the old logs in every folder"
        NeedsYou.note(request("s-1", .approval, command), at: start, in: defaults)
        NeedsYou.settle("s-1", at: start.addingTimeInterval(3), in: defaults)
        #expect(!NeedsYou.take(note("approval", String(command.prefix(50)) + "…"), at: start.addingTimeInterval(5), in: defaults))
        #expect(NeedsYou.waiting(at: start, in: defaults).isEmpty)
        // Another command in that conversation is a new request, and so is the same one once
        // Hermes would have stopped waiting for the first.
        #expect(NeedsYou.take(note("approval", "git push --force", at: start.addingTimeInterval(8)), at: start.addingTimeInterval(8), in: defaults))
        NeedsYou.settle("s-1", at: start.addingTimeInterval(9), in: defaults)
        #expect(NeedsYou.take(note("approval", "git push --force", at: start.addingTimeInterval(400)), at: start.addingTimeInterval(400), in: defaults))
        // One the app sees for itself is live, whatever was remembered.
        NeedsYou.settle("s-1", at: start.addingTimeInterval(401), in: defaults)
        #expect(NeedsYou.note(request("s-1", .approval, "git push --force", at: start.addingTimeInterval(402)), at: start.addingTimeInterval(402), in: defaults))
    }

    // MARK: The widgets' timelines and links

    @Test func theWidgetLetsGoOfEachRequestWhenItsTimeIsUp() {
        let requests = [request("s-1"), request("s-2", .question, "Which branch?"), request("s-3", .sudo, "")]
        let entries = NeedsYouEntry.timeline(requests, from: start.addingTimeInterval(10), hidesWords: true)
        #expect(entries.map(\.date) == [10, 120, 300, 3600].map { start.addingTimeInterval($0) })
        #expect(entries.map { $0.requests.map(\.id) } == [["s-1", "s-2", "s-3"], ["s-1", "s-2"], ["s-2"], []])
        #expect(entries.map(\.hidesWords) == [true, true, true, true])
        #expect(entries.first?.relevance != nil && entries.last?.relevance == nil, "something waiting is worth showing; nothing isn't")
        // Nothing waiting: one entry, and no dates to come back for.
        #expect(NeedsYouEntry.timeline([], from: start, hidesWords: false).map(\.requests.count) == [0])
        #expect(NeedsYouEntry.timeline([request("old")], from: start.addingTimeInterval(900), hidesWords: false).map(\.requests.count) == [0])
    }

    @Test func aTapOpensTheConversationThatWaits() throws {
        let url = NeedsYouCard.destination(request("20261008_101500_ab12cd"))
        #expect(url.absoluteString == "echo://session?id=20261008_101500_ab12cd")
        #expect(EchoURL.parseSession(url) == "20261008_101500_ab12cd")
        #expect(EchoURL.parseSession(EchoURL.session("a b&c=d")) == "a b&c=d")
        #expect(EchoURL.parseSession(EchoURL.open) == nil)
        #expect(EchoURL.parseSession(EchoURL.listen(handsFree: true)) == nil)
        let bare = try #require(URL(string: "echo://session"))
        #expect(EchoURL.parseSession(bare) == nil)
        // A conversation the server has no session for: the app comes forward where it is.
        var local = request("c:local")
        local.session = nil
        #expect(NeedsYouCard.destination(local) == EchoURL.open)
        #expect(NeedsYouCard.destination(nil) == EchoURL.open)
        #expect(NeedsYouCard.count(0) == "Nothing needs you")
        #expect(NeedsYouCard.count(1) == "1 waiting on you")
        #expect(NeedsYouCard.count(3) == "3 waiting on you")
    }

    // MARK: Drawing

    /// A card drawn at a widget's size, with the margins and background a widget gives it.
    private func drawn(_ card: some View, _ family: WidgetFamily, dark: Bool = false) -> UIImage? {
        let size: CGSize = switch family {
        case .systemMedium: CGSize(width: 364, height: 170)
        case .accessoryCircular: CGSize(width: 76, height: 76)
        case .accessoryRectangular: CGSize(width: 172, height: 76)
        case .accessoryInline: CGSize(width: 240, height: 26)
        default: CGSize(width: 170, height: 170)
        }
        let home = family == .systemSmall || family == .systemMedium
        let renderer = ImageRenderer(content: card
            .padding(home ? 16 : 0)
            .frame(width: size.width, height: size.height)
            .background(home ? Color(.secondarySystemBackground) : Color(.systemGray4), in: .rect(cornerRadius: home ? 24 : 12))
            .padding(8)
            .background(Color(.systemBackground))
            .environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = 3
        return renderer.uiImage
    }

    @Test func theCardsDrawInEverySize() {
        let two = [request("s-1", .approval, "rm -rf ~/builds/2025-* && find . -name '*.log' -mtime +30 -delete", title: "Clear out the old builds"),
                   request("s-2", .question, "Should the old addresses redirect at the server, or with a plugin?", title: "Move the blog to the new site")]
        let reading = ContextReading(used: 84_600, window: 128_000, title: "Move the blog to the new site", date: start)
        var shots: [(String, UIImage?)] = []
        for family in [WidgetFamily.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline] {
            shots.append(("needs-two-\(family)", drawn(NeedsYouCard(requests: two, family: family), family)))
            shots.append(("needs-one-\(family)", drawn(NeedsYouCard(requests: [two[0]], family: family), family)))
            shots.append(("needs-none-\(family)", drawn(NeedsYouCard(requests: [], family: family), family)))
            shots.append(("needs-hidden-\(family)", drawn(NeedsYouCard(requests: two, hidesWords: true, family: family), family)))
        }
        shots.append(("needs-dark-systemMedium", drawn(NeedsYouCard(requests: two, family: .systemMedium), .systemMedium, dark: true)))
        for family in [WidgetFamily.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline] {
            shots.append(("context-\(family)", drawn(ContextCard(reading: reading, family: family), family)))
            shots.append(("context-none-\(family)", drawn(ContextCard(reading: nil, family: family), family)))
            shots.append(("context-hidden-\(family)", drawn(ContextCard(reading: reading, hidesWords: true, family: family), family)))
        }
        shots.append(("context-full-systemSmall", drawn(ContextCard(reading: ContextReading(used: 121_000, window: 128_000, title: "A long one", date: start), family: .systemSmall), .systemSmall)))
        shots.append(("context-dark-systemSmall", drawn(ContextCard(reading: reading, family: .systemSmall), .systemSmall, dark: true)))
        for (name, image) in shots {
            #expect(image != nil, "\(name) didn't draw")
        }
    }

    // MARK: The context reading

    @Test func aReadingIsSavedOnceAndSaysHowFull() throws {
        let defaults = suite()
        let reading = ContextReading(used: 54_210, window: 128_000, title: "Plan the hike", date: start)
        #expect(abs(reading.share - 0.4235) < 0.001)
        #expect(reading.amounts == "54k of 128k")
        #expect(ContextReading(used: 900, window: 8192, title: nil, date: start).amounts == "900 of 8.2k")
        #expect(ContextReading(used: 300_000, window: 200_000, title: nil, date: start).share == 1, "never past full")
        #expect(ContextReading(used: 5, window: 0, title: nil, date: start).share == 0)

        #expect(reading.save(in: defaults))
        var again = reading
        again.date = start.addingTimeInterval(60)
        #expect(!again.save(in: defaults), "the same reading taken later is no news for the widget")
        #expect(ContextReading.load(in: defaults)?.date == start)
        again.used = 60_000
        #expect(again.save(in: defaults))
        #expect(ContextReading.load(in: defaults)?.used == 60_000)
        ContextReading.clear(in: defaults)
        #expect(ContextReading.load(in: defaults) == nil)
    }

    // MARK: The conversation's hand in it

    private func conversation(_ events: [TurnEvent], hang: Bool = false, defaults: UserDefaults) -> Conversation {
        let settings = Settings(defaults: UserDefaults(suiteName: "widgets-\(UUID().uuidString)")!)
        settings.transport = .chatCompletions
        settings.fastLaneURL = "http://example.invalid:11500"
        settings.fastLaneModel = "test"
        let conversation = Conversation(settings: settings,
                                        store: ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "widgets-\(UUID().uuidString)")),
                                        transportOverride: ConversationLifecycleTests.ScriptedTransport(events, hang: hang))
        conversation.widgetDefaults = defaults
        return conversation
    }

    private func waits(_ conversation: Conversation) async throws {
        for _ in 0 ..< 300 where conversation.pendingInterrupt == nil { try await Task.sleep(for: .milliseconds(10)) }
    }

    private let approval = ApprovalRequest(id: "req-1", command: "rm -rf ~/builds/2025-*", description: "recursive delete", choices: ["once", "deny"])

    @Test func aCardInTheAppIsOnTheWidgetForAsLongAsItWaits() async throws {
        let defaults = suite()
        let c = conversation([.sessionID("s-9"), .interrupt(.approval(approval), runtimeSession: "run-1")], hang: true, defaults: defaults)
        _ = c.send("Clear out the old builds")
        try await waits(c)
        let waiting = try #require(NeedsYou.waiting(in: defaults).first)
        #expect(waiting.id == "s-9" && waiting.session == "s-9")
        #expect(waiting.kind == .approval && waiting.text == "rm -rf ~/builds/2025-*")
        #expect(waiting.title == "Clear out the old builds")
        #expect(abs(waiting.until.timeIntervalSince(waiting.since) - 300) < 1)
        // Stop: the turn is over, and nothing waits.
        c.cancel()
        #expect(NeedsYou.waiting(in: defaults).isEmpty)
    }

    @Test func aRequestThatExpiresOrATurnThatEndsComesOffTheWidget() async throws {
        let question = ClarifyRequest(id: "req-2", questions: [.init(id: "", question: "Which branch should I push?", choices: [], multiSelect: false)], isBatch: false)
        let expired = suite()
        let c = conversation([.sessionID("s-1"), .interrupt(.clarify(question), runtimeSession: "run-1")], hang: true, defaults: expired)
        _ = c.send("Push it")
        try await waits(c)
        #expect(NeedsYou.waiting(in: expired).map(\.text) == ["Which branch should I push?"])
        #expect(NeedsYou.waiting(in: expired).first?.kind == .question)

        // Hermes says the request ran out.
        let gone = suite()
        let d = conversation([.sessionID("s-2"), .interrupt(.approval(approval), runtimeSession: "run-2"), .interruptExpired(id: "req-1")], hang: true, defaults: gone)
        _ = d.send("Clear out the old builds")
        for _ in 0 ..< 300 where d.statusLine != "request expired" { try await Task.sleep(for: .milliseconds(10)) }
        #expect(d.statusLine == "request expired")
        #expect(NeedsYou.waiting(in: gone).isEmpty)

        // It was answered somewhere else and the turn ran to its end.
        let ended = suite()
        let e = conversation([.sessionID("s-3"), .interrupt(.approval(approval), runtimeSession: "run-3"), .textDelta("Removed."), .done], defaults: ended)
        _ = e.send("Clear out the old builds")
        for _ in 0 ..< 300 where e.isStreaming { try await Task.sleep(for: .milliseconds(10)) }
        #expect(e.messages.last?.text == "Removed.")
        #expect(NeedsYou.waiting(in: ended).isEmpty)
    }

    @Test func aReplyThatSaysHowFullTheContextIsGoesToTheWidget() async throws {
        let defaults = suite()
        let c = conversation([.textDelta("Sunrise at Bear Peak works."), .usage(TokenUsage(input: 54_000, output: 210, cached: nil, contextUsed: 54_210, contextMax: 128_000)), .done],
                             defaults: defaults)
        #expect(ContextReading.load(in: defaults) == nil, "a new conversation has no reading")
        _ = c.send("Plan the weekend hike")
        for _ in 0 ..< 300 where c.isStreaming { try await Task.sleep(for: .milliseconds(10)) }
        let reading = try #require(ContextReading.load(in: defaults))
        #expect(reading.used == 54_210 && reading.window == 128_000)
        #expect(reading.title == "Plan the weekend hike")
        // A new conversation, with no reading of its own yet, leaves that one on the widget.
        c.reset()
        #expect(ContextReading.load(in: defaults)?.title == "Plan the weekend hike")
    }
}
