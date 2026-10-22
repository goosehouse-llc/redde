import Foundation
import UIKit
import WidgetKit

#if DEBUG
// Screenshot and dev-hook seeding (`-echo.demo*` launch arguments) — kept out of
// Conversation proper so the turn logic stays readable.
extension Conversation {
    /// The demo conversation's id, the same at every launch: a test that leaves it for another
    /// conversation saves it, and the next seeding replaces that copy instead of adding one more.
    static let demoID = UUID(uuidString: "DE300000-0000-4000-8000-000000000001")!

    /// Dev hook (`-echo.demo`): a canned exchange so screenshots show every transcript element.
    func seedDemo() {
        cancel()
        replaceForDemo(id: Self.demoID, messages: [Message(role: .user, text: "What's on my calendar tomorrow, and remind me to call the vet?")])
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
        reply.tools = [ToolActivity(name: "calendar", preview: "list events for tomorrow", status: .completed,
                                    args: "date: tomorrow",
                                    output: "09:30–09:45  Standup\n12:15–13:15  Lunch with Dana"),
                       ToolActivity(name: "reminders", preview: "create reminder", status: .completed,
                                    args: "title: Call the vet\nat: 16:00",
                                    output: "created: true\nid: 4F2A")]
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

    /// Promo video (`-echo.demoStream`): the demo's first exchange played live: the question,
    /// then the thinking, the tool calls and the answer streaming in, as a real turn would.
    /// With a number of seconds, the conversation starts empty, on the start screen, and the
    /// question is sent after that long: it rises out of the message field as a sent one does.
    func streamDemo(askingAfter delay: Double? = nil) {
        seedDemo()
        guard messages.count >= 2 else { return }
        var question = messages[0]
        let full = messages[1]
        mutateMessagesForDemo { $0 = delay == nil ? [question] : [] }
        Task { @MainActor in
            if let delay {
                try? await Task.sleep(for: .seconds(delay))
                question.createdAt = .now   // just sent, so it arrives (`MessageArrival`)
                mutateMessagesForDemo { $0 = [question] }
            }
            try? await Task.sleep(for: .seconds(0.8))
            var reply = Message(role: .assistant, text: "")
            let id = reply.id
            mutateMessagesForDemo { $0.append(reply) }
            setStreamingForDemo(true)
            defer { setStreamingForDemo(false) }
            @MainActor func update(_ change: (inout Message) -> Void) {
                change(&reply)
                mutateMessagesForDemo { if let i = $0.firstIndex(where: { $0.id == id }) { $0[i] = reply } }
            }
            let started = Date.now
            update { $0.reasoningStartedAt = .now }
            for word in full.reasoning.split(separator: " ") {
                update { $0.reasoning += ($0.reasoning.isEmpty ? "" : " ") + word }
                try? await Task.sleep(for: .milliseconds(12))
            }
            update { $0.reasoningEndedAt = .now }
            for var tool in full.tools {
                try? await Task.sleep(for: .milliseconds(260))
                tool.status = .running
                tool.startedAt = .now
                update { $0.tools.append(tool) }
                try? await Task.sleep(for: .milliseconds(900))
                update { if let i = $0.tools.firstIndex(where: { $0.id == tool.id }) { $0.tools[i].status = .completed; $0.tools[i].endedAt = .now } }
            }
            try? await Task.sleep(for: .milliseconds(300))
            let first = Date.now
            // Word by word, keeping the line breaks and code fence intact.
            var rest = Substring(full.text)
            while !rest.isEmpty {
                let end = rest.firstIndex(where: { $0 == " " || $0 == "\n" }).map { rest.index(after: $0) } ?? rest.endIndex
                update { $0.text += rest[..<end] }
                rest = rest[end...]
                try? await Task.sleep(for: .milliseconds(34))
            }
            update {
                $0.metrics = TurnMetrics(sentAt: started, firstTokenAt: first, completedAt: .now,
                                         characters: full.text.count, usage: full.metrics?.usage, contextWindow: 131_072)
            }
        }
    }

    /// Dev hook (`-echo.demoPhone`): the agent using the phone, played live for the video. It
    /// reads tomorrow's calendar, wants to add a reminder, which Phone tools puts to the person
    /// with its own question (the take waits for the answer), and then finds a photo by what
    /// it shows. Nothing on the phone is read or changed: what the tools answer is canned.
    /// `reach`: the other two instead, a call and a message, to numbers that are nobody's. On
    /// an iPhone iOS really asks about the call and the Messages sheet really opens; a
    /// simulator has no phone and no Messages, so there the two are only spoken of.
    func streamPhoneDemo(reach: Bool = false) {
        cancel()
        replaceForDemo(messages: [])
        Task { @MainActor in
            setStreamingForDemo(true)
            defer { setStreamingForDemo(false) }
            if reach {
                try? await Task.sleep(for: .seconds(1.4))
                await playForDemo(
                    question: "Call the vet.",
                    thinking: "Riverside Vet is in the contacts with a main line and an after-hours one. It is the afternoon: the main line.",
                    steps: [(ToolActivity(name: "phone_contacts_search", preview: "vet", status: .running, output: "Riverside Vet: main, after hours"), nil),
                            (ToolActivity(name: "phone_people_call", preview: "Riverside Vet, main", status: .running, output: "asked"), {
                                if let number = URL(string: "tel:5550107700") { _ = await SystemPeople().open(number) }
                            })],
                    reply: "Your iPhone is asking whether to call **Riverside Vet**. Tap Call and it dials.")
                try? await Task.sleep(for: .seconds(1.8))
                await playForDemo(
                    question: "Text Dana that I'm running ten minutes late.",
                    thinking: "A message is the person's to send. I write it, and Messages opens with it for them.",
                    steps: [(ToolActivity(name: "phone_people_message", preview: "Dana Lee", status: .running, output: "sent"), {
                        // Where there is no Messages to open, the time a person takes to read and send.
                        if await MessageSheet.shared.present(to: ["+1 (555) 010-2030"], text: "Running about ten minutes late. Start without me!") == .failed {
                            try? await Task.sleep(for: .seconds(2.2))
                        }
                    })],
                    reply: "You sent it. Dana knows you're ten minutes behind.")
                return
            }
            // Tomorrow at four, on this phone's own calendar.
            let tomorrow = Calendar.current.dateComponents([.year, .month, .day], from: Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now)
            let due = String(format: "%04d-%02d-%02dT16:00", tomorrow.year ?? 2026, tomorrow.month ?? 1, tomorrow.day ?? 1)
            // The question is the real one, asked by a service whose plugin and tools are stand-ins.
            let phone = DeviceToolsService(settings: .shared, defaults: UserDefaults(suiteName: "demo-phone") ?? .standard,
                                           command: { _ in "" }, run: { _, _, _ in .object([:]) })
            try? await Task.sleep(for: .seconds(1.4))
            await playForDemo(
                question: "What's on tomorrow? And remind me to call the vet at 4.",
                thinking: "Two things. Tomorrow's events come from the calendar on the phone. The reminder is a change there, so the phone asks first.",
                steps: [(ToolActivity(name: "phone_calendar_events", preview: "tomorrow", status: .running,
                                      output: "09:30 Standup\n12:15 Lunch with Dana"), nil),
                        (ToolActivity(name: "phone_reminders_add", preview: "Call the vet, 4:00 PM", status: .running, output: "added"), {
                            _ = try? await phone.perform(DeviceRequest(id: "demo", tool: DeviceTool.remindersAdd.rawValue,
                                                                       arguments: .object(["title": .string("Call the vet"), "due": .string(due)])))
                        })],
                reply: """
                Tomorrow you have **two things**:

                - 9:30 standup
                - 12:15 lunch with Dana

                The reminder to call the vet is set for 4 PM.
                """)
            try? await Task.sleep(for: .seconds(1.6))
            await playForDemo(
                question: "Find my photo of the bowling scoreboard.",
                thinking: "The phone looks through its own pictures for what they show. I ask for the best match and look at it.",
                steps: [(ToolActivity(name: "phone_photos_search", preview: "bowling scoreboard", status: .running, output: "1 match: scoreboard, lane, 187"), nil),
                        (ToolActivity(name: "phone_photos_get", preview: "Saturday, 8:42 PM", status: .running, output: "scoreboard.jpg"), nil)],
                reply: "Found it, from Saturday at 8:42 PM. You bowled a **187**, your best this year.",
                picture: Self.scoreboardForDemo())
        }
    }

    /// The scenes of the second Phone tools video (`-echo.demoFun`): a day with the agent, every
    /// area in turn. Played like `streamPhoneDemo`; the timer and the widget are set for real, so
    /// the Lock Screen and the Home Screen show them.
    func streamFunDemo(_ scene: String) {
        cancel()
        replaceForDemo(messages: [])
        Task { @MainActor in
            func step(_ name: String, _ preview: String, _ output: String) -> ToolActivity {
                ToolActivity(name: name, preview: preview, status: .running, output: output)
            }
            if scene == "look" {
                // Once the camera has been opened and the question asked over it.
                while DemoEye.openedAt == nil { try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .seconds(3.6))
            } else {
                try? await Task.sleep(for: .seconds(1.4))
            }
            setStreamingForDemo(true)
            defer { setStreamingForDemo(false) }
            switch scene {
            case "morning":
                let today = Calendar.current.dateComponents([.year, .month, .day], from: .now)
                let due = String(format: "%04d-%02d-%02dT16:00", today.year ?? 2026, today.month ?? 1, today.day ?? 1)
                let phone = DeviceToolsService(settings: .shared, defaults: UserDefaults(suiteName: "demo-phone") ?? .standard,
                                               command: { _ in "" }, run: { _, _, _ in .object([:]) })
                await playForDemo(
                    question: "Morning! What's on today?",
                    thinking: "Today's events are on the phone's calendar.",
                    steps: [(step("phone_calendar_events", "today", "09:30 Standup\n12:15 Lunch with Dana\n19:00 Pasta night"), nil)],
                    reply: """
                    Morning ☀️ Today you've got:

                    - 9:30 standup
                    - 12:15 lunch with Dana
                    - 7:00 pasta night 🍝
                    """)
                try? await Task.sleep(for: .seconds(1.2))
                await playForDemo(
                    question: "Remind me to call the vet at 4.",
                    thinking: "A reminder is a change on the phone, so the phone asks first.",
                    steps: [(step("phone_reminders_add", "Call the vet, 4:00 PM", "added"), {
                        _ = try? await phone.perform(DeviceRequest(id: "demo", tool: DeviceTool.remindersAdd.rawValue,
                                                                   arguments: .object(["title": .string("Call the vet"), "due": .string(due)])))
                    })],
                    reply: "Done ✅ I'll nudge you at 4.")
            case "timer":
                await playForDemo(
                    question: "Pasta's in! Nine minute timer?",
                    thinking: "A timer on the phone, one of iOS's own, so it rings like the Clock app's.",
                    steps: [(step("phone_alarms_set", "Pasta, 9 minutes", "set"), {
                        _ = try? await DeviceAlarms().set(.object(["title": .string("Pasta"), "minutes": .number(9)]))
                    })],
                    reply: "Timer's on: **9 minutes**. It's on your Lock Screen, and it rings even with Redde closed.")
            case "widget":
                await playForDemo(
                    question: "Save my shopping list to Files and stick it on my widget: spaghetti, basil, parmesan, two lemons.",
                    thinking: "The list goes in Redde's folder in Files, and the same lines on its widget.",
                    steps: [(step("phone_files_save", "Shopping list.md", "saved"), nil),
                            (step("phone_widget_set", "Shopping list", "on the widget"), {
                                _ = try? await DeviceBoard().set(.object(["title": .string("Shopping list"),
                                                                         "text": .string("Spaghetti\nBasil\nParmesan\nTwo lemons")]))
                            })],
                    reply: "Saved to **Files**, and it's on your widget. Don't forget the parmesan.")
            case "photo":
                await playForDemo(
                    question: "Find my bowling scoreboard from Saturday.",
                    thinking: "The phone looks through its own pictures for what they show. I ask for the best match and look at it.",
                    steps: [(step("phone_photos_search", "bowling scoreboard", "1 match: scoreboard, lane, 187"), nil),
                            (step("phone_photos_get", "Saturday, 8:42 PM", "scoreboard.jpg"), nil)],
                    reply: "Found it 🎳 You bowled a **187**. Personal best, by the way.",
                    picture: Self.scoreboardForDemo())
            case "look":
                await playForDemo(
                    question: "Is my plant okay? It looks kind of sad.",
                    thinking: "A pothos: drooping stems, dry soil pulling away from the pot, one yellow leaf.",
                    steps: [],
                    reply: "That's a pothos, and it's **thirsty** 🪴 The droop and the dry soil give it away. Water it until it drains, and it'll perk up by tomorrow.",
                    shown: Attachment.image(DemoEye.plant(), filename: "camera.jpg"))
            case "reach":
                await playForDemo(
                    question: "Call the vet.",
                    thinking: "Riverside Vet is in the contacts with a main line and an after-hours one. It's the afternoon: the main line.",
                    steps: [(step("phone_contacts_search", "vet", "Riverside Vet: main, after hours"), nil),
                            (step("phone_people_call", "Riverside Vet, main", "asked"), {
                                if let number = URL(string: "tel:5550107700") { _ = await SystemPeople().open(number) }
                            })],
                    reply: "Your iPhone's asking whether to call **Riverside Vet** 📞 Tap Call and it dials.")
                try? await Task.sleep(for: .seconds(1.6))
                await playForDemo(
                    question: "Text Dana I'm running ten minutes late.",
                    thinking: "A message is theirs to send. I write it, and Messages opens with it.",
                    steps: [(step("phone_people_message", "Dana Lee", "written"), {
                        // Where there is no Messages to open, the time a person takes to read and send.
                        if await MessageSheet.shared.present(to: ["+1 (555) 010-2030"], text: "Running ten minutes late, start without me! 🏃") == .failed {
                            try? await Task.sleep(for: .seconds(1.6))
                        }
                    })],
                    reply: "It's written and waiting in Messages 💬 Tap Send and Dana knows.")
            default:
                break
            }
        }
    }

    /// One exchange played live: the question arrives (with `shown`, a picture sent with it),
    /// then thinking, each tool step in turn (a step with something to wait for waits for it),
    /// then the reply word by word.
    private func playForDemo(question: String, thinking: String, steps: [(ToolActivity, (() async -> Void)?)], reply text: String,
                             picture: Attachment? = nil, shown: Attachment? = nil) async {
        mutateMessagesForDemo {
            var asked = Message(role: .user, text: question)
            if let shown { asked.attachments = [shown] }
            $0.append(asked)
        }
        try? await Task.sleep(for: .seconds(0.9))
        var reply = Message(role: .assistant, text: "")
        let id = reply.id
        mutateMessagesForDemo { $0.append(reply) }
        func update(_ change: (inout Message) -> Void) {
            change(&reply)
            mutateMessagesForDemo { if let i = $0.firstIndex(where: { $0.id == id }) { $0[i] = reply } }
        }
        let started = Date.now
        update { $0.reasoningStartedAt = .now }
        for word in thinking.split(separator: " ") {
            update { $0.reasoning += ($0.reasoning.isEmpty ? "" : " ") + word }
            try? await Task.sleep(for: .milliseconds(28))
        }
        update { $0.reasoningEndedAt = .now }
        for (step, wait) in steps {
            var tool = step
            try? await Task.sleep(for: .milliseconds(260))
            tool.startedAt = .now
            update { $0.tools.append(tool) }
            try? await Task.sleep(for: .milliseconds(wait == nil ? 1000 : 500))
            await wait?()
            update { if let i = $0.tools.firstIndex(where: { $0.id == tool.id }) { $0.tools[i].status = .completed; $0.tools[i].endedAt = .now } }
        }
        try? await Task.sleep(for: .milliseconds(300))
        if let picture { update { $0.attachments.append(picture) } }
        let first = Date.now
        var rest = Substring(text)
        while !rest.isEmpty {
            let end = rest.firstIndex(where: { $0 == " " || $0 == "\n" }).map { rest.index(after: $0) } ?? rest.endIndex
            update { $0.text += rest[..<end] }
            rest = rest[end...]
            try? await Task.sleep(for: .milliseconds(42))
        }
        update { $0.metrics = TurnMetrics(sentAt: started, firstTokenAt: first, completedAt: .now, characters: text.count, usage: nil, contextWindow: 131_072) }
    }

    /// A picture of a bowling alley's scoreboard, drawn: the photo the demo's agent finds.
    static func scoreboardForDemo() -> Attachment? {
        let size = CGSize(width: 1200, height: 800)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            UIColor(red: 0.04, green: 0.05, blue: 0.12, alpha: 1).setFill()
            cg.fill(CGRect(origin: .zero, size: size))
            // The glow of a screen hung over the lane.
            let glow = CGGradient(colorsSpace: nil, colors: [UIColor(red: 0.16, green: 0.25, blue: 0.62, alpha: 1).cgColor,
                                                              UIColor(red: 0.04, green: 0.05, blue: 0.12, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
            cg.drawRadialGradient(glow, startCenter: CGPoint(x: 600, y: 380), startRadius: 0, endCenter: CGPoint(x: 600, y: 380), endRadius: 720, options: [])
            func write(_ text: String, at point: CGPoint, size: CGFloat, weight: UIFont.Weight, color: UIColor, width: CGFloat? = nil) {
                let style = NSMutableParagraphStyle()
                style.alignment = width == nil ? .left : .center
                let string = NSAttributedString(string: text, attributes: [.font: UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight),
                                                                             .foregroundColor: color, .paragraphStyle: style])
                if let width { string.draw(in: CGRect(x: point.x, y: point.y, width: width, height: size * 1.4)) } else { string.draw(at: point) }
            }
            let gold = UIColor(red: 1, green: 0.78, blue: 0.25, alpha: 1)
            write("LANE 12", at: CGPoint(x: 70, y: 56), size: 64, weight: .heavy, color: gold)
            write("SAT 8:42 PM", at: CGPoint(x: 800, y: 76), size: 40, weight: .semibold, color: .white.withAlphaComponent(0.7))
            let rows: [(String, [String], [String], String)] = [
                ("ALEX", ["X", "9/", "X", "X", "81", "X", "7/", "X", "9-", "XX8"], ["20", "40", "68", "87", "96", "116", "136", "155", "164", "187"], "187"),
                ("DANA", ["72", "X", "9/", "63", "X", "8/", "71", "X", "9/", "X81"], ["9", "29", "45", "54", "74", "91", "99", "119", "139", "158"], "158"),
            ]
            for (r, row) in rows.enumerated() {
                let top = 210 + CGFloat(r) * 270
                write(row.0, at: CGPoint(x: 70, y: top - 62), size: 46, weight: .bold, color: .white)
                write(row.3, at: CGPoint(x: 930, y: top - 74), size: 64, weight: .heavy, color: r == 0 ? gold : .white, width: 200)
                for frame in 0 ..< 10 {
                    let box = CGRect(x: 70 + CGFloat(frame) * 106, y: top, width: 100, height: 150)
                    UIColor.white.withAlphaComponent(0.08).setFill()
                    UIBezierPath(roundedRect: box, cornerRadius: 10).fill()
                    UIColor.white.withAlphaComponent(0.35).setStroke()
                    let edge = UIBezierPath(roundedRect: box, cornerRadius: 10)
                    edge.lineWidth = 2
                    edge.stroke()
                    write(row.1[frame], at: CGPoint(x: box.minX, y: box.minY + 14), size: 34, weight: .semibold, color: .white.withAlphaComponent(0.85), width: 100)
                    write(row.2[frame], at: CGPoint(x: box.minX, y: box.minY + 78), size: 40, weight: .bold, color: r == 0 ? gold : .white, width: 100)
                }
            }
        }
        return Attachment.image(image, filename: "scoreboard.jpg")
    }

    /// Measuring aid (`-echo.demoHeavy [turns]`, 32 by default): a thread of long replies, about
    /// ten thousand characters each, like a long session with a model that writes at length.
    func seedHeavyDemo(turns: Int) {
        cancel()
        let section = """
        ## Sequencing the work

        The countertop crew can't template until the cabinets are set, so everything hangs on that \
        delivery. The supplier confirmed the **18th**, two days ahead of the date, which leaves room \
        for one slip but not two. If the truck is late, the template moves to the following week \
        and the install with it.

        - Demo comes first, with the plumber capping the lines the same afternoon
        - Rough-in for the island and the under-cabinet lights follows
        - Nothing closes up until the inspection passes
        - Drywall and paint go in while the room is empty

        ```bash
        hermes remind --at 16:00 "confirm the cabinet delivery window"
        ```

        After that the cabinets go in and get levelled, and only then is there something to \
        measure against. Stone takes about ten days from template to install.


        """
        let reply = String(repeating: section, count: 12)   // ≈ 10,000 characters
        var all: [Message] = []
        for turn in 1 ... max(1, turns) {
            all.append(Message(role: .user, text: "Turn \(turn): walk me through the sequence again, in full."))
            all.append(Message(role: .assistant, text: reply))
        }
        replaceForDemo(messages: all)
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

    /// Dev hook (`-echo.demoTodos`): two replies in which the agent keeps a task list, written the
    /// way a transcript holds it: the first call names the whole list, the next ones only what
    /// changed, and the checklist is read back out of those steps.
    func seedTodoDemo() {
        cancel()
        var first = Message(role: .assistant, text: "I'll move the blog in five steps. The export is done and the import is running now.")
        first.tools = [
            ToolActivity(name: "todo_list", preview: "5 tasks", status: .completed, args: """
            merge: false
            todos: [{"id":"1","content":"Export the posts from the old site","status":"in_progress"},{"id":"2","content":"Import them into the new one","status":"pending"},{"id":"3","content":"Fix the image links","status":"pending"},{"id":"3a","content":"Cover images","status":"pending","parent":"3"},{"id":"3b","content":"Inline images","status":"pending","parent":"3"},{"id":"4","content":"Redirect the old addresses","status":"pending"},{"id":"5","content":"Check the feed in a reader","status":"pending"}]
            """),
            ToolActivity(name: "terminal", preview: "wp export --dir=./export", status: .completed, args: "command: wp export --dir=./export", output: "Success: 214 posts exported."),
            ToolActivity(name: "todo_list", preview: "2 updates", status: .completed, args: """
            merge: true
            todos: [{"id":"1","status":"completed"},{"id":"2","status":"in_progress"}]
            """),
        ]
        var second = Message(role: .assistant, text: "Imported, and the cover images are fixed. The old site has no redirect plugin, so I've dropped that step; say if you want redirects done at the server instead.")
        second.tools = [
            ToolActivity(name: "todo_list", preview: "4 updates", status: .completed, args: """
            merge: true
            todos: [{"id":"2","status":"completed"},{"id":"3","status":"in_progress"},{"id":"3a","status":"completed"},{"id":"4","status":"cancelled"}]
            """),
        ]
        replaceForDemo(messages: [Message(role: .user, text: "Move the blog to the new site."), first,
                                  Message(role: .user, text: "Carry on."), second])
    }

    /// Dev hook (`-echo.demoBots`): a chat with a bot, Quill, for the Bots screenshots.
    func seedBotDemo() {
        cancel()
        // One id, so seeding again replaces the saved copy rather than adding one.
        replaceForDemo(id: UUID(uuidString: "DE300000-0000-4000-8000-000000000002")!, serverSessionID: "demo-bot-writer", messages: [
            Message(role: .user, text: "Can you tighten the opening of the hike post?"),
            Message(role: .assistant, text: """
                Here's a tighter opening:

                > We left the car at six, before the fog had made up its mind.

                It drops the weather report and starts on the trail. Want me to carry that through the next paragraph?
                """),
        ] + (DevHooks.demoMarks ? Self.botExchangeDemo : []), bot: BotRef(profile: "writer", name: "Quill"))
    }

    /// With `-echo.demoMarks`: Scout messages Quill, Quill asks Scout back, and Scout's reply
    /// comes in, for the screenshots of bots talking.
    private static var botExchangeDemo: [Message] {
        var asked = Message(role: .user, text: "Dana wants the post to mention Lost Lake. Can you work it into the second paragraph?")
        asked.delivered = Delivered(kind: .message, profile: "scout", name: "Scout")
        var reply = Message(role: .assistant, text: "Happy to. I've asked Scout which trailhead it starts from, so the line is right.")
        reply.tools = [ToolActivity(name: "message_agent", preview: "@scout", status: .completed, args: "message: Which trailhead for Lost Lake?\ntarget: scout")]
        var answer = Message(role: .user, text: "From the Gold Creek trailhead: 4.2 miles, about 1,100 ft of climbing.")
        answer.delivered = Delivered(kind: .reply, profile: "scout", name: "Scout")
        var done = Message(role: .assistant, text: "Added: *By noon we'd reached Lost Lake, 4.2 miles up from Gold Creek.*")
        done.tools = []
        var notice = Message(role: .user, text: "built in 3.1 s")
        notice.delivered = Delivered(kind: .process, title: "Background task finished: npm run build")
        return [asked, reply, answer, done, notice]
    }

    /// Dev hook (`-echo.demoPhoneShot`): the agent having used the phone four times, short, for
    /// the Phone tools store screenshot: the day from the calendar, a timer, the widget, a
    /// message. Short so the screenshot's insets (the timer on the Lock Screen, the widget) sit
    /// below it.
    func seedPhoneShotDemo() {
        cancel()
        func answer(_ text: String, _ tools: [(String, String)]) -> Message {
            var reply = Message(role: .assistant, text: text)
            reply.tools = tools.map { ToolActivity(name: $0.0, preview: $0.1, status: .completed) }
            return reply
        }
        replaceForDemo(messages: [
            Message(role: .user, text: "Morning! What's on today?"),
            answer("Morning ☀️ Standup at 9:30, lunch with Dana at 12:15, and pasta night at 7 🍝", [("phone_calendar_events", "today")]),
            Message(role: .user, text: "Pasta's in! Nine minute timer?"),
            answer("Timer's on: **9 minutes**. It's on your Lock Screen ⏰", [("phone_alarms_set", "Pasta, 9 minutes")]),
            Message(role: .user, text: "Stick my shopping list on my widget."),
            answer("Done 🛒 Spaghetti, basil, parmesan and two lemons, right on your Home Screen.", [("phone_files_read", "Shopping list.md"), ("phone_widget_set", "Shopping list")]),
            Message(role: .user, text: "Text Dana I'm running ten minutes late."),
            answer("It's written and waiting in Messages 💬 Tap Send and Dana knows.", [("phone_people_message", "Dana Lee")]),
        ])
    }

    /// Dev hook (`-echo.demoPhotos [n]`): a reply with n photos, as the phone's photo tool hands
    /// them over one after another (five unless a number says otherwise), after a message that
    /// sent two and a reply with one, to look at the collage and the viewer. The pictures are
    /// drawn here: a colour each, its number large in the middle, in the shapes a camera makes,
    /// with fine lines to zoom into.
    func seedPhotoDemo(count: Int = 5) {
        reset()
        func picture(_ number: Int, set: String) -> Attachment {
            let shapes = [CGSize(width: 1600, height: 1200), CGSize(width: 1200, height: 1600), CGSize(width: 1600, height: 1600), CGSize(width: 1600, height: 900)]
            let size = shapes[(number - 1) % shapes.count]
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let jpeg = UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.8) { context in
                let hue = CGFloat((number * 67) % 360) / 360
                UIColor(hue: hue, saturation: 0.55, brightness: 0.62, alpha: 1).setFill()
                context.fill(CGRect(origin: .zero, size: size))
                UIColor.white.withAlphaComponent(0.18).setStroke()
                for x in stride(from: CGFloat(0), through: size.width, by: 40) {
                    let line = UIBezierPath(); line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height)); line.stroke()
                }
                for y in stride(from: CGFloat(0), through: size.height, by: 40) {
                    let line = UIBezierPath(); line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: size.width, y: y)); line.stroke()
                }
                let words = NSAttributedString(string: "\(number)", attributes: [
                    .font: UIFont.systemFont(ofSize: size.height * 0.5, weight: .bold), .foregroundColor: UIColor.white,
                ])
                let room = words.size()
                words.draw(at: CGPoint(x: (size.width - room.width) / 2, y: (size.height - room.height) / 2))
            }
            return Attachment(kind: .image, filename: "\(set)-\(number).jpg", mimeType: "image/jpeg", data: jpeg)
        }
        var sent = Message(role: .user, text: "Which of these two is sharper?")
        sent.attachments = [picture(1, set: "sent"), picture(2, set: "sent")]
        var one = Message(role: .assistant, text: "The second. Here it is again.")
        one.attachments = [picture(2, set: "again")]
        var reply = Message(role: .assistant, text: "Here are the \(count) most recent photos from your library.")
        reply.attachments = (1 ... max(count, 1)).map { picture($0, set: "photo") }
        replaceForDemo(messages: [sent, one, Message(role: .user, text: "Show me my latest photos."), reply])
    }

    /// Dev hook (`-echo.demoAudio`): a reply that came with a sound file, as the agent's speech
    /// tool delivers one, to look at the player and to press it. The sound is a tone made here:
    /// four seconds, rising.
    func seedAudioDemo() {
        // A new conversation first, not only a stop: the one saved last may still be coming off
        // the disk, or be there already with a message it is trying to send, and either can take
        // the screen back.
        reset()
        let rate = 16000, seconds = 4
        var wav = Data()
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        let count = rate * seconds
        wav.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + count * 2)); wav.append(contentsOf: Array("WAVEfmt ".utf8))
        put(UInt32(16)); put(UInt16(1)); put(UInt16(1)); put(UInt32(rate)); put(UInt32(rate * 2)); put(UInt16(2)); put(UInt16(16))
        wav.append(contentsOf: Array("data".utf8)); put(UInt32(count * 2))
        var phase = 0.0
        for i in 0 ..< count {
            let t = Double(i) / Double(rate)
            phase += 2 * .pi * (330 + 55 * t) / Double(rate)
            put(Int16(sin(phase) * 6000 * min(1, t * 8, (Double(seconds) - t) * 8)))
        }
        var reply = Message(role: .assistant, text: "Here is this morning's summary, read aloud. It runs to about a minute.")
        reply.attachments = [Attachment(kind: .other, filename: "summary.wav", mimeType: "audio/wav", data: wav)]
        replaceForDemo(messages: [Message(role: .user, text: "Read me this morning's summary."), reply])
    }

    /// Dev hook (`-echo.demoDocument`): a reply that came with a Markdown file, as an agent's
    /// `MEDIA:` delivery arrives, to open in QuickLook; then one that names its files by path.
    func seedDocumentDemo() {
        reset()
        let markdown = "# Morning briefing\n\n- Three posts worth reading\n- Dry until three, then rain\n"
        // And one named that isn't here: with no Dashboard login it can't be fetched.
        var reply = Message(role: .assistant, text: "Here is this morning's briefing as a file.\nMEDIA:/home/hermes/briefings/week-ahead.md")
        reply.attachments = [Attachment(kind: .text, filename: "briefing.md", mimeType: "text/markdown", data: Data(markdown.utf8))]
        // And files named only in passing: each path opens its file.
        let samples = Message(role: .assistant, text: "I made two voice samples and left them at `/home/hermes/voices/af heart.wav` and /home/hermes/voices/bm_lewis.wav.")
        replaceForDemo(messages: [Message(role: .user, text: "Send me this morning's briefing as a file."), reply,
                                  Message(role: .user, text: "And a couple of voice samples?"), samples])
    }

    /// `-echo.demoPage`: a reply with a page the agent made (`::preview`), drawn by its own script,
    /// with buttons that send the agent a message.
    func seedPageDemo() {
        reset()
        let html = """
        <!doctype html>
        <html><head><style>
          .card { display: inline-block; padding: 12px 14px; border: 1px solid var(--border); border-radius: 12px; background: var(--card); }
          h3 { margin: 0 0 2px; font-size: 15px; }
          p { margin: 0 0 10px; color: var(--muted-foreground); font-size: 13px; }
          .bars { display: flex; align-items: flex-end; gap: 6px; height: 72px; margin-bottom: 10px; }
          .bar { width: 22px; border-radius: 4px 4px 0 0; background: var(--accent); }
          button { font: inherit; font-size: 13px; padding: 6px 10px; margin-right: 6px; border-radius: 8px;
                   border: 1px solid var(--border); background: transparent; color: var(--foreground); }
        </style></head><body>
        <div class="card">
          <h3>Rain this week, Lisbon</h3>
          <p id="note">Millimetres a day</p>
          <div class="bars" id="bars"></div>
          <button data-hermes-send="Show Porto instead">Porto</button><button data-hermes-send="Show Faro instead">Faro</button>
        </div>
        <script>
          [2, 0, 5, 9, 3, 0, 1].forEach(function (mm) {
            var b = document.createElement('div'); b.className = 'bar'; b.style.height = (8 + mm * 7) + 'px';
            document.getElementById('bars').appendChild(b);
          });
          document.getElementById('note').textContent = 'Millimetres a day, drawn by the page';
        </script>
        </body></html>
        """
        var reply = Message(role: .assistant, text: "Here's the week's rain. Tap a city to see it there.")
        reply.attachments = [AgentPage.attachment(Attachment(kind: .text, filename: "rain.html", mimeType: "text/html", data: Data(html.utf8)),
                                                  from: "/home/hermes/pages/rain.html")]
        replaceForDemo(messages: [Message(role: .user, text: "Show me how much rain is coming this week."), reply])
    }

    /// Screenshot helper (`-echo.demoLibrary`): a few local conversations so the list isn't empty.
    /// `savedFrom`: as this iPhone's copies of conversations on that Hermes server instead
    /// (`-echo.demoSaved`), which is what the list falls back to when the server can't be reached.
    func seedDemoLibrary(savedFrom server: UUID? = nil) {
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
                                            transport: server == nil ? .chatCompletions : .hermesSessions,
                                            serverSessionID: server == nil ? nil : "demo_\(abs(q.hashValue))",
                                            messages: [Message(role: .user, text: q, createdAt: when), reply], serverID: server))
        }
    }
}
#endif
