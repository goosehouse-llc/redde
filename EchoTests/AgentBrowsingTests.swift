import Foundation
import Testing
@testable import Echo

/// Watching the agent work: a reply's browser steps read from its tool steps as each connection
/// keeps them, the terminal's tail, and Bot Screen's model (tickets, the lease, close codes).
@MainActor
struct AgentBrowsingTests {
    private func json(_ text: String) -> JSONValue { try! JSONValue.parse(Data(text.utf8)) }

    /// A step as the Dashboard's `tool.start` / `tool.complete` leave it (`HermesServeTransport`).
    private func dashboardStep(_ name: String, args: String, result: String, status: ToolActivity.Status = .completed) -> ToolActivity {
        ToolActivity(name: name, preview: nil, status: status, args: ToolActivity.args(name, json(args)),
                     output: status == .running ? nil : ToolActivity.detail(json(result)))
    }

    /// The Hermes API's `tool.started` / `tool.completed`: the arguments, never the result.
    private func apiStep(_ name: String, args: String) -> ToolActivity {
        ToolActivity(name: name, preview: nil, status: .completed, args: ToolActivity.args(name, json(args)))
    }

    @Test func aPageOpenedOnTheDashboardHasItsAddressAndTitle() {
        let tools = [dashboardStep("browser_navigate", args: #"{"url": "https://example.com"}"#,
                                   result: #"{"success": true, "url": "https://www.example.com/home", "title": "Example Domain"}"#)]
        let steps = AgentBrowsing.steps(tools)
        #expect(steps.count == 1)
        #expect(steps[0].kind == .open)
        #expect(steps[0].url == "https://www.example.com/home", "where it ended up, not where it was sent")
        #expect(steps[0].title == "Example Domain")
        #expect(AgentBrowsing.currentPage(steps)?.title == "Example Domain")
    }

    @Test func onTheHermesAPIThePageIsWhereItWasSent() {
        let steps = AgentBrowsing.steps([apiStep("browser_navigate", args: #"{"url": "https://news.ycombinator.com"}"#)])
        #expect(steps.first?.url == "https://news.ycombinator.com")
        #expect(steps.first?.title == nil)
        #expect(AgentBrowsing.shortURL(steps[0].url!) == "news.ycombinator.com")
    }

    @Test func otherToolsAreNotBrowsing() {
        let tools = [ToolActivity(name: "terminal", preview: "ls", status: .completed, args: "command: ls"),
                     ToolActivity(name: "web_search", preview: nil, status: .completed, args: "query: url: https://x")]
        #expect(AgentBrowsing.steps(tools).isEmpty)
    }

    @Test func screenshotsComeFromVisionAndTheScreen() {
        let tools = [
            dashboardStep("browser_vision", args: #"{"question": "Is there a login form?"}"#,
                          result: #"{"success": true, "analysis": "Yes, a sign-in form.", "screenshot_path": "/home/h/.hermes/cache/screenshots/browser_screenshot_ab12.png"}"#),
            dashboardStep("computer_use", args: #"{"action": "capture"}"#,
                          result: #"{"ok": true, "screenshot_path": "/home/h/.hermes/cache/screens/cap_1.png", "elements_file": "/tmp/e.json"}"#),
        ]
        let steps = AgentBrowsing.steps(tools)
        #expect(steps.map(\.kind) == [.look, .screen])
        #expect(steps[0].note == "Is there a login form?")
        #expect(AgentBrowsing.latestScreenshot(steps) == "/home/h/.hermes/cache/screens/cap_1.png")
    }

    @Test func whatWasTypedIsNeverKept() {
        let step = AgentBrowsing.steps([dashboardStep("browser_type", args: #"{"ref": "@e9", "text": "hunter2"}"#, result: #"{"success": true}"#)])[0]
        #expect(step.kind == .type)
        #expect(step.note == nil)
        #expect(!AgentBrowsing.label(step).contains("hunter2"))
    }

    @Test func pagesAreCountedOnceEach() {
        let tools = [
            apiStep("browser_navigate", args: #"{"url": "https://a.example"}"#),
            apiStep("browser_click", args: #"{"ref": "@e1"}"#),
            apiStep("browser_navigate", args: #"{"url": "https://b.example"}"#),
            apiStep("browser_navigate", args: #"{"url": "https://a.example"}"#),
        ]
        let steps = AgentBrowsing.steps(tools)
        #expect(AgentBrowsing.pages(steps) == ["https://a.example", "https://b.example"])
        #expect(AgentBrowsing.summary(steps).contains("2"))
    }

    @Test func aMultiLineFieldIsLeftOutAndALongSnapshotDoesntHideTheURL() {
        let fields = AgentBrowsing.fields(in: "snapshot:\n- heading \"Hi\"\n- link: \"x\"\ntitle: Shop\nurl: https://shop.example/cart")
        #expect(fields["title"] == "Shop")
        #expect(fields["url"] == "https://shop.example/cart")
        #expect(fields["snapshot"] == nil)
    }

    @Test func aStepRunningHasNoResultYet() {
        let tools = [dashboardStep("browser_navigate", args: #"{"url": "https://slow.example"}"#, result: "{}", status: .running)]
        let step = AgentBrowsing.steps(tools)[0]
        #expect(step.status == .running)
        #expect(step.url == "https://slow.example")
    }

    // MARK: The terminal

    @Test func theTerminalKeepsTheLastLinesWithoutColour() {
        var tail = TerminalTail()
        tail.append("\u{1B}[32mok\u{1B}[0m one\ntwo\npart")
        #expect(tail.shown == ["ok one", "two", "part"])
        tail.append("ial\n")
        #expect(tail.shown == ["ok one", "two", "partial"])
        for i in 0 ..< 60 { tail.append("line \(i)\n") }
        #expect(tail.lines.count == TerminalTail.keep)
        #expect(tail.lines.last == "line 59")
    }

    @Test func aProgressBarRewritesItsLine() {
        var tail = TerminalTail()
        tail.append("download 10%\rdownload 50%\rdownload 100%\n")
        #expect(tail.shown == ["download 100%"])
    }

    // MARK: Bot Screen

    @Test func theStreamAddressCarriesTheTicketOnly() {
        let url = BotScreen.socketURL(baseURL: URL(string: "https://hermes.example.ts.net:9119")!, path: "/api/display/ws", ticket: "t-1+2")
        #expect(url?.scheme == "wss")
        #expect(url?.path == "/api/display/ws")
        #expect(URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "display_ticket", value: "t-1+2")])
        let plain = BotScreen.socketURL(baseURL: URL(string: "http://127.0.0.1:19119/")!, path: "api/display/ws", ticket: "x")
        #expect(plain?.absoluteString == "ws://127.0.0.1:19119/api/display/ws?display_ticket=x")
    }

    @Test func theViewerHashIsTheFirstTwelveHexOfSHA256() {
        // sha256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
        #expect(BotScreen.viewerHash("abc") == "ba7816bf8f01")
    }

    @Test func whoDrivesFollowsTheLease() {
        let mine = BotScreen.viewerHash("viewer-1")
        #expect(BotScreen.control(BotScreen.Lease(), viewerHash: mine) == .agent)
        #expect(BotScreen.control(BotScreen.Lease(holder: "human", viewerHash: mine), viewerHash: mine) == .you)
        #expect(BotScreen.control(BotScreen.Lease(holder: "human", viewerHash: "000000000000"), viewerHash: mine) == .someoneElse)
        #expect(BotScreen.control(BotScreen.Lease(holder: "human", viewerHash: mine), viewerHash: nil) == .someoneElse)
    }

    @Test func statusSaysWhyThereIsNoScreen() {
        let mac = BotScreen.Status(json(#"{"profile": "default", "supported": false, "installed": false, "missing": ["Xvnc"], "running": false, "geometry": "1280x800", "lease": {"holder": "agent", "epoch": 0}}"#))
        #expect(BotScreen.availability(mac) == .notLinux)
        let bare = BotScreen.Status(json(#"{"supported": true, "installed": false, "missing": ["Xvnc", "xfce4-session"], "install_command": "apt-get install -y tigervnc-standalone-server xfce4"}"#))
        #expect(BotScreen.availability(bare) == .notInstalled(missing: ["Xvnc", "xfce4-session"], command: "apt-get install -y tigervnc-standalone-server xfce4"))
        let stopped = BotScreen.Status(json(#"{"supported": true, "installed": true, "running": false}"#))
        #expect(BotScreen.availability(stopped) == .stopped(stopped))
        let low = BotScreen.Status(json(#"{"supported": true, "installed": true, "running": false, "blocker": "only 300 MB free"}"#))
        #expect(BotScreen.availability(low) == .blocked("only 300 MB free"))
        let up = BotScreen.Status(json(#"{"supported": true, "installed": true, "running": true, "profile_key": "/home/h/.hermes", "lease": {"holder": "human", "viewer_hash": "abcdefabcdef", "epoch": 4}}"#))
        #expect(BotScreen.availability(up) == .ready(up))
        #expect(up.lease.humanHolds && up.lease.epoch == 4)
        #expect(BotScreen.Availability.notLinux.explanation?.isEmpty == false)
        #expect(BotScreen.Availability.notDashboard.explanation?.isEmpty == false)
    }

    @Test func closeCodesSayWhatHappened() {
        #expect(BotScreen.Ended(code: 4000) == .controlTaken)
        #expect(BotScreen.Ended(code: 4001) == .screenGone)
        #expect(BotScreen.Ended(code: 4401) == .badTicket)
        #expect(BotScreen.Ended(code: 4403) == .refused)
        #expect(BotScreen.Ended(code: 1000) == .closed)
        #expect(BotScreen.Ended(code: 1006) == .dropped)
    }

    @Test func aCostlyLinkGetsTheSmallPicture() {
        #expect(BotScreen.quality(expensive: true).quality < BotScreen.quality(expensive: false).quality)
    }

    @Test func anOlderHermesHasNoDisplayMethods() {
        #expect(BotScreen.isMissingMethod(HermesServeClient.RPCError(code: -32601, message: "Method not found")))
        #expect(!BotScreen.isMissingMethod(HermesServeClient.RPCError(code: 5300, message: "not running")))
    }

    // MARK: The session against a stand-in Dashboard

    @Test func takingOverAndHandingBackGoThroughTheLease() async throws {
        let host = FakeScreenHost()
        let session = BotScreenSession(profile: "ops", host: host, isDashboard: true)
        await session.open()
        #expect(session.availability.status?.running == true)
        #expect(host.calls.first?.method == "display.status")
        #expect(host.calls.first?.params["profile"]?.string == "ops", "every call names the bot's profile")

        let (ticket, path) = try await session.observe()
        #expect(ticket == "tk-1" && path == "/api/display/ws")
        #expect(session.control == .agent)

        await session.takeOver()
        let acquire = try #require(host.calls.last)
        #expect(acquire.method == "display.lease.acquire")
        #expect(acquire.params["viewer_id"]?.string == "viewer-xyz")
        #expect(session.control == .you)

        // Someone else takes over (Hermes Desktop): the lease event says so.
        host.emit(("display.lease", nil, json(#"{"profile_key": "/srv/hermes/profiles/ops", "lease": {"holder": "human", "viewer_hash": "999999999999", "epoch": 3}}"#)))
        #expect(session.control == .someoneElse)
        #expect(session.notice != nil)

        await session.takeOver()
        await session.handBack()
        #expect(host.calls.last?.method == "display.lease.release")
        #expect(session.control == .agent)
        #expect(session.handedBack)

        // A reconnect presents the id this connection was given.
        _ = try await session.observe()
        #expect(host.calls.last?.params["viewer_id"]?.string == "viewer-xyz")
        session.close()
        #expect(host.listeners.isEmpty)
    }

    @Test func anotherProfilesLeaseIsntOurs() async {
        let host = FakeScreenHost()
        let session = BotScreenSession(profile: "ops", host: host, isDashboard: true)
        await session.open()
        host.emit(("display.lease", nil, json(#"{"profile_key": "/srv/hermes", "lease": {"holder": "human", "viewer_hash": "999999999999", "epoch": 9}}"#)))
        #expect(session.lease.epoch == 0)
    }

    @Test func anOlderHermesSaysSo() async {
        let host = FakeScreenHost()
        host.missing = true
        let session = BotScreenSession(profile: nil, host: host, isDashboard: true)
        await session.open()
        #expect(session.availability == .olderHermes)
    }

    @Test func theHermesAPIHasNoScreen() async {
        let session = BotScreenSession(profile: nil, host: nil, isDashboard: false)
        await session.open()
        #expect(session.availability == .notDashboard)
    }

    @Test func aWithheldThumbnailIsSaidAndAStillIsKept() async {
        let host = FakeScreenHost()
        let session = BotScreenSession(profile: "ops", host: host, isDashboard: true)
        await session.open()
        await session.refreshThumbnail()
        #expect(session.thumbnail == Data([0xFF, 0xD8, 0xFF]))
        host.withhold = true
        await session.refreshThumbnail()
        #expect(session.thumbnailWithheld)
        #expect(session.thumbnail != nil, "the last still stays")
    }
}

/// A stand-in Dashboard answering `display.*` as Hermes 0.22 does.
@MainActor
private final class FakeScreenHost: BotScreenHost {
    var calls: [(method: String, params: JSONValue)] = []
    var listeners: [UUID: (HermesServeClient.Event) -> Void] = [:]
    var missing = false
    var withhold = false
    private var lease = #"{"holder": "agent", "viewer_hash": null, "epoch": 0, "reason": ""}"#

    private func json(_ text: String) -> JSONValue { try! JSONValue.parse(Data(text.utf8)) }

    private var status: String {
        #"{"profile": "ops", "profile_key": "/srv/hermes/profiles/ops", "supported": true, "installed": true, "missing": [], "running": true, "geometry": "1280x800", "lease": \#(lease)}"#
    }

    func call(_ method: String, params: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        calls.append((method, params))
        if missing { throw HermesServeClient.RPCError(code: -32601, message: "Method not found") }
        switch method {
        case "display.status": return json(status)
        case "display.observe":
            let body = String(status.dropLast()) + #", "ticket": "tk-1", "path": "/api/display/ws", "viewer_id": "viewer-xyz"}"#
            return json(body)
        case "display.thumbnail":
            return withhold ? json(#"{"data_url": null, "suppressed": "human_has_control"}"#)
                            : json(#"{"data_url": "data:image/jpeg;base64,/9j/"}"#)
        case "display.lease.acquire":
            lease = #"{"holder": "human", "viewer_hash": "\#(BotScreen.viewerHash(params["viewer_id"]?.string ?? ""))", "epoch": 2, "reason": "x"}"#
            return json(#"{"lease": \#(lease)}"#)
        case "display.lease.release":
            lease = #"{"holder": "agent", "viewer_hash": null, "epoch": 5, "reason": ""}"#
            return json(#"{"lease": \#(lease)}"#)
        default:
            throw HermesServeClient.RPCError(code: -32601, message: "Method not found")
        }
    }

    func addListener(_ listener: @escaping (HermesServeClient.Event) -> Void) -> UUID {
        let id = UUID()
        listeners[id] = listener
        return id
    }

    func removeListener(_ id: UUID) { listeners[id] = nil }

    func ensureConnected() async throws {}

    func emit(_ event: HermesServeClient.Event) { for l in listeners.values { l(event) } }
}
