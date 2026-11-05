#if DEBUG
import SwiftUI

/// Dev hooks for watching the agent work (screenshots): `-echo.demoBrowsing` seeds a chat whose
/// agent browsed and is browsing; `-echo.demoBotScreen` gives the Agent's Screen a made-up desktop.
extension Conversation {
    func seedBrowsingDemo() {
        reset()
        let start = Date.now.addingTimeInterval(-40)
        func step(_ name: String, _ args: String?, _ output: String?, _ status: ToolActivity.Status = .completed, at: Double) -> ToolActivity {
            ToolActivity(name: name, preview: nil, status: status, startedAt: start.addingTimeInterval(at),
                         endedAt: status == .running ? nil : start.addingTimeInterval(at + 2), args: args, output: output)
        }
        var first = Message(role: .assistant, text: "The Oceanário is open 10 AM to 7 PM every day, last entry at 6. Tickets are €25 for adults; Saturday still has morning slots.")
        first.tools = [
            step("browser_navigate", "url: https://www.oceanario.pt", "success: true\ntitle: Oceanário de Lisboa\nurl: https://www.oceanario.pt/en", at: 0),
            step("browser_snapshot", nil, "snapshot: …", at: 3),
            step("browser_click", "ref: @e14", "success: true", at: 6),
            step("browser_navigate", "url: https://www.oceanario.pt/en/plan-your-visit/hours", "success: true\ntitle: Opening hours\nurl: https://www.oceanario.pt/en/plan-your-visit/hours", at: 9),
            step("browser_navigate", "url: https://tickets.oceanario.pt", "success: true\ntitle: Tickets · Oceanário\nurl: https://tickets.oceanario.pt/en", at: 13),
        ]
        var second = Message(role: .assistant, text: "")
        second.tools = [
            step("browser_navigate", "url: https://tickets.oceanario.pt/en/saturday", "success: true\ntitle: Saturday · Choose a time\nurl: https://tickets.oceanario.pt/en/saturday", at: 20),
            step("browser_click", "ref: @e7", "success: true", at: 24),
            step("browser_type", "ref: @e9\ntext: (hidden)", nil, .running, at: 27),
        ]
        replaceForDemo(messages: [
            Message(role: .user, text: "When is the Oceanário open, and how much are tickets?"),
            first,
            Message(role: .user, text: "Book two for Saturday at 10."),
            second,
        ])
        setStreamingForDemo(true)
        AgentTerminalWatch.demoTail = {
            var tail = TerminalTail()
            tail.append("$ npm run build\n> tickets@1.0.0 build\nvite v6.2.1 building for production...\n✓ 214 modules transformed.\ndist/index.html  0.46 kB\n")
            return tail
        }()
    }
}

enum BotScreenDemo {
    /// A made-up Bot Desktop: Xfce's panel and a browser on the ticket page.
    @MainActor
    static func thumbnail() -> Data? {
        let view = ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.16, green: 0.22, blue: 0.33), Color(red: 0.09, green: 0.12, blue: 0.2)], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 0) {
                HStack {
                    Text("Applications").font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text("Sat 10:02").font(.system(size: 11))
                }
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 10).frame(height: 22)
                .background(Color.black.opacity(0.55))
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Circle().fill(.red).frame(width: 9); Circle().fill(.yellow).frame(width: 9); Circle().fill(.green).frame(width: 9)
                        Text("tickets.oceanario.pt/en/saturday").font(.system(size: 11)).foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 3).background(Color(white: 0.93), in: .capsule)
                        Spacer()
                    }
                    .padding(8).background(Color(white: 0.97))
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Saturday · Choose a time").font(.system(size: 22, weight: .bold)).foregroundStyle(.black)
                        HStack(spacing: 10) {
                            ForEach(["10:00", "10:30", "11:00", "11:30"], id: \.self) { slot in
                                Text(slot).font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(slot == "10:00" ? .white : .black)
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(slot == "10:00" ? Color.blue : Color(white: 0.9), in: .rect(cornerRadius: 8))
                            }
                        }
                        Text("Adults").font(.system(size: 13)).foregroundStyle(.gray)
                        Text("2").font(.system(size: 16, weight: .semibold)).foregroundStyle(.black)
                            .frame(width: 60, height: 32).background(Color(white: 0.95), in: .rect(cornerRadius: 6))
                        Text("Email for the tickets").font(.system(size: 13)).foregroundStyle(.gray)
                        RoundedRectangle(cornerRadius: 6).stroke(Color.blue, lineWidth: 2).frame(width: 320, height: 32)
                        Spacer()
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(.white)
                }
                .clipShape(.rect(cornerRadius: 8))
                .padding(40)
            }
        }
        .frame(width: 960, height: 600)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        #if canImport(UIKit)
        return renderer.uiImage?.jpegData(compressionQuality: 0.8)
        #else
        guard let cg = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [:])
        #endif
    }
}
#endif
