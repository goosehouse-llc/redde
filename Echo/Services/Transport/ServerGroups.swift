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

/// A bot's reply in a room as it is being written. Hermes writes a reply to the room only once it
/// is finished; meanwhile it is in the bot's own session for the room, a hidden one on the bot's
/// profile titled "Group: <room>", whose last events Hermes keeps for a client that reconnects
/// (`session.events.since`, every release). That is where it is read. The session is never resumed
/// or activated: either would tie it to this phone, and Hermes puts away a session whose phone has
/// gone, mid-reply. It is in the Dashboard's list of live sessions only while the Dashboard's
/// process runs the room (Hermes's gateway can run it instead); then replies show when finished.
nonisolated struct GroupDraft: Identifiable, Equatable, Sendable {
    /// The live session's id.
    var id: String
    /// The bot writing it, once its session is found on its profile.
    var memberID: String?
    var text = ""
    /// When the bot's session finished the reply: it shows until the room has it.
    var finishedAt: Date?
    /// The room log's last event when it began: the bot's message after that takes its place.
    var after: Int
    var began = Date.now

    /// The title Hermes gives a bot's session for a room.
    static func sessionTitle(_ room: String) -> String { "Group: " + room }

    /// `events` (from `session.events.since`, oldest first) read onto the draft: a reply starts over
    /// at each `message.start`, and at each `message.interim` (what a bot wrote beside a tool call,
    /// which the reply in the room leaves out), grows by each `message.delta`, and is whole at
    /// `message.complete`. True when a reply's start was among them.
    @discardableResult
    mutating func read(_ events: [JSONValue]) -> Bool {
        var started = false
        for event in events {
            switch event["type"]?.string {
            case "message.start":
                (text, finishedAt, started) = ("", nil, true)
            case "message.interim":
                text = ""
            case "message.delta":
                text += event["payload"]?["text"]?.string ?? ""
            case "message.complete":
                if let whole = event["payload"]?["text"]?.string, !whole.isEmpty { text = whole }
                finishedAt = .now
            default:
                break
            }
        }
        return started
    }
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

    /// The live sessions a room's bots are run in (`GroupDraft`), with their state ("working",
    /// "starting", "waiting", "idle"): from `session.active_list`, which lists every live session in
    /// the Dashboard's process, hidden ones too.
    func groupLiveSessions(_ room: String) async throws -> [(id: String, key: String, status: String)] {
        try await ensureConnected()
        let result = try await call("session.active_list", params: .object([:]), timeout: 15)
        let title = GroupDraft.sessionTitle(room)
        return (result["sessions"]?.array ?? []).compactMap { row in
            guard row["title"]?.string == title, let id = row["id"]?.string else { return nil }
            return (id, row["session_key"]?.string ?? "", row["status"]?.string ?? "")
        }
    }

    /// A bot's session for a room, by its title on the bot's profile: its stored id (the latest
    /// part, once Hermes has compressed it), which its live session goes by.
    func groupMemberSession(_ room: String, profile: String) async throws -> String? {
        let title = GroupDraft.sessionTitle(room)
        let result = try await call("session.list", params: .object([
            "profile": .string(profile), "title": .string(title), "include_hidden": .bool(true), "limit": .number(20)]))
        guard let row = (result["sessions"]?.array ?? []).first(where: { $0["title"]?.string == title }) else { return nil }
        return row["resolved_id"]?.string?.nilIfEmpty ?? row["id"]?.string
    }

    /// What a live session has sent after event `since`, as Hermes keeps it for a client that
    /// reconnects: `truncated` when some in between are gone (it keeps the last 512).
    func sessionEvents(_ session: String, since: Int) async throws -> (events: [JSONValue], latest: Int, truncated: Bool) {
        let result = try await call("session.events.since", params: .object([
            "session_id": .string(session), "last_seen": .number(Double(since))]))
        return (result["events"]?.array ?? [], result["latest_seq"]?.int ?? since, result["truncated"]?.bool ?? false)
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

    /// `-echo.demoDraft`: Scout's reply written into the demo room a few words at a time, then
    /// finished (the room's live reply, for screenshots and recording).
    func playDemoDraft() async {
        events.append(GroupEvent(seq: 8, kind: "message.user", actorKind: "user", actorID: nil,
                                 payload: .object(["text": .string("@scout is Falls Loop open this weekend?")]), createdAt: .now))
        cursor = 8
        try? await Task.sleep(for: .seconds(1))
        state = GroupState(working: true)
        var draft = GroupDraft(id: "demo-draft", memberID: "scout", after: cursor)
        let words = "Yes. The ranger update from this morning says Falls Loop is open; it's muddy past the second footbridge, so wear boots. Parking fills by 9 on Saturdays.".split(separator: " ")
        for word in words {
            try? await Task.sleep(for: .milliseconds(220))
            draft.text += (draft.text.isEmpty ? "" : " ") + word
            drafts = [draft]
        }
        try? await Task.sleep(for: .seconds(1))
        events.append(GroupEvent(seq: 9, kind: "message.member", actorKind: "member", actorID: "scout",
                                 payload: .object(["text": .string(draft.text)]), createdAt: .now))
        // The round's end, as Hermes writes it.
        events.append(GroupEvent(seq: 10, kind: "room.activity", actorKind: "system", actorID: nil,
                                 payload: .object(["status": .string("settled")]), createdAt: .now))
        drafts = []
        state = GroupState()
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
    /// Replies being written now (`GroupDraft`), each until the room has it.
    private(set) var drafts: [GroupDraft] = []
    /// Each live session's last event read.
    private var draftSeen: [String: Int] = [:]
    /// The bots' sessions for this room, by stored id: whose a live one is.
    private var memberSessions: [String: String] = [:]
    private var lookedForMembers: Date?
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
        guard !isDemo else {
            #if DEBUG
            if DevHooks.has("-echo.demoDraft") { await playDemoDraft() }
            #endif
            return
        }
        // While bots talk: the replies being written twice a second, the room once a second.
        var tick = 0
        while !Task.isCancelled {
            let busy = discussing || state.working
            if !busy || tick.isMultiple(of: 2) { await look() }
            await lookAtDrafts()
            tick += 1
            try? await Task.sleep(for: busy ? .milliseconds(500) : .seconds(5))
        }
    }

    /// The bots' replies as they are written (`GroupDraft`), while the room is at work.
    func lookAtDrafts() async {
        guard !room.inDesktop else { return }
        let busy = discussing || state.working
        // A reply goes once the room has it; a finished one the room never wrote (a bot that
        // passed), after a while; one still being written, when the room stops.
        let kept = drafts.filter { draft in
            if events.contains(where: { $0.kind == "message.member" && $0.seq > draft.after && (draft.memberID == nil || $0.actorID == draft.memberID) }) { return false }
            if let done = draft.finishedAt { return Date.now.timeIntervalSince(done) < 20 }
            return busy
        }
        if kept != drafts { drafts = kept }
        guard busy, let live = try? await client.groupLiveSessions(room.id) else { return }
        var next = drafts
        for session in live {
            let index = next.firstIndex { $0.id == session.id }
            // A session at work, or one whose reply is still being followed.
            guard ["working", "starting"].contains(session.status) || index.map({ next[$0].finishedAt == nil }) == true else { continue }
            if memberSessions[session.key] == nil { await findMemberSessions() }
            let first = draftSeen[session.id] == nil
            guard let read = try? await client.sessionEvents(session.id, since: draftSeen[session.id] ?? 0) else { continue }
            draftSeen[session.id] = read.latest
            var draft = index.map { next[$0] } ?? GroupDraft(id: session.id, after: cursor)
            draft.memberID = memberSessions[session.key]
            // Read first after its start was let go (Hermes keeps the last 512 events): the rest of it.
            if !draft.read(read.events), first, read.truncated, !draft.text.isEmpty { draft.text = "…" + draft.text }
            if let index { next[index] = draft } else if draft.finishedAt == nil || !draft.text.isEmpty { next.append(draft) }
        }
        if next != drafts { drafts = next }
    }

    /// Which bot each of the room's live sessions is: each bot's session for the room, by its title
    /// on the bot's profile. Not more than once every few seconds.
    private func findMemberSessions() async {
        if let last = lookedForMembers, Date.now.timeIntervalSince(last) < 5 { return }
        lookedForMembers = .now
        for member in room.members {
            if let key = try? await client.groupMemberSession(room.id, profile: member.profile) { memberSessions[key] = member.id }
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
