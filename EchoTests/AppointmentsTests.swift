import Foundation
import Testing
@testable import Echo

/// Appointments that come round again (asked 2026-11-26, "do 4"): which events are appointments,
/// what the plugin is told of them, and when.
@MainActor
struct AppointmentsTests {
    static let now = Date(timeIntervalSince1970: 1_795_700_000)   // 2026-11-26

    static func day(_ days: Double, hour: Double = 10) -> Date {
        Calendar.current.startOfDay(for: now).addingTimeInterval(days * 86400 + hour * 3600)
    }

    @Test func titlesAreSortedIntoKinds() {
        let kinds: [String: String?] = [
            "Haircut": "haircut", "Hair cut w/ Alex": "haircut", "Barber": "haircut", "Main St Barbershop": "haircut",
            "Dentist - cleaning": "dentist", "Dental check-up": "dentist", "Orthodontist": "dentist",
            "Dr. Patel": "doctor", "Annual physical": "doctor", "Check-up": "doctor", "Pediatrician (Robin)": "doctor",
            "Eye exam": "eyes", "Eye doctor": "eyes", "Dermatologist": "skin", "Physical therapy": "physio", "Chiropractor": "physio",
            "Vet – Biscuit shots": "vet", "Dog grooming": "grooming", "Nail salon": "nails", "Mani-pedi": "nails",
            "Massage": "massage", "Oil change": "car",
            "Call the dentist": nil, "Book haircut": nil, "Reschedule vet": nil, "Team standup": nil, "Movie night": nil,
            "Veterans Day": nil, "Drive to airport": nil,
        ]
        for (title, kind) in kinds {
            #expect(Appointments.kind(of: title) == kind, "\(title)")
        }
    }

    @Test func eachKindsVisitsLastOneAndNextAreFound() throws {
        let events = [
            Appointments.Event(title: "Haircut", start: Self.day(-75), end: Self.day(-75, hour: 10.5)),
            Appointments.Event(title: "Haircut", start: Self.day(-40), end: Self.day(-40, hour: 10.5)),
            Appointments.Event(title: "Barber", start: Self.day(-5), end: Self.day(-5, hour: 10.75),
                               location: "Main Street Barbers\n12 Main St, Springfield"),
            Appointments.Event(title: "Dentist", start: Self.day(30), end: Self.day(30, hour: 11)),   // only booked
            Appointments.Event(title: "Dentist", start: Self.day(-150), end: Self.day(-150, hour: 11)),
            Appointments.Event(title: "Doctor", start: Self.day(-10), end: Self.day(-10), allDay: true),   // all day: not a visit
            Appointments.Event(title: "Team standup", start: Self.day(-1), end: Self.day(-1, hour: 10.25)),
        ]
        let found = Appointments.found(events, now: Self.now)
        #expect(found.map(\.kind) == ["dentist", "haircut"])
        let dentist = found[0], haircut = found[1]
        #expect(haircut.visits.count == 3 && haircut.next == nil && haircut.where == "Main Street Barbers")
        let iso = ISO8601DateFormatter()
        let visits: [Date] = haircut.visits.compactMap { iso.date(from: $0) }
        let expected: [Date] = [Self.day(-75), Self.day(-40), Self.day(-5)]
        #expect(visits == expected)
        #expect(haircut.ended.flatMap { iso.date(from: $0) } == Self.day(-5, hour: 10.75))
        #expect(dentist.visits.count == 1 && dentist.next.flatMap { iso.date(from: $0) } == Self.day(30), "the one booked ahead")
    }

    @Test func onlyTheNewestVisitsGo() {
        var many: [Appointments.Event] = []
        for n in 1...20 {
            let days = Double(-35 * n)
            many.append(Appointments.Event(title: "Haircut", start: Self.day(days), end: Self.day(days, hour: 11)))
        }
        #expect(Appointments.found(many, now: Self.now)[0].visits.count == Appointments.visits)
    }

    @Test func thePluginsLineIsBase64URL() throws {
        let found = [Appointments.Found(kind: "haircut", visits: ["2026-10-20T10:00:00-04:00"], ended: nil, next: nil, where: "Café ✂️")]
        let line = try #require(Appointments.line(device: "abc-1", found))
        let parts = line.split(separator: " ")
        #expect(parts.count == 4 && parts[0] == "follow" && parts[1] == "appts" && parts[2] == "abc-1")
        let raw = String(parts[3])
        #expect(!raw.contains("=") && !raw.contains("+") && !raw.contains("/"))
        var base64 = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        let back = try JSONDecoder().decode([Appointments.Found].self, from: try #require(Data(base64Encoded: base64)))
        #expect(back == found)
    }

    @Test func sentAtMostEverySixHoursPerServerAndOnlyWithAccess() async throws {
        let defaults = try #require(UserDefaults(suiteName: "AppointmentsTests-\(UUID().uuidString)"))
        var lines: [String] = []
        let haircut = Appointments.Event(title: "Haircut", start: Self.day(-5), end: Self.day(-5, hour: 11))
        let events: @Sendable (Date) async -> [Appointments.Event] = { _ in [haircut] }
        func send(at: Date, server: String = "s1", allowed: Bool = true, fails: Bool = false) async {
            await Appointments.send(now: at, defaults: defaults, server: server, allowed: allowed, events: events) { line in
                if fails { throw URLError(.notConnectedToInternet) }
                lines.append(line)
                return "redde-push follow {\"appointments\": {\"kinds\": 1}}"
            }
        }
        await send(at: Self.now, allowed: false)
        #expect(lines.isEmpty, "no calendar access, nothing read or sent")
        await send(at: Self.now)
        #expect(lines.count == 1 && lines[0].hasPrefix("follow appts "))
        let device = lines[0].split(separator: " ")[2]
        await send(at: Self.now.addingTimeInterval(3600))
        #expect(lines.count == 1, "not again within six hours")
        await send(at: Self.now.addingTimeInterval(3600), server: "s2")
        #expect(lines.count == 2, "another server is told on its own")
        #expect(lines[1].split(separator: " ")[2] == device, "the same device each time")
        await send(at: Self.now.addingTimeInterval(7 * 3600), fails: true)
        await send(at: Self.now.addingTimeInterval(7 * 3600 + 60))
        #expect(lines.count == 3, "a failed send is tried again at the next look")
    }
}
