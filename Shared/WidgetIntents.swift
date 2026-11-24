import AppIntents
import Foundation
import WidgetKit

// The widgets' buttons (`WidgetAction`): Live Activity intents, so iOS runs them in the app, which
// does what the same button in Redde does and tells the Hermes. Compiled into the widgets too,
// which only name them on their buttons. Not offered to Shortcuts or Siri.

struct TickListItemIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Tick an Item"
    static let isDiscoverable = false

    @Parameter(title: "List") var list: String
    @Parameter(title: "Item") var item: String
    @Parameter(title: "Done") var done: Bool

    init() {}
    init(list: String, item: String, done: Bool) {
        self.list = list
        self.item = item
        self.done = done
    }

    func perform() async throws -> some IntentResult {
        let action = WidgetAction.tick(list: list, item: item, done: done)
        await WidgetActions.perform(action)
        return .result()
    }
}

struct AnswerFromWidgetIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Answer"
    static let isDiscoverable = false

    @Parameter(title: "Request") var request: String
    @Parameter(title: "Choice") var choice: String

    init() {}
    init(request: String, choice: String) {
        self.request = request
        self.choice = choice
    }

    func perform() async throws -> some IntentResult {
        let action = WidgetAction.answer(request: request, choice: choice)
        await WidgetActions.perform(action)
        return .result()
    }
}

struct IdeaNotNowIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Not Now"
    static let isDiscoverable = false

    @Parameter(title: "Idea") var idea: String

    init() {}
    init(idea: String) { self.idea = idea }

    func perform() async throws -> some IntentResult {
        let action = WidgetAction.notNow(idea: idea)
        await WidgetActions.perform(action)
        return .result()
    }
}

struct TickGoalStepIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Tick a Step"
    static let isDiscoverable = false

    @Parameter(title: "Goal") var goal: String
    @Parameter(title: "Step") var index: Int
    @Parameter(title: "Done") var done: Bool

    init() {}
    init(goal: String, index: Int, done: Bool) {
        self.goal = goal
        self.index = index
        self.done = done
    }

    func perform() async throws -> some IntentResult {
        let action = WidgetAction.step(goal: goal, index: index, done: done)
        await WidgetActions.perform(action)
        return .result()
    }
}

/// Remind Me in 10 on Up Next's way out: a notification ten minutes on.
struct RemindToLeaveIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Remind Me in 10"
    static let isDiscoverable = false

    @Parameter(title: "Event") var event: String
    @Parameter(title: "Starts") var start: Date

    init() {}
    init(event: String, start: Date) {
        self.event = event
        self.start = start
    }

    func perform() async throws -> some IntentResult {
        let action = WidgetAction.remind(title: event, start: start)
        await WidgetActions.perform(action)
        return .result()
    }
}

// MARK: - Which list, which goal

nonisolated struct ListEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "List"
    static let defaultQuery = ListQuery()

    var id: String
    var title: String
    var emoji: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(emoji.map { $0 + " " } ?? "")\(title)")
    }
}

nonisolated struct ListQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ListEntity] {
        TodayList.kept().filter { identifiers.contains($0.id) }.map(\.entity)
    }
    func suggestedEntities() async throws -> [ListEntity] { TodayList.kept().map(\.entity) }
    func defaultResult() async -> ListEntity? { TodayList.pick(TodayList.kept())?.entity }
}

nonisolated extension TodayList {
    var entity: ListEntity { ListEntity(id: id, title: title, emoji: emoji) }
}

struct ListWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "List"
    static let description = IntentDescription("Pick the list the widget shows.")
    static let isDiscoverable = false

    @Parameter(title: "List") var list: ListEntity?

    init() {}
    init(list: ListEntity?) { self.list = list }
}

nonisolated struct GoalEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Goal"
    static let defaultQuery = GoalQuery()

    var id: String
    var title: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

nonisolated struct GoalQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [GoalEntity] {
        GoalReport.showing().filter { identifiers.contains($0.id) }.map(\.entity)
    }
    func suggestedEntities() async throws -> [GoalEntity] { GoalReport.showing().map(\.entity) }
    func defaultResult() async -> GoalEntity? { GoalReport.pick(GoalReport.showing())?.entity }
}

nonisolated extension GoalReport {
    var entity: GoalEntity { GoalEntity(id: id, title: title) }

    /// The goal a widget shows when none was picked: one not done, its next step yours first.
    static func pick(_ goals: [GoalReport]) -> GoalReport? {
        let going = goals.filter { !$0.isComplete }
        return going.first { $0.nextForYou != nil } ?? going.first ?? goals.first
    }
}

struct GoalWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Goal"
    static let description = IntentDescription("Pick the goal the widget shows.")
    static let isDiscoverable = false

    @Parameter(title: "Goal") var goal: GoalEntity?

    init() {}
    init(goal: GoalEntity?) { self.goal = goal }
}
