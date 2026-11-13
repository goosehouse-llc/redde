import SwiftUI
import Testing
import UIKit
@testable import Echo

/// The drawer laid out from scratch (2026-11-13): Coder's waits, the hello, and its colours.
@MainActor
struct NewDrawerTests {
    private func note(_ id: String, profile: String = "coder", title: String = "Waiting on your approval",
                      detail: String = "Server steps: a\nSay \"go\" to see the card.", ago: TimeInterval = 60,
                      kind: AgentActivityNote.Kind = .routine, now: Date) -> AgentActivityNote {
        AgentActivityNote(id: id, kind: kind, profile: profile, agent: "Coder", title: title, detail: detail,
                          at: now.addingTimeInterval(-ago), failed: false)
    }

    @Test func coderStepsAreReadFromEitherNote() {
        #expect(ConversationsList.drawerSteps("Server steps: systemctl restart x; rm -f /tmp/y")
                == ["systemctl restart x", "rm -f /tmp/y"])
        #expect(ConversationsList.drawerSteps("Card 12: Claude wants to run on the server: make deploy")
                == ["make deploy"])
        #expect(ConversationsList.drawerSteps("Claude's change is ready to put in.") == nil)
        #expect(ConversationsList.drawerSteps("Server steps: ") == nil)
    }

    @Test func theWordBringsTheRightCard() {
        let now = Date.now
        #expect(NewDrawer.word(for: note("a", now: now)) == "go")
        #expect(NewDrawer.word(for: note("b", detail: "Claude's change is ready to put in.\nSay \"put it in\" to see the card.", now: now))
                == "put it in")
    }

    /// Only Coder-style waits from the last 12 hours, the newest per bot, none dismissed.
    @Test func botWaitsKeepTheNewestPerBot() {
        let now = Date.now
        let notes = [
            note("old", ago: 13 * 3600, now: now),
            note("first", ago: 600, now: now),
            note("latest", title: "Coder needs your OK", ago: 60, now: now),
            note("other", profile: "writer", ago: 120, now: now),
            note("gone", profile: "ops", ago: 30, now: now),
            note("brief", profile: "sol", title: "Morning brief", kind: .routine, now: now),
            note("idea", profile: "scout", kind: .ideas, now: now),
        ]
        let waits = NewDrawer.botWaits(notes, now: now, dismissed: ["gone"])
        #expect(waits.map(\.id) == ["latest", "other"])
    }

    @Test func theHelloFollowsTheClock() throws {
        let cal = Calendar.current
        let day = cal.startOfDay(for: .now)
        func hello(_ hour: Int) throws -> String {
            ConversationsList.drawerHello(at: try #require(cal.date(byAdding: .hour, value: hour, to: day)))
        }
        #expect(try hello(8) == String(localized: "Good morning", comment: "The drawer's hello, before noon"))
        #expect(try hello(13) == String(localized: "Good afternoon", comment: "The drawer's hello, noon to five"))
        #expect(try hello(19) == String(localized: "Good evening", comment: "The drawer's hello, five to ten"))
        #expect(try hello(2) == String(localized: "Hello, night owl", comment: "The drawer's hello, late at night"))
    }

    /// Dragging a tile onto another's place on the Today page (asked 2026-11-13).
    @Test func aDraggedTileTakesThePlaceItIsDroppedOn() {
        let keys = ["inbox", "list:a", "brief:b", "goal:c"]
        #expect(TodayStrip.placing("inbox", at: "brief:b", in: keys, order: []) == ["list:a", "brief:b", "inbox", "goal:c"])
        #expect(TodayStrip.placing("goal:c", at: "inbox", in: keys, order: []) == ["goal:c", "inbox", "list:a", "brief:b"])
        // A tile not shown today keeps its kept place after the shown ones.
        #expect(TodayStrip.placing("list:a", at: "inbox", in: keys, order: ["brief:old", "inbox"])
                == ["list:a", "inbox", "brief:b", "goal:c", "brief:old"])
        // Onto itself, or a tile that isn't there: nothing changes.
        #expect(TodayStrip.placing("inbox", at: "inbox", in: keys, order: ["x"]) == ["x"])
        #expect(TodayStrip.placing("inbox", at: "gone", in: keys, order: ["x"]) == ["x"])
    }

    /// The calendar tile sits beside the inbox (asked 2026-11-13) until it's placed by hand.
    @Test func theCalendarTileSitsBesideTheInbox() {
        let keys = ["list:a", "inbox", "brief:b", "upnext"]
        #expect(TodayStrip.besideInbox(keys, order: ["list:a", "inbox"]) == ["list:a", "inbox", "upnext", "brief:b"])
        // Placed by hand, it stays where it was put; with no inbox, where it fell.
        #expect(TodayStrip.besideInbox(keys, order: ["upnext"]) == keys)
        #expect(TodayStrip.besideInbox(["list:a", "upnext"], order: []) == ["list:a", "upnext"])
    }

    @Test func theCalendarPillSaysHowLongUntil() throws {
        let cal = Calendar.current
        let now = try #require(cal.date(bySettingHour: 9, minute: 0, second: 0, of: .now))
        func event(_ minutes: Double, for length: Double = 30) -> CalendarUpNext.Event {
            let start = now.addingTimeInterval(minutes * 60)
            return CalendarUpNext.Event(id: "e", title: "Lunch", start: start, end: start.addingTimeInterval(length * 60), location: nil, color: nil)
        }
        #expect(TodayCalendarFeature.pill(event(25), now: now) == CalendarUpNext.when(event(25), now: now))
        #expect(TodayCalendarFeature.pill(event(-10), now: now) == CalendarUpNext.when(event(-10), now: now))
        let threeHours = TodayCalendarFeature.pill(event(200), now: now)
        #expect(threeHours.contains("3"))
        #expect(TodayCalendarFeature.pill(event(24 * 60), now: now) == String(localized: "Tomorrow", comment: "An agenda card's day"))
    }

    // MARK: Colours

    private func rgb(_ color: Color, _ scheme: ColorScheme) -> (Double, Double, Double) {
        var env = EnvironmentValues()
        env.colorScheme = scheme
        let ui = UIColor(cgColor: color.resolve(in: env).cgColor)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b))
    }

    private func contrast(_ x: Color, _ y: Color, _ scheme: ColorScheme) -> Double {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        func lum(_ c: (Double, Double, Double)) -> Double { 0.2126 * lin(c.0) + 0.7152 * lin(c.1) + 0.0722 * lin(c.2) }
        let (a, b) = (lum(rgb(x, scheme)), lum(rgb(y, scheme)))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// The button's words and the place buttons' symbols are drawn in the page colour on the warm
    /// and place fills; in light mode the first cut put white on pale tan.
    @Test(arguments: Theme.allCases)
    func wordsOnTheFillsRead(_ theme: Theme) {
        let tone = DrawerTone(theme.resolved(with: nil))
        for scheme in [ColorScheme.light, .dark] {
            let name = "\(theme.rawValue) \(scheme == .dark ? "dark" : "light")"
            #expect(contrast(tone.page, tone.warm, scheme) >= 3, "\(name): the button's words")
            for (i, fill) in tone.places.enumerated() {
                #expect(contrast(tone.page, fill, scheme) >= 2.2, "\(name): place \(i)'s symbol")
            }
        }
    }

    @Test func arcadeGetsTheNeonItself() {
        let tone = DrawerTone(Theme.arcade.resolved(with: nil))
        for scheme in [ColorScheme.light, .dark] {
            #expect(rgb(tone.warm, scheme) == rgb(Theme.arcadeHues[1], scheme))
            #expect(rgb(tone.places[0], scheme) == rgb(Theme.arcadeHues[0], scheme))
        }
        #expect(DrawerTone(Theme.paper.resolved(with: nil)).design == .serif)
        #expect(DrawerTone(Theme.standard.resolved(with: nil)).design == .rounded)
    }
}
