import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Carries out one phone tool and gives back what it found or did, as the JSON the agent reads.
/// The permission questions (is the area on, does the person have to be asked) are settled
/// before this is called (`DeviceToolsService`).
nonisolated struct DeviceToolRunner: Sendable {
    var files = DeviceFiles()
    #if os(iOS)
    var alarms = DeviceAlarms()
    #endif
    var board = DeviceBoard()
    #if os(iOS)
    var people = DevicePeople()
    #endif

    func run(_ tool: DeviceTool, _ args: JSONValue, info: JSONValue = .object([:])) async throws -> JSONValue {
        switch tool {
        case .info: info
        // `copy_most` comes only from Keep a Copy (the agent's arguments are `args`, not `info`).
        case .calendarEvents: try await DeviceCalendar.events(args, most: info["copy_most"]?.int ?? 200)
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
        #if os(iOS)
        case .alarmsSet: try await alarms.set(args)
        case .alarmsList: try await alarms.list(args)
        case .alarmsCancel: try await alarms.cancel(args)
        #else
        case .alarmsSet, .alarmsList, .alarmsCancel: throw DeviceToolError("This Mac has no alarms or calls; that tool is the iPhone's.")
        #endif
        case .widgetSet: try await board.set(args)
        case .widgetClear: try await board.clear(args)
        // A name is looked up in Contacts, which is for the person to have turned on.
        #if os(iOS)
        case .peopleCall: try await people.call(args, contactsOn: info["areas"]?[DeviceArea.contacts.rawValue]?.string?.hasPrefix("on") == true)
        case .peopleMessage: try await people.message(args, contactsOn: info["areas"]?[DeviceArea.contacts.rawValue]?.string?.hasPrefix("on") == true)
        #else
        case .peopleCall, .peopleMessage: throw DeviceToolError("This Mac has no alarms or calls; that tool is the iPhone's.")
        #endif
        // What may be read is what `phone_info` says is shared, which the settings decide.
        case .healthRead:
            try await DeviceHealth.read(args, shared: (info["health_shared"]?.array ?? []).compactMap { $0.string.flatMap(HealthKind.init) })
        case .homeList: try await DeviceHome.list(args)
        case .homeSet: try await DeviceHome.set(args)
        case .homeScene: try await DeviceHome.scene(args)
        case .mapsSearch: try await DeviceMaps.search(args)
        case .mapsDirections: try await DeviceMaps.directions(args)
        case .mapsOpen: try await DeviceMaps.open(args)
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
            case let (from?, to?): inside ? String(localized: "from \(from) to \(to)", comment: "Dates, inside a sentence") : String(localized: "From \(from) to \(to)")
            case let (from?, nil): inside ? String(localized: "from \(from)", comment: "A date, inside a sentence") : String(localized: "From \(from)")
            case let (nil, to?): inside ? String(localized: "up to \(to)", comment: "A date, inside a sentence") : String(localized: "Up to \(to)")
            case (nil, nil): nil
            }
        }
        switch tool {
        case .info:
            title = String(localized: "See what this iPhone allows"); detail = String(localized: "The time here, and which phone tools are on")
        case .calendarEvents:
            title = String(localized: "Look at your calendar")
            detail = [span() ?? String(localized: "The coming week"), quoted("query").map { String(localized: "matching \($0)", comment: "Calendar events whose words match, quoted") }].compactMap { $0 }.joined(separator: ", ")
        case .calendarAdd:
            title = String(localized: "Add an event to your calendar")
            detail = [quoted("title"), day("start")].compactMap { $0 }.joined(separator: ", ")
        case .remindersList:
            title = String(localized: "Read your reminders")
            detail = quoted("list").map { String(localized: "The list \($0)", comment: "A reminders list, named in quotes") } ?? String(localized: "Every list", comment: "Every reminders list")
        case .remindersAdd:
            title = String(localized: "Add a reminder")
            detail = [quoted("title"), day("due").map { String(localized: "due \($0)", comment: "When a reminder is due") }].compactMap { $0 }.joined(separator: ", ")
        case .remindersComplete:
            title = String(localized: "Mark a reminder as done"); detail = String(localized: "One reminder")
        case .contactsSearch:
            title = String(localized: "Look up a contact"); detail = quoted("query") ?? ""
        case .photosSearch:
            title = String(localized: "Look through your photos")
            let kind = switch args["kind"]?.string?.lowercased() ?? "" {
            case "screenshot", "screenshots": String(localized: "Screenshots")
            case "video", "videos": String(localized: "Videos")
            case "photo", "photos": String(localized: "Photos", comment: "Pictures in the photo library, not videos")
            default: String(localized: "Photos and videos")
            }
            let which = [kind, span(inside: true)].compactMap { $0 }.joined(separator: " ")
            // Found by what they show, the agent is told what the phone made out in each.
            detail = if let words = quoted("query") { String(localized: "\(which) that match \(words): what each shows and says, not the pictures") }
            else { String(localized: "\(which): when each was taken, not the pictures") }
        case .photosGet:
            title = String(localized: "Look at one of your photos"); detail = String(localized: "The picture is sent to your server")
        case .photosDelete:
            let count = args["ids"]?.array?.count ?? 0
            title = count == 1 ? String(localized: "Delete a photo") : String(localized: "Delete \(count) photos"); detail = String(localized: "iOS shows them and asks you")
        case .filesList:
            title = String(localized: "See what is in Redde's folder"); detail = quoted("path") ?? String(localized: "Files › On My iPhone › Redde", comment: "Where Redde's folder is in the Files app")
        case .filesRead:
            title = String(localized: "Read a file in Redde's folder"); detail = quoted("path") ?? ""
        case .filesWrite:
            title = String(localized: "Save a file to Redde's folder"); detail = quoted("path") ?? ""
        case .filesDelete:
            title = String(localized: "Delete from Redde's folder"); detail = quoted("path") ?? ""
        case .alarmsSet:
            // A timer when it is given minutes, as the tool itself reads it.
            if let minutes = args["minutes"]?.number {
                title = String(localized: "Set a timer")
                let length = Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
                detail = [quoted("title"), String(localized: "for \(length)", comment: "How long a timer runs")].compactMap { $0 }.joined(separator: ", ")
            } else {
                title = String(localized: "Set an alarm")
                detail = [quoted("title"), day("at")].compactMap { $0 }.joined(separator: ", ")
            }
        case .alarmsList:
            title = String(localized: "See the alarms Redde set"); detail = String(localized: "Alarms and timers set through Redde, not the Clock app's")
        case .alarmsCancel:
            title = String(localized: "Cancel an alarm or a timer"); detail = String(localized: "One that Redde set")
        case .widgetSet:
            title = String(localized: "Write on its widget")
            let words = quoted("title") ?? quoted("text") ?? ""
            detail = [words, day("at").map { String(localized: "from \($0)", comment: "A date, inside a sentence") }].compactMap { $0?.nilIfEmpty }.joined(separator: ", ")
        case .widgetClear:
            title = String(localized: "Clear its widget"); detail = String(localized: "What it shows, and what was set for later")
        case .peopleCall:
            title = switch (args["kind"]?.string ?? "").lowercased() {
            case let kind where kind.contains("audio"): String(localized: "Start a FaceTime audio call")
            case let kind where kind.contains("facetime") || kind == "video": String(localized: "Start a FaceTime call")
            default: String(localized: "Start a phone call")
            }
            detail = [quoted("to"), quoted("label")].compactMap { $0 }.joined(separator: ", ")
        case .peopleMessage:
            title = String(localized: "Write a message for you to send")
            let to = args["to"]?.array?.compactMap(\.string).joined(separator: ", ") ?? args["to"]?.string ?? ""
            detail = to.isEmpty ? "" : String(localized: "To “\(String(to.prefix(80)))”", comment: "Who a message is for")
        case .homeList:
            title = String(localized: "Look at your Apple Home")
            detail = quoted("query") ?? quoted("room") ?? String(localized: "Its accessories and scenes", comment: "What the agent reads from Apple Home")
        case .homeSet:
            let target = quoted("target") ?? ""
            // What could let someone in, said as it is: "Unlock “Front Door”".
            if let lock = args["lock"]?.string?.lowercased() {
                title = lock == "unlock" ? String(localized: "Unlock \(target)", comment: "Apple Home: unlock a lock, named in quotes")
                    : String(localized: "Lock \(target)", comment: "Apple Home: lock a lock, named in quotes")
            } else if let door = args["door"]?.string?.lowercased() {
                title = door == "open" ? String(localized: "Open \(target)", comment: "Apple Home: open a garage door, named in quotes")
                    : String(localized: "Close \(target)", comment: "Apple Home: close a garage door, named in quotes")
            } else if let security = args["security"]?.string?.lowercased() {
                title = security == "off" ? String(localized: "Turn off the alarm", comment: "Apple Home: disarm the security system")
                    : String(localized: "Set the alarm to \(security)", comment: "Apple Home: arm the security system: home, away or night")
            } else if let on = args["on"]?.bool, args["brightness"] == nil {
                title = on ? String(localized: "Turn on \(target)", comment: "Apple Home: turn an accessory on, named in quotes")
                    : String(localized: "Turn off \(target)", comment: "Apple Home: turn an accessory off, named in quotes")
            } else if let position = args["position"]?.int {
                title = String(localized: "Set \(target) to \(position)% open", comment: "Apple Home: blinds, a window or a door, named in quotes")
            } else {
                title = String(localized: "Change \(target)", comment: "Apple Home: change an accessory, named in quotes")
            }
            detail = String(localized: "In Apple Home", comment: "Where a phone tool's change happens")
        case .homeScene:
            title = String(localized: "Run the scene \(quoted("scene") ?? "")", comment: "Apple Home: run a scene, named in quotes")
            detail = String(localized: "In Apple Home", comment: "Where a phone tool's change happens")
        case .mapsSearch:
            title = String(localized: "Look up places in Apple Maps", comment: "A phone tool's question: the agent searches Apple Maps")
            detail = [quoted("query"), quoted("near").map { String(localized: "near \($0)", comment: "Where a Maps search looks, a place in quotes") }
                ?? String(localized: "near your iPhone", comment: "Where a Maps search looks: where the phone is")].compactMap { $0 }.joined(separator: " ")
        case .mapsDirections:
            title = String(localized: "Work out the way to \(quoted("to") ?? "")", comment: "Apple Maps: travel time and directions to a place, named in quotes")
            detail = quoted("from").map { String(localized: "From \($0)", comment: "A delivery card: where the package comes from, e.g. From Apple") }
                ?? String(localized: "From where your iPhone is", comment: "Where a way starts: the phone")
        case .mapsOpen:
            title = String(localized: "Open Apple Maps to \(quoted("to") ?? "")", comment: "Apple Maps opens with the way to a place, named in quotes")
            detail = String(localized: "Ready to go", comment: "Apple Maps opened with directions, ready to start")
        case .healthRead:
            title = String(localized: "Read your Health data")
            let kind = args["type"]?.string.flatMap { HealthKind(rawValue: $0.lowercased()) }
            detail = [kind?.label ?? args["type"]?.string, span(inside: true)].compactMap { $0?.nilIfEmpty }.joined(separator: ", ")
        }
    }
}
