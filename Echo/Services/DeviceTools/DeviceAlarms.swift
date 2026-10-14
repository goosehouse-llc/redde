import AlarmKit
import Foundation
import SwiftUI

/// What the alarms tools need of iOS: AlarmKit in the app, a stand-in in tests.
nonisolated protocol AlarmSetting: Sendable {
    /// Whether iOS lets Redde set alarms, asking the person the first time.
    func allowed() async -> Bool
    /// An alarm that rings at a moment.
    func ring(id: UUID, title: String, at date: Date) async throws
    /// A timer that counts down from now and then rings.
    func count(id: UUID, title: String, down seconds: TimeInterval) async throws
    func cancel(id: UUID) throws
    /// The alarms and timers iOS still holds for Redde: the ones yet to ring.
    func held() throws -> [UUID]
}

/// The alarms tools: an alarm at a time of day or a timer from now, set with AlarmKit, so it
/// rings like the Clock app's: through silent mode and a Focus, with Redde open or not. Redde
/// sees and cancels only what it set; iOS shows no app the Clock app's alarms.
nonisolated struct DeviceAlarms: Sendable {
    var system: any AlarmSetting = SystemAlarms()
    /// Where the titles are kept: iOS hands back an alarm's id and state, not what it was for.
    var file: URL = .applicationSupportDirectory.appending(path: "phone-alarms.json")

    /// The longest timer: a day. Past that it is an alarm with a date.
    static let longestTimer: TimeInterval = 24 * 3600

    nonisolated struct Kept: Codable, Equatable, Sendable {
        var id: UUID
        var title: String
        var rings: Date
        var timer: Bool
    }

    /// `title`, and `at` (a moment) or `minutes` (a timer from now): one of the two.
    func set(_ args: JSONValue, now: Date = .now) async throws -> JSONValue {
        guard await system.allowed() else { throw DeviceToolError.refused(.alarms) }
        let title = String(try args.required("title").prefix(80))
        let minutes = args["minutes"]?.number
        let at = try args.date("at")
        var kept = Kept(id: UUID(), title: title, rings: now, timer: minutes != nil)
        do {
            switch (at, minutes) {
            case (nil, nil), (.some, .some):
                throw DeviceToolError("Give \"at\" for an alarm at a time, or \"minutes\" for a timer from now: one of the two.")
            case let (at?, nil):
                if let text = args["at"]?.string, DeviceDates.isDayOnly(text) { throw DeviceToolError("\"at\" needs a time of day, like 2026-10-14T06:10.") }
                guard at > now else { throw DeviceToolError("That time has passed: it is \(DeviceDates.string(now)) on the phone.") }
                kept.rings = at
                try await system.ring(id: kept.id, title: title, at: at)
            case let (nil, minutes?):
                let seconds = minutes * 60
                guard seconds >= 1, seconds <= Self.longestTimer else { throw DeviceToolError("A timer runs from a second to a day. For later than that, set an alarm with \"at\".") }
                kept.rings = now.addingTimeInterval(seconds)
                try await system.count(id: kept.id, title: title, down: seconds)
            }
        } catch let error as DeviceToolError {
            throw error
        } catch AlarmManager.AlarmError.maximumLimitReached {
            throw DeviceToolError("The iPhone won't hold any more alarms from Redde. Cancel one first.")
        } catch {
            throw DeviceToolError("The \(kept.timer ? "timer" : "alarm") couldn't be set: \(error.localizedDescription)")
        }
        save(load() + [kept])
        return .object(["set": describe(kept)])
    }

    /// The ones yet to ring, soonest first.
    func list(_ args: JSONValue) async throws -> JSONValue {
        guard await system.allowed() else { throw DeviceToolError.refused(.alarms) }
        return .object(["alarms": .array(try waiting().map(describe))])
    }

    /// `id`, as a list or a set gave it.
    func cancel(_ args: JSONValue) async throws -> JSONValue {
        guard await system.allowed() else { throw DeviceToolError.refused(.alarms) }
        let id = try args.required("id")
        guard let kept = try waiting().first(where: { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame }) else {
            throw DeviceToolError("There is no alarm or timer with that id. It may have rung already.")
        }
        do { try system.cancel(id: kept.id) } catch { throw DeviceToolError("It couldn't be cancelled: \(error.localizedDescription)") }
        save(load().filter { $0.id != kept.id })
        return .object(["cancelled": describe(kept)])
    }

    /// What Redde set and iOS still holds. One that has rung, or was stopped on the phone, is
    /// gone from iOS, and is forgotten here.
    private func waiting() throws -> [Kept] {
        let held: Set<UUID>
        do { held = Set(try system.held()) } catch { throw DeviceToolError("The iPhone's alarms couldn't be read: \(error.localizedDescription)") }
        let all = load()
        let still = all.filter { held.contains($0.id) }
        if still.count != all.count { save(still) }
        return still.sorted { $0.rings < $1.rings }
    }

    private func describe(_ kept: Kept) -> JSONValue {
        .object(["id": .string(kept.id.uuidString), "title": .string(kept.title), "kind": .string(kept.timer ? "timer" : "alarm"),
                 "rings": .string(DeviceDates.string(kept.rings))])
    }

    private func load() -> [Kept] {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Kept].self, from: $0) } ?? []
    }

    private func save(_ kept: [Kept]) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(kept).write(to: file, options: .atomic)
    }
}

/// AlarmKit. The alert when one rings is iOS's own, with its Stop button; a timer's countdown
/// on the Lock Screen and in the Dynamic Island is drawn by `AlarmCountdownActivity`.
nonisolated struct SystemAlarms: AlarmSetting {
    func allowed() async -> Bool {
        switch AlarmManager.shared.authorizationState {
        case .authorized: true
        case .notDetermined: (try? await AlarmManager.shared.requestAuthorization()) == .authorized
        default: false
        }
    }

    func ring(id: UUID, title: String, at date: Date) async throws {
        let attributes = AlarmAttributes(presentation: AlarmPresentation(alert: Self.alert(title)),
                                         metadata: AgentAlarm(title: title), tintColor: .accentColor)
        _ = try await AlarmManager.shared.schedule(id: id, configuration: .alarm(schedule: .fixed(date), attributes: attributes))
    }

    func count(id: UUID, title: String, down seconds: TimeInterval) async throws {
        let presentation = AlarmPresentation(alert: Self.alert(title), countdown: .init(title: "\(title)"))
        let attributes = AlarmAttributes(presentation: presentation, metadata: AgentAlarm(title: title), tintColor: .accentColor)
        _ = try await AlarmManager.shared.schedule(id: id, configuration: .timer(duration: seconds, attributes: attributes))
    }

    func cancel(id: UUID) throws { try AlarmManager.shared.cancel(id: id) }

    func held() throws -> [UUID] { try AlarmManager.shared.alarms.map(\.id) }

    /// What shows when it rings. iOS 26.0 wants to be handed the Stop button it draws anyway.
    private static func alert(_ title: String) -> AlarmPresentation.Alert {
        if #available(iOS 26.1, *) { return .init(title: "\(title)") }
        return .init(title: "\(title)", stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle"))
    }
}
