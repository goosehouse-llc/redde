import Foundation
import Testing
@testable import Echo

/// The Week Ahead as a calendar (asked 2026-10-29): read from the shape the job asks for, and from
/// the bold one the first briefings came in.
struct WeekPlanTests {
    private let english = Locale(identifier: "en_US")

    @Test func theAskedForShapeReadsAsDaysOfTimedThings() throws {
        let text = """
            A heavy Friday, then a quiet weekend.

            ## Friday, Oct 30
            > Payday
            - 9–12 Morning blocks
            - 11:30 AM Planning session on the semantic layer
            - 12:30 PM DataOps stand-up
            - Reports due

            ## Saturday, Oct 31
            - Halloween
            - Fill out time allocations

            ## Sunday, Nov 1
            > Clocks go back
            - 1:00 PM Vikings vs. Lions

            Get ready: costumes for Saturday night
            """
        let plan = try #require(WeekPlan.parse(text, locale: english))
        #expect(plan.intro == "A heavy Friday, then a quiet weekend.")
        #expect(plan.days.map(\.weekday) == ["FRI", "SAT", "SUN"])
        #expect(plan.days.map(\.number) == ["30", "31", "1"])
        #expect(plan.days[0].notes == ["Payday"])
        #expect(plan.days[0].items == [.init(time: "9–12", what: "Morning blocks"),
                                       .init(time: "11:30 AM", what: "Planning session on the semantic layer"),
                                       .init(time: "12:30 PM", what: "DataOps stand-up"),
                                       .init(time: nil, what: "Reports due")])
        #expect(plan.days[2].items == [.init(time: "1:00 PM", what: "Vikings vs. Lions")])
        #expect(plan.after == ["costumes for Saturday night"])
        #expect(plan.count == 7)
    }

    @Test func theBoldShapeOfTheFirstBriefingsReadsToo() throws {
        let text = """
            Here is your week ahead (Oct 30 – Nov 5):

            **Friday, Oct 30** — Heavy day. Planning session (11:30), stand-up (12:30).

            **Saturday, Oct 31** — Halloween. Light day.
            """
        let plan = try #require(WeekPlan.parse(text, locale: english))
        #expect(plan.days.map(\.title) == ["Friday, Oct 30", "Saturday, Oct 31"])
        #expect(plan.days[0].notes == ["Heavy day. Planning session (11:30), stand-up (12:30)."])
        #expect(plan.days[1].items.isEmpty)
    }

    @Test func aBriefingThatIsntAWeekStaysText() {
        #expect(WeekPlan.parse("**Done:** the vet booked.\n\n**Tomorrow:** call the plumber.", locale: english) == nil)
        #expect(WeekPlan.parse("## Friday, Oct 30\n- 9:00 AM One day only", locale: english) == nil, "one day isn't a week")
    }

    @Test func daysInThePhonesLanguageRead() throws {
        let text = "## Viernes, 30 de oct.\n- 9:00 Reunión\n## Sábado, 31 de oct.\n- Halloween"
        let plan = try #require(WeekPlan.parse(text, locale: Locale(identifier: "es_ES")))
        #expect(plan.days.map(\.number) == ["30", "31"])
        #expect(plan.days[0].items == [.init(time: "9:00", what: "Reunión")])
    }
}
