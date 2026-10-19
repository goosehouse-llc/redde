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

    init?(_ json: JSONValue) {
        guard let id = json["room_id"]?.string else { return nil }
        self.id = id
        name = json["name"]?.string ?? id
        members = (json["members"]?.array ?? []).compactMap(GroupMember.init)
        updatedAt = json["updated_at"]?.number.map { Date(timeIntervalSince1970: $0) }
        latestSeq = json["latest_seq"]?.int
    }

    func member(_ id: String?) -> GroupMember? { members.first { $0.id == id } }
}

/// One entry of a room's log.
nonisolated struct GroupEvent: Identifiable, Equatable, Sendable {
    var seq: Int
    var kind: String
    /// "user" or "member" (or "system", "gateway").
    var actorKind: String
    /// The member's id, for a member's entry.
    var actorID: String?
    var payload: JSONValue
    var createdAt: Date

    var id: Int { seq }
    var text: String { payload["text"]?.string ?? "" }

    init?(_ json: JSONValue) {
        guard let seq = json["seq"]?.int, let kind = json["kind"]?.string else { return nil }
        self.seq = seq
        self.kind = kind
        actorKind = json["actor"]?["kind"]?.string ?? ""
        actorID = json["actor"]?["id"]?.string ?? json["payload"]?["member_id"]?.string
        payload = json["payload"] ?? .null
        createdAt = json["created_at"]?.number.map { Date(timeIntervalSince1970: $0) } ?? .now
    }

    /// Something someone said: the person, or a bot.
    var isMessage: Bool { kind == "message.user" || kind == "message.member" }

    /// A discussion is over: it ran its course or hit its limit (`room.activity`), or was stopped.
    var endsDiscussion: Bool { kind == "room.activity" || kind == "room.stop_requested" }

    /// A line about the room rather than something said, or nil when it isn't worth a line.
    func note(in room: GroupRoom) -> String? {
        let who = room.member(actorID ?? payload["member_id"]?.string)?.label ?? "A bot"
        switch kind {
        case "turn.settled": return payload["passed"]?.bool == true ? "\(who) passed" : nil
        case "turn.failed": return "\(who) couldn't answer" + (payload["error"]?.string.map { ": \($0)" } ?? "")
        case "turn.cancelled": return payload["reason"]?.string == "superseded_by_newer_user_event" ? nil : "\(who) was stopped"
        case "room.activity": return payload["status"]?.string == "bounded" ? "That's as long as a round goes. Say something to carry on." : nil
        case "room.renamed": return payload["name"]?.string.map { "Renamed “\($0)”" }
        default: return nil
        }
    }
}

/// What a room waits on, and whether a bot is at work.
nonisolated struct GroupState: Equatable, Sendable {
    var working = false
    var blocked = false
    var approvals: [GroupApproval] = []

    init(working: Bool = false, blocked: Bool = false, approvals: [GroupApproval] = []) {
        self.working = working
        self.blocked = blocked
        self.approvals = approvals
    }

    init(_ status: JSONValue?) {
        working = status?["working"]?.bool ?? false
        blocked = status?["blocked"]?.bool ?? false
        approvals = (status?["pending_actions"]?.array ?? []).compactMap(GroupApproval.init)
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

extension GroupFeed {
    /// The demo room with a short exchange in it, not followed.
    static func demo() -> GroupFeed {
        let feed = GroupFeed(room: .demo)
        feed.isDemo = true
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

    func refresh(client: HermesServeClient = .shared, settings: Settings = .shared) async {
        let key = settings.connectionKey
        guard let support = try? await client.groupSupport() else { return }
        let rooms = support.supported ? ((try? await client.groupRooms()) ?? []) : []
        guard key == settings.connectionKey else { return }
        self.rooms = rooms.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
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

    func forget(_ room: String) { rooms.removeAll { $0.id == room } }
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
    var discussing: Bool {
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
            if let current { room.members = current.members.isEmpty ? room.members : current.members }
            self.state = state
            problem = nil
        } catch {
            problem = error.localizedDescription
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
        Task {
            do {
                try await client.answerGroupApproval(room.id, approval, choice: choice)
                await look()
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    func rename(to name: String) async throws {
        try await client.renameGroup(room.id, to: name)
        room.name = name
        await look()
    }
}
