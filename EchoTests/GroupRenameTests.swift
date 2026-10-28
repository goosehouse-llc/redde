import Foundation
import Testing
@testable import Echo

/// Renaming a group chat (asked 2026-10-28: from its row in the chat list too, not only from the
/// chat's own menu): the list and the open chat show the new name at once, not at the next
/// listing, on either connection, the room being Hermes's.
@MainActor
struct GroupRenameTests {
    private func room(_ id: String, _ name: String) -> GroupRoom {
        GroupRoom(.object(["room_id": .string(id), "name": .string(name)]))!
    }

    @Test func theListAndTheOpenChatShowTheNewName() {
        let groups = GroupDirectory()
        groups.set(rooms: [room("a", "Weekend hike"), room("b", "Garden")], supported: true, writable: true, key: "k")
        groups.open = room("a", "Weekend hike")
        groups.renamed("a", to: "Mountain weekend")
        #expect(groups.rooms.map(\.name) == ["Mountain weekend", "Garden"])
        #expect(groups.open?.name == "Mountain weekend")
        // Another room's rename leaves the open one alone.
        groups.renamed("b", to: "Allotment")
        #expect(groups.rooms.map(\.name) == ["Mountain weekend", "Allotment"] && groups.open?.name == "Mountain weekend")
        groups.renamed("gone", to: "Nothing")
        #expect(groups.rooms.count == 2)
    }

    @Test func anOpenChatFollowsARenameFromTheList() {
        let feed = GroupFeed(room: room("a", "Weekend hike"))
        feed.named("Mountain weekend")
        #expect(feed.room.name == "Mountain weekend")
    }
}
