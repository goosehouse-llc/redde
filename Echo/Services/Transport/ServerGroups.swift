import CryptoKit
import Foundation
import Observation

/// Group chats: Hermes's hosted bot rooms (`groups.*` on the Dashboard socket, the same methods on
/// Hermes 0.21.0 to 0.22.2). Hermes runs a room itself: a message goes to the bots it tags, or to
/// all of them, one after another; a bot a reply tags may answer in turn, for three rounds or ten
/// replies at most; a bot with nothing to add passes. The app makes rooms, sends to them and reads
/// what was said from the room's log; Hermes pushes nothing about a room, so the log is read again
/// every second or so while bots are talking. There is no streaming of a reply: each comes whole.

/// One bot in a room.
nonisolated struct GroupMember: Identifiable, Equatable, Sendable {
    /// Its id in the room: the bot's profile name.
    var id: String
    var profile: String
    /// What a message tags it with ("@scout").
    var handle: String
    var displayName: String?

    init(id: String, profile: String, handle: String, displayName: String? = nil) {
        self.id = id
        self.profile = profile
        self.handle = handle
        self.displayName = displayName
    }

    init?(_ json: JSONValue) {
        guard let id = json["member_id"]?.string ?? json["profile"]?.string else { return nil }
        self.init(id: id, profile: json["profile"]?.string ?? id, handle: json["handle"]?.string ?? id,
                  displayName: json["display_name"]?.string?.nilIfEmpty)
    }

    var label: String { displayName ?? handle }

    /// A room member as `groups.create` takes it.
    var wire: JSONValue {
        var fields: [String: JSONValue] = ["member_id": .string(id), "profile": .string(profile), "handle": .string(handle)]
        if let displayName { fields["display_name"] = .string(String(displayName.prefix(200))) }
        return .object(fields)
    }
}

/// A room.
nonisolated struct GroupRoom: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var members: [GroupMember]
    var updatedAt: Date?
    var latestSeq: Int?
    /// One Hermes Desktop runs itself, shown here from its copy (`desktopRooms(in:)`): read only.
    var inDesktop = false
    /// That copy's messages, the last 16 at most, oldest first.
    var desktopMessages: [DesktopMessage] = []
    /// How many earlier ones the copy leaves out.
    var omitted = 0

    init?(_ json: JSONValue) {
        guard let id = json["room_id"]?.string else { return nil }
        self.id = id
        name = json["name"]?.string ?? id
        members = (json["members"]?.array ?? []).compactMap(GroupMember.init)
        updatedAt = json["updated_at"]?.number.map { Date(timeIntervalSince1970: $0) }
        latestSeq = json["latest_seq"]?.int
    }

    func member(_ id: String?) -> GroupMember? { members.first { $0.id == id } }

    /// One message of a Hermes Desktop room's copy.
    nonisolated struct DesktopMessage: Equatable, Sendable {
        /// Its id, else when it was said and by whom: the same message keeps it as the copy moves on.
        var key: String
        var at: Date
        /// The person's (any Desktop's), or a bot's.
        var fromPerson: Bool
        /// A bot's profile.
        var profile: String?
        var text: String
    }

    /// Its bots called as the roster calls them where the copy gives no name (the main agent, as a
    /// rule: Redde's name for it).
    func naming(with roster: BotRoster?, mainName: String) -> GroupRoom {
        var room = self
        for i in room.members.indices where room.members[i].displayName == nil {
            room.members[i].displayName = roster?.named(room.members[i].profile)?.label(mainName: mainName)
                ?? (room.members[i].profile == "default" ? mainName : nil)
        }
        return room
    }

    /// The rooms Hermes Desktop runs itself. Its Bot Mode never uses `groups.*`: it runs a room on
    /// the Mac or PC it is open on and keeps a copy of each, with the last 16 messages (1,200
    /// characters each), in the main profile's `ui_meta["hermes-bots-groups"]`, version 3, "so
    /// mobile can show the same messages" (apps/desktop/src/plugins/hermes-bots/group-chat.ts, the
    /// same on 0.21.0 to 0.22.2). Rooms it ended are kept as tombstones under `deleted`.
    static func desktopRooms(in copy: JSONValue?) -> [GroupRoom] {
        guard let copy, (copy["version"]?.int ?? 0) >= 3, let rooms = copy["rooms"]?.object else { return [] }
        let deleted = copy["deleted"]?.object ?? [:]
        return rooms.compactMap { key, room -> GroupRoom? in
            let revision = room["revision"]?.int ?? 0
            if let gone = deleted[key]?.int, gone >= revision { return nil }
            return GroupRoom(desktopKey: key, room)
        }
        .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    private init?(desktopKey key: String, _ json: JSONValue) {
        guard json.object != nil else { return nil }
        id = "desktop:" + key
        name = json["name"]?.string?.nilIfEmpty ?? String(key.drop { $0 != ":" }.dropFirst())
        members = (json["members"]?.array ?? []).compactMap { member -> GroupMember? in
            guard let profile = member["name"]?.string?.nilIfEmpty else { return nil }
            return GroupMember(id: profile, profile: profile, handle: member["handle"]?.string?.nilIfEmpty ?? profile,
                               displayName: member["title"]?.string?.nilIfEmpty ?? member["display_name"]?.string?.nilIfEmpty)
        }
        desktopMessages = (json["log"]?.array ?? []).compactMap { entry -> DesktopMessage? in
            guard let text = entry["text"]?.string, !text.isEmpty else { return nil }
            let millis = entry["at"]?.number ?? 0
            let person = entry["from"]?["kind"]?.string != "member"
            let name = entry["from"]?["name"]?.string
            return DesktopMessage(key: entry["id"]?.string ?? "\(Int(millis))|\(name ?? "")|\(text.prefix(40))",
                                  at: Date(timeIntervalSince1970: millis / 1000), fromPerson: person,
                                  profile: person ? nil : name, text: text)
        }
        // A copy without its members (an older Desktop's) still shows who spoke.
        if members.isEmpty {
            var seen = Set<String>()
            members = desktopMessages.compactMap(\.profile).filter { seen.insert($0).inserted }
                .map { GroupMember(id: $0, profile: $0, handle: $0) }
        }
        omitted = json["omitted"]?.int ?? 0
        updatedAt = desktopMessages.last?.at
        inDesktop = true
    }
}

/// One entry of a room's log.
nonisolated struct GroupEvent: Identifiable, Equatable, Sendable {
    var seq: Int
    var kind: String
    /// "user" or "member" (or "system", "gateway").
    var actorKind: String
    /// The member it is about: the one who spoke, or whose turn it was (Hermes writes a turn's end
    /// as itself, the gateway, with the member in the payload).
    var actorID: String?
    var payload: JSONValue
    var createdAt: Date

    var id: Int { seq }
    var text: String { payload["text"]?.string ?? "" }

    init(seq: Int, kind: String, actorKind: String, actorID: String?, payload: JSONValue, createdAt: Date) {
        self.seq = seq
        self.kind = kind
        self.actorKind = actorKind
        self.actorID = actorID
        self.payload = payload
        self.createdAt = createdAt
    }

    init?(_ json: JSONValue) {
        guard let seq = json["seq"]?.int, let kind = json["kind"]?.string else { return nil }
        self.seq = seq
        self.kind = kind
        actorKind = json["actor"]?["kind"]?.string ?? ""
        actorID = json["payload"]?["member_id"]?.string ?? (actorKind == "member" ? json["actor"]?["id"]?.string : nil)
        payload = json["payload"] ?? .null
        createdAt = json["created_at"]?.number.map { Date(timeIntervalSince1970: $0) } ?? .now
    }

    /// Something someone said: the person, or a bot.
    var isMessage: Bool { kind == "message.user" || kind == "message.member" }

    /// A discussion is over: it ran its course or hit its limit (`room.activity`), or was stopped.
    var endsDiscussion: Bool { kind == "room.activity" || kind == "room.stop_requested" }

    /// A line about the room rather than something said, or nil when it isn't worth a line.
    func note(in room: GroupRoom) -> String? {
        let who = room.member(actorID)?.label ?? "A bot"
        switch kind {
        case "turn.settled": return payload["passed"]?.bool == true ? "\(who) passed" : nil
        case "turn.failed": return "\(who) couldn't answer" + (payload["error"]?.string.map { ": \($0)" } ?? "")
        case "turn.cancelled": return payload["reason"]?.string == "superseded_by_newer_user_event" ? nil : "\(who) was stopped"
        case "turn.deferred": return "\(who) didn't finish"
        case "room.activity": return payload["status"]?.string == "bounded" ? "That's as long as a round goes. Say something to carry on." : nil
        case "room.renamed": return payload["name"]?.string.map { "Renamed “\($0)”" }
        default: return nil
        }
    }
}

/// What a room waits on, and whether a bot is at work.
nonisolated struct GroupState: Equatable, Sendable {
    var working = false
    /// A stop under way, or a reply Hermes lost track of being sorted out: not a question for the
    /// person (those are `approvals` and `retries`).
    var blocked = false
    /// Bots stopping after Stop.
    var stopping = false
    var approvals: [GroupApproval] = []
    /// Replies that stopped partway, Hermes unsure how far they got (a restart mid-reply, a bot it
    /// couldn't reach): their tasks, each run again only when the person says so (`groups.retry`).
    var retries: [String] = []

    init(working: Bool = false, blocked: Bool = false, approvals: [GroupApproval] = [], retries: [String] = []) {
        self.working = working
        self.blocked = blocked
        self.approvals = approvals
        self.retries = retries
    }

    init(_ status: JSONValue?) {
        working = status?["working"]?.bool ?? false
        blocked = status?["blocked"]?.bool ?? false
        stopping = (status?["counts"]?["stopping"]?.int ?? 0) > 0
        let pending = status?["pending_actions"]?.array ?? []
        approvals = pending.compactMap(GroupApproval.init)
        retries = pending.compactMap { $0["kind"]?.string == "retry" ? $0["task_id"]?.string : nil }
    }

    /// Something only the person can settle: a command to approve, or a reply to try again.
    var waitsOnPerson: Bool { !approvals.isEmpty || !retries.isEmpty }
}

/// A command a bot in a room waits to have approved.
nonisolated struct GroupApproval: Identifiable, Equatable, Sendable {
    var memberID: String
    var taskID: String
    var executionGeneration: Int
    var request: ApprovalRequest

    var id: String { request.id }

    init?(_ json: JSONValue) {
        guard json["kind"]?.string == "approval", let member = json["member_id"]?.string, let task = json["task_id"]?.string,
              let generation = json["execution_generation"]?.int,
              let requestID = json["request_id"]?.string ?? json["approval"]?["request_id"]?.string else { return nil }
        memberID = member
        taskID = task
        executionGeneration = generation
        var request = ApprovalRequest(payload: json["approval"] ?? .null)
        request.id = requestID
        // A room takes "once" or "deny" only.
        request.choices = request.choices.filter { $0 == "once" || $0 == "deny" }
        if request.choices.isEmpty { request.choices = ["once", "deny"] }
        self.request = request
    }
}

extension HermesServeClient {
    nonisolated enum GroupProblem: LocalizedError {
        case unavailable
        var errorDescription: String? {
            "Group chats are run by a worker in Hermes that isn't running right now. Try again in a moment."
        }
    }

    /// Whether this Dashboard has group chats, and can start or send to one now (its room
    /// worker runs; it starts a moment after the Dashboard does).
    func groupSupport() async throws -> (supported: Bool, writable: Bool) {
        try await ensureConnected()
        let caps: JSONValue
        do {
            caps = try await call("groups.capabilities", params: .object([:]), timeout: 15)
        } catch let error as RPCError where error.code == -32601 {
            return (false, false)
        }
        let methods = Set((caps["methods"]?.array ?? []).compactMap(\.string))
        let supported = ["groups.list", "groups.create", "groups.state", "groups.send", "groups.log"].allSatisfy(methods.contains)
        return (supported, supported && caps["driver"]?.bool == true)
    }

    func groupRooms() async throws -> [GroupRoom] {
        try await ensureConnected()
        var rooms: [GroupRoom] = []
        var offset = 0
        for _ in 0 ..< 10 {
            let page = try await call("groups.list", params: .object(["limit": .number(100), "offset": .number(Double(offset))]))
            rooms += (page["rooms"]?.array ?? []).compactMap(GroupRoom.init)
            guard let next = page["next_offset"]?.int else { break }
            offset = next
        }
        return rooms
    }

    /// Makes a room of `bots` (two to six), named `name`.
    func createGroup(named name: String, bots: [HermesBot], mainName: String) async throws -> GroupRoom {
        try await ensureConnected()
        let members = bots.map { GroupMember(id: $0.name, profile: $0.name, handle: $0.handle, displayName: $0.label(mainName: mainName)) }
        let room = "redde-" + UUID().uuidString.lowercased()
        let result = try await call("groups.create", params: .object([
            "room_id": .string(room), "name": .string(String(name.prefix(200))), "members": .array(members.map(\.wire))]))
        guard let made = result["room"].flatMap(GroupRoom.init) else { throw TransportError.malformed("Hermes made no room") }
        return made
    }

    func groupState(_ room: String) async throws -> (room: GroupRoom?, state: GroupState) {
        try await ensureConnected()
        let result = try await call("groups.state", params: .object(["room_id": .string(room)]))
        return (result["room"].flatMap(GroupRoom.init), GroupState(result["driver_status"]))
    }

    /// Says `text` in the room. `eventID` is the message's own: sent again, it is the same message.
    func sendToGroup(_ room: String, text: String, eventID: String) async throws {
        try await ensureConnected()
        _ = try await call("groups.send", params: .object([
            "room_id": .string(room), "event_id": .string(eventID),
            "payload": .object(["text": .string(text), "thread_id": .string("main")])]))
    }

    /// Hermes Desktop's rooms, from its copy in the main profile (`GroupRoom.desktopRooms(in:)`).
    func desktopRooms() async throws -> [GroupRoom] {
        try await ensureConnected()
        let result = try await call("profiles.list", params: .object(["include_sessions": .bool(false)]))
        let main = result["profiles"]?.array?.first { $0["name"]?.string == "default" || $0["is_default"]?.bool == true }
        return GroupRoom.desktopRooms(in: main?["ui_meta"]?["hermes-bots-groups"])
    }

    /// The room's log after `since` (a sequence number), all of it.
    func groupLog(_ room: String, since: Int) async throws -> [GroupEvent] {
        try await ensureConnected()
        var events: [GroupEvent] = []
        var cursor = since
        for _ in 0 ..< 50 {
            let page = try await call("groups.log", params: .object([
                "room_id": .string(room), "since_seq": .number(Double(cursor)), "limit": .number(200)]))
            events += (page["events"]?.array ?? []).compactMap(GroupEvent.init).filter { $0.seq > cursor }
            cursor = max(cursor, page["cursor"]?.int ?? events.last?.seq ?? cursor)
            guard page["has_more"]?.bool == true else { break }
        }
        return events
    }

    /// Stops the bots in the room. A fresh `cancel_id` each time: one used before stops nothing new.
    func stopGroup(_ room: String) async throws {
        try await ensureConnected()
        _ = try await call("groups.stop", params: .object(["room_id": .string(room), "cancel_id": .string("stop-" + UUID().uuidString)]))
    }

    func renameGroup(_ room: String, to name: String) async throws {
        try await ensureConnected()
        _ = try await call("groups.rename", params: .object([
            "room_id": .string(room), "event_id": .string("rename-" + UUID().uuidString), "name": .string(String(name.prefix(200)))]))
    }

    /// Ends the room for good. Bots still stopping make Hermes refuse for a moment: tried again.
    func disbandGroup(_ room: String) async throws {
        try await ensureConnected()
        for attempt in 0 ..< 5 {
            do {
                _ = try await call("groups.disband", params: .object(["room_id": .string(room), "cancel_id": .string("disband-" + UUID().uuidString)]))
                return
            } catch let error as RPCError where error.message.localizedCaseInsensitiveContains("stopping") && attempt < 4 {
                try await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Runs a reply that stopped partway again (`GroupState.retries`).
    func retryGroupTask(_ room: String, task: String) async throws {
        try await ensureConnected()
        _ = try await call("groups.retry", params: .object(["room_id": .string(room), "task_id": .string(task)]))
    }

    /// Answers a bot's command: "once" or "deny". One answered meanwhile (on another device, or
    /// it waited too long) is refused with 5119, nothing for the person to fix.
    func answerGroupApproval(_ room: String, _ approval: GroupApproval, choice: String) async throws {
        try await ensureConnected()
        _ = try await call("groups.approve", params: .object([
            "room_id": .string(room), "member_id": .string(approval.memberID), "task_id": .string(approval.taskID),
            "execution_generation": .number(Double(approval.executionGeneration)), "request_id": .string(approval.request.id),
            "choice": .string(choice)]))
    }
}

#if DEBUG
extension GroupRoom {
    /// `-echo.demoBots`: a group chat of three of the demo bots.
    static let demo = GroupRoom(.object([
        "room_id": .string("demo-room"), "name": .string("Weekend hike"), "updated_at": .number(Date.now.timeIntervalSince1970 - 300),
        "members": .array([
            .object(["member_id": .string("default"), "profile": .string("default"), "handle": .string("hermes"), "display_name": .string("Redde")]),
            .object(["member_id": .string("scout"), "profile": .string("scout"), "handle": .string("scout"), "display_name": .string("Scout")]),
            .object(["member_id": .string("writer"), "profile": .string("writer"), "handle": .string("writer"), "display_name": .string("Quill")]),
        ]),
    ]))!
}

extension GroupRoom {
    /// `-echo.demoBots`: a room Hermes Desktop runs, as its copy has it.
    static let demoDesktop: GroupRoom = {
        let now = Date.now.timeIntervalSince1970 * 1000
        func said(_ ago: Double, _ kind: String, _ name: String, _ text: String) -> JSONValue {
            .object(["at": .number(now - ago * 1000), "from": .object(["kind": .string(kind), "name": .string(name)]), "text": .string(text)])
        }
        return desktopRooms(in: .object([
            "version": .number(3),
            "rooms": .object(["id:demo-desk": .object([
                "name": .string("Garage project"), "roomId": .string("demo-desk"), "revision": .number(3), "omitted": .number(6),
                "members": .array([.object(["name": .string("fixit"), "title": .string("Fix-it")]),
                                   .object(["name": .string("scout"), "title": .string("Scout")])]),
                "log": .array([
                    said(5400, "user", "You", "Can the bench go along the back wall, under the window?"),
                    said(5340, "member", "fixit", "Yes, if it's 60 cm deep at most: the door swings 70 cm in. I'd put the outlets at 110 cm."),
                    said(5300, "member", "scout", "Back-wall benches in single garages are usually 50 to 60 cm deep. Pegboard above the window line keeps the light."),
                ]),
            ])]),
        ])).first!
    }()
}

extension GroupFeed {
    /// The demo room with a short exchange in it, not followed.
    static func demo(_ room: GroupRoom = .demo) -> GroupFeed {
        let feed = GroupFeed(room: room)
        feed.isDemo = true
        if room.inDesktop {
            var seqs: [String: Int] = [:]
            feed.events = events(of: room, numbering: &seqs)
            return feed
        }
        func event(_ seq: Int, _ kind: String, _ actor: String, _ text: String, extra: [String: JSONValue] = [:]) -> GroupEvent {
            var payload: [String: JSONValue] = ["text": .string(text), "member_id": .string(actor)]
            payload.merge(extra) { $1 }
            return GroupEvent(.object(["seq": .number(Double(seq)), "kind": .string(kind),
                                       "actor": .object(["kind": .string(kind == "message.user" ? "user" : "member"), "id": .string(actor)]),
                                       "payload": .object(payload), "created_at": .number(Date.now.timeIntervalSince1970 - Double(400 - seq * 30))]))!
        }
        feed.events = [
            event(1, "message.user", "desktop", "We want a hike Saturday, under two hours' drive. Ideas?"),
            event(2, "message.member", "default", "Saturday looks dry until three. I'll keep the morning clear on your calendar."),
            event(3, "message.member", "scout", "Three trails fit: **Bear Ridge** (6 mi, 1h20 away), **Falls Loop** (4 mi, 50 min) and **Cedar Notch** (8 mi, 1h45). Falls Loop has the best views for the effort."),
            event(4, "turn.settled", "writer", "", extra: ["passed": .bool(true)]),
            event(5, "message.user", "desktop", "@writer a two-line invite for the group chat?"),
            event(6, "message.member", "writer", "Falls Loop, Saturday, 8 am sharp — four easy miles and a waterfall at the end.\nBring layers; coffee's on me after."),
        ]
        feed.events.append(GroupEvent(.object(["seq": .number(7), "kind": .string("room.activity"),
                                               "actor": .object(["kind": .string("system"), "id": .string("room")]),
                                               "payload": .object(["status": .string("settled"), "reason_code": .string("silent_round")])]))!)
        feed.cursor = 7
        // With -echo.demoMarks, the room waits on the person: Scout's command to approve, and a
        // reply of Quill's that stopped partway, to try again.
        if DevHooks.demoMarks {
            feed.events.append(event(8, "message.user", "desktop", "@scout check the trail report and save it to my notes"))
            feed.events.append(event(9, "turn.deferred", "writer", "", extra: ["task_id": .string("dtask:demo-writer"), "reason": .string("member_unavailable")]))
            feed.cursor = 9
            feed.state = GroupState(.object([
                "working": .bool(true),
                "pending_actions": .array([
                    .object(["kind": .string("approval"), "member_id": .string("scout"), "task_id": .string("dtask:demo-scout"),
                             "execution_generation": .number(1), "request_id": .string("demo-approval"),
                             "approval": .object(["command": .string("curl -s https://trails.example.org/falls-loop > ~/notes/falls-loop.md"),
                                                  "description": .string("Writes a file outside the working folder"),
                                                  "choices": .array([.string("once"), .string("deny")])])]),
                    .object(["kind": .string("retry"), "task_id": .string("dtask:demo-writer")]),
                ]),
            ]))
        }
        return feed
    }
}
#endif

/// The server's group chats, as last listed: for the chat list's Bots section.
@Observable
final class GroupDirectory {
    static let shared = GroupDirectory()

    private(set) var rooms: [GroupRoom] = []
    /// Hermes has group chats, and can run one now.
    private(set) var supported = false
    private(set) var writable = false
    private(set) var key = ""
    /// The group chat in the chat's place, where a conversation would be: until a conversation
    /// is opened (from the list or anywhere else), or the group chat is ended.
    var open: GroupRoom?

    func refresh(client: HermesServeClient = .shared, settings: Settings = .shared) async {
        let key = settings.connectionKey
        guard let support = try? await client.groupSupport() else { return }
        let hosted = support.supported ? ((try? await client.groupRooms()) ?? []) : []
        let desktop = ((try? await client.desktopRooms()) ?? [])
            .map { $0.naming(with: BotDirectory.shared.key == key ? BotDirectory.shared.roster : nil, mainName: settings.headerTitle) }
        guard key == settings.connectionKey else { return }
        self.rooms = (hosted + desktop).sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        supported = support.supported
        writable = support.writable
        self.key = key
    }

    func set(rooms: [GroupRoom], supported: Bool, writable: Bool, key: String) {
        self.rooms = rooms
        self.supported = supported
        self.writable = writable
        self.key = key
    }

    func forget(_ room: String) {
        rooms.removeAll { $0.id == room }
        if open?.id == room { open = nil }
    }
}

/// One room as it is followed on screen: what was said, read from its log, and what it waits on,
/// read again every second while bots are talking and every few seconds otherwise.
@Observable
final class GroupFeed {
    private(set) var room: GroupRoom
    private(set) var events: [GroupEvent] = []
    private(set) var state = GroupState()
    /// Messages sent and not in the log yet, by their event id.
    private(set) var sending: [(id: String, text: String)] = []
    /// Approvals and retries answered here and not yet gone from the state: their cards hide.
    private(set) var answering: Set<String> = []
    private(set) var problem: String?
    private var cursor = 0
    private let client: HermesServeClient
    /// Sample data that isn't followed (screenshots).
    private var isDemo = false

    init(room: GroupRoom, client: HermesServeClient = .shared) {
        self.room = room
        self.client = client
    }

    /// Bots are talking: a message of the person's has had no end of discussion after it yet.
    /// (Hermes Desktop's copy says nothing of that.)
    var discussing: Bool {
        guard !room.inDesktop else { return false }
        guard let lastAsk = events.last(where: { $0.kind == "message.user" })?.seq else { return !sending.isEmpty }
        return !sending.isEmpty || !events.contains { $0.seq > lastAsk && $0.endsDiscussion }
    }

    /// Follows the room until the task is cancelled (the screen goes).
    func follow() async {
        guard !isDemo else { return }
        while !Task.isCancelled {
            await look()
            try? await Task.sleep(for: .seconds(discussing || state.working ? 1 : 5))
        }
    }

    func look() async {
        guard !room.inDesktop else { return await lookInDesktop() }
        do {
            let fresh = try await client.groupLog(room.id, since: cursor)
            if !fresh.isEmpty {
                events += fresh
                cursor = fresh.last?.seq ?? cursor
                // A message of the person's that is now in the log isn't waiting any more.
                let said = Set(fresh.filter { $0.kind == "message.user" }.map(\.text))
                sending.removeAll { said.contains($0.text) }
                if let renamed = fresh.last(where: { $0.kind == "room.renamed" })?.payload["name"]?.string { room.name = renamed }
            }
            let (current, state) = try await client.groupState(room.id)
            // Written only when changed: each write redraws the room, every second while bots talk.
            if let current, !current.members.isEmpty, current.members != room.members { room.members = current.members }
            if state != self.state { self.state = state }
            if problem != nil { problem = nil }
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Each Hermes Desktop message's number here, by its key: the same message keeps its row.
    private var desktopSeqs: [String: Int] = [:]

    /// A Hermes Desktop room: its copy read again (Desktop writes it a moment after each message).
    private func lookInDesktop() async {
        do {
            guard let current = try await client.desktopRooms().first(where: { $0.id == room.id }) else {
                problem = "This group chat was ended in Hermes Desktop."
                return
            }
            let named = current.naming(with: BotDirectory.shared.roster, mainName: Settings.shared.headerTitle)
            if named != room { room = named }
            let fresh = Self.events(of: room, numbering: &desktopSeqs)
            if fresh != events { events = fresh }
            if problem != nil { problem = nil }
        } catch {
            problem = error.localizedDescription
        }
    }

    /// A Hermes Desktop room's copy as the log's entries the screen shows.
    static func events(of room: GroupRoom, numbering seqs: inout [String: Int]) -> [GroupEvent] {
        room.desktopMessages.map { message in
            let seq = seqs[message.key] ?? ((seqs.values.max() ?? 0) + 1)
            seqs[message.key] = seq
            return GroupEvent(seq: seq, kind: message.fromPerson ? "message.user" : "message.member",
                              actorKind: message.fromPerson ? "user" : "member", actorID: message.profile,
                              payload: .object(["text": .string(message.text)]), createdAt: message.at)
        }
    }

    func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let id = UUID().uuidString
        sending.append((id, text))
        Task {
            do {
                try await client.sendToGroup(room.id, text: text, eventID: id)
                await look()
            } catch {
                sending.removeAll { $0.id == id }
                problem = "Couldn't send: \(error.localizedDescription)"
            }
        }
    }

    func stop() {
        Task {
            do {
                try await client.stopGroup(room.id)
                await look()
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    func answer(_ approval: GroupApproval, _ choice: String) {
        settle(approval.id) { try await $0.answerGroupApproval(self.room.id, approval, choice: choice) }
    }

    func retry(_ task: String) {
        settle(task) { try await $0.retryGroupTask(self.room.id, task: task) }
    }

    /// Answers one of the room's questions, its card hidden meanwhile. Refused as no longer
    /// pending (answered elsewhere, or it timed out), the room is read again and the card goes.
    private func settle(_ id: String, _ call: @escaping (HermesServeClient) async throws -> Void) {
        guard !answering.contains(id) else { return }
        answering.insert(id)
        Task {
            do {
                try await call(client)
                await look()
            } catch let error as HermesServeClient.RPCError where error.code == 5119 || error.code == 5118 {
                await look()
            } catch {
                problem = error.localizedDescription
            }
            answering.remove(id)
        }
    }

    /// The bot whose task this is, by the room's log (a turn's end names it), if it has said.
    func member(forTask task: String) -> GroupMember? {
        events.last { $0.payload["task_id"]?.string == task && $0.actorID != nil }.flatMap { room.member($0.actorID) }
    }

    func rename(to name: String) async throws {
        try await client.renameGroup(room.id, to: name)
        room.name = name
        await look()
    }
}
