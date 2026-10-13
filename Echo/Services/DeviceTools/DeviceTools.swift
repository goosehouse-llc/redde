import Foundation

/// Phone tools: things on this iPhone that the agent can ask Redde to do for it, because Apple
/// lets an app do them with the person's permission. The calendar, reminders, contacts, the
/// photo library, and a folder of files. Nothing here reaches into another app: iOS has no way
/// to do that, for any app.
///
/// The tools are declared to the agent by Redde's plugin on the Hermes server
/// (`companion/hermes-plugin/redde-push/device.py`), which holds each one's description and
/// arguments; the names here must match the names there. When the agent calls one, the plugin
/// keeps the request and waits. Redde sees the tool start in the turn it is following, asks the
/// plugin what is wanted (`DeviceToolsService`), does it here, and hands the answer back.
///
/// A tool belongs to an area, and an area is off until it is turned on in Settings → Phone
/// tools, which is also when iOS is asked for its permission.
nonisolated enum DeviceArea: String, CaseIterable, Codable, Sendable, Identifiable {
    case calendar, reminders, contacts, photos, files

    var id: String { rawValue }

    var label: String {
        switch self {
        case .calendar: "Calendar"
        case .reminders: "Reminders"
        case .contacts: "Contacts"
        case .photos: "Photos"
        case .files: "Files"
        }
    }

    var symbol: String {
        switch self {
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .contacts: "person.crop.circle"
        case .photos: "photo.on.rectangle"
        case .files: "folder"
        }
    }

    /// What turning it on lets the agent do, for Settings.
    var blurb: String {
        switch self {
        case .calendar: "Look up your events and add new ones."
        case .reminders: "Read your reminders, add one, mark one done."
        case .contacts: "Look someone up: names, numbers, addresses. It can't change them."
        case .photos: "Find photos by date, kind and what they show, look at one, and delete (iOS asks you each time)."
        case .files: "Read and save files in Redde's folder in the Files app."
        }
    }
}

nonisolated enum DeviceTool: String, CaseIterable, Sendable {
    case info = "phone_info"
    case calendarEvents = "phone_calendar_events"
    case calendarAdd = "phone_calendar_add_event"
    case remindersList = "phone_reminders_list"
    case remindersAdd = "phone_reminders_add"
    case remindersComplete = "phone_reminders_complete"
    case contactsSearch = "phone_contacts_search"
    case photosSearch = "phone_photos_search"
    case photosGet = "phone_photos_get"
    case photosDelete = "phone_photos_delete"
    case filesList = "phone_files_list"
    case filesRead = "phone_files_read"
    case filesWrite = "phone_files_write"
    case filesDelete = "phone_files_delete"

    /// Every phone tool's name starts with this: how a turn's tool is told from the agent's own.
    static let prefix = "phone_"

    /// The area it belongs to; nil for the one that needs none (what the phone is and allows).
    var area: DeviceArea? {
        switch self {
        case .info: nil
        case .calendarEvents, .calendarAdd: .calendar
        case .remindersList, .remindersAdd, .remindersComplete: .reminders
        case .contactsSearch: .contacts
        case .photosSearch, .photosGet, .photosDelete: .photos
        case .filesList, .filesRead, .filesWrite, .filesDelete: .files
        }
    }

    /// It adds, changes or removes something: asked about every time, whatever the area allows
    /// for reading. (Deleting photos is asked about by iOS itself, so Redde doesn't ask twice.)
    var changes: Bool {
        switch self {
        case .calendarAdd, .remindersAdd, .remindersComplete, .filesWrite, .filesDelete: true
        default: false
        }
    }
}

/// One thing the agent has asked the phone for, as the plugin hands it over.
nonisolated struct DeviceRequest: Equatable, Sendable, Identifiable {
    var id: String
    var tool: String
    var arguments: JSONValue
    /// The Hermes session the turn is in, when the plugin knows.
    var session: String?

    init(id: String, tool: String, arguments: JSONValue = .object([:]), session: String? = nil) {
        self.id = id; self.tool = tool; self.arguments = arguments; self.session = session
    }

    /// From the plugin's JSON; nil for something that isn't a request.
    init?(_ value: JSONValue) {
        guard let id = value["id"]?.string, !id.isEmpty, let tool = value["tool"]?.string else { return nil }
        self.init(id: id, tool: tool, arguments: value["args"] ?? .object([:]), session: value["session"]?.string)
    }
}

/// Why a tool couldn't do what was asked, in words the agent can pass on.
nonisolated struct DeviceToolError: Error, Equatable, Sendable {
    var message: String
    init(_ message: String) { self.message = message }

    static let off = DeviceToolError("Phone tools are turned off in Redde on the iPhone (Settings → Phone tools).")
    static func areaOff(_ area: DeviceArea) -> DeviceToolError {
        DeviceToolError("\(area.label) is turned off in Redde on the iPhone (Settings → Phone tools).")
    }
    static func refused(_ area: DeviceArea) -> DeviceToolError {
        DeviceToolError("iOS doesn't let Redde use \(area.label): it has to be allowed in the iPhone's Settings → Privacy & Security.")
    }
    static let denied = DeviceToolError("The person said no on the iPhone.")
    static func missing(_ name: String) -> DeviceToolError { DeviceToolError("The argument \"\(name)\" is missing or isn't what it should be.") }
}

/// Dates as the agent writes them and as it is told them.
nonisolated enum DeviceDates {
    /// "2026-10-13T09:00:00-04:00", the same without seconds or without a zone (the phone's own
    /// time), with fractions of a second, or a day alone ("2026-10-13": its first moment here).
    static func parse(_ text: String, calendar: Calendar = .current) -> Date? {
        let text = text.trimmingCharacters(in: .whitespaces)
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: text) { return date }
        }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.calendar = calendar
        local.timeZone = calendar.timeZone
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            local.dateFormat = format
            if let date = local.date(from: text) { return date }
        }
        return nil
    }

    /// Whether what was written names a day and no time.
    static func isDayOnly(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil
    }

    /// With the phone's own offset, so the agent reads the time the person lives in.
    static func string(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    /// For a person: "Tuesday, October 13 at 9:00 AM".
    static func spoken(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).month(.wide).day().hour().minute())
    }
}

extension JSONValue {
    /// An argument that has to be there, as text.
    nonisolated func required(_ name: String) throws -> String {
        guard let text = self[name]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { throw DeviceToolError.missing(name) }
        return text
    }

    /// A date argument: nil when absent, an error when it can't be read.
    nonisolated func date(_ name: String) throws -> Date? {
        guard let text = self[name]?.string, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let date = DeviceDates.parse(text) else { throw DeviceToolError("\"\(name)\" isn't a date I can read: write it like 2026-10-13T09:00.") }
        return date
    }

    /// A count the agent asked for, kept within what is sensible.
    nonisolated func limit(_ name: String = "limit", default fallback: Int, most: Int) -> Int {
        min(max(self[name]?.int ?? fallback, 1), most)
    }
}
