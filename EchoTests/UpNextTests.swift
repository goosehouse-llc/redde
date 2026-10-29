import CoreLocation
import Foundation
import SwiftUI
import Testing
import WidgetKit
@testable import Echo

/// Up Next and when to leave (asked 2026-10-28, "Proactive"): a heads-up's event, its start and
/// address from Redde's plugin 1.9, the leaving time worked out on the phone, and the Lock Screen
/// widget counting down to it.
struct UpNextTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "upnext-\(UUID().uuidString)")! }

    private func headsUp(_ title: String, starts: String?, where place: String?, at: Double) throws -> PushNote {
        var json: [String: Any] = ["v": 1, "k": "routine", "at": at, "n": "dchermes", "p": "default", "d": "Sol",
                                   "t": "Heads-up: \(title)", "b": "Bring the card.", "x": "brief", "i": "headsups"]
        if let starts { json["u"] = starts }
        if let place { json["r"] = place }
        return try JSONDecoder().decode(PushNote.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test func aHeadsUpKeepsItsEventAndTheNextOneComesFirst() throws {
        let store = defaults()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(AgentBriefing.take(try headsUp("Dentist", starts: "2027-01-15T10:20:00Z", where: "12 Main St", at: 1_800_000_000), now: now, in: store))
        #expect(AgentBriefing.take(try headsUp("Lunch", starts: "2027-01-15T09:00:00Z", where: "", at: 1_800_000_010), now: now, in: store))
        #expect(AgentBriefing.take(try headsUp("No time", starts: nil, where: nil, at: 1_800_000_020), now: now, in: store))
        let kept = AgentBriefing.all(in: store, now: now)
        let dentist = try #require(kept.first { $0.heading == "Dentist" })
        #expect(dentist.eventAt == ISO8601DateFormatter().date(from: "2027-01-15T10:20:00Z"))
        #expect(dentist.place == "12 Main St")
        #expect(kept.first { $0.heading == "Lunch" }?.place == nil, "an empty address is none")
        #expect(kept.first { $0.heading == "No time" }?.eventAt == nil)

        let morning = ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z")!
        #expect(AgentBriefing.next(in: kept, after: morning)?.heading == "Lunch", "the soonest first")
        #expect(AgentBriefing.next(in: kept, after: morning.addingTimeInterval(1.5 * 3600))?.heading == "Dentist", "lunch has started")
        #expect(AgentBriefing.next(in: kept, after: morning.addingTimeInterval(3 * 3600)) == nil)

        let lunch = try #require(kept.first { $0.heading == "Lunch" })
        AgentBriefing.snooze(lunch.id, until: morning.addingTimeInterval(3600), in: store)
        #expect(AgentBriefing.next(in: AgentBriefing.all(in: store, now: now), after: morning)?.heading == "Dentist", "put off: out till then")
        AgentBriefing.setLeave(dentist.id, at: morning.addingTimeInterval(3600), in: store)
        #expect(AgentBriefing.all(in: store, now: now).first { $0.id == dentist.id }?.leaveAt == morning.addingTimeInterval(3600))
    }

    @Test func theLeavingTimeAndItsLine() {
        let event = Date(timeIntervalSince1970: 1_800_000_000)
        let leave = LeaveTime.leave(for: event, travel: 25 * 60)
        #expect(leave == event.addingTimeInterval(-30 * 60), "the way there and five minutes in hand")
        let early = leave.addingTimeInterval(-3600)
        #expect(LeaveTime.line(leave: leave, travel: 25 * 60, mode: .driving, now: early).hasPrefix("Leave by "))
        #expect(LeaveTime.line(leave: leave, travel: 25 * 60, mode: .driving, now: early).hasSuffix(" · 25 min by car"))
        #expect(LeaveTime.line(leave: leave, travel: 12 * 60, mode: .walking, now: leave) == "Leave now · 12 min on foot")
        #expect(LeaveTime.line(leave: leave, travel: 20, mode: .transit, now: leave.addingTimeInterval(600)) == "Leave now · 1 min by transit")
    }

    @Test func theWayAndWhereThePhoneWasStayOnThePhone() {
        let store = defaults()
        #expect(LeaveTime.mode(in: store) == .driving, "by car unless told")
        LeaveTime.setMode(.transit, in: store)
        #expect(LeaveTime.mode(in: store) == .transit)
        let then = Date(timeIntervalSince1970: 1_800_000_000)
        LeaveTime.remember(CLLocation(coordinate: CLLocationCoordinate2D(latitude: 40.7, longitude: -74), altitude: 0,
                                      horizontalAccuracy: 10, verticalAccuracy: 10, timestamp: then), in: store)
        #expect(LeaveTime.lastKnown(in: store, now: then.addingTimeInterval(3600))?.coordinate.latitude == 40.7)
        #expect(LeaveTime.lastKnown(in: store, now: then.addingTimeInterval(13 * 3600)) == nil, "half a day, then not trusted")
    }

    @Test func offWorksNothingOut() async {
        let store = defaults()
        LeaveTime.setMode(.off, in: store)
        var briefing = AgentBriefing(id: "x", title: "Heads-up: Dentist", agent: "", text: "", at: .now, failed: false)
        briefing.eventAt = .now.addingTimeInterval(3600)
        briefing.place = "12 Main St"
        #expect(await LeaveTime.work(out: briefing, in: store) == nil)
        LeaveTime.setMode(.driving, in: store)
        briefing.place = nil
        #expect(await LeaveTime.work(out: briefing, in: store) == nil, "no address, nothing to work out")
    }

    @Test func theCardDrawsInEverySize() throws {
        let empty = UpNextEntry(date: .now)
        var hidden = UpNextEntry.sample
        hidden.hidesWords = true
        for family in [WidgetFamily.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline] {
            for (name, entry) in [("full", UpNextEntry.sample), ("empty", empty), ("hidden", hidden)] {
                let size: CGSize = switch family {
                case .systemMedium: CGSize(width: 364, height: 170)
                case .accessoryRectangular: CGSize(width: 172, height: 76)
                case .accessoryInline: CGSize(width: 240, height: 26)
                default: CGSize(width: 170, height: 170)
                }
                let renderer = ImageRenderer(content: UpNextCard(entry: entry, family: family).frame(width: size.width, height: size.height))
                renderer.scale = 2
                let image = try #require(renderer.uiImage, "\(family) \(name)")
                if let folder = ProcessInfo.processInfo.environment["BOARD_SHOTS"] {
                    try image.pngData()?.write(to: URL(fileURLWithPath: folder).appendingPathComponent("upnext-\(family)-\(name).png"))
                }
                #expect(image.size.width > 0)
            }
        }
    }
}
