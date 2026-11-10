import Foundation
import Testing
@testable import Echo

/// Every Kanban column shows its newest card first, whatever order the server sends (2026-11-09).
struct KanbanOrderTests {
    private func card(_ id: String, made: Double?) -> KanbanTask? {
        var fields: [String: JSONValue] = ["id": .string(id), "title": .string(id), "status": .string("todo")]
        if let made { fields["created_at"] = .number(made) }
        return KanbanTask(.object(fields))
    }

    @Test func newestFirst() {
        let tasks = [card("old", made: 100), card("undated", made: nil), card("new", made: 300), card("mid", made: 200),
                     card("tie-a", made: 50), card("tie-b", made: 50)].compactMap(\.self)
        let column = KanbanColumn(name: "todo", tasks: tasks)
        #expect(column.tasks.map(\.id) == ["new", "mid", "old", "tie-a", "tie-b", "undated"])
    }

    /// Hermes keeps several boards and every route says which with `?board=` (GitHub issue 65: only
    /// the current one could be seen). With none named, the route is left as it was: the board
    /// current on the server, which the rest of Redde works on.
    @Test func aRouteNamesItsBoard() {
        #expect(KanbanClient.path("board", board: nil) == "api/plugins/kanban/board")
        #expect(KanbanClient.path("board", board: "") == "api/plugins/kanban/board")
        #expect(KanbanClient.path("tasks/t_1", board: "garden") == "api/plugins/kanban/tasks/t_1?board=garden")
        #expect(KanbanClient.path("dispatch", board: "a&b=c") == "api/plugins/kanban/dispatch?board=a%26b%3Dc")
    }

    /// `GET /boards` as Hermes 2026.8.31 to 0.22.7 answer it (`list_boards` + `is_current`, `total`).
    @Test func theBoardsHermesKeeps() throws {
        let listed = try JSONDecoder().decode(JSONValue.self, from: Data("""
            {"current": "default", "boards": [
              {"slug": "default", "name": "Default", "description": "", "icon": "", "archived": false, "is_current": true, "total": 11, "counts": {"todo": 5}},
              {"slug": "garden", "name": " Garden ", "icon": "🌱", "archived": false, "is_current": false, "total": 2},
              {"slug": "nameless", "name": "", "is_current": false},
              {"slug": "old", "name": "Old", "archived": true, "total": 40}]}
            """.utf8))
        let boards = (listed["boards"]?.array ?? []).compactMap(KanbanClient.BoardInfo.init)
        #expect(boards.map(\.slug) == ["default", "garden", "nameless"], "an archived board isn't offered")
        #expect(boards.map(\.name) == ["Default", "Garden", "nameless"])
        #expect(boards.map(\.total) == [11, 2, 0] && boards.map(\.isCurrent) == [true, false, false])
    }
}
