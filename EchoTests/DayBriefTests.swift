import Foundation
import Testing
@testable import Echo

/// A daily brief read as one day's calendar (asked 2026-10-31: "the daily morning brief showed my
/// calendar but not in the card"), and every briefing shown without the model's narration ahead.
struct DayBriefTests {
    private let english = Locale(identifier: "en_US")
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 7) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    /// The shape the first one came in (names made up): the model's working line, a rule, a
    /// heading with the date, a table with a Time column, then a second table naming one again.
    private let tabled = """
        No attendees or Zoom link on the Climbing event. Now let me compile the morning meeting brief.

        ---

        ## Morning Meeting Brief — Saturday, October 31, 2026

        ### Meetings from 9:00 AM onwards:

        | Time | Title | Attendees | Zoom Link |
        |---|---|---|---|
        | All day | Priya PTO (through Nov 3) | 3 | — |
        | All day | Halloween | — | — |
        | All day | Fill Out Time Allocations | 2 | — |
        | 10:00 – 11:00 | Climbing | — | — |

        **Scheduling conflicts:** None — all-day events overlap by nature, but there is one scheduled time-block: **Climbing** at 10:00–11:00 AM.

        ### Zoom Links

        | Time | Title | Zoom Link |
        |---|---|---|
        | 10:00 – 11:00 | Climbing | — |
        | 2:00 – 2:30 PM | Design review | [Join](https://zoom.us/j/5550100) |

        No Zoom links are associated with today's events. Have a good weekend, Alex.
        """

    @Test func theTableShapeReadsAsItsDayDeduplicated() throws {
        let shown = DayBrief.withoutNarration(tabled)
        let brief = try #require(DayBrief.read(title: "Daily meeting brief", text: shown, at: at(2026, 10, 31), calendar: calendar, locale: english))
        #expect(brief.day == "2026-10-31")
        #expect(brief.allDay.map(\.title) == ["Priya PTO (through Nov 3)", "Halloween", "Fill Out Time Allocations"])
        #expect(brief.timed.map(\.title) == ["Climbing", "Design review"], "Climbing once, though both tables name it")
        #expect(brief.timed.first?.start == 600 && brief.timed.first?.end == 660)
        #expect(brief.timed.last?.start == 14 * 60 && brief.timed.last?.end == 14 * 60 + 30)
        #expect(brief.timed.last?.place == "https://zoom.us/j/5550100", "a Zoom column's link is its place")
        #expect(brief.rows.first?.place == nil, "a dash is nothing")
    }

    /// Under the card, only what it doesn't show (asked 2026-11-06), in the shape of his brief.
    @Test func theWordsUnderTheCardLeaveOutItsSchedule() {
        let brief = """
            ## Today, Friday, November 6

            | Time | Title | Attendees | Zoom |
            |---|---|---|---|
            | All day | Sam PTO | 2 | — |
            | 12:30 – 1:00 PM | Stand-up | 4 | — |
            | 5:00 – 6:00 PM | Weekly Review | 33 | [Join](https://zoom.us/j/5550100) |

            **Conflict:** Dentist and Weekly Review, 5:00–6:00 PM (overlap).
            """
        #expect(DayBrief.withoutSchedule(brief) == "**Conflict:** Dentist and Weekly Review, 5:00–6:00 PM (overlap).")
        let shown = DayBrief.withoutSchedule(DayBrief.withoutNarration(tabled))
        #expect(!shown.contains("| Climbing |") && !shown.contains("Design review"), "both tables go")
        #expect(shown.contains("**Scheduling conflicts:**") && shown.contains("Have a good weekend"), "the rest stays")
        #expect(!shown.contains("Morning Meeting Brief") && !shown.contains("Meetings from 9:00 AM"), "headings over the schedule, or naming the day, go")
        #expect(DayBrief.withoutSchedule("- 9:00 AM Stand-up\n- All day: Rent") == "", "a list of times and nothing else: nothing")
        #expect(DayBrief.withoutSchedule("Bring the slides.") == "Bring the slides.")
    }

    @Test func aBulletListUnderACalendarTitleReadsAsTomorrow() throws {
        let text = """
            Here's what's on tomorrow.

            - 9:00 AM Stand-up
            - **12:30 PM** · Lunch with Dana @ Rossio Roasters
            - All day: Pay the rent
            - 9:00 AM Stand-up
            """
        let brief = try #require(DayBrief.read(title: "Your agenda", text: text, at: at(2026, 10, 30, 20), calendar: calendar, locale: english))
        #expect(brief.day == "2026-10-31", "\"tomorrow\", read against when it came")
        #expect(brief.rows.map(\.title) == ["Pay the rent", "Stand-up", "Lunch with Dana"], "all day first, then by time; the stand-up once")
        #expect(brief.rows[2].start == 12 * 60 + 30 && brief.rows[2].place == "Rossio Roasters")
        // Two timed lines make a schedule under any title, with a date in a heading.
        let dated = "## Sat Oct 31\n- 8:00 AM Run\n- 6:00 PM Dinner at Lucia's"
        #expect(DayBrief.read(title: "Morning note", text: dated, at: at(2026, 10, 30), calendar: calendar, locale: english)?.day == "2026-10-31")
    }

    @Test func aHeadsUpAWeekAndAWrapUpAreNotADay() {
        // A heads-up: its own event card, and no schedule in it anyway.
        let headsUp = AgentBriefing(id: "h/1", title: AgentBriefing.headsUpPrefix + "Dentist", agent: "Sol",
                                    text: "- 7:30 AM Dentist\n- 8:30 AM Back home", at: .now, failed: false)
        #expect(headsUp.dayBrief == nil)
        #expect(DayBrief.read(title: "Heads-up: Dentist", text: "Dentist at 7:30, in 30 minutes. Bring your card.", at: .now) == nil)
        // The Week Ahead: several days, `WeekPlan`'s.
        let week = "A heavy Friday.\n\n## Friday, Oct 30\n- 9:00 AM Morning blocks\n- 11:30 AM Planning\n\n## Saturday, Oct 31\n- 10:00 AM Climbing\n- 1:00 PM Lunch"
        #expect(DayBrief.read(title: "Morning schedule", text: week, at: at(2026, 10, 29), calendar: calendar, locale: english) == nil, "two days aren't a day")
        #expect(AgentBriefing(id: "w/1", title: WeekAhead.title, agent: "Sol", text: week, at: .now, failed: false).dayBrief == nil)
        // The wrap-up, by its title, though it names times tomorrow.
        let wrapUp = "### Tomorrow\n- 9:00 AM The plumber\n- 3:30 PM Pickles at the vet"
        #expect(AgentBriefing(id: "e/1", title: EveningWrapUp.title, agent: "Sol", text: wrapUp, at: .now, failed: false).dayBrief == nil)
        #expect(AgentBriefing(id: "m/1", title: "Morning Ideas", agent: "Sol", text: wrapUp, at: .now, failed: false).dayBrief == nil)
        // No schedule in it: words.
        #expect(DayBrief.read(title: "Daily brief", text: "**Done:** the vet booked.\n\n**Tomorrow:** call the plumber.", at: .now) == nil)
        #expect(DayBrief.read(title: "Daily news", text: "Markets opened up today. Rain at 3.", at: .now) == nil)
    }

    @Test func timesAsModelsWriteThem() {
        func span(_ text: String) -> [Int?]? { DayBrief.clock(text).map { [$0.start, $0.end] } }
        #expect(span("10:00 – 11:00") == [600, 660])
        #expect(span("11–1 PM") == [660, 780])
        #expect(span("9:30 AM–12 PM") == [570, 720])
        #expect(span("1:00 – 1:45 PM") == [780, 825])
        #expect(span("2:00 – 3:00") == [840, 900], "a meeting brief's 2:00 is in the afternoon")
        #expect(span("14:00") == [840, nil])
        #expect(span("07:30") == [450, nil])
        #expect(span("10am") == [600, nil])
        #expect(span("Noon") == [720, nil])
        #expect(span("9–12") == [540, 720])
        #expect(span("3 meetings") == nil)
        #expect(span("2026") == nil)
    }

    @Test func datesWithAndWithoutAYear() {
        let near = at(2026, 12, 30)
        func day(_ line: String) -> DateComponents? {
            DayBrief.date(in: line, near: near, calendar: calendar, locale: english).map { calendar.dateComponents([.year, .month, .day], from: $0) }
        }
        #expect(day("Fri, Jan 1")?.year == 2027, "the nearest year")
        #expect(day("## Wednesday, December 30th")?.day == 30)
        #expect(day("30 December 2026")?.month == 12)
        #expect(day("Nothing dated here") == nil)
    }

    @Test func theNarrationBeforeTheBriefIsntShown() {
        let shown = DayBrief.withoutNarration(tabled)
        #expect(shown.hasPrefix("## Morning Meeting Brief"))
        #expect(shown.contains("Have a good weekend"))
        // A rule with no heading after it, a rule after long reasoning, a rule first, a heading
        // first: as they are.
        let noHeading = "Let me check.\n\n---\n\nYou have nothing on today."
        #expect(DayBrief.withoutNarration(noHeading) == noHeading)
        let long = Array(repeating: "A long paragraph of the answer itself, not narration at all.", count: 5).joined(separator: "\n\n") + "\n\n---\n\n## More"
        #expect(DayBrief.withoutNarration(long) == long)
        let ruleFirst = "---\n\n## Brief"
        #expect(DayBrief.withoutNarration(ruleFirst) == ruleFirst)
        let headed = "## Brief\n\nText.\n\n---\n\n## Second"
        #expect(DayBrief.withoutNarration(headed) == headed)
        // Shown on any briefing, kept as it came.
        let briefing = AgentBriefing(id: "n/1", title: "Daily meeting brief", agent: "Sol", text: tabled, at: at(2026, 10, 31), failed: false)
        #expect(briefing.shownText.hasPrefix("## Morning"))
        #expect(briefing.text == tabled)
    }

    @Test func thePhonesEventsComeFirstWithTheBriefsOthers() throws {
        let brief = try #require(DayBrief.read(title: "Daily meeting brief", text: DayBrief.withoutNarration(tabled),
                                               at: at(2026, 10, 31), calendar: calendar, locale: english))
        let fallback = brief.agenda(calendar: calendar)
        #expect(fallback.days == ["2026-10-31"] && fallback.events.count == 5)
        let climbing = try #require(fallback.events.first { $0.title == "Climbing" })
        #expect(climbing.start == calendar.date(bySettingHour: 10, minute: 0, second: 0, of: at(2026, 10, 31)))
        #expect(!climbing.allDay && climbing.day == "2026-10-31" && climbing.calendar == nil)
        let phone = [ReplyCard.Agenda.Event(title: "Climbing gym", start: climbing.start, end: climbing.end, allDay: false,
                                            day: "2026-10-31", location: "Boulder Barn", calendar: "Home", notes: nil),
                     ReplyCard.Agenda.Event(title: "Halloween", start: at(2026, 10, 31, 0), end: nil, allDay: true,
                                            day: "2026-10-31", location: nil, calendar: "Holidays", notes: nil)]
        let merged = brief.agenda(phone: phone, calendar: calendar)
        #expect(merged.events.map(\.title) == ["Climbing gym", "Halloween", "Priya PTO (through Nov 3)", "Fill Out Time Allocations", "Design review"])
        #expect(brief.agenda(phone: [], calendar: calendar).events.count == 5, "a calendar without them: the brief's")
    }
}
