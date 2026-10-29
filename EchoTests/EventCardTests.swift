import Foundation
import Testing
@testable import Echo

/// A heads-up's event card (asked 2026-10-29): when it starts, whether it is online and on what.
@MainActor
struct EventCardTests {
    @Test func theStartIsReadFromTheWordsWhenThePluginSentNone() throws {
        let now = Date.now
        var briefing = AgentBriefing(id: "h", title: "Heads-up: Design review", agent: "Sol",
                                     text: "Design review is tomorrow at 9:15 AM, on Zoom. No agenda yet.", at: now, failed: false)
        let read = try #require(briefing.startsAt)
        let parts = Calendar.current.dateComponents([.hour, .minute], from: read)
        #expect((parts.hour, parts.minute) == (9, 15))
        #expect(read > now && read < now.addingTimeInterval(36 * 3600))
        let sent = now.addingTimeInterval(1800)
        briefing.eventAt = sent
        #expect(briefing.startsAt == sent, "the plugin's start wins")
        let wrapUp = AgentBriefing(id: "w", title: "Evening wrap-up", agent: "Sol", text: "Tomorrow at 9:15 AM: the review.", at: now, failed: false)
        #expect(wrapUp.startsAt == nil, "only a heads-up is an event")
    }

    @Test func aMeetingLinkIsJoinedAndANamedServiceIsShown() {
        let linked = EventDetails.online(in: "Join at https://acme.zoom.us/j/123456789 when it starts.")
        #expect(linked?.service == "Zoom" && linked?.link?.host() == "acme.zoom.us")
        #expect(EventDetails.online(in: "Zoom via the link in the calendar invite.") == .init(service: "Zoom", link: nil))
        #expect(EventDetails.online(in: "A Google Meet call with the team.")?.service == "Google Meet")
        #expect(EventDetails.online(in: "The invite is virtual.") == .init(service: nil, link: nil))
        #expect(EventDetails.online(in: "At the dentist on Main St.") == nil)
    }

    @Test func theCountdownSaysHowLongUntilOrSince() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(EventDetails.until(now.addingTimeInterval(28 * 60), now: now).contains("28"))
        #expect(EventDetails.until(now.addingTimeInterval(20), now: now) == String(localized: "now", comment: "An event card: it starts now"))
        #expect(EventDetails.until(now.addingTimeInterval(-5 * 60), now: now).contains("5"))
        #expect(EventDetails.calendarURL(for: now)?.scheme == "calshow")
    }
}
