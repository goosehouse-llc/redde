import CoreLocation
import Foundation
import Testing
@testable import Echo

/// Leave-By Alerts (asked 2026-10-30): which events get one, when the way is asked of Apple Maps
/// again, what is set and taken away, one reminder an event alongside the heads-ups', and when
/// the background refresh comes.
struct LeaveByTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let address = "200 East Robinson St, Orlando, FL"
    private let here = CLLocation(latitude: 28.5421, longitude: -81.3673)

    private func event(_ title: String = "Dentist", in minutes: Double = 120, at place: String? = nil, id: String? = nil) -> LeaveBy.Event {
        LeaveBy.Event(id: id ?? "E-\(title)", title: title, start: now.addingTimeInterval(minutes * 60), place: place ?? address, calendar: "Home")
    }

    private func worked(_ event: LeaveBy.Event, travel minutes: Double = 25, at: Date? = nil, from: CLLocation? = nil,
                        mode: LeaveTime.Mode = .driving, alertAt: Date? = nil) -> LeaveBy.Worked {
        let from = from ?? here
        return LeaveBy.Worked(title: event.title, start: event.start, place: event.place ?? "", mode: mode,
                              fromLatitude: from.coordinate.latitude, fromLongitude: from.coordinate.longitude,
                              toLatitude: 28.5436, toLongitude: -81.3747, travel: minutes * 60, at: at ?? now, alertAt: alertAt)
    }

    // MARK: Which events

    @Test func onlyTimedEventsToComeAtAStreetAddressInAShownCalendar() {
        var allDay = event("Holiday"); allDay.allDay = true
        var cancelled = event("Cancelled"); cancelled.cancelled = true
        var declined = event("Declined"); declined.declined = true
        var elsewhere = event("Work thing"); elsewhere.calendar = "Work"
        let events = [event("Lunch", in: 300), event("Dentist", in: 60), allDay, cancelled, declined, elsewhere,
                      event("Started", in: -5), event("Too far", in: 40 * 60), event("Room", at: "Office · Room 4"),
                      event("Call", at: "https://zoom.us/j/81234567890"), event("Zoom", at: "Zoom"), event("Nowhere", at: "")]
        let kept = LeaveBy.qualifying(events, chosen: ["Home"], now: now)
        #expect(kept.map(\.title) == ["Dentist", "Lunch"], "soonest first; nothing all-day, cancelled, declined, started, far off, in a room or online")
        #expect(LeaveBy.qualifying(events, chosen: [], now: now).map(\.title) == ["Dentist", "Work thing", "Lunch"], "none chosen: every calendar")
    }

    @Test func eachOccurrenceHasItsOwnAlert() {
        let first = event(in: 60), again = event(in: 60 + 7 * 24 * 60)
        #expect(first.alertID.hasPrefix(LeaveTime.reminderPrefix + "event."))
        #expect(first.alertID != again.alertID, "a repeating event's occurrences share its id, not their start")
        #expect(LeaveBy.qualifying([first, first], chosen: [], now: now).count == 1)
    }

    // MARK: When to ask Apple Maps again

    @Test func theWayIsAskedAgainOnlyWhenSomethingChangedOrItIsOld() {
        let soon = event(in: 90), later = event("Lunch", in: 5 * 60), tomorrow = event("Flight", in: 20 * 60)
        #expect(LeaveBy.needsTravel(soon, worked: nil, from: here, mode: .driving, now: now), "never asked")
        #expect(!LeaveBy.needsTravel(later, worked: worked(later, at: now.addingTimeInterval(-10 * 60)), from: here, mode: .driving, now: now))
        #expect(LeaveBy.needsTravel(later, worked: worked(later, at: now.addingTimeInterval(-25 * 60)), from: here, mode: .driving, now: now), "twenty minutes old")
        #expect(LeaveBy.needsTravel(soon, worked: worked(soon, at: now.addingTimeInterval(-6 * 60)), from: here, mode: .driving, now: now), "within two hours: each run")
        #expect(!LeaveBy.needsTravel(soon, worked: worked(soon, at: now.addingTimeInterval(-60)), from: here, mode: .driving, now: now), "but not twice in a minute")
        #expect(!LeaveBy.needsTravel(tomorrow, worked: worked(tomorrow, at: now.addingTimeInterval(-60 * 60)), from: here, mode: .driving, now: now), "tomorrow's: every two hours")
        #expect(LeaveBy.needsTravel(later, worked: worked(later, mode: .walking), from: here, mode: .driving, now: now), "another way of getting about")
        var moved = later; moved.place = "1 Infinite Loop, Cupertino, CA"
        #expect(LeaveBy.needsTravel(moved, worked: worked(later), from: here, mode: .driving, now: now), "another place")
        let far = CLLocation(latitude: 28.56, longitude: -81.3673)   // about 2 km north
        #expect(LeaveBy.needsTravel(later, worked: worked(later), from: far, mode: .driving, now: now), "moved far")
        let near = CLLocation(latitude: 28.545, longitude: -81.3673)  // about 300 m
        #expect(!LeaveBy.needsTravel(later, worked: worked(later), from: near, mode: .driving, now: now))
        #expect(!LeaveBy.needsTravel(soon, worked: worked(soon, at: now.addingTimeInterval(-3600), alertAt: now.addingTimeInterval(-60)), from: far, mode: .walking, now: now),
                "its alert went off: once is all")
    }

    @Test func runsAtMostEveryTenMinutesUnlessSomethingChanged() {
        #expect(LeaveBy.shouldRun(last: nil, now: now, forced: false))
        #expect(!LeaveBy.shouldRun(last: now.addingTimeInterval(-5 * 60), now: now, forced: false))
        #expect(LeaveBy.shouldRun(last: now.addingTimeInterval(-5 * 60), now: now, forced: true))
        #expect(LeaveBy.shouldRun(last: now.addingTimeInterval(-10 * 60), now: now, forced: false))
        #expect(LeaveBy.shouldRun(last: now.addingTimeInterval(3600), now: now, forced: false), "the clock went back")
    }

    @Test func theNewerOfTheTwoPlacesIsWhereTheDeviceIs() {
        let kept = CurrentLocation.Here(words: "Thornton Park", latitude: 28.54, longitude: -81.37, at: now)
        let old = CLLocation(coordinate: here.coordinate, altitude: 0, horizontalAccuracy: 50, verticalAccuracy: -1, timestamp: now.addingTimeInterval(-600))
        #expect(LeaveBy.origin(kept: kept, here: old)?.coordinate.latitude == 28.54)
        let fresh = CLLocation(coordinate: here.coordinate, altitude: 0, horizontalAccuracy: 50, verticalAccuracy: -1, timestamp: now.addingTimeInterval(60))
        #expect(LeaveBy.origin(kept: kept, here: fresh)?.coordinate.latitude == here.coordinate.latitude)
        #expect(LeaveBy.origin(kept: nil, here: nil) == nil)
    }

    // MARK: The plan

    @Test func anAlertAtTheLeavingTimeAndNoneForAnEventGone() throws {
        let dentist = event(in: 120)
        let plan = LeaveBy.plan(events: [dentist], worked: [dentist.alertID: worked(dentist), "gone": worked(event("Gone"))],
                                headsUps: [], pending: [dentist.alertID, LeaveBy.idPrefix + "gone.1", LeaveTime.reminderPrefix + "headsup/1"], now: now)
        let alert = try #require(plan.alerts.first)
        #expect(alert.leave == dentist.start.addingTimeInterval(-30 * 60), "25 minutes there and five in hand")
        #expect(!alert.now)
        #expect(plan.remove == [LeaveBy.idPrefix + "gone.1"], "an event removed or moved takes its alert; a heads-up's reminder is left")
        #expect(plan.worked.keys.sorted() == [dentist.alertID], "nothing kept for an event gone")
        #expect(plan.worked[dentist.alertID]?.alertAt == alert.leave)
        #expect(LeaveBy.next(in: plan.worked, now: now) == LeaveBy.Next(title: "Dentist", leave: alert.leave))
    }

    @Test func aLeavingTimeJustGoneGoesOffAtOnceOnlyBeforeTheEventStarts() {
        let close = event(in: 28)   // leave was two minutes ago with 25 + 5
        let plan = LeaveBy.plan(events: [close], worked: [close.alertID: worked(close)], headsUps: [], pending: [], now: now)
        #expect(plan.alerts.map(\.now) == [true])
        #expect(plan.worked[close.alertID]?.alertAt == now)
        // Run again a minute later: it went off already.
        let again = LeaveBy.plan(events: [close], worked: plan.worked, headsUps: [], pending: [], now: now.addingTimeInterval(60))
        #expect(again.alerts.isEmpty)

        let late = event(in: 20)   // ten minutes late already
        let tooLate = LeaveBy.plan(events: [late], worked: [late.alertID: worked(late)], headsUps: [], pending: [], now: now)
        #expect(tooLate.alerts.isEmpty, "too late to be of use")
        #expect(tooLate.worked[late.alertID]?.done(at: now) == true)
    }

    @Test func anAlertThatWentOffNeverGoesOffAgainWhenTheTrafficMovesIt() {
        let dentist = event(in: 20)
        var gone = worked(dentist, travel: 10)
        gone.alertAt = now.addingTimeInterval(-60)   // went off a minute ago
        let plan = LeaveBy.plan(events: [dentist], worked: [dentist.alertID: gone], headsUps: [], pending: [], now: now)
        #expect(plan.alerts.isEmpty)
    }

    @Test func oneReminderAnEventTheFresherKept() {
        let dentist = event("Dentist appointment", in: 120)
        let older = LeaveTime.Reminder(id: LeaveTime.reminderPrefix + "headsups/1", title: "Dentist", start: dentist.start,
                                       fireAt: dentist.start.addingTimeInterval(-40 * 60), worked: now.addingTimeInterval(-3600))
        let mine = LeaveBy.plan(events: [dentist], worked: [dentist.alertID: worked(dentist)], headsUps: [older], pending: [], now: now)
        #expect(mine.alerts.count == 1)
        #expect(mine.remove == [older.id], "the heads-up's older reminder goes")

        var fresher = older
        fresher.worked = now.addingTimeInterval(60)
        let theirs = LeaveBy.plan(events: [dentist], worked: [dentist.alertID: worked(dentist)], headsUps: [fresher], pending: [dentist.alertID], now: now)
        #expect(theirs.alerts.isEmpty)
        #expect(theirs.remove == [dentist.alertID], "this one's goes, so both never fire")
        #expect(theirs.worked[dentist.alertID]?.alertAt == fresher.fireAt, "and it isn't set later either")

        var other = older
        other.start = dentist.start.addingTimeInterval(3600)
        #expect(LeaveBy.plan(events: [dentist], worked: [dentist.alertID: worked(dentist)], headsUps: [other], pending: [], now: now).remove.isEmpty,
                "another time is another event")
    }

    @Test func theSameEventByNameAndStart() {
        let start = now.addingTimeInterval(3600)
        func reminder(_ title: String, _ offset: TimeInterval = 0, worked: TimeInterval = 0, id: String? = nil) -> LeaveTime.Reminder {
            LeaveTime.Reminder(id: id ?? title, title: title, start: start.addingTimeInterval(offset), fireAt: nil, worked: now.addingTimeInterval(worked))
        }
        #expect(LeaveTime.sameEvent(reminder("Dentist"), reminder("dentist ")))
        #expect(LeaveTime.sameEvent(reminder("Café with Ana"), reminder("Cafe with Ana", 30)))
        #expect(LeaveTime.sameEvent(reminder("Dentist"), reminder("Dentist appointment")))
        #expect(!LeaveTime.sameEvent(reminder("Dentist"), reminder("Dentist", 120)), "more than a minute apart")
        #expect(!LeaveTime.sameEvent(reminder("Gym"), reminder("Gymnastics with Sam")), "too short a name to match within another")
        #expect(!LeaveTime.sameEvent(reminder("Dentist"), reminder("Lunch")))
        let gone = LeaveTime.losers([reminder("Dentist", worked: 0, id: "a"), reminder("Dentist appointment", worked: 60, id: "b"), reminder("Lunch", id: "c")])
        #expect(gone == ["a"], "the one worked out last stays")
    }

    @Test func whatTheAlertSays() {
        let leave = now.addingTimeInterval(3600)
        let content = LeaveTime.content(event: "Dentist", startsAt: leave.addingTimeInterval(1800), leave: leave, travel: 25 * 60, mode: .driving,
                                        worked: now, saying: .distantPast)
        #expect(content.title == "Time to leave for Dentist")
        #expect(content.body.hasPrefix("Leave by ") && content.body.hasSuffix(" · 25 min by car"))
        #expect(content.interruptionLevel == .timeSensitive)
        #expect(content.userInfo[LeaveTime.eventTitleKey] as? String == "Dentist")
        #expect(content.userInfo[LeaveTime.eventStartKey] as? Double == leave.addingTimeInterval(1800).timeIntervalSince1970)
        #expect(content.userInfo[PushNote.taskKey] == nil, "a tap opens Redde, not Briefings")
        #expect(LeaveTime.content(event: "Dentist", startsAt: nil, leave: leave, travel: 25 * 60, mode: .driving, worked: now).body == "Leave now · 25 min by car",
                "a heads-up's, as it always said at its time")
    }

    // MARK: The background refresh

    @Test func theRefreshComesAheadOfTheSoonestAlert() {
        #expect(LeaveBy.nextRefresh(after: now, alerts: []) == now.addingTimeInterval(4 * 3600), "nothing due: in a few hours")
        #expect(LeaveBy.nextRefresh(after: now, alerts: [now.addingTimeInterval(3 * 3600), now.addingTimeInterval(2 * 3600)])
                == now.addingTimeInterval(2 * 3600 - 40 * 60), "forty minutes before the soonest")
        #expect(LeaveBy.nextRefresh(after: now, alerts: [now.addingTimeInterval(20 * 60)]) == now.addingTimeInterval(15 * 60), "never sooner than fifteen minutes")
        #expect(LeaveBy.nextRefresh(after: now, alerts: [now.addingTimeInterval(-60), now.addingTimeInterval(30 * 3600)]) == now.addingTimeInterval(4 * 3600))
    }

    // MARK: Time in hand

    private var orlando: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        orlando.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!   // the 3rd a Tuesday, the 7th a Saturday
    }

    @Test func theSpareGrowsWithTheTripAndTheRushHour() {
        func spare(_ minutes: Double, _ mode: LeaveTime.Mode, arriving: Date) -> Double {
            LeaveTime.spare(travel: minutes * 60, mode: mode, arriving: arriving, calendar: orlando) / 60
        }
        #expect(spare(12, .walking, arriving: at(3, 8, 30)) == 5, "a short walk: five minutes, rush hour or not")
        #expect(spare(50, .driving, arriving: at(3, 8, 30)) == 8, "a 50-minute drive at the morning rush: 15%, 7.5 up to 8")
        #expect(spare(50, .driving, arriving: at(3, 17, 45)) == 8, "and the evening's")
        #expect(spare(50, .driving, arriving: at(3, 11)) == 5, "midday: 10% is five")
        #expect(spare(50, .transit, arriving: at(3, 8, 30)) == 5, "the rush hour is the driver's")
        #expect(spare(65, .driving, arriving: at(3, 11)) == 7, "10% of 65 minutes, 6.5 up to 7")
        #expect(spare(180, .driving, arriving: at(3, 8)) == 20, "capped at twenty")
        #expect(spare(240, .transit, arriving: at(3, 11)) == 20)
        #expect(spare(60, .driving, arriving: at(7, 8, 30)) == 6, "a Saturday morning is no rush hour")
        #expect(spare(60, .driving, arriving: at(3, 9, 30)) == 6, "9:30 is past the morning's")
        #expect(spare(60, .driving, arriving: at(3, 7)) == 9, "7:00 is in it")
        let event = at(3, 8, 30)
        #expect(LeaveTime.leave(for: event, travel: 50 * 60, mode: .driving, calendar: orlando) == event.addingTimeInterval(-58 * 60))
    }

    // MARK: The traffic re-check

    private func alert(_ title: String = "Dentist", leaveIn minutes: Double, worked: Date? = nil, now atOnce: Bool = false) -> LeaveBy.Alert {
        let leave = now.addingTimeInterval(minutes * 60)
        return LeaveBy.Alert(id: LeaveBy.alertID(event: "E-\(title)", start: leave.addingTimeInterval(1800)), title: title,
                             start: leave.addingTimeInterval(1800), leave: leave, travel: 25 * 60, mode: .driving,
                             to: CLLocationCoordinate2D(latitude: 28.5436, longitude: -81.3747), worked: worked ?? now, now: atOnce)
    }

    @Test func theHermesIsAskedToWakeTheDeviceTwentyMinutesBefore() throws {
        let later = alert("Lunch", leaveIn: 180), soon = alert(leaveIn: 60)
        let wakes = LeaveBy.wakes(for: [later, soon, alert("Now", leaveIn: 0, now: true)], now: now)
        #expect(wakes.map(\.title) == ["Dentist", "Lunch"], "soonest first; none for one going off at once")
        #expect(wakes.first?.at == now.addingTimeInterval(40 * 60))
        #expect(wakes.first?.id == LeaveCheck.id(of: soon.id))
        #expect(wakes.first?.id.count == 16 && !(wakes.first?.id.contains("E-") ?? true), "an opaque id: nothing of the calendar's")
        // Within twenty minutes: at once, only when the estimate in hand is old.
        #expect(LeaveBy.wakes(for: [alert(leaveIn: 10)], now: now).isEmpty, "just worked out: a check would say the same")
        #expect(LeaveBy.wakes(for: [alert(leaveIn: 10, worked: now.addingTimeInterval(-8 * 60))], now: now).map(\.at) == [now])
        #expect(LeaveBy.wakes(for: [alert(leaveIn: 2, worked: now.addingTimeInterval(-8 * 60))], now: now).isEmpty, "too close to help")
        #expect(LeaveBy.wakes(for: (0 ..< 40).map { alert("E\($0)", leaveIn: Double(60 + $0)) }, now: now).count == 30)

        let command = LeaveBy.wakeCommand(wakes, devices: ["dev-1", "dev-2"])
        let words = command.split(separator: " ").map(String.init)
        #expect(words.count == 4 && words[0] == "leave" && words[1] == "set" && words[2] == "dev-1,dev-2")
        let json = try #require(PushSeal.data(base64URL: words[3]))
        let listed = try #require(try JSONSerialization.jsonObject(with: json) as? [[String: Any]])
        #expect(listed.count == 2)
        #expect(Set(listed[0].keys) == ["i", "t", "w"], "the id, the title, the time: nothing else")
        #expect(listed[0]["t"] as? String == "Dentist" && listed[0]["w"] as? Int == Int(now.timeIntervalSince1970) + 40 * 60)
        #expect(LeaveBy.wakeCommand([], devices: ["dev-1"]) == "leave cancel dev-1")
    }

    @Test func eachChangeIsSaidOnceAndAnOlderPluginIsLeftAlone() {
        let set = "leave set dev-1 abc", other = "leave set dev-1 abd"
        #expect(LeaveBy.shouldSay(set, after: nil, now: now))
        #expect(!LeaveBy.shouldSay("leave cancel dev-1", after: nil, now: now), "never asked: nothing to take back")
        #expect(!LeaveBy.shouldSay(set, after: set, now: now))
        #expect(LeaveBy.shouldSay(other, after: set, now: now), "an alert moved")
        #expect(LeaveBy.shouldSay("leave cancel dev-1", after: set, now: now), "turned off, or the events gone")
        let unheard = "unheard \(Int(now.timeIntervalSince1970) - 3600)"
        #expect(!LeaveBy.shouldSay(other, after: unheard, now: now), "a plugin from before 1.11: not every run")
        #expect(LeaveBy.shouldSay(other, after: unheard, now: now.addingTimeInterval(6 * 3600)))
    }

    @Test func whatACheckFoundIsTakenIn() {
        let dentist = event(in: 120), lunch = event("Lunch", in: 300)
        let kept = [dentist.alertID: worked(dentist, at: now.addingTimeInterval(-30 * 60), alertAt: dentist.start.addingTimeInterval(-30 * 60)),
                    lunch.alertID: worked(lunch)]
        let merged = LeaveBy.merge([dentist.alertID: LeaveCheck.Checked(travel: 30 * 60, at: now, fired: nil),
                                    lunch.alertID: LeaveCheck.Checked(travel: 10 * 60, at: now.addingTimeInterval(-60), fired: nil),
                                    "gone": LeaveCheck.Checked(travel: 1, at: now, fired: nil)], into: kept)
        #expect(merged[dentist.alertID]?.travel == 30 * 60 && merged[dentist.alertID]?.at == now, "a fresher estimate wins")
        #expect(merged[lunch.alertID] == kept[lunch.alertID], "an older one doesn't")
        #expect(merged["gone"] == nil)
        // The plan then keeps the extension's time: nothing to set back, and Apple Maps not asked again.
        let plan = LeaveBy.plan(events: [dentist], worked: merged, headsUps: [], pending: [], now: now)
        #expect(plan.alerts.first?.leave == dentist.start.addingTimeInterval(-35 * 60), "30 minutes there, five in hand (10% of 30 is three; 15% would be five too)")
        #expect(!LeaveBy.needsTravel(dentist, worked: merged[dentist.alertID], from: here, mode: .driving, now: now.addingTimeInterval(60)))
        // One the extension set off itself has gone off.
        let fired = LeaveBy.merge([dentist.alertID: LeaveCheck.Checked(travel: 80 * 60, at: now, fired: now)], into: kept)
        #expect(LeaveBy.plan(events: [dentist], worked: fired, headsUps: [], pending: [], now: now.addingTimeInterval(60)).alerts.isEmpty)
    }

    @Test func whatTheCheckSays() {
        let leave = now.addingTimeInterval(40 * 60)
        #expect(LeaveCheck.outcome(was: leave, now: leave.addingTimeInterval(-4 * 60), at: now) == .same)
        #expect(LeaveCheck.outcome(was: leave, now: leave.addingTimeInterval(-5 * 60), at: now) == .heavier)
        #expect(LeaveCheck.outcome(was: leave, now: leave.addingTimeInterval(6 * 60), at: now) == .lighter)
        #expect(LeaveCheck.outcome(was: leave, now: now.addingTimeInterval(30), at: now) == .leaveNow)
        #expect(LeaveCheck.outcome(was: leave, now: nil, at: now) == .unchecked)

        let same = LeaveCheck.content(.same, title: "Dentist", leave: leave, travel: 25 * 60, mode: .driving, sound: true)
        #expect(same.title == "Dentist: traffic checked")
        #expect(same.body.hasPrefix("Leave by ") && same.body.hasSuffix(" · 25 min by car"))
        #expect(same.interruptionLevel == .passive && same.sound == nil, "quiet")
        #expect(same.userInfo[PushNote.kindKey] as? String == "leave")
        let heavier = LeaveCheck.content(.heavier, title: "Dentist", leave: leave, travel: 35 * 60, mode: .driving, sound: true)
        #expect(heavier.title == "Dentist: traffic is heavier" && heavier.body.hasSuffix(" · 35 min by car"))
        #expect(heavier.interruptionLevel == .timeSensitive && heavier.sound != nil)
        #expect(LeaveCheck.content(.heavier, title: "Dentist", leave: leave, travel: 35 * 60, mode: .driving, sound: false).sound == nil, "the sound setting holds")
        #expect(LeaveCheck.content(.lighter, title: "Dentist", leave: leave, travel: 15 * 60, mode: .driving).interruptionLevel == .passive)
        let atOnce = LeaveCheck.content(.leaveNow, title: "Dentist", leave: now, travel: 45 * 60, mode: .driving, sound: true)
        #expect(atOnce.title == "Time to leave for Dentist" && atOnce.body == "Leave now · 45 min by car")
        #expect(LeaveCheck.content(.unchecked, title: "Dentist", leave: leave, travel: nil, mode: .driving, alertBody: "Leave by 2:05 PM · 25 min by car").body
                == "Leave by 2:05 PM · 25 min by car", "the alert stays as it was")
        let gone = LeaveCheck.content(.gone, title: "", leave: now, travel: nil, mode: .driving, sound: true)
        #expect(gone.title.isEmpty && gone.body == "Leave-By Alerts checked your calendar." && gone.interruptionLevel == .passive && gone.sound == nil)
    }

    @Test func aChecksFindingsAreTakenOnce() throws {
        let store = try #require(UserDefaults(suiteName: "leavecheck-\(UUID().uuidString)"))
        LeaveCheck.keep(LeaveCheck.Checked(travel: 600, at: now, fired: nil), for: "a", in: store)
        LeaveCheck.keep(LeaveCheck.Checked(travel: 900, at: now, fired: now), for: "b", in: store)
        #expect(LeaveCheck.take(in: store).keys.sorted() == ["a", "b"])
        #expect(LeaveCheck.take(in: store).isEmpty)
    }

    @Test func workedOutIsKeptBetweenRuns() throws {
        let store = try #require(UserDefaults(suiteName: "leaveby-\(UUID().uuidString)"))
        let dentist = event()
        LeaveBy.keep([dentist.alertID: worked(dentist)], in: store)
        #expect(LeaveBy.worked(in: store)[dentist.alertID] == worked(dentist))
        LeaveBy.keep([:], in: store)
        #expect(LeaveBy.worked(in: store).isEmpty)
    }
}
