import Foundation
import WidgetKit

#if DEBUG
// Screenshot and dev-hook seeding (`-echo.demo*` launch arguments) — kept out of
// Conversation proper so the turn logic stays readable.
extension Conversation {
    /// Dev hook (`-echo.demo`): a canned exchange so screenshots show every transcript element.
    func seedDemo() {
        cancel()
        replaceForDemo(messages: [Message(role: .user, text: "What's on my calendar tomorrow, and remind me to call the vet?")])
        var reply = Message(role: .assistant, text: """
        Tomorrow you have **two things** on the calendar:

        - 9:30 standup
        - 12:15 lunch with Dana

        I've added a reminder to call the vet at 4 pm. If you want to move it, say so.

        ```bash
        hermes remind --at 16:00 "call the vet"
        ```
        """)
        reply.reasoning = "The user wants two things: a calendar readout and a reminder. I'll query the calendar tool for tomorrow, then create the reminder, then summarize both briefly since this is a voice reply."
        reply.subagents = [
            SubagentActivity(id: "demo-1", goal: "Check the vet's opening hours for tomorrow", taskIndex: 0, taskCount: 2,
                             status: .completed, toolCount: 3, summary: "Open 8–6; no appointment needed for a callback.", durationSeconds: 14),
            SubagentActivity(id: "demo-2", goal: "Draft a reminder message for Dana about lunch", taskIndex: 1, taskCount: 2,
                             status: .running, toolCount: 1, lastTool: "write_file"),
        ]
        reply.tools = [ToolActivity(name: "calendar", preview: "list events for tomorrow", status: .completed),
                       ToolActivity(name: "reminders", preview: "create reminder", status: .completed)]
        reply.metrics = TurnMetrics(sentAt: .now.addingTimeInterval(-3.1), firstTokenAt: .now.addingTimeInterval(-2.4),
                                    completedAt: .now, characters: reply.text.count,
                                    usage: TokenUsage(input: 2140, output: 96, cached: nil, contextUsed: 2236), contextWindow: 131_072)
        mutateMessagesForDemo { $0.append(reply) }

        // A second exchange that exercises the richer Markdown: tasks, table, quote, links.
        mutateMessagesForDemo { $0.append(Message(role: .user, text: "Where are we on the kitchen project?")) }
        var second = Message(role: .assistant, text: """
        Kitchen remodel
        ---------------
        - [x] Permits approved
        - [x] Cabinets ordered (`ETA 09-22`)
        - [ ] Countertop template
        - [ ] Plumbing rough-in

        | Item | Qty | Cost |
        |:-----|:---:|-----:|
        | Cabinets | 12 | $6,400 |
        | Quartz | 1 | $2,150 |
        | Labor | — | $3,800 |

        > The countertop crew can't template until the cabinets are set.
        > Earliest slot is the **24th**.

        Details are in the [shared plan](https://example.com/kitchen). Ping me if you want ~~Friday~~ Monday instead.
        """)
        second.createdAt = .now
        second.metrics = TurnMetrics(sentAt: .now.addingTimeInterval(-2.2), firstTokenAt: .now.addingTimeInterval(-1.7),
                                     completedAt: .now, characters: second.text.count,
                                     usage: TokenUsage(input: 2410, output: 142, cached: nil, contextUsed: 2552), contextWindow: 131_072)
        mutateMessagesForDemo { $0.append(second) }

        mutateMessagesForDemo { $0.append(Message(role: .user, text: "Sketch the approval flow and the cost formula.")) }
        var third = Message(role: .assistant, text: """
        Here's the flow Hermes follows for a risky command:

        ```mermaid
        flowchart LR
          A[Tool call] --> B{Needs approval?}
          B -- no --> C[Run]
          B -- yes --> D[Notify you]
          D --> E{Approve / Deny}
          E -- approve --> C
          E -- deny --> F[Skip and explain]
        ```

        And the per-turn cost, with cached prompt tokens discounted:

        $$
        \\text{cost} = p_{in}\\,(n_{in} - n_{cache}) + p_{cache}\\,n_{cache} + p_{out}\\,n_{out}
        $$
        """)
        third.createdAt = .now
        third.metrics = TurnMetrics(sentAt: .now.addingTimeInterval(-2.6), firstTokenAt: .now.addingTimeInterval(-1.9),
                                    completedAt: .now, characters: third.text.count,
                                    usage: TokenUsage(input: 2610, output: 160, cached: nil, contextUsed: 2770), contextWindow: 131_072)
        mutateMessagesForDemo { $0.append(third) }
        WidgetSnapshot.save(question: messages[0].text, reply: reply.text)
        WidgetCenter.shared.reloadTimelines(ofKind: "com.goosehouse.echo.lastreply")
    }

    /// Screenshot helper: trims the seeded demo to its first messages.
    func keepFirstMessages(_ n: Int) { mutateMessagesForDemo { $0 = Array($0.prefix(n)) } }

    /// UI-test helper: the demo repeated until the transcript is many screens long, ending on a
    /// known line so a test can tell it reached the bottom.
    func seedLongDemo() {
        seedDemo()
        let one = messages
        let repeated = (0..<8).flatMap { _ in
            one.map { m -> Message in
                var copy = Message(role: m.role, text: m.text, createdAt: m.createdAt)
                copy.metrics = m.metrics; copy.reasoning = m.reasoning; copy.tools = m.tools; copy.subagents = m.subagents
                return copy
            }
        }
        mutateMessagesForDemo { $0 = repeated }
        mutateMessagesForDemo { $0.append(Message(role: .user, text: "End of the long demo.")) }
    }

    /// Screenshot helper (`-echo.demoLibrary`): a few local conversations so the list isn't empty.
    func seedDemoLibrary() {
        let samples: [(String, String, TimeInterval)] = [
            ("Plan the weekend hike", "Sunrise at Bear Peak works: 5:40 am start, back by 10. I've saved the route and packed-list reminder.", -3_600),
            ("Draft the landlord email", "Here's a firm but friendly draft about the heating; it references the lease clause and asks for a date.", -26_000),
            ("What did we decide about the deck?", "Composite boards, the mid-grey, and the contractor comes the week of the 21st.", -190_000),
            ("Lisbon trip ideas", "Three days: Alfama and the miradouros, a day in Sintra, and the LX Factory market on Sunday.", -600_000),
        ]
        // Idempotent: drop earlier copies so repeated launches don't stack duplicates.
        let titles = Set(samples.map(\.0))
        storeForDemo.summaries.filter { titles.contains($0.title) }.forEach { storeForDemo.delete(id: $0.id) }
        for (q, a, ago) in samples {
            let when = Date.now.addingTimeInterval(ago)
            var reply = Message(role: .assistant, text: a, createdAt: when.addingTimeInterval(4))
            reply.metrics = TurnMetrics(sentAt: when, firstTokenAt: when.addingTimeInterval(0.6), completedAt: when.addingTimeInterval(4), characters: a.count)
            storeForDemo.upsert(ConversationRecord(id: UUID(), title: q, createdAt: when, updatedAt: when.addingTimeInterval(4),
                                            transport: .chatCompletions, serverSessionID: nil,
                                            messages: [Message(role: .user, text: q, createdAt: when), reply]))
        }
    }
}
#endif
