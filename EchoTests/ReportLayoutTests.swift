import Foundation
import Testing
@testable import Echo

/// A report laid out rather than a wall of text (asked 2026-11-08 of a Strata watch's answer).
struct ReportLayoutTests {
    /// The answer that was asked about, cut down.
    private let strata = """
        These are session logs, not a prior milestone record. I have enough. Let me report the findings.

        None of the four trigger milestones has been reached — but there is concrete progress worth reporting.

        **Status: No release yet, but there's real progress on the Metal port — nothing usable for you yet, sir.**

        **The short answer:** Qwen3.6-35B-A3B still does NOT run on your M1 Max.

        1. **A full working Metal port now exists — on a fork branch, not yet merged.** Issue #3932 is still open. Measured on an **M5 Pro, 64 GB**:
           - Decode 74.6 tok/s
           - Prompt 4K/32K: 1,923 / 1,413 tok/s

        2. **PR #4885 — the "Metal silu gate" — is a DRAFT, not merged.** It's the first of a proposed 3-PR split.

        3. **Docs unchanged:** QWEN36.md still reads "The Intel Arc and Mac engines do not run it."
        """

    @Test func theStrataReportIsLaidOut() throws {
        let text = DayBrief.withoutNarration(strata)
        #expect(text.hasPrefix("None of the four"), "The model's working words are still at the top")
        let parts = try #require(ReportLayout.parts(text))
        #expect(parts.count == 6)
        // The outcome above the paragraph that led into it.
        #expect(parts[0] == .headline(label: "Status", text: "No release yet, but there's real progress on the Metal port — nothing usable for you yet, sir."))
        #expect(parts[1] == .block(.paragraph("None of the four trigger milestones has been reached — but there is concrete progress worth reporting.")))
        #expect(parts[2] == .callout(label: "The short answer", text: "Qwen3.6-35B-A3B still does NOT run on your M1 Max."))
        guard case let .point(number, lead, body) = parts[3] else { Issue.record("No first point"); return }
        #expect(number == "1")
        #expect(lead == "A full working Metal port now exists — on a fork branch, not yet merged.")
        #expect(body.first == .paragraph("Issue #3932 is still open. Measured on an **M5 Pro, 64 GB**:"))
        guard case let .list(items)? = body.last else { Issue.record("The point's own items aren't under it"); return }
        #expect(items.map(\.text) == ["Decode 74.6 tok/s", "Prompt 4K/32K: 1,923 / 1,413 tok/s"])
        #expect(items.allSatisfy { $0.indent == 0 })
        guard case let .point(_, docs, rest) = parts[5] else { Issue.record("No third point"); return }
        #expect(docs == "Docs unchanged")
        #expect(rest == [.paragraph("QWEN36.md still reads \"The Intel Arc and Mac engines do not run it.\"")])
    }

    @Test func plainTextStaysPlain() {
        #expect(ReportLayout.parts("The parcel is out for delivery and should arrive by 6.") == nil)
        #expect(ReportLayout.parts("**Done:** the vet booked.\n\nNothing else today.") == nil, "One callout alone isn't a report")
        #expect(ReportLayout.parts("- milk\n- **eggs**, the big ones\n- bread") == nil)
    }

    @Test func aShortBoldLineIsASectionName() throws {
        let parts = try #require(ReportLayout.parts("**What changed**\n\n- **Price:** down to $40\n- **Stock:** back in"))
        #expect(parts.first == .block(.heading(level: 3, text: "What changed")))
        #expect(parts.dropFirst().map { if case let .point(nil, lead, _) = $0 { lead } else { "" } } == ["Price", "Stock"])
    }

    @Test func aTaskListIsNotPoints() {
        #expect(ReportLayout.parts("**Status: two left.**\n\n- [x] **Vet** booked\n- [ ] **Plumber** to call") == nil)
    }

    @Test func announcingWordsGoOnlyWhenTheyAnnounce() {
        #expect(DayBrief.withoutAnnouncement("I have enough. Now I'll write up the summary:\n\n**All quiet.**") == "**All quiet.**")
        #expect(DayBrief.withoutAnnouncement("Time to compose the notification.\n\nYour parcel is here.") == "Your parcel is here.")
        // What leads into the rest, or asks something of the person, stays.
        let kept = ["Your parcel is out for delivery. Here's the update:\n\n- Arrives by 6",
                    "Let me know if you'd like me to send a reminder.\n\nThe vet is Thursday.",
                    "I'll tell you when it ships.\n\nIt's still at the warehouse.",
                    "Let me report the findings."]
        for text in kept { #expect(DayBrief.withoutAnnouncement(text) == text) }
    }

    /// The evening wrap-up as it came (2026-11-08): labels set off by a dash, the model's lead-in on an earlier run.
    @Test func theWrapUpsDashedLabelsAreCallouts() throws {
        let text = DayBrief.withoutNarration("""
            Both follow-ups set. Here is the evening wrap-up:

            **Done** — Venice picker v3: Claude finished two revisions today.

            **Waiting on you** — Both files are delivered but never landed. Say "put it in".

            **Tomorrow** – I'll offer the put-in back to you at nine.
            """)
        let parts = try #require(ReportLayout.parts(text))
        #expect(parts == [.callout(label: "Done", text: "Venice picker v3: Claude finished two revisions today."),
                          .callout(label: "Waiting on you", text: "Both files are delivered but never landed. Say \"put it in\"."),
                          .callout(label: "Tomorrow", text: "I'll offer the put-in back to you at nine.")])
        #expect(DayBrief.withoutAnnouncement("Here's the update:\n\n- Arrives by 6") == "Here's the update:\n\n- Arrives by 6")
    }
}
