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
}
