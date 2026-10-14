import Foundation
import WidgetKit

/// The widget tools: the agent writes a title and a few lines onto Redde's "From Your Agent"
/// widget, for now or for a moment later in the day, and takes them off again (`AgentBoard`).
/// Nothing is read from the phone and nothing on it is changed but Redde's own widget, so
/// these are not asked about one by one once the area is allowed.
nonisolated struct DeviceBoard: Sendable {
    /// The App Group's defaults by name, so tests can use a suite of their own.
    var suite: String? = PushVault.group
    /// Tells iOS the widget has something new, and says whether one is on a screen at all.
    var reload: @Sendable () async -> Bool = {
        WidgetCenter.shared.reloadTimelines(ofKind: AgentBoard.widgetKind)
        return ((try? await WidgetCenter.shared.currentConfigurations()) ?? []).contains { $0.kind == AgentBoard.widgetKind }
    }

    private var defaults: UserDefaults? { suite.flatMap(UserDefaults.init(suiteName:)) }

    /// `text` and optionally `title`, `at` (from when; now without it) and `until`.
    func set(_ args: JSONValue, now: Date = .now) async throws -> JSONValue {
        let title = args["title"]?.string ?? ""
        let text = args["text"]?.string ?? ""
        guard !(title + text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DeviceToolError.missing("text") }
        let from = try args.date("at") ?? now
        let until = try args.date("until")
        if let until, until <= max(from, now) { throw DeviceToolError("\"until\" has to be after it starts, and not in the past: it is \(DeviceDates.string(now)) on the phone.") }
        let board = AgentBoard(title: title, text: text, from: from, until: until)
        AgentBoard.put(board, at: now, in: defaults)
        return await answer(now: now, set: board)
    }

    func clear(_ args: JSONValue, now: Date = .now) async throws -> JSONValue {
        AgentBoard.clear(in: defaults)
        return await answer(now: now, set: nil)
    }

    /// What the widget shows now and what waits to, so the agent sees what it did; and whether
    /// the person has the widget on a screen at all, which only they can do.
    private func answer(now: Date, set: AgentBoard?) async -> JSONValue {
        let onScreen = await reload()
        let kept = AgentBoard.all(in: defaults)
        var fields: [String: JSONValue] = [
            "showing": AgentBoard.showing(at: now, among: kept).map(describe) ?? .null,
            "later": .array(kept.filter { $0.from > now }.map(describe)),
            "widget_on_a_screen": .bool(onScreen),
        ]
        if let set, set.title.count == AgentBoard.titleLimit || set.text.count == AgentBoard.textLimit {
            fields["note"] = .string("It was cut to fit: a title holds \(AgentBoard.titleLimit) characters and the text \(AgentBoard.textLimit).")
        }
        if !onScreen {
            fields["widget"] = .string("The person hasn't added Redde's \"From Your Agent\" widget to their Home Screen or Lock Screen yet. It is kept and shows once they do.")
        }
        return .object(fields)
    }

    private func describe(_ board: AgentBoard) -> JSONValue {
        var fields: [String: JSONValue] = ["title": .string(board.title), "text": .string(board.text), "from": .string(DeviceDates.string(board.from))]
        if let until = board.until { fields["until"] = .string(DeviceDates.string(until)) }
        return .object(fields)
    }
}
