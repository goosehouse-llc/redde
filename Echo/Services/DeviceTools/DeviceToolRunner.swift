import Foundation
import UIKit

/// Carries out one phone tool and gives back what it found or did, as the JSON the agent reads.
/// The permission questions (is the area on, does the person have to be asked) are settled
/// before this is called (`DeviceToolsService`).
nonisolated struct DeviceToolRunner: Sendable {
    var files = DeviceFiles()
    var alarms = DeviceAlarms()
    var board = DeviceBoard()
    var people = DevicePeople()

    func run(_ tool: DeviceTool, _ args: JSONValue, info: JSONValue = .object([:])) async throws -> JSONValue {
        switch tool {
        case .info: info
        case .calendarEvents: try await DeviceCalendar.events(args)
        case .calendarAdd: try await DeviceCalendar.addEvent(args)
        case .remindersList: try await DeviceCalendar.reminders(args)
        case .remindersAdd: try await DeviceCalendar.addReminder(args)
        case .remindersComplete: try await DeviceCalendar.completeReminder(args)
        case .contactsSearch: try await DeviceContacts.search(args)
        case .photosSearch: try await DevicePhotos.search(args)
        case .photosGet: try await DevicePhotos.get(args)
        case .photosDelete: try await DevicePhotos.delete(args)
        case .filesList: try files.list(args)
        case .filesRead: try files.read(args)
        case .filesWrite: try files.write(args)
        case .filesDelete: try files.delete(args)
        case .alarmsSet: try await alarms.set(args)
        case .alarmsList: try await alarms.list(args)
        case .alarmsCancel: try await alarms.cancel(args)
        case .widgetSet: try await board.set(args)
        case .widgetClear: try await board.clear(args)
        // A name is looked up in Contacts, which is for the person to have turned on.
        case .peopleCall: try await people.call(args, contactsOn: info["areas"]?[DeviceArea.contacts.rawValue]?.string?.hasPrefix("on") == true)
        case .peopleMessage: try await people.message(args, contactsOn: info["areas"]?[DeviceArea.contacts.rawValue]?.string?.hasPrefix("on") == true)
        }
    }
}

/// What the person is asked before a tool runs, and what the log says it was: one line of what,
/// one of which. Written from the arguments alone, so it can be shown before anything is touched.
nonisolated struct DeviceAsk: Equatable, Sendable {
    var title: String
    var detail: String

    init(_ tool: DeviceTool, _ args: JSONValue) {
        func quoted(_ name: String) -> String? { args[name]?.string?.nilIfEmpty.map { "“\(String($0.prefix(80)))”" } }
        func day(_ name: String) -> String? {
            guard let text = args[name]?.string, let date = DeviceDates.parse(text) else { return nil }
            return DeviceDates.isDayOnly(text) ? date.formatted(.dateTime.weekday(.wide).month(.wide).day()) : DeviceDates.spoken(date)
        }
        /// "From Monday to Friday"; `inside` a sentence, without the capital.
        func span(inside: Bool = false) -> String? {
            switch (day("start"), day("end")) {
            case let (from?, to?): "\(inside ? "from" : "From") \(from) to \(to)"
            case let (from?, nil): "\(inside ? "from" : "From") \(from)"
            case let (nil, to?): "\(inside ? "up" : "Up") to \(to)"
            case (nil, nil): nil
            }
        }
        switch tool {
        case .info:
            title = "See what this iPhone allows"; detail = "The time here, and which phone tools are on"
        case .calendarEvents:
            title = "Look at your calendar"
            detail = [span() ?? "The coming week", quoted("query").map { "matching \($0)" }].compactMap { $0 }.joined(separator: ", ")
        case .calendarAdd:
            title = "Add an event to your calendar"
            detail = [quoted("title"), day("start")].compactMap { $0 }.joined(separator: ", ")
        case .remindersList:
            title = "Read your reminders"
            detail = quoted("list").map { "The list \($0)" } ?? "Every list"
        case .remindersAdd:
            title = "Add a reminder"
            detail = [quoted("title"), day("due").map { "due \($0)" }].compactMap { $0 }.joined(separator: ", ")
        case .remindersComplete:
            title = "Mark a reminder as done"; detail = "One reminder"
        case .contactsSearch:
            title = "Look up a contact"; detail = quoted("query") ?? ""
        case .photosSearch:
            title = "Look through your photos"
            let kind = switch args["kind"]?.string?.lowercased() ?? "" {
            case "screenshot", "screenshots": "Screenshots"
            case "video", "videos": "Videos"
            case "photo", "photos": "Photos"
            default: "Photos and videos"
            }
            let which = [kind, span(inside: true)].compactMap { $0 }.joined(separator: " ")
            // Found by what they show, the agent is told what the phone made out in each.
            detail = if let words = quoted("query") { "\(which) that match \(words): what each shows and says, not the pictures" }
            else { "\(which): when each was taken, not the pictures" }
        case .photosGet:
            title = "Look at one of your photos"; detail = "The picture is sent to your server"
        case .photosDelete:
            let count = args["ids"]?.array?.count ?? 0
            title = "Delete \(count == 1 ? "a photo" : "\(count) photos")"; detail = "iOS shows them and asks you"
        case .filesList:
            title = "See what is in Redde's folder"; detail = quoted("path") ?? "Files › On My iPhone › Redde"
        case .filesRead:
            title = "Read a file in Redde's folder"; detail = quoted("path") ?? ""
        case .filesWrite:
            title = "Save a file to Redde's folder"; detail = quoted("path") ?? ""
        case .filesDelete:
            title = "Delete from Redde's folder"; detail = quoted("path") ?? ""
        case .alarmsSet:
            // A timer when it is given minutes, as the tool itself reads it.
            if let minutes = args["minutes"]?.number {
                title = "Set a timer"
                let length = Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
                detail = [quoted("title"), "for \(length)"].compactMap { $0 }.joined(separator: ", ")
            } else {
                title = "Set an alarm"
                detail = [quoted("title"), day("at")].compactMap { $0 }.joined(separator: ", ")
            }
        case .alarmsList:
            title = "See the alarms Redde set"; detail = "Alarms and timers set through Redde, not the Clock app's"
        case .alarmsCancel:
            title = "Cancel an alarm or a timer"; detail = "One that Redde set"
        case .widgetSet:
            title = "Write on its widget"
            let words = quoted("title") ?? quoted("text") ?? ""
            detail = [words, day("at").map { "from \($0)" }].compactMap { $0?.nilIfEmpty }.joined(separator: ", ")
        case .widgetClear:
            title = "Clear its widget"; detail = "What it shows, and what was set for later"
        case .peopleCall:
            title = switch (args["kind"]?.string ?? "").lowercased() {
            case let kind where kind.contains("audio"): "Start a FaceTime audio call"
            case let kind where kind.contains("facetime") || kind == "video": "Start a FaceTime call"
            default: "Start a phone call"
            }
            detail = [quoted("to"), quoted("label")].compactMap { $0 }.joined(separator: ", ")
        case .peopleMessage:
            title = "Write a message for you to send"
            let to = args["to"]?.array?.compactMap(\.string).joined(separator: ", ") ?? args["to"]?.string ?? ""
            detail = to.isEmpty ? "" : "To “\(String(to.prefix(80)))”"
        }
    }
}
