import Foundation
import Testing
import UIKit
@testable import Echo

/// The home, reminder, comparison and score cards (asked 2026-10-30): read leniently as agents
/// write them, the messages their controls send (the entity named, so the agent hits the right
/// one), what asks first, and how each is said.
@MainActor
struct MoreCardsTests {
    private func card(_ text: String) throws -> ReplyCard { try #require(ReplyCards.parse(try JSONValue.parse(Data(text.utf8))).first) }

    // MARK: Home

    @Test func devicesAreReadAsHomeAssistantSaysThem() throws {
        guard case let .home(home) = try card(#"""
        {"type": "home", "title": "Downstairs", "devices": [
          {"name": "Kitchen lights", "area": "Kitchen", "state": "on", "brightness": 204, "entity": "light.kitchen"},
          {"friendly_name": "Thermostat", "entity_id": "climate.downstairs", "state": "heat", "current_temperature": "67°", "target_temperature": 70},
          {"name": "Garage door", "type": "garage_door", "state": "closed", "entity": "cover.garage_door"},
          {"name": "Front door", "kind": "lock", "state": "locked"},
          {"name": "Porch", "kind": "light", "state": false, "brightness": 90},
          {"entity": "sensor.basement_humidity", "state": "48", "unit_of_measurement": "%"},
          {"area": "nothing to call it"}]}
        """#) else { Issue.record("not a home card"); return }
        let d = home.devices
        #expect(d.map(\.name) == ["Kitchen lights", "Thermostat", "Garage door", "Front door", "Porch", "sensor.basement_humidity"], "one with no name nor entity is dropped")
        #expect(d[0].kind == .light && d[0].brightness == 80 && d[0].isOn, "a kind from its entity's domain, brightness from 0–255")
        #expect(d[1].kind == .climate && d[1].temperature == 67 && d[1].target == 70 && d[1].entity == "climate.downstairs")
        #expect(d[2].kind == .cover && !d[2].isOn && d[2].risky, "a garage opened is asked first")
        #expect(d[3].kind == .lock && d[3].risky && !d[3].isOn)
        #expect(d[4].state == "off" && d[4].brightness == nil, "an off light has no brightness")
        #expect(d[5].kind == .sensor && HomeCard.reading(d[5]) == "48%")
        #expect(HomeCard.status(d[0]) == "Kitchen · On · 80%" && HomeCard.summary(home) == "1 light on")
    }

    @Test func aControlAsksTheAgentNamingTheEntity() throws {
        let light = ReplyCard.Home.Device(name: "Kitchen lights", kind: .light, state: "on", entity: "light.kitchen")
        let off = HomeCard.message(.power(false), light)
        #expect(off.shown == "Turn off Kitchen lights")
        #expect(off.said.contains("turn off \"Kitchen lights\" (light.kitchen)") && off.said.contains("Home Assistant tools"))
        let thermostat = ReplyCard.Home.Device(name: "Thermostat", kind: .climate, target: 70, unit: "°F", entity: "climate.downstairs")
        #expect(HomeCard.message(.target(71), thermostat).shown == "Set Thermostat to 71°")
        #expect(HomeCard.message(.brightness(60), light).shown == "Set Kitchen lights to 60%")
        #expect(HomeCard.step(thermostat) == 1 && HomeCard.step(.init(name: "x", kind: .climate, unit: "°C")) == 0.5)
        let door = ReplyCard.Home.Device(name: "Front door", kind: .lock, state: "locked", entity: "lock.front_door")
        let garage = ReplyCard.Home.Device(name: "Garage door", kind: .cover, state: "closed", entity: "cover.garage_door")
        let blinds = ReplyCard.Home.Device(name: "Blinds", kind: .cover, state: "closed")
        #expect(HomeCard.isRisky(.lock(false), door) && !HomeCard.isRisky(.lock(true), door), "unlocking asks first; locking doesn't")
        #expect(HomeCard.isRisky(.open(true), garage) && !HomeCard.isRisky(.open(false), garage) && !HomeCard.isRisky(.open(true), blinds))
        #expect(HomeCard.title(.lock(false), door) == "Unlock Front door?")
        let all = HomeCard.allOff([light, .init(name: "Porch light", kind: .light, state: "on", entity: "light.porch")])
        #expect(all.shown == "Turn off Kitchen lights and Porch light" && all.said.contains("(light.porch)"))
        for kind in ReplyCard.Home.Device.Kind.allCases {
            for on in [true, false] {
                #expect(UIImage(systemName: HomeCard.symbol(.init(name: "garage", kind: kind, state: on ? "on" : "off"), on: on)) != nil, "\(kind)")
            }
        }
    }

    // MARK: Reminders

    @Test func aReminderSaysWhenAndWhere() throws {
        guard case let .reminder(r) = try card(#"""
        {"type": "reminder", "title": "Send the weekly report", "kind": "schedule", "at": "2026-11-02T09:00:00-05:00",
         "repeat": "Every Monday at 9 AM", "where": "Hermes", "id": "cron_7f3a"}
        """#) else { Issue.record("not a reminder"); return }
        #expect(r.kind == .schedule && r.repeats == "Every Monday at 9 AM" && r.place == "Hermes" && r.id == "cron_7f3a")
        #expect(r.at == ISO8601DateFormatter().date(from: "2026-11-02T14:00:00Z"))
        guard case let .reminder(words) = try card(#"{"type": "timer", "title": "Call", "when": "after lunch"}"#) else { Issue.record("timer"); return }
        #expect(words.at == nil && words.when == "after lunch" && words.kind == .timer, "its type said what it is")
        guard case let .reminder(timer) = try card(#"{"type": "reminder", "kind": "timer", "title": "Pasta", "duration": "20 min"}"#) else { Issue.record("timer"); return }
        #expect(timer.duration == 1200 && timer.at.map { abs($0.timeIntervalSinceNow - 1200) < 5 } == true, "a timer with only its length ends that long from now")
        #expect(ReplyCards.duration(.string("1h 30m")) == 5400 && ReplyCards.duration(.string("00:20:00")) == 1200 && ReplyCards.duration(.number(90)) == 90)
        #expect(ReplyCards.parse(try JSONValue.parse(Data(#"{"type": "reminder", "at": "2026-11-02T09:00:00-05:00"}"#.utf8))).isEmpty, "no title: no card")
    }

    @Test func aReminderIsSaidAndAnsweredInWords() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.locale = Locale(identifier: "en_US")
        let now = ISO8601DateFormatter().date(from: "2026-10-30T19:00:00Z")!
        func when(_ seconds: TimeInterval) -> String {
            ReminderCard.when(now.addingTimeInterval(seconds), now: now, calendar: calendar).replacing(/\s/, with: " ")
        }
        #expect(when(1200).hasPrefix("in 20 min"), "\(when(1200))")
        let late = ISO8601DateFormatter().date(from: "2026-10-31T03:49:00Z")!   // 11:49 PM there
        let pasta = ReminderCard.when(late.addingTimeInterval(1200), now: late, calendar: calendar).replacing(/\s/, with: " ")
        #expect(pasta.hasPrefix("in 20 min"), "a timer past midnight says how long first: \(pasta)")
        #expect(when(18 * 3600).hasPrefix("Tomorrow, ") && when(18 * 3600).hasSuffix("in 18 hr."), "\(when(18 * 3600))")
        #expect(ReminderCard.clock(1182) == "19:42" && ReminderCard.clock(3900) == "1:05:00")
        let vet = ReplyCard.Reminder(title: "Call the vet", kind: .reminder, id: "x-apple-reminder://4F2A")
        let cancel = ReminderCard.cancel(vet)
        #expect(cancel.shown == "Cancel the reminder “Call the vet”" && cancel.said.contains("(id x-apple-reminder://4F2A)"))
        let change = ReminderCard.change(.init(title: "Pasta", kind: .timer), "5 more minutes")
        #expect(change.shown == "Change the timer “Pasta”: 5 more minutes" && change.said.contains("tapped Change"))
        #expect(!cancel.said.contains("tapped Change") && cancel.said.contains("tapped Cancel"), "the card tells which was asked")
        for kind in ReplyCard.Reminder.Kind.allCases { #expect(UIImage(systemName: ReminderCard.symbol(kind)) != nil) }
    }

    // MARK: Comparisons

    @Test func aComparisonHasItsOptionsRowsAndPick() throws {
        guard case let .compare(c) = try card(#"""
        {"type": "compare", "title": "A first language", "options": ["Python", {"title": "JavaScript", "pros": ["Runs in a browser"], "cons": "Quirks"}, "Go", "Rust", "C"],
         "rows": [{"criterion": "Learning curve", "values": ["Gentle", "Moderate"], "best": 0},
                  {"criterion": "Setup", "values": ["One install", "None", "", "", ""], "best": "javascript"},
                  {"criterion": "Empty", "values": ["", ""]}, {"values": ["no criterion"]}],
         "verdict": "For you: Python", "pick": "Python"}
        """#) else { Issue.record("not a comparison"); return }
        #expect(c.options.map(\.name) == ["Python", "JavaScript", "Go", "Rust"], "four at most")
        #expect(c.options[1].pros == ["Runs in a browser"] && c.options[1].cons == ["Quirks"])
        #expect(c.rows.count == 2 && c.rows[0].values == ["Gentle", "Moderate", "", ""], "a value for every option")
        #expect(c.rows[0].best == 0 && c.rows[1].best == 1 && c.pick == 0, "by place, or by name")
        #expect(CompareCard.spoken(c.rows[0], options: c.options) == "Learning curve: Python Gentle, JavaScript Moderate, Go –, Rust –, better: Python")
        #expect(ReplyCards.parse(try JSONValue.parse(Data(#"{"type": "compare", "options": ["A"], "rows": [{"criterion": "x", "values": ["1"]}]}"#.utf8))).isEmpty)
        #expect(!ReplyCard.compare(c).answerable)
    }

    // MARK: Scores

    @Test func gamesAreReadWithTheirStatusAndTeams() throws {
        guard case let .score(s) = try card(#"""
        {"type": "score", "note": "From the league's site", "games": [
          {"league": "NBA", "status": "Final", "home": {"name": "Orlando Magic", "short": "orl", "color": "0077C0", "score": 112, "record": "5-2"},
           "away": {"name": "Boston Celtics", "color": "green", "score": "104"}},
          {"league": "NHL", "status": "in progress", "period": "2nd", "clock": "8:41", "home": "Tampa Bay Lightning", "away": {"name": "Florida Panthers"}},
          {"home": {"name": "Miami Heat"}, "away": {"name": "Orlando Magic"}, "start": "2026-10-31T19:30:00-04:00", "broadcast": "FanDuel SN"},
          {"home": {"name": "Only one team"}}]}
        """#) else { Issue.record("not a score card"); return }
        #expect(s.games.count == 3 && s.note == "From the league's site")
        let a = s.games[0], b = s.games[1], c = s.games[2]
        #expect(a.status == .final && a.winner == .home && a.home.mark == "ORL" && a.home.color == "#0077C0" && a.away.color == nil && a.away.score == 104)
        #expect(a.away.mark == "BC", "no short name: its first letters")
        #expect(b.status == .live && b.period == "2nd" && b.clock == "8:41" && b.home.name == "Tampa Bay Lightning" && b.winner == nil)
        #expect(c.status == .upcoming && c.start == ISO8601DateFormatter().date(from: "2026-10-31T23:30:00Z") && c.broadcast == "FanDuel SN")
        let refresh = ScoreCard.refresh(s)
        #expect(refresh.shown == "Update the score" && refresh.said.contains("Boston Celtics at Orlando Magic (NBA)") && refresh.said.contains("tapped Refresh"))
        #expect(ScoreCard.sport("NBA") == "basketball" && ScoreCard.sport("Premier League") == "soccerball" && ScoreCard.sport("NHL") == "hockey.puck")
        #expect(ScoreCard.light("#0077C0") && !ScoreCard.light("#FFD100"), "white letters on a dark colour, black on a light one")
        #expect(ScoreCard.colour("#0077C0") != nil && ScoreCard.colour("nope") == nil)
        for league in ["NBA", "NFL", "MLB", "NHL", "ATP", "MLS", "Cricket"] { #expect(UIImage(systemName: ScoreCard.sport(league)) != nil, "\(league)") }
    }

    @Test func theNewCardsKeepTheirKeysAndRoundTrip() throws {
        let all = ReplyCards.parse(try JSONValue.parse(Data(#"""
        {"cards": [{"type": "home", "devices": [{"name": "Lamp", "state": "on", "entity": "light.lamp"}]},
                   {"type": "reminder", "title": "Pasta", "kind": "timer", "at": "2026-10-30T15:45:00-04:00"},
                   {"type": "compare", "options": ["A", "B"], "rows": [{"criterion": "x", "values": ["1", "2"]}]},
                   {"type": "score", "games": [{"home": "Magic", "away": "Heat"}]}]}
        """#.utf8)))
        #expect(all.count == 4)
        let again = try JSONDecoder().decode([ReplyCard].self, from: JSONEncoder().encode(all))
        #expect(again == all && again.map(\.key) == all.map(\.key))
        #expect(all[0].answerable && all[1].answerable && !all[2].answerable && all[3].answerable)
        #expect(Set(all.filter(\.answerable).map(\.key)).count == 3 && !all[0].key.isEmpty)
    }
}
