import Foundation
import Testing
@testable import Echo

// Replay contract tests: what each Hermes release answered to the routes the app parses, recorded
// from unmodified releases by `scripts/hermes-lab/lab.sh fixtures` (record_fixtures.py) and kept in
// EchoTests/Fixtures/Hermes/<release>/, fed to the app's own parsing for that route. They catch the
// app breaking against a Hermes that answers a little differently from the one it was built against
// (GitHub issues 70, 73, 78, 81), before a release, with no Hermes running. Each answer is also
// changed a little (a key left out, one added, a number sent as text where Hermes has done that),
// and the parsers must take every change without crashing and lose no more than the key they lost.

// MARK: - The fixtures

/// One recorded answer, as record_fixtures.py writes it.
nonisolated struct ReplayFixture {
    let name: String
    /// The whole record (Foundation's own objects, so a whole number stays one when written again).
    let record: [String: Any]

    var kind: String { record["kind"] as? String ?? "" }
    var status: Int? { record["status"] as? Int }
    var ok: Bool { (200 ..< 300).contains(status ?? 0) }
    /// What came back: the HTTP body, or the socket call's result.
    var payload: Any? {
        if kind == "ws" { return record["result"] }
        return record["body"]
    }
    var text: String? { record["text"] as? String }
    var error: JSONValue? { (record["error"]).flatMap(ReplayFixture.json) }
    var events: [JSONValue] { ((record["events"] as? [Any]) ?? []).compactMap(ReplayFixture.json) }
    var json: JSONValue? { payload.flatMap(ReplayFixture.json) }
    var data: Data { ReplayFixture.data(payload) }

    static func data(_ object: Any?) -> Data {
        guard let object, !(object is NSNull) else { return Data("null".utf8) }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])) ?? Data()
    }

    static func json(_ object: Any) -> JSONValue? { try? JSONValue.parse(data(object)) }
}

nonisolated enum Replay {
    private final class Marker {}

    /// The bundle's copy of EchoTests/Fixtures/Hermes (a folder reference, see project.yml).
    static let root: URL? = Bundle(for: Marker.self).url(forResource: "Hermes", withExtension: nil)

    /// Every release recorded, oldest first by how Hermes numbered them (2026.x was 0.21).
    static let versions: [String] = {
        guard let root, let names = try? FileManager.default.contentsOfDirectory(atPath: root.path()) else { return [] }
        return names.filter { $0.hasPrefix("v") }.sorted { order($0).lexicographicallyPrecedes(order($1)) }
    }()

    private static func order(_ tag: String) -> [Int] {
        let parts = tag.dropFirst().split(separator: ".").compactMap { Int($0) }
        return parts.first.map { $0 >= 2000 } == true ? [0, 21] + parts : parts
    }

    static func names(_ version: String) -> [String] {
        guard let root, let files = try? FileManager.default.contentsOfDirectory(atPath: root.appending(path: version).path()) else { return [] }
        return files.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }

    static func fixture(_ version: String, _ name: String) -> ReplayFixture? {
        guard let url = root?.appending(path: version).appending(path: "\(name).json"),
              let data = try? Data(contentsOf: url),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return ReplayFixture(name: name, record: record)
    }

    /// The Dashboard chat the recorder made and talked to: its stored id.
    static func storedChat(_ version: String, webapp: Bool = false) -> String? {
        let made = fixture(version, webapp ? "webapp.ws.session-create" : "ws.session-create")?.json
        return made?["stored_session_id"]?.string ?? made?["session_id"]?.string
    }

    /// The Hermes API chat the recorder made.
    static func apiChat(_ version: String) -> String? {
        fixture(version, "api.session-create")?.json?["session"]?["id"]?.string
    }

    static let said = "Hello from the replay recorder"
    /// What the lab's stub model answers (stub A, model alpha).
    static let answer = "[A:alpha]"
}

// MARK: - A Dashboard that answers from the fixtures

/// Answers the Dashboard client's REST calls from fixtures, by method and path. The sign-in probe
/// and the login itself are let through. Only HermesReplayTests uses it (its suite is serialized).
nonisolated final class ReplayStub: URLProtocol {
    nonisolated(unsafe) static var routes: [String: (Int, Data)] = [:]
    /// For a PATCH: the answer by whether the body is fenced (has a request id) or not.
    nonisolated(unsafe) static var patch: (fenced: (Int, Data), bare: (Int, Data))?
    nonisolated(unsafe) static var sent: [(String, Data?)] = []

    static func reset() { routes = [:]; patch = nil; sent = [] }

    static func serve(_ method: String, _ path: String, _ fixture: ReplayFixture?) {
        guard let fixture else { return }
        routes["\(method) \(path)"] = (fixture.status ?? 200, fixture.data)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open(); defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            return data
        }
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path() ?? ""
        Self.sent.append(("\(method) \(path)", body))
        let answer: (Int, Data)
        if method == "POST", path == "/auth/password-login" {
            answer = (200, Data("{}".utf8))
        } else if method == "PATCH", let patch = Self.patch {
            let fenced = body.flatMap { try? JSONValue.parse($0) }?["request_id"]?.string != nil
            answer = fenced ? patch.fenced : patch.bare
        } else if let routed = Self.routes["\(method) \(path)"] {
            answer = routed
        } else if method == "GET", path == "/api/sessions" {
            answer = (200, Data(#"{"sessions":[]}"#.utf8))   // the sign-in probe
        } else {
            answer = (404, Data(#"{"detail":"Not Found"}"#.utf8))
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.0, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.1)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - The tests

@MainActor
@Suite(.serialized)
struct HermesReplayTests {
    private func client() -> HermesServeClient {
        let settings = Settings(defaults: UserDefaults(suiteName: "replay-\(UUID().uuidString)")!)
        settings.serveURL = "http://replay.test:9119"
        settings.serveUsername = "lab"
        return HermesServeClient(settings: settings, password: { "labpass" }, tokens: HermesServeClientTests.TokenBox().store,
                                 protocolClasses: [ReplayStub.self])
    }

    private func fixture(_ version: String, _ name: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> ReplayFixture {
        try #require(Replay.fixture(version, name), "\(version) has no \(name).json", sourceLocation: sourceLocation)
    }

    @Test func everyReleaseIsRecorded() {
        #expect(Replay.versions.count >= 7, "fixtures in the bundle: \(Replay.versions)")
        for version in Replay.versions {
            #expect(Replay.names(version).count >= 60, "\(version): \(Replay.names(version).count) fixtures")
        }
    }

    // MARK: Dashboard REST

    /// Settings → Gateway and the connection test: the release's version, and that it asks for a login.
    @Test(arguments: Replay.versions)
    func theDashboardSaysItsVersion(_ version: String) throws {
        let status = try #require(try fixture(version, "rest.status").json)
        let gateway = GatewayStatus(status)
        #expect(!gateway.version.isEmpty && gateway.version.first?.isNumber == true, "\(version): version \(gateway.version)")
        #expect(version.hasPrefix("v2026") || version == "v" + gateway.version, "\(version) says it is \(gateway.version)")
        #expect(gateway.gatewayRunning, "\(version): the gateway runs beside the lab's Dashboard")
        #expect(status["auth_required"]?.bool == true, "\(version): the lab's Dashboard has a login")
        if let webapp = Replay.fixture(version, "webapp.rest.status")?.json {
            #expect(GatewayStatus(webapp).version == gateway.version)
        }
    }

    /// The chat list, through the app's own client.
    @Test(arguments: Replay.versions)
    func theChatListHasTheConversation(_ version: String) async throws {
        ReplayStub.reset(); defer { ReplayStub.reset() }
        let stored = try #require(Replay.storedChat(version))
        ReplayStub.serve("GET", "/api/sessions", try fixture(version, "rest.sessions"))
        let rows = try await client().listSessions()
        let row = try #require(rows.first { $0.id == stored }, "\(version): \(rows.map(\.id))")
        #expect(row.lastActiveDate != nil)
        #expect(row.hidden == false, "hidden comes as SQLite's 0")
        #expect(row.shownPreview?.contains(Replay.said) == true)

        ReplayStub.serve("GET", "/api/profiles/sessions", try fixture(version, "rest.profiles-sessions"))
        let everyProfile = try await client().allProfileSessions()
        #expect(everyProfile.contains { $0.id == stored && $0.profile == "default" }, "\(version): \(everyProfile.map(\.id))")

        if let webapp = Replay.fixture(version, "webapp.rest.sessions"), let chat = Replay.storedChat(version, webapp: true) {
            ReplayStub.serve("GET", "/api/sessions", webapp)
            #expect(try await client().listSessions().contains { $0.id == chat }, "\(version): the Webapp's own chat is listed")
        }
    }

    /// A conversation opened: its messages page, both turns, read as the app shows them.
    @Test(arguments: Replay.versions)
    func theTranscriptHasBothTurns(_ version: String) async throws {
        ReplayStub.reset(); defer { ReplayStub.reset() }
        for webapp in [false, true] {
            guard let page = Replay.fixture(version, webapp ? "webapp.rest.messages" : "rest.messages") else { continue }
            let stored = try #require(Replay.storedChat(version, webapp: webapp))
            ReplayStub.serve("GET", "/api/sessions/\(stored)/messages", page)
            let rows = try await client().transcript(stored: stored)
            #expect(rows.first?.role == "user" && rows.first?.content?.text == Replay.said, "\(version): \(rows.map(\.role))")
            #expect(rows.allSatisfy { $0.id != nil && $0.timestamp != nil }, "row ids are numbers on every release: read as text")
            let shown = await Conversation.readied(stored: rows)
            #expect(shown.first { $0.role == .user }?.text == Replay.said)
            #expect(shown.contains { $0.role == .assistant && $0.text.contains(Replay.answer) }, "\(version): \(shown.map(\.text))")
            if !webapp {
                #expect(shown.contains { $0.role == .user && $0.text == "lab:todo" }, "the second turn, with its tool")
            }
        }
    }

    /// The same conversation as a resume hands it over (the socket's rows, not the REST page).
    @Test(arguments: Replay.versions)
    func theResumeHasBothTurns(_ version: String) async throws {
        for name in ["ws.session-resume", "webapp.ws.session-resume"] {
            guard let resume = Replay.fixture(version, name)?.json else { continue }
            #expect(resume["session_id"]?.string != nil, "\(version) \(name): openSession needs the runtime id")
            let shown = await Conversation.readied(serveRows: resume["messages"]?.array ?? [])
            #expect(shown.first?.role == .user && shown.first?.text == Replay.said, "\(version) \(name): \(shown.map(\.text))")
            #expect(shown.contains { $0.role == .assistant && $0.text.contains(Replay.answer) })
            _ = TodoList.list(resume["todo_state"])
        }
    }

    /// Rename, pin, mark read (issues 52 and 70): the write goes fenced where the host has the
    /// snapshot route and bare where it doesn't, and the host takes it either way.
    @Test(arguments: Replay.versions)
    func aRenameIsTakenAsTheAppSendsIt(_ version: String) async throws {
        ReplayStub.reset(); defer { ReplayStub.reset() }
        let stored = try #require(Replay.storedChat(version))
        let snapshot = try fixture(version, "rest.mutation-snapshot")
        let fenced = try fixture(version, "rest.patch-rename"), bare = try fixture(version, "rest.patch-rename-bare")
        ReplayStub.serve("GET", "/api/sessions/\(stored)/mutation-snapshot", snapshot)
        ReplayStub.patch = ((fenced.status ?? 0, fenced.data), (bare.status ?? 0, bare.data))
        try await client().updateSession(stored: stored, title: "Replay rename")
        let sent = try #require(ReplayStub.sent.last { $0.0.hasPrefix("PATCH") }?.1.flatMap { try? JSONValue.parse($0) })
        #expect((sent["request_id"] != nil) == snapshot.ok, "\(version): fenced exactly where the snapshot route is (\(snapshot.status ?? 0))")
        // The contract the fallback rests on: a host that refuses the bare write has the route.
        if bare.status == 409 {
            #expect(snapshot.ok, "\(version) refuses a bare write but has no snapshot route")
            #expect(HermesServeClient.refusal(409, bare.data).errorDescription?.contains("client_upgrade_required") == true)
        }
        // A session the host doesn't have: 0.22.7 and later still answer the snapshot, with no
        // revision to speak of; earlier ones say 404. Neither may crash the write.
        let unknown = try fixture(version, "rest.error.unknown-mutation-snapshot")
        if unknown.ok { #expect(unknown.json?["exists"]?.bool == false) } else { #expect(unknown.status == 404) }
    }

    /// Profiles, skills, toolsets and the model list, through the app's client.
    @Test(arguments: Replay.versions)
    func profilesSkillsToolsetsAndModels(_ version: String) async throws {
        ReplayStub.reset(); defer { ReplayStub.reset() }
        ReplayStub.serve("GET", "/api/profiles", try fixture(version, "rest.profiles"))
        ReplayStub.serve("GET", "/api/skills", try fixture(version, "rest.skills"))
        ReplayStub.serve("GET", "/api/tools/toolsets", try fixture(version, "rest.toolsets"))
        let client = client()
        let profiles = try await client.profiles()
        #expect(profiles.first?.isDefault == true && profiles.first?.name == "default", "\(version): \(profiles.map(\.name))")
        #expect(profiles.first?.path.hasPrefix("<run>") == true, "the profile's home, as the profile list says it")
        let skills = try await client.dashboardSkills()
        #expect(skills.contains { $0.name == "lab-hello" }, "\(version): \(skills.count) skills")
        let toolsets = try await client.dashboardToolsets()
        #expect(toolsets.count > 5 && toolsets.contains { $0.name == "terminal" }, "\(version): \(toolsets.map(\.name))")

        for name in ["rest.model-options", "ws.model-options", "api.model-options"] {
            let models = HermesSessionsAPI.parseModelOptions(try #require(try fixture(version, name).json))
            #expect(models.contains { $0.model == "alpha" && !$0.provider.isEmpty }, "\(version) \(name): \(models.map(\.model))")
            #expect(models.filter(\.isCurrent).map(\.model) == ["alpha"], "\(version) \(name): one current model")
        }
    }

    /// Settings' pages that read one answer each: plugins, MCP servers, host stats, scheduled jobs.
    @Test(arguments: Replay.versions)
    func settingsPagesReadTheirAnswers(_ version: String) throws {
        let hub = try #require(try fixture(version, "rest.plugins-hub").json)
        #expect(PushPlugin.State(hub: hub).installed == false, "the approval lab has no Redde plugin")
        #expect((hub["plugins"]?.array ?? []).count > 3, "\(version): the hub lists Hermes's own plugins")
        let servers = try #require(try fixture(version, "rest.mcp-servers").json)
        #expect(servers["servers"]?.array != nil, "\(version): \(servers)")
        _ = HostStats(try #require(try fixture(version, "rest.system-stats").json))
        let jobs = try #require(try fixture(version, "rest.cron-jobs").json)
        #expect((jobs.array ?? jobs["jobs"]?.array) != nil, "\(version): the jobs come as a list")
        let plugins = try #require(try fixture(version, "ws.plugins-list").json)
        let installed = (plugins["plugins"]?.array ?? []).compactMap(InstalledPlugin.init)
        #expect(installed.count == plugins["plugins"]?.array?.count && !installed.isEmpty, "\(version): every plugin read")
        let tree = try fixture(version, "ws.projects-tree")
        let projects = (tree.json?["projects"]?.array ?? []).compactMap(HermesServeClient.Project.init)
        #expect(tree.error == nil && !projects.isEmpty, "\(version): \(String(describing: tree.error))")
    }

    // MARK: Dashboard WebSocket

    /// `gateway.ready`: whose sessions they are (issue 81). `hermes serve` says nothing of it; the
    /// gateway's own Dashboard (0.23) says they are the canonical owner's.
    @Test(arguments: Replay.versions)
    func gatewayReadySaysWhoseSessionsTheyAre(_ version: String) throws {
        let ready = try #require(try fixture(version, "ws.gateway-ready").events.first, "\(version): no gateway.ready on connecting")
        #expect(ready["type"]?.string == "gateway.ready")
        #expect(HermesServeClient.claimsSessionAuthority(ready: ready["payload"] ?? .null) == false, "\(version): hermes serve")
        if let webapp = Replay.fixture(version, "webapp.ws.gateway-ready")?.events.first {
            #expect(HermesServeClient.claimsSessionAuthority(ready: webapp["payload"] ?? .null), "\(version): the Webapp's sessions are the owner's")
        }
    }

    /// `session.create` and `prompt.submit` in each one's shapes (issue 81): what the app sends is
    /// what the recorder sent and the host took, and the answer has the ids the app reads.
    @Test(arguments: Replay.versions)
    func aChatIsMadeInTheShapeEachOwnerTakes(_ version: String) throws {
        for (name, canonical) in [("ws.session-create", false), ("webapp.ws.session-create", true)] {
            guard let made = Replay.fixture(version, name) else { continue }
            let app = JSONValue.object(CanonicalRequests.create(model: nil, provider: nil, reasoningEffort: nil, folder: nil,
                                                                hidden: false, profile: nil, canonical: canonical))
            #expect(ReplayFixture.json(made.record["params"] ?? NSNull()) == app, "\(version) \(name): the app's params")
            #expect(made.error == nil && made.json?["session_id"]?.string != nil, "\(version) \(name): \(String(describing: made.error))")
            #expect(made.json?["stored_session_id"]?.string != nil, "\(version) \(name): the stored id comes with it")
        }
        // The other owner's shape is refused, as issue 81 saw.
        if let refused = Replay.fixture(version, "webapp.ws.error.serve-create")?.error {
            #expect(HermesServeClient.RPCError(refused).code == 4001)
        }
        // The canonical owner's resume says where the session stands, as the app's edits are fenced with.
        if let resume = Replay.fixture(version, "webapp.ws.session-resume")?.json {
            #expect(resume["revision"]?.int != nil && resume["execution_generation"]?.int != nil, "\(version): the fences")
            let mutation = CanonicalRequests.mutation(stored: "s", operation: "delete", payload: [:], snapshot: resume, requestID: "r", profile: nil)
            #expect(mutation["expected_revision"]?.int == resume["revision"]?.int)
            #expect(mutation["expected_generation"]?.int == resume["execution_generation"]?.int)
            let rename = try fixture(version, "webapp.ws.session-mutate-rename")
            #expect(rename.error == nil, "\(version): a rename fenced from a resume is taken: \(String(describing: rename.error))")
        }
    }

    /// A turn's events, heard as the app hears them: the reply streams, its tools show, and
    /// `message.complete` ends it.
    @Test(arguments: Replay.versions)
    func aTurnsEventsEndItWithTheReply(_ version: String) async throws {
        for name in ["ws.turn-events", "ws.turn-events-tool", "webapp.ws.turn-events"] {
            guard let recorded = Replay.fixture(version, name) else { continue }
            let runtime = try #require(recorded.events.first { $0["type"]?.string == "message.complete" }?["session_id"]?.string,
                                       "\(version) \(name): no message.complete")
            let (events, ended) = await hear(recorded.events, runtime: runtime)
            #expect(ended == true, "\(version) \(name): the turn ended well")
            let text = events.compactMap { if case let .textDelta(t) = $0 { t } else { nil } }.joined()
            #expect(!text.isEmpty, "\(version) \(name): the reply streamed")
            if name.hasSuffix("tool") {
                #expect(events.contains { if case let .toolStarted(name, _, _) = $0 { name.hasPrefix("todo") } else { false } }, "\(version): the to-do tool showed")
                #expect(events.contains { if case let .todos(list) = $0 { list.count == 3 } else { false } }, "\(version): its list of three")
            } else {
                #expect(text.contains(Replay.answer), "\(version) \(name): \(text)")
            }
        }
    }

    /// The chat list's marks (issue 12, Working / Needs you): a chat with a turn under way is
    /// working, the one that finished isn't.
    @Test(arguments: Replay.versions)
    func theLiveListSaysWhichChatWorks(_ version: String) throws {
        for name in ["ws.session-active-list", "webapp.ws.session-active-list"] {
            guard let list = Replay.fixture(version, name)?.json else { continue }
            let kinds = ChatActivity.kinds(activeList: list)
            #expect(kinds.values.contains(.working), "\(version) \(name): \(kinds)")
            if name == "ws.session-active-list", let stored = Replay.storedChat(version) {
                #expect(kinds[stored] == nil, "\(version): the finished chat isn't marked")
            }
        }
    }

    /// Bots: the main profile is in the roster, and its details read.
    @Test(arguments: Replay.versions)
    func theBotRosterHasTheMainProfile(_ version: String) throws {
        let roster = BotRoster(try #require(try fixture(version, "ws.profiles-list").json))
        #expect(roster.bots.contains { $0.isDefault && $0.name == "default" }, "\(version): \(roster.bots.map(\.name))")
        let details = BotDetails(try #require(try fixture(version, "ws.profiles-describe").json))
        #expect(!details.toolsets.isEmpty, "\(version): the main profile's toolsets")
        // A bot's chat is found in `session.list` by its id and title (ServerBots.findBotChat).
        let rows = try #require(try fixture(version, "ws.session-list").json?["sessions"]?.array)
        #expect(rows.contains { $0["id"]?.string == Replay.storedChat(version) && $0["title"]?.string != nil }, "\(version)")
        // Group chats (issue 73): a release without them says so as an unknown method, which the
        // app takes for "no group chats"; one with them names its methods.
        let groups = try fixture(version, "ws.groups-capabilities")
        if let error = groups.error {
            #expect(HermesServeClient.RPCError(error).code == -32601, "\(version): \(error)")
        } else {
            #expect(groups.json?["methods"]?.array != nil, "\(version): \(String(describing: groups.json))")
        }
    }

    /// Deleting a chat still at work (issue 78): Hermes refuses with 4023 while the session is live,
    /// which is the refusal the app closes the session for and tries again on; after the close the
    /// delete goes. Replayed through the app's own delete with the recorded answers.
    @Test(arguments: Replay.versions)
    func aChatStillAtWorkIsClosedThenDeleted(_ version: String) async throws {
        let refused = try #require(try fixture(version, "ws.error.delete-running").error, "\(version): the delete was taken while the turn ran")
        let deleted = try #require(try fixture(version, "ws.session-delete").json)
        #expect(HermesServeClient.RPCError(refused).code == 4023, "\(version): \(refused)")
        nonisolated(unsafe) var refusals = 1, sent: [String] = []
        try await HermesServeClient.deleteClosingFirst(stored: "chat", known: nil, pause: { _ in }) { method, _ in
            sent.append(method)
            switch method {
            case "session.delete":
                if refusals > 0 { refusals -= 1; throw HermesServeClient.RPCError(refused) }
                return deleted
            case "session.resume": return .object(["session_id": .string("rt-1")])
            default: return .object([:])
            }
        }
        #expect(sent == ["session.delete", "session.resume", "session.close", "session.delete"], "\(version): \(sent)")

        // An unknown session is not "still at work": no retry for it.
        let unknown = HermesServeClient.RPCError(try #require(try fixture(version, "ws.error.resume-unknown").error))
        #expect(unknown.code == 4007 && unknown.code != 4023)
        let unknownMethod = HermesServeClient.RPCError(try #require(try fixture(version, "ws.error.unknown-method").error))
        #expect(unknownMethod.code == -32601 && unknownMethod.errorDescription?.isEmpty == false)

        // The canonical owner (0.23's Webapp) refuses a delete while a turn runs with 4001
        // "session_busy", which the app neither retries nor puts in its own words yet.
        if let busy = Replay.fixture(version, "webapp.ws.session-mutate-delete-running")?.error {
            let error = HermesServeClient.RPCError(busy)
            #expect(error.code == 4001 && error.message == "session_busy", "\(version): \(busy)")
            // The app says it as what to do (ChatBusyError), not as Hermes words it.
            #expect(HermesServeClient.isBusy(error), "\(version): \(busy)")
        }
        // And a title another session has comes back as an internal error there, not "already in
        // use", which ServerBots.makeBotChat looks for when two apps make a bot's chat at once.
        if let taken = Replay.fixture(version, "webapp.ws.error.mutate-rename-taken")?.error {
            let error = HermesServeClient.RPCError(taken)
            #expect(error.code == -32603, "\(version): \(taken)")
            // ServerBots.makeBotChat takes it as a taken title there, and finds the other app's chat.
            #expect(HermesServeClient.isTitleTaken(error, canonical: true), "\(version): \(taken)")
            #expect(!HermesServeClient.isTitleTaken(error, canonical: false), "only the canonical owner says it so")
        }
    }

    /// REST refusals in the app's words: a session that isn't there, and the login gone.
    @Test(arguments: Replay.versions)
    func dashboardRefusalsAreTheAppsErrors(_ version: String) async throws {
        ReplayStub.reset(); defer { ReplayStub.reset() }
        let missing = "20260101_000000_nosuch"
        ReplayStub.serve("GET", "/api/sessions/\(missing)/messages", try fixture(version, "rest.error.unknown-session-messages"))
        do {
            _ = try await client().transcript(stored: missing)
            Issue.record("\(version): a session that isn't there read as an empty transcript")
        } catch let TransportError.http(status, body) {
            #expect(status == 404 && body == "Session not found", "\(version): the detail, not the JSON: \(body)")
        }
        let signedOut = try fixture(version, "rest.error.signed-out")
        #expect(signedOut.status == 401)
        let refusal = HermesServeClient.refusal(401, signedOut.data)
        #expect(refusal.errorDescription?.contains("Unauthorized") == true, "\(version): \(String(describing: refusal.errorDescription))")
        let gone = try fixture(version, "rest.error.unknown-session")
        #expect(gone.status == 404 && HermesServeClient.refusal(404, gone.data).errorDescription?.contains("{") == false)
    }

    // MARK: Hermes API

    /// The Hermes API's lists and a chat's transcript, read with the app's decoders.
    @Test(arguments: Replay.versions)
    func theHermesAPIsListsRead(_ version: String) async throws {
        #expect(try fixture(version, "api.health").status == 200)
        let models = try #require(try fixture(version, "api.models").json)
        #expect(models["data"]?.array?.isEmpty == false, "the connection test reads a model list")
        let made = try JSONDecoder().decode(HermesSessionsAPI.SessionEnvelope.self, from: try fixture(version, "api.session-create").data)
        let sessions = try JSONDecoder().decode(HermesSessionsAPI.ListEnvelope<HermesSessionsAPI.SessionSummary>.self,
                                                from: try fixture(version, "api.sessions").data).data
        #expect(sessions.contains { $0.id == made.session.id }, "\(version): \(sessions.map(\.id))")
        let messages = try JSONDecoder().decode(HermesSessionsAPI.ListEnvelope<HermesSessionsAPI.StoredMessage>.self,
                                                from: try fixture(version, "api.messages").data).data
        let shown = await Conversation.readied(stored: messages)
        #expect(shown.contains { $0.role == .assistant && $0.text.contains(Replay.answer) }, "\(version): \(shown.map(\.text))")
        let toolsets = try JSONDecoder().decode(HermesSessionsAPI.ListEnvelope<HermesSessionsAPI.Toolset>.self,
                                                from: try fixture(version, "api.toolsets").data).data
        #expect(toolsets.contains { $0.name == "terminal" }, "\(version): \(toolsets.map(\.name))")
        let skills = try fixture(version, "api.skills")
        if skills.ok {
            let list = try JSONDecoder().decode(HermesSessionsAPI.ListEnvelope<HermesSessionsAPI.Skill>.self, from: skills.data).data
            #expect(list.contains { $0.name == "lab-hello" })
        } else {
            // 0.21.5 to 0.23.2 as shipped: GET /v1/skills fails in Hermes itself (`find_all_skills`
            // was given a keyword it doesn't take). The Skills screen on a Hermes API connection
            // shows that refusal as it comes.
            withKnownIssue("Hermes \(version)'s /v1/skills answers HTTP \(skills.status ?? 0)") {
                #expect(skills.ok)
            }
            let shownError = TransportError.http(status: skills.status ?? 0, body: String(decoding: skills.data, as: UTF8.self)).errorDescription
            #expect(shownError?.contains("\(skills.status ?? 0)") == true)
        }
        #expect(try fixture(version, "api.patch-rename").ok, "\(version): a rename over the Hermes API (issue 70)")
    }

    /// A turn as a run (the app from 1.10): its id, its events read to the end, and its status.
    @Test(arguments: Replay.versions)
    func aRunIsFollowedToItsEnd(_ version: String) throws {
        let start = try #require(try fixture(version, "api.run-start").json)
        let run = try #require(start["run_id"]?.string, "HermesRuns.start reads run_id")
        var parser = SSEParser()
        let stream = try #require(try fixture(version, "api.run-events").text)
        var decoded = parser.feed(stream).compactMap { HermesRuns.decode($0, run: run) }
        if let last = parser.finish(), let tail = HermesRuns.decode(last, run: run) { decoded.append(tail) }
        #expect(decoded.contains { $0.ending == .completed }, "\(version): the events end the run")
        #expect(decoded.flatMap(\.events).contains { if case let .textDelta(t) = $0 { t.contains(Replay.answer) } else { false } })
        if version.hasPrefix("v0.2") { #expect(decoded.contains { $0.seq != nil }, "\(version): 0.22 and later number a run's events") }

        let status = HermesRuns.decode(status: try #require(try fixture(version, "api.run-status").json), run: run)
        #expect(status.ending == .completed && status.events.contains(.textFinal(Replay.answer)), "\(version): \(status)")
        let running = try #require(try fixture(version, "api.run-status-running").json)
        #expect(HermesRuns.decode(status: running, run: run).ending == nil)
        #expect(ChatActivity.kind(runStatus: running["status"]?.string ?? "") == .working, "\(version): \(running["status"] ?? .null)")
    }

    /// The chat stream, the app's turn where a gateway has no runs: read to its end, or failed
    /// with Hermes's own words.
    @Test(arguments: Replay.versions)
    func theChatStreamReadsToItsEnd(_ version: String) throws {
        var parser = SSEParser()
        let events = parser.feed(try #require(try fixture(version, "api.chat-stream").text)) + [parser.finish()].compactMap { $0 }
        var finished = false, text = "", failure: String?
        for event in events {
            do {
                let (turn, done) = try HermesSessionsTransport.decode(event)
                finished = finished || done
                for case let .textDelta(t) in turn { text += t }
            } catch let TransportError.malformed(message) {
                failure = message
                break
            }
        }
        if let failure {
            // 0.21.0 and 0.21.3: a chat stream after a run in the same session finds no provider.
            #expect(!failure.isEmpty && failure != "run failed", "\(version): Hermes's words: \(failure)")
        } else {
            #expect(finished && !text.isEmpty, "\(version): \(text)")
        }
    }

    /// The Hermes API's refusals, in the app's words.
    @Test(arguments: Replay.versions)
    func hermesAPIRefusalsAreTheAppsErrors(_ version: String) throws {
        for name in ["api.error.bad-key", "api.error.bad-key-sessions"] {
            let refused = try fixture(version, name)
            let error = TransportError.http(status: refused.status ?? 0, body: String(decoding: refused.data.prefix(300), as: UTF8.self))
            #expect(error.errorDescription == TransportError.keyRejectedText, "\(version) \(name): \(String(describing: error.errorDescription))")
        }
        // A run the host no longer knows is a 404, which HermesSessionsAPI.runStatus reads as nil.
        #expect(try fixture(version, "api.error.unknown-run").status == 404)
        #expect(try fixture(version, "api.error.unknown-session-messages").status == 404)
        #expect(try fixture(version, "api.error.unknown-session").status == 404)
        // A delete while a run works: 0.22 and later refuse it (409).
        let busy = try fixture(version, "api.error.delete-running")
        if !busy.ok {
            #expect(busy.status == 409, "\(version): \(busy.status ?? 0)")
            // Said as what to do (ChatBusyError), not as Hermes's JSON after the status.
            #expect(ChatBusyError.isBusy(TransportError.http(status: 409, body: String(decoding: busy.data.prefix(300), as: UTF8.self))),
                    "\(version): \(String(decoding: busy.data.prefix(200), as: UTF8.self))")
        }
    }

    // MARK: Changed answers

    /// Every recorded answer a little changed: a key left out (one at a time, at every level, in the
    /// first row of each list), a key the app doesn't know added, a number sent as text where Hermes
    /// has done that (a message's id and time, SQLite's 0 and 1 for a session's `hidden`). Nothing
    /// may crash; a key added changes nothing; a key left out costs at most what it carried, unless
    /// it is one the parser can't do without (`needs`).
    @Test(arguments: Replay.versions)
    func changedAnswersAreTakenGracefully(_ version: String) async throws {
        ReplayStub.reset(); defer { ReplayStub.reset() }
        var tried = 0
        for parser in Self.parsers {
            guard let fixture = Replay.fixture(version, parser.fixture), fixture.ok || fixture.kind == "ws",
                  fixture.error == nil, let payload = fixture.payload else { continue }
            let base: Int
            do {
                base = try await parser.read(payload, version)
            } catch {
                Issue.record("\(version) \(parser.fixture): the recorded answer itself fails: \(error)")
                continue
            }
            for variant in ReplayMutations.variants(of: payload, swappingNumbers: !parser.decodable) {
                tried += 1
                let got: Int
                do {
                    got = try await parser.read(variant.value, version)
                } catch {
                    if case let .dropped(key) = variant.change, parser.needs.contains(key) { continue }
                    Issue.record("\(version) \(parser.fixture) \(variant.description): \(error)")
                    continue
                }
                switch variant.change {
                case .added, .swapped:
                    if got != base { Issue.record("\(version) \(parser.fixture) \(variant.description): \(got), not \(base)") }
                case let .dropped(key):
                    if got > base || (got < base && !parser.needs.contains(key) && !parser.carries.contains(key)) {
                        Issue.record("\(version) \(parser.fixture) \(variant.description): \(got), not \(base)")
                    }
                case .retyped:
                    break   // only that nothing crashes
                }
            }
        }
        #expect(tried > 500, "\(version): \(tried) changed answers")
    }

    // MARK: Helpers

    /// What `HermesServeTransport.hear` makes of a turn's events: the reply's events, and whether
    /// (and how) the turn ended.
    private func hear(_ events: [JSONValue], runtime: String) async -> ([TurnEvent], Bool?) {
        let turn = HermesServeTransport.TurnState(runtime: runtime, stored: "stored")
        let reply = AsyncThrowingStream<TurnEvent, Error>.makeStream()
        let finished = AsyncStream<Result<Void, Error>>.makeStream()
        let client = client()
        for event in events {
            HermesServeTransport.hear((event["type"]?.string ?? "", event["session_id"]?.string, event["payload"] ?? .null),
                                      turn: turn, client: client, continuation: reply.continuation, finished: finished.continuation)
        }
        finished.continuation.finish()
        reply.continuation.finish()
        var ended: Bool?
        for await result in finished.stream {
            if ended == nil { if case .success = result { ended = true } else { ended = false } }
        }
        var out: [TurnEvent] = []
        do { for try await event in reply.stream { out.append(event) } } catch {}
        return (out, ended)
    }

    /// A route's parser as the app runs it, reading an answer to a number to compare (how many
    /// rows it read, mostly). `needs`: keys it can't do without (left out, it may fail or read
    /// fewer); `carries`: keys whose loss may cost rows (they hold them, or say which count).
    struct Parser {
        var fixture: String
        var needs: Set<String> = []
        var carries: Set<String> = []
        /// Built on `Decodable` types, which take a number for a number only: no blanket swaps.
        var decodable = false
        var read: @MainActor (Any, String) async throws -> Int
    }

    private static func json(_ value: Any) throws -> JSONValue {
        try JSONValue.parse(ReplayFixture.data(value))
    }

    private static func served(_ path: String, _ value: Any) -> HermesServeClient {
        ReplayStub.routes["GET \(path)"] = (200, ReplayFixture.data(value))
        let settings = Settings(defaults: UserDefaults(suiteName: "replay-\(UUID().uuidString)")!)
        settings.serveURL = "http://replay.test:9119"
        settings.serveUsername = "lab"
        return HermesServeClient(settings: settings, password: { "labpass" }, tokens: HermesServeClientTests.TokenBox().store,
                                 protocolClasses: [ReplayStub.self])
    }

    private static func decoded<T: Decodable>(_ type: T.Type, _ value: Any) throws -> T {
        try JSONDecoder().decode(type, from: ReplayFixture.data(value))
    }

    static let parsers: [Parser] = [
        // Dashboard REST, through the app's client.
        Parser(fixture: "rest.sessions", needs: ["id"], carries: ["sessions"], decodable: true) { value, _ in
            try await served("/api/sessions", value).listSessions().count
        },
        Parser(fixture: "rest.profiles-sessions", needs: ["id"], carries: ["sessions"], decodable: true) { value, _ in
            try await served("/api/profiles/sessions", value).allProfileSessions().count
        },
        Parser(fixture: "rest.messages", needs: ["messages"], decodable: true) { value, version in
            let stored = Replay.storedChat(version) ?? ""
            return try await served("/api/sessions/\(stored)/messages", value).transcript(stored: stored).count
        },
        Parser(fixture: "rest.profiles", needs: ["profiles", "name", "path", "is_default"], decodable: true) { value, _ in
            try await served("/api/profiles", value).profiles().count
        },
        Parser(fixture: "rest.skills", needs: ["name"], carries: ["skills", "data"], decodable: true) { value, _ in
            try await served("/api/skills", value).dashboardSkills().count
        },
        Parser(fixture: "rest.toolsets", needs: ["name"], decodable: true) { value, _ in
            try await served("/api/tools/toolsets", value).dashboardToolsets().count
        },
        // Dashboard answers read as JSON.
        Parser(fixture: "rest.status", carries: ["version"]) { value, _ in GatewayStatus(try json(value)).version.isEmpty ? 0 : 1 },
        Parser(fixture: "rest.model-options", carries: ["providers", "models"]) { value, _ in HermesSessionsAPI.parseModelOptions(try json(value)).count },
        Parser(fixture: "ws.model-options", carries: ["providers", "models"]) { value, _ in HermesSessionsAPI.parseModelOptions(try json(value)).count },
        Parser(fixture: "api.model-options", carries: ["providers", "models"]) { value, _ in HermesSessionsAPI.parseModelOptions(try json(value)).count },
        Parser(fixture: "rest.plugins-hub", carries: ["plugins", "name"]) { value, _ in
            _ = PushPlugin.State(hub: try json(value))
            return try json(value)["plugins"]?.array?.count ?? 0
        },
        Parser(fixture: "rest.mcp-servers", carries: ["servers", "name"]) { value, _ in
            (try json(value)["servers"]?.array ?? []).compactMap(MCPServer.init).count
        },
        Parser(fixture: "rest.system-stats") { value, _ in _ = HostStats(try json(value)); return 1 },
        Parser(fixture: "rest.cron-jobs", carries: ["jobs", "id", "job_id"]) { value, _ in
            let list = try json(value)
            return (list.array ?? list["jobs"]?.array ?? []).compactMap(CronJob.init).count
        },
        Parser(fixture: "ws.session-active-list", carries: ["sessions", "status"]) { value, _ in ChatActivity.kinds(activeList: try json(value)).count },
        Parser(fixture: "ws.profiles-list", carries: ["profiles", "name"]) { value, _ in BotRoster(try json(value)).bots.count },
        Parser(fixture: "ws.profiles-describe", carries: ["toolsets", "name"]) { value, _ in BotDetails(try json(value)).toolsets.count },
        Parser(fixture: "ws.projects-tree", carries: ["projects", "id"]) { value, _ in
            (try json(value)["projects"]?.array ?? []).compactMap(HermesServeClient.Project.init).count
        },
        Parser(fixture: "ws.plugins-list", carries: ["plugins", "name"]) { value, _ in
            (try json(value)["plugins"]?.array ?? []).compactMap(InstalledPlugin.init).count
        },
        Parser(fixture: "ws.session-resume", carries: ["messages", "role", "text", "content", "display_kind"]) { value, _ in
            let rows = try json(value)["messages"]?.array ?? []
            return await Conversation.readied(serveRows: rows).count
        },
        Parser(fixture: "webapp.ws.session-resume", carries: ["messages", "role", "text", "content", "display_kind"]) { value, _ in
            await Conversation.readied(serveRows: try json(value)["messages"]?.array ?? []).count
        },
        Parser(fixture: "webapp.ws.session-active-list", carries: ["sessions", "status"]) { value, _ in ChatActivity.kinds(activeList: try json(value)).count },
        // The Hermes API, with the app's decoders.
        Parser(fixture: "api.sessions", needs: ["data", "id"], decodable: true) { value, _ in
            try decoded(HermesSessionsAPI.ListEnvelope<HermesSessionsAPI.SessionSummary>.self, value).data.count
        },
        Parser(fixture: "api.session-create", needs: ["session", "id"], decodable: true) { value, _ in
            _ = try decoded(HermesSessionsAPI.SessionEnvelope.self, value); return 1
        },
        Parser(fixture: "api.messages", needs: ["data"], decodable: true) { value, _ in
            let rows = try decoded(HermesSessionsAPI.ListEnvelope<HermesSessionsAPI.StoredMessage>.self, value).data
            _ = await Conversation.readied(stored: rows)
            return rows.count
        },
        Parser(fixture: "api.toolsets", needs: ["data", "name"], decodable: true) { value, _ in
            try decoded(HermesSessionsAPI.ListEnvelope<HermesSessionsAPI.Toolset>.self, value).data.count
        },
        Parser(fixture: "api.skills", needs: ["data", "name"], decodable: true) { value, _ in
            try decoded(HermesSessionsAPI.ListEnvelope<HermesSessionsAPI.Skill>.self, value).data.count
        },
        Parser(fixture: "api.run-status", carries: ["status", "output", "usage", "input_tokens", "prompt_tokens"]) { value, _ in
            HermesRuns.decode(status: try json(value), run: "run").events.count
        },
        Parser(fixture: "api.run-status-running", carries: ["status"]) { value, _ in
            HermesRuns.decode(status: try json(value), run: "run").ending == nil ? 1 : 0
        },
        Parser(fixture: "api.run-start", carries: ["run_id"]) { value, _ in try json(value)["run_id"]?.string == nil ? 0 : 1 },
    ]
}

// MARK: - Changing an answer

nonisolated enum ReplayMutations {
    enum Change: Equatable {
        case dropped(String)
        case added
        /// A number as text (or text as a number) where Hermes has sent it so: the parser must read
        /// it the same.
        case swapped
        /// Every number as text, for the parsers that read JSON by hand: nothing may crash.
        case retyped
    }

    struct Variant {
        var description: String
        var change: Change
        var value: Any
    }

    /// Where Hermes has sent a number as text or the other way round, by key: a stored message's
    /// row id (a number, read as text) and time; SQLite's 0 and 1 for a session's `hidden` and
    /// `archived` on the Dashboard's list of every profile.
    nonisolated(unsafe) static let swaps: [String: (Any) -> Any?] = [
        "id": { value in (value as? NSNumber).flatMap { isBool($0) ? nil : $0.stringValue } },
        "timestamp": { value in (value as? NSNumber).flatMap { isBool($0) ? nil : $0.stringValue } },
        "hidden": { value in (value as? NSNumber).map { isBool($0) ? NSNumber(value: $0.boolValue ? 1 : 0) : NSNumber(value: $0.intValue != 0) } },
        "archived": { value in (value as? NSNumber).map { isBool($0) ? NSNumber(value: $0.boolValue ? 1 : 0) : NSNumber(value: $0.intValue != 0) } },
    ]

    static func isBool(_ n: NSNumber) -> Bool { CFGetTypeID(n) == CFBooleanGetTypeID() }

    /// A path into an answer: keys of objects, and 0 for the first row of a list.
    private enum Step { case key(String), first }

    /// The objects in an answer, by path: at every level, and in the first row of each list.
    private static func objects(in value: Any, at path: [Step] = [], depth: Int = 0, into out: inout [([Step], [String: Any])]) {
        guard depth < 6 else { return }
        if let object = value as? [String: Any] {
            out.append((path, object))
            for key in object.keys.sorted() { objects(in: object[key]!, at: path + [.key(key)], depth: depth + 1, into: &out) }
        } else if let list = value as? [Any], let first = list.first {
            objects(in: first, at: path + [.first], depth: depth + 1, into: &out)
        }
    }

    private static func changing(_ value: Any, at path: ArraySlice<Step>, _ change: (inout [String: Any]) -> Void) -> Any {
        guard let step = path.first else {
            guard var object = value as? [String: Any] else { return value }
            change(&object)
            return object
        }
        switch step {
        case let .key(key):
            guard var object = value as? [String: Any], let inner = object[key] else { return value }
            object[key] = changing(inner, at: path.dropFirst(), change)
            return object
        case .first:
            guard var list = value as? [Any], !list.isEmpty else { return value }
            list[0] = changing(list[0], at: path.dropFirst(), change)
            return list
        }
    }

    private static func retyped(_ value: Any) -> Any {
        if let n = value as? NSNumber { return isBool(n) ? n : n.stringValue }
        if let object = value as? [String: Any] { return object.mapValues(retyped) }
        if let list = value as? [Any] { return list.map(retyped) }
        return value
    }

    static func variants(of answer: Any, swappingNumbers: Bool, most: Int = 400) -> [Variant] {
        var found: [([Step], [String: Any])] = []
        objects(in: answer, into: &found)
        var out: [Variant] = []
        func where_(_ path: [Step]) -> String {
            path.isEmpty ? "the answer" : path.map { if case let .key(k) = $0 { k } else { "[0]" } }.joined(separator: ".")
        }
        for (path, object) in found {
            out.append(Variant(description: "with a key added at \(where_(path))", change: .added,
                               value: changing(answer, at: path[...]) { $0["zz_replay_unknown"] = ["nested": [1, "x", NSNull()]] }))
            for key in object.keys.sorted() {
                out.append(Variant(description: "without \(where_(path + [.key(key)]))", change: .dropped(key),
                                   value: changing(answer, at: path[...]) { $0[key] = nil }))
                if let swap = swaps[key], let swapped = swap(object[key]!) {
                    out.append(Variant(description: "with \(where_(path + [.key(key)])) as \(type(of: swapped))", change: .swapped,
                                       value: changing(answer, at: path[...]) { $0[key] = swapped }))
                }
            }
        }
        if swappingNumbers {
            out.append(Variant(description: "with every number as text", change: .retyped, value: retyped(answer)))
        }
        return Array(out.prefix(most))
    }
}
