import Foundation
import Testing
@testable import Echo

/// Phone tools: the agent asks Redde for things on the iPhone. What is held here is the phone's
/// side with a stand-in for the plugin: which requests may run, what the person is asked, what
/// goes back. The tools that touch the calendar, reminders, contacts and photos need iOS's
/// permission and a library to look in, which a test run has not; the files tools run for real.
@MainActor
struct PhoneToolsTests {
    // MARK: Dates

    @Test func datesAreReadTheWaysAnAgentWritesThem() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let nine = try #require(DeviceDates.parse("2026-10-13T09:00:00-04:00", calendar: calendar))
        #expect(DeviceDates.parse("2026-10-13T13:00:00Z", calendar: calendar) == nine)
        #expect(DeviceDates.parse("2026-10-13T09:00", calendar: calendar) == nine, "no zone: the phone's own time")
        #expect(DeviceDates.parse("2026-10-13 09:00:00", calendar: calendar) == nine)
        #expect(DeviceDates.parse("2026-10-13T09:00:00.250-04:00", calendar: calendar) == nine.addingTimeInterval(0.25))
        let day = try #require(DeviceDates.parse("2026-10-13", calendar: calendar))
        #expect(nine.timeIntervalSince(day) == 9 * 3600, "a day alone is its first moment here")
        #expect(DeviceDates.isDayOnly("2026-10-13") && !DeviceDates.isDayOnly("2026-10-13T09:00"))
        #expect(DeviceDates.parse("next Tuesday") == nil)
        #expect(DeviceDates.string(nine, timeZone: calendar.timeZone) == "2026-10-13T09:00:00-04:00")
    }

    @Test func argumentsThatAreMissingOrWrongSaySo() throws {
        let args = JSONValue.object(["title": .string("  Dentist "), "start": .string("soon"), "limit": .number(5000)])
        #expect(try args.required("title") == "Dentist")
        #expect(throws: DeviceToolError.missing("notes")) { try args.required("notes") }
        #expect(throws: DeviceToolError.self) { try args.date("start") }
        #expect(try args.date("end") == nil)
        #expect(args.limit(default: 50, most: 200) == 200 && JSONValue.object([:]).limit(default: 50, most: 200) == 50)
    }

    // MARK: Files, in a folder of the test's own

    private func files() -> DeviceFiles {
        DeviceFiles(root: FileManager.default.temporaryDirectory.appending(path: "phone-files-\(UUID().uuidString)"))
    }

    @Test func aFileIsSavedListedReadAndDeleted() throws {
        let files = files()
        let saved = try files.write(.object(["path": .string("notes/shopping.txt"), "text": .string("Milk\nEggs")]))
        #expect(saved["saved"]?.string == "notes/shopping.txt" && saved["bytes"]?.int == 9)
        let top = try files.list(.object([:]))
        #expect(top["entries"]?.array?.map { $0["name"]?.string } == ["notes"])
        #expect(top["entries"]?.array?.first?["kind"]?.string == "folder")
        let inside = try files.list(.object(["path": .string("notes")]))
        #expect(inside["entries"]?.array?.first?["name"]?.string == "shopping.txt")
        #expect(inside["entries"]?.array?.first?["bytes"]?.int == 9)
        #expect(try files.read(.object(["path": .string("/notes/shopping.txt")]))["text"]?.string == "Milk\nEggs")
        #expect(try files.delete(.object(["path": .string("notes/shopping.txt")]))["deleted"]?.string == "notes/shopping.txt")
        #expect(throws: DeviceToolError.self) { try files.read(.object(["path": .string("notes/shopping.txt")])) }
    }

    @Test func whatIsNotTextComesBackAsTheFile() throws {
        let files = files()
        try FileManager.default.createDirectory(at: files.root, withIntermediateDirectories: true)
        try Data([0xFF, 0xD8, 0xFF, 0x00, 0x01]).write(to: files.root.appending(path: "scan.jpg"))
        let read = try files.read(.object(["path": .string("scan.jpg")]))
        #expect(read["text"] == nil)
        #expect(read["file"]?["name"]?.string == "scan.jpg")
        #expect(read["file"]?["base64"]?.string == Data([0xFF, 0xD8, 0xFF, 0x00, 0x01]).base64EncodedString())
    }

    @Test func aPathCannotLeaveTheFolder() throws {
        let files = files()
        for path in ["../secret.txt", "notes/../../secret.txt", "./../x", ".."] {
            #expect(files.resolve(path) == nil, "\(path) leaves the folder")
            #expect(throws: DeviceToolError.self) { try files.write(.object(["path": .string(path), "text": .string("x")])) }
        }
        // A leading slash is the folder's own top, not the phone's.
        #expect(files.resolve("/etc/passwd")?.path.hasPrefix(files.root.standardizedFileURL.path) == true)
        // And the folder itself is never deleted.
        #expect(throws: DeviceToolError.self) { try files.delete(.object(["path": .string("/")])) }
    }

    // MARK: What the person is asked

    @Test func theQuestionSaysWhatAndWhich() {
        let add = DeviceAsk(.calendarAdd, .object(["title": .string("Dentist"), "start": .string("2026-10-13T09:00")]))
        #expect(add.title == "Add an event to your calendar")
        #expect(add.detail.hasPrefix("“Dentist”, Tuesday, October 13"))
        #expect(DeviceAsk(.contactsSearch, .object(["query": .string("Dana")])) == DeviceAsk(.contactsSearch, .object(["query": .string("Dana")])))
        #expect(DeviceAsk(.contactsSearch, .object(["query": .string("Dana")])).detail == "“Dana”")
        #expect(DeviceAsk(.remindersList, .object([:])).detail == "Every list")
        #expect(DeviceAsk(.photosDelete, .object(["ids": .array([.string("a"), .string("b")])])).title == "Delete 2 photos")
        let search = DeviceAsk(.photosSearch, .object(["kind": .string("screenshot"), "start": .string("2026-10-05"), "end": .string("2026-10-11")]))
        #expect(search.detail.hasPrefix("Screenshots from Monday, October 5 to Sunday, October 11"))
        #expect(search.detail.hasSuffix("not the pictures"))
    }

    // MARK: Which requests may run

    /// What the service is given to work with: a plugin that hands out requests and takes
    /// answers, tools that only say they ran, and a person who answers as told.
    @MainActor final class World {
        var waiting: [[String: JSONValue]] = []
        /// How many times `device next` says "nothing" before it hands the requests over.
        var late = 0
        private(set) var commands: [String] = []
        private(set) var ran: [DeviceTool] = []
        private(set) var asked: [DeviceToolsService.Question] = []
        var answer = DeviceToolsService.Answer.allow
        var onScreen = true
        var failure: DeviceToolError?
        /// The areas the plugin knows, for an older one; nil knows them all.
        var pluginKnows: Set<String>?
        /// A plugin from before 1.24.0, which gives bots nothing of their own.
        var pluginBeforeBots = false

        func command(_ arguments: String) throws -> String {
            commands.append(arguments)
            if arguments == "device next" {
                if late > 0 { late -= 1; return "redde-push device next " + Data("[]".utf8).base64EncodedString() }
                let data = try JSONEncoder().encode(JSONValue.array(waiting.map(JSONValue.object)))
                return "redde-push device next " + data.base64EncodedString()
            }
            if arguments.hasPrefix("device bots ") {
                if pluginBeforeBots { return "redde-push device: this command is for the Redde app." }
                return "redde-push " + arguments
            }
            if arguments.hasPrefix("device areas ") {
                let asked = arguments.dropFirst("device areas ".count).split(separator: ",").map(String.init)
                let held = asked.filter { $0 != "none" && pluginKnows?.contains($0) != false }
                return "redde-push device areas " + (held.isEmpty ? "none" : held.joined(separator: ","))
            }
            return "redde-push device done"
        }

        func run(_ tool: DeviceTool) throws -> JSONValue {
            if let failure { throw failure }
            ran.append(tool)
            return .object(["ran": .string(tool.rawValue)])
        }

        func ask(_ question: DeviceToolsService.Question) -> DeviceToolsService.Answer { asked.append(question); return answer }

        /// The answers handed to the plugin, by request id.
        var answers: [String: JSONValue] {
            var found: [String: JSONValue] = [:]
            for command in commands where command.hasPrefix("device done ") {
                let words = command.split(separator: " ")
                if words.count == 4, let data = Data(base64Encoded: String(words[3])), let value = try? JSONValue.parse(data) { found[String(words[2])] = value }
            }
            return found
        }
    }

    struct Harness {
        let world = World()
        let settings: Settings
        let defaults = UserDefaults(suiteName: "phone-tools-\(UUID().uuidString)")!
        let service: DeviceToolsService

        init(on: Bool = true, _ areas: [DeviceArea: PhoneToolsSettings.Access] = [:]) {
            settings = Settings(defaults: defaults)
            settings.phoneTools.on = on
            for (area, access) in areas { settings.phoneTools.set(area, access) }
            let world = world
            service = DeviceToolsService(settings: settings, defaults: defaults, command: { try world.command($0) },
                                         run: { tool, _, _ in try world.run(tool) }, ask: { world.ask($0) }, onScreen: { world.onScreen })
            service.patience = (5, .milliseconds(20))
        }
    }

    @Test func everythingIsOffUntilTurnedOn() async throws {
        #expect(PhoneToolsSettings().access(.calendar) == .off)
        var set = PhoneToolsSettings()
        set.set(.calendar, .allow)
        #expect(set.access(.calendar) == .off && set.open.isEmpty, "an area's switch means nothing while the whole thing is off")
        set.on = true
        #expect(set.access(.calendar) == .allow && set.open == [.calendar])

        let off = Harness(on: false, [.calendar: .allow])
        await #expect(throws: DeviceToolError.off) { try await off.service.perform(.init(id: "1", tool: "phone_calendar_events")) }
        let areaOff = Harness([.reminders: .allow])
        await #expect(throws: DeviceToolError.areaOff(.calendar)) { try await areaOff.service.perform(.init(id: "1", tool: "phone_calendar_events")) }
        #expect(off.world.ran.isEmpty && areaOff.world.ran.isEmpty && off.world.asked.isEmpty)
        #expect(areaOff.service.log.first?.outcome == .failed)
    }

    @Test func readingIsAskedAboutUntilItIsAllowed() async throws {
        let h = Harness([.contacts: .ask])
        let request = DeviceRequest(id: "1", tool: "phone_contacts_search", arguments: .object(["query": .string("Dana")]))
        h.world.answer = .deny
        await #expect(throws: DeviceToolError.denied) { try await h.service.perform(request) }
        #expect(h.world.asked.count == 1 && h.world.asked[0].offersAlways && h.world.ran.isEmpty)
        #expect(h.service.log.first?.outcome == .denied && h.service.log.first?.title == "Look up a contact")

        h.world.answer = .allow
        #expect(try await h.service.perform(request)["ran"]?.string == "phone_contacts_search")
        #expect(h.settings.phoneTools.access(.contacts) == .ask, "yes once is yes once")

        h.world.answer = .always
        _ = try await h.service.perform(request)
        #expect(h.settings.phoneTools.access(.contacts) == .allow)
        _ = try await h.service.perform(request)
        #expect(h.world.asked.count == 3, "and from then on it isn't asked")
        #expect(h.service.log.count == 4 && h.service.log.first?.outcome == .done)
    }

    @Test func changesAreAskedAboutEvenWhereReadingIsAllowed() async throws {
        let h = Harness([.reminders: .allow, .files: .allow, .calendar: .allow, .alarms: .allow])
        _ = try await h.service.perform(.init(id: "1", tool: "phone_reminders_list"))
        #expect(h.world.asked.isEmpty)
        for tool in ["phone_reminders_add", "phone_reminders_complete", "phone_calendar_add_event", "phone_files_write", "phone_files_delete",
                     "phone_alarms_set", "phone_alarms_cancel"] {
            _ = try await h.service.perform(.init(id: tool, tool: tool))
        }
        #expect(h.world.asked.count == 7)
        #expect(h.world.asked.allSatisfy { !$0.offersAlways }, "no \"always\" for a change")
        // "Always" pressed on a change anyway changes nothing.
        h.world.answer = .always
        _ = try await h.service.perform(.init(id: "x", tool: "phone_reminders_add"))
        #expect(h.settings.phoneTools.access(.reminders) == .allow)
    }

    /// iOS shows the photos and asks; Redde asking first would be asking twice.
    @Test func deletingPhotosIsLeftToiOSToAskAbout() async throws {
        let h = Harness([.photos: .ask])
        _ = try await h.service.perform(.init(id: "1", tool: "phone_photos_delete", arguments: .object(["ids": .array([.string("a")])])))
        #expect(h.world.asked.isEmpty && h.world.ran == [.photosDelete])
        h.world.onScreen = false
        await #expect(throws: DeviceToolError.self) { try await h.service.perform(.init(id: "2", tool: "phone_photos_delete")) }
    }

    @Test func aQuestionNeedsReddeOnTheScreen() async throws {
        let h = Harness([.calendar: .ask, .contacts: .allow])
        h.world.onScreen = false
        await #expect(throws: DeviceToolError.self) { try await h.service.perform(.init(id: "1", tool: "phone_calendar_events")) }
        #expect(h.world.asked.isEmpty && h.world.ran.isEmpty)
        // What needs no question still runs: Redde can be behind the lock while a turn goes on.
        _ = try await h.service.perform(.init(id: "2", tool: "phone_contacts_search"))
        _ = try await h.service.perform(.init(id: "3", tool: "phone_info"))
        #expect(h.world.ran == [.contactsSearch, .info])
    }

    @Test func aToolThisReddeDoesNotKnowSaysSo() async throws {
        let h = Harness([.calendar: .allow])
        await #expect(throws: DeviceToolError.self) { try await h.service.perform(.init(id: "1", tool: "phone_teleport")) }
    }

    @Test func theAgentIsToldWhatThePhoneAllows() {
        let h = Harness([.calendar: .allow, .photos: .ask])
        let info = h.service.info(now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(info["areas"]?["calendar"]?.string?.hasPrefix("on; reading needs no asking") == true)
        #expect(info["areas"]?["photos"]?.string == "on; the person is asked each time")
        #expect(info["areas"]?["contacts"]?.string == "off")
        #expect(info["time_zone"]?.string == TimeZone.current.identifier && info["time"]?.string?.hasPrefix("2027-01-1") == true)
    }

    // MARK: With the plugin

    @Test func aRequestIsFetchedCarriedOutAndAnswered() async throws {
        let h = Harness([.contacts: .allow])
        h.world.waiting = [["id": .string("r1"), "tool": .string("phone_contacts_search"), "args": .object(["query": .string("Dana")]), "session": .string("s1")]]
        h.world.late = 2   // the agent's call shows in the turn before the plugin has written it down
        await h.service.collect()
        #expect(h.world.commands.filter { $0 == "device next" }.count == 3)
        #expect(h.world.answers["r1"] == .object(["ok": .bool(true), "result": .object(["ran": .string("phone_contacts_search")])]))
        // Asked again (another tool in the same turn), the same request is not carried out twice.
        await h.service.collect()
        #expect(h.world.ran == [.contactsSearch])
    }

    @Test func aRefusalGoesBackAsWords() async throws {
        let h = Harness([.calendar: .ask])
        h.world.answer = .deny
        h.world.waiting = [["id": .string("r1"), "tool": .string("phone_calendar_events")], ["id": .string("r2"), "tool": .string("phone_photos_search")]]
        await h.service.collect()
        #expect(h.world.answers["r1"] == .object(["ok": .bool(false), "error": .string("The person said no on the iPhone.")]))
        #expect(h.world.answers["r2"]?["error"]?.string?.contains("Photos is turned off") == true)
        // And a tool that fails says how.
        let failing = Harness([.contacts: .allow])
        failing.world.failure = DeviceToolError("Contacts couldn't be searched.")
        failing.world.waiting = [["id": .string("r3"), "tool": .string("phone_contacts_search")]]
        await failing.service.collect()
        #expect(failing.world.answers["r3"]?["error"]?.string == "Contacts couldn't be searched.")
        #expect(failing.service.log.first?.note == "Contacts couldn't be searched.")
    }

    @Test func thePluginIsToldWhichAreasAreOn() async throws {
        let h = Harness([.calendar: .allow, .files: .ask, .photos: .off])
        #expect(await h.service.publish() == [.calendar, .files])
        #expect(h.world.commands.suffix(2) == ["device areas calendar,files", "device bots none"])
        h.settings.phoneTools.on = false
        #expect(await h.service.publish() == [])
        #expect(h.world.commands.suffix(2) == ["device areas none", "device bots none"])
    }

    // MARK: A bot's own (11-10)

    @Test func aBotIsGivenSomeOfTheMainAgentsAreas() async throws {
        let h = Harness([.calendar: .allow, .health: .allow, .photos: .ask])
        let server = h.settings.activeServerID.uuidString
        #expect(h.settings.phoneTools.open(for: "health", server: server).isEmpty, "a bot has none until given some")
        h.settings.phoneTools.give("health", server: server, .health, true)
        h.settings.phoneTools.give("health", server: server, .contacts, true)   // off for the main agent: given, but not open
        h.settings.phoneTools.give("scout", server: server, .photos, true)
        #expect(h.settings.phoneTools.open(for: "health", server: server) == [.health])
        #expect(h.settings.phoneTools.access(.photos, agent: "scout", server: server) == .ask, "at the main agent's access")
        #expect(h.settings.phoneTools.access(.calendar, agent: "scout", server: server) == .off)
        #expect(h.settings.phoneTools.access(.calendar, agent: "default", server: server) == .allow)
        #expect(h.settings.phoneTools.given("health", server: "another server").isEmpty, "bots are a server's")
        // Told to the plugin all at once, after the main agent's.
        _ = await h.service.publish()
        #expect(h.world.commands.suffix(2) == ["device areas calendar,photos,health", "device bots health=health scout=photos"])
        #expect(!h.service.botsUnsupported)
        // Taken back, a bot is left out: the plugin then gives it none.
        h.settings.phoneTools.give("scout", server: server, .photos, false)
        #expect(h.settings.phoneTools.bots?[server]?["scout"] == nil)
        await h.service.publishBots()
        #expect(h.world.commands.last == "device bots health=health")
        // Kept with the rest of Phone tools.
        let kept = try JSONDecoder().decode(PhoneToolsSettings.self, from: JSONEncoder().encode(h.settings.phoneTools))
        #expect(kept == h.settings.phoneTools)
    }

    @Test func aBotAsksOnlyInItsOwnAreasAndByName() async throws {
        let h = Harness([.calendar: .allow, .contacts: .ask])
        let server = h.settings.activeServerID.uuidString
        h.settings.phoneTools.give("scout", server: server, .contacts, true)
        await #expect(throws: DeviceToolError.notGiven(.calendar)) {
            try await h.service.perform(.init(id: "1", tool: "phone_calendar_events", profile: "scout"))
        }
        // The main agent's own areas are untouched, and an older plugin's requests are its.
        _ = try await h.service.perform(.init(id: "2", tool: "phone_calendar_events", profile: "default"))
        _ = try await h.service.perform(.init(id: "3", tool: "phone_calendar_events"))
        // In its own area it is asked about as the main agent would be, by its own name, with no "always".
        _ = try await h.service.perform(.init(id: "4", tool: "phone_contacts_search", profile: "scout"))
        #expect(h.world.asked.count == 1 && h.world.asked[0].asker == "scout" && !h.world.asked[0].offersAlways)
        #expect(h.world.ran == [.calendarEvents, .calendarEvents, .contactsSearch])
        // phone_info tells it of its own areas only.
        #expect(h.service.info(agent: "scout")["areas"]?["calendar"]?.string == "off")
        #expect(h.service.info(agent: "scout")["areas"]?["contacts"]?.string == "on; the person is asked each time")
        #expect(h.service.info()["areas"]?["calendar"]?.string?.hasPrefix("on") == true)
        // The plugin's word for whose a request is.
        let read = try #require(DeviceRequest(.object(["id": .string("r"), "tool": .string("phone_info"), "profile": .string("scout")])))
        #expect(read.bot == "scout" && DeviceRequest(id: "r", tool: "phone_info", profile: "default").bot == nil)
    }

    @Test func anOlderPluginGivesBotsNothingAndItIsPointedOut() async {
        let h = Harness([.health: .allow])
        h.world.pluginBeforeBots = true
        await h.service.publishBots()
        #expect(!h.service.botsUnsupported, "nothing given, nothing missed")
        h.settings.phoneTools.give("health", server: h.settings.activeServerID.uuidString, .health, true)
        await h.service.publishBots()
        #expect(h.service.botsUnsupported)
    }

    /// A plugin from before an area was added drops it: Settings says so under that area.
    @Test func anAreaAnOlderPluginDoesNotKnowIsPointedOut() async throws {
        let h = Harness([.contacts: .allow, .people: .allow])
        #expect(await h.service.publish() == [.contacts, .people])
        #expect(h.service.unoffered.isEmpty)
        h.world.pluginKnows = ["calendar", "contacts"]
        #expect(await h.service.publish() == [.contacts])
        #expect(h.service.unoffered == [.people])
        h.settings.phoneTools.set(.people, .off)
        #expect(await h.service.publish() == [.contacts])
        #expect(h.service.unoffered.isEmpty)
    }

    /// The cue: a phone tool starting in a turn Redde is following.
    @Test func aPhoneToolStartingInATurnIsTheCue() async throws {
        let h = Harness([.contacts: .allow])
        h.world.waiting = [["id": .string("r1"), "tool": .string("phone_contacts_search")]]
        let transport = ConversationLifecycleTests.ScriptedTransport([
            .toolStarted(name: "terminal", preview: "ls"), .toolFinished(name: "terminal", failed: false),
            .toolStarted(name: "phone_contacts_search", preview: "Dana"), .toolFinished(name: "phone_contacts_search", failed: false),
            .textDelta("Dana's number is on its way."), .done,
        ])
        let conversation = Conversation(settings: h.settings, store: ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "phone-\(UUID().uuidString)")),
                                        transportOverride: transport)
        h.settings.transport = .chatCompletions
        h.settings.fastLaneURL = "http://example.invalid:11500"
        h.settings.fastLaneModel = "test"
        conversation.phoneTools = h.service
        for await _ in conversation.send("What's Dana's number?") {}
        let deadline = Date().addingTimeInterval(3)
        while h.world.answers.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(h.world.answers["r1"]?["ok"]?.bool == true)
        #expect(h.world.commands.first == "device next", "the agent's own tools are no cue")

        // With phone tools off, nothing is asked of the plugin at all.
        let off = Harness(on: false)
        let quiet = Conversation(settings: off.settings, store: ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "phone-\(UUID().uuidString)")),
                                 transportOverride: transport)
        off.settings.transport = .chatCompletions
        off.settings.fastLaneURL = "http://example.invalid:11500"
        off.settings.fastLaneModel = "test"
        quiet.phoneTools = off.service
        for await _ in quiet.send("What's Dana's number?") {}
        try await Task.sleep(for: .milliseconds(150))
        #expect(off.world.commands.isEmpty)
    }

    // MARK: A photo handed to the agent is shown to the person

    /// A turn that stands still on its tool until it is let go, and then runs to its end.
    final class HeldTransport: HermesTransport, @unchecked Sendable {
        private let before: [TurnEvent], after: [TurnEvent]
        private let gate = AsyncStream<Void>.makeStream()
        init(_ before: [TurnEvent], then after: [TurnEvent]) { self.before = before; self.after = after }
        func letGo() { gate.continuation.yield() }
        nonisolated func stream(_ request: TurnRequest) -> AsyncThrowingStream<TurnEvent, Error> {
            let before = before, after = after, opened = gate.stream
            return AsyncThrowingStream { continuation in
                let task = Task {
                    for event in before { continuation.yield(event) }
                    for await _ in opened { break }
                    for event in after { continuation.yield(event) }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    /// The picture the agent is given is put in the reply as it goes: the person sees what left
    /// the phone, and "show me my latest photo" shows it.
    @Test func aPhotoOnItsWayToTheAgentIsPutInTheConversation() async throws {
        let defaults = UserDefaults(suiteName: "phone-tools-\(UUID().uuidString)")!
        let settings = Settings(defaults: defaults)
        settings.phoneTools.on = true
        settings.phoneTools.set(.photos, .allow)
        settings.transport = .hermesServe
        let world = World()
        let picture = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
        world.waiting = [["id": .string("r1"), "tool": .string("phone_photos_get"), "args": .object(["id": .string("C77D2C20-AAAA")])]]
        let service = DeviceToolsService(settings: settings, defaults: defaults, command: { try world.command($0) }, run: { tool, _, _ in
            _ = try world.run(tool)
            return .object(["kind": .string("photo"), "file": .object(["name": .string("photo-C77D2C20.jpg"), "base64": .string(picture.base64EncodedString())])])
        }, ask: { world.ask($0) }, onScreen: { true })
        service.patience = (5, .milliseconds(20))

        // The agent's turn stands still on the tool, as a real one does, then names the picture too.
        let path = "/home/hermes/.hermes/redde-push/device/files/ff2df40a-photo-C77D2C20.jpg"
        let gated = HeldTransport([.toolStarted(name: "phone_photos_get", preview: nil)],
                                  then: [.toolFinished(name: "phone_photos_get", failed: false),
                                         .textDelta("Bowling scoreboards for lanes 3 and 4.\nMEDIA:\(path)"), .done])
        var asked: [String] = []
        let conversation = Conversation(settings: settings, store: ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "phone-\(UUID().uuidString)")),
                                        transportOverride: gated)
        conversation.phoneTools = service
        conversation.fetchServerFile = { path, _ in asked.append(path); return nil }
        let events = conversation.send("Show me my most recent photo")
        Task { for await _ in events {} }
        let deadline = Date().addingTimeInterval(3)
        while conversation.messages.last?.attachments.isEmpty != false, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let shown = try #require(conversation.messages.last?.attachments.first)
        #expect(shown.kind == .image && shown.filename == "photo-C77D2C20.jpg" && shown.data == picture)
        #expect(world.answers["r1"]?["ok"]?.bool == true, "and the agent has it too")

        gated.letGo()
        while conversation.isStreaming, Date() < deadline.addingTimeInterval(3) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(conversation.messages.last?.text == "Bowling scoreboards for lanes 3 and 4.", "the path it named is taken out")
        #expect(conversation.messages.last?.attachments.count == 1, "and the picture is not shown twice")
        #expect(asked.isEmpty, "nor fetched back from the server it was just sent to")
    }

    /// An agent that fetches several photos asks for them one after the other, or all at once.
    /// A call that starts while the one before is being answered was lost: its request was not
    /// with the plugin yet when the first was asked for, and nothing looked again, so one
    /// picture came and the others waited until the server gave up on them.
    @Test func photosFetchedOneAfterAnotherAreAllShown() async throws {
        let defaults = UserDefaults(suiteName: "phone-tools-\(UUID().uuidString)")!
        let settings = Settings(defaults: defaults)
        settings.phoneTools.on = true
        settings.phoneTools.set(.photos, .allow)
        let world = World()
        func request(_ number: Int) -> [String: JSONValue] {
            ["id": .string("r\(number)"), "tool": .string("phone_photos_get"), "args": .object(["id": .string("PHOTO-\(number)")])]
        }
        world.waiting = [request(1)]
        final class Later { var service: DeviceToolsService?; var fetched = 0 }
        let later = Later()
        let service = DeviceToolsService(settings: settings, defaults: defaults, command: { try world.command($0) }, run: { tool, _, _ in
            _ = try world.run(tool)
            later.fetched += 1
            // While the first picture is being read the agent's next two calls start, and only
            // now do their requests reach the plugin.
            if later.fetched == 1 {
                world.waiting += [request(2), request(3)]
                later.service?.toolStarted("phone_photos_get")
                later.service?.toolStarted("phone_photos_get")
            }
            let picture = Data([0xFF, 0xD8, UInt8(later.fetched)])
            return .object(["file": .object(["name": .string("photo-\(later.fetched).jpg"), "base64": .string(picture.base64EncodedString())])])
        }, ask: { world.ask($0) }, onScreen: { true })
        service.patience = (5, .milliseconds(20))
        later.service = service

        var shown: [Echo.Attachment] = []
        service.toolStarted("phone_photos_get") { shown.append($0) }
        let deadline = Date().addingTimeInterval(3)
        while shown.count < 3, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(shown.map(\.filename) == ["photo-1.jpg", "photo-2.jpg", "photo-3.jpg"])
        #expect(shown.allSatisfy { $0.kind == .image })
        #expect(world.answers.keys.sorted() == ["r1", "r2", "r3"], "and the agent has all three")
        #expect(world.ran == [.photosGet, .photosGet, .photosGet], "each fetched once")
    }

    /// Asked to "show me" a photo it was given a moment ago, an agent answered with the file's
    /// path on the server, in backticks. That path is in the plugin's own folder: it is shown.
    @Test func aPhotoNamedByItsBarePathIsShown() async throws {
        let path = "/home/hermes/.hermes/redde-push/device/files/ff2df40a-photo-C77D2C20.jpg"
        let reply = "The photo is already saved on this machine at:\n\n`\(path)`\n\nIt's a 4032×3024 shot of bowling scoreboards."
        let found = ServeMedia.candidates(in: reply)
        #expect(found.map(\.path) == [path] && found.first?.whole == "`\(path)`")
        #expect(ServeMedia.candidates(in: "MEDIA:\(path)").map(\.path) == [path, path], "named properly it is one file, found twice")
        // A path that is not the plugin's folder is a path, as before.
        #expect(ServeMedia.candidates(in: "It is at `/home/hermes/pictures/cam.jpg`.").isEmpty)
        #expect(ServeMedia.isFromThePhone(path) && !ServeMedia.isFromThePhone("/home/hermes/pictures/cam.jpg"))

        let settings = Settings(defaults: UserDefaults(suiteName: "phone-tools-\(UUID().uuidString)")!)
        settings.transport = .hermesServe
        let transport = ConversationLifecycleTests.ScriptedTransport([.textDelta(reply), .done])
        let conversation = Conversation(settings: settings, store: ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "phone-\(UUID().uuidString)")),
                                        transportOverride: transport)
        var asked: [String] = []
        conversation.fetchServerFile = { path, _ in asked.append(path); return "data:image/jpeg;base64,\(Data([0xFF, 0xD8, 0xFF]).base64EncodedString())" }
        for await _ in conversation.send("Show me") {}
        let deadline = Date().addingTimeInterval(3)
        while conversation.isStreaming, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(asked == [path])
        #expect(conversation.messages.last?.attachments.first?.kind == .image)
        #expect(conversation.messages.last?.text.contains("redde-push") == false)
        #expect(conversation.messages.last?.text.hasSuffix("bowling scoreboards.") == true)
    }

    @Test func whatThePluginSaysIsReadWhateverItIs() {
        let list = Data(#"[{"id":"r1","tool":"phone_info","args":{}},{"tool":"no id"},7]"#.utf8).base64EncodedString()
        let payload = DeviceToolsService.payload(of: "redde-push device next \(list)\n", after: "redde-push device next ")
        #expect(payload?.array?.compactMap(DeviceRequest.init) == [DeviceRequest(id: "r1", tool: "phone_info")])
        #expect(DeviceToolsService.payload(of: "redde-push: this command is for the Redde app.", after: "redde-push device next ") == nil)
        #expect(DeviceToolsService.payload(of: "redde-push device next not-base64!", after: "redde-push device next ") == nil)
    }

    @Test func everyToolBelongsWhereItsNameSays() {
        for tool in DeviceTool.allCases {
            #expect(tool.rawValue.hasPrefix(DeviceTool.prefix))
            if let area = tool.area { #expect(tool.rawValue.hasPrefix("phone_\(area.rawValue)"), "\(tool.rawValue) is filed under \(area.rawValue)") }
        }
        #expect(DeviceTool.allCases.filter(\.changes).map(\.rawValue).sorted()
            == ["phone_alarms_cancel", "phone_alarms_set", "phone_calendar_add_event", "phone_files_delete", "phone_files_write",
                "phone_reminders_add", "phone_reminders_complete"])
    }
}

/// Keep a Copy (issue 50, PR 51) and its Send Now: what reaches the plugin, when, and what the
/// person is told when it doesn't.
@MainActor
struct KeepACopyTests {
    final class Plugin {
        var commands: [String] = []
        var reply: (String) -> String = { arguments in
            arguments.hasPrefix("device sync ") ? "redde-push device sync \(arguments.split(separator: " ")[2]) 1" : "redde-push device done"
        }
        func synced(_ kind: String) -> JSONValue? {
            guard let command = commands.last(where: { $0.hasPrefix("device sync \(kind) ") }),
                  let data = Data(base64Encoded: String(command.split(separator: " ")[3])) else { return nil }
            return try? JSONValue.parse(data)
        }
    }

    private func service(_ plugin: Plugin, copy: Bool = true, calendar: JSONValue? = nil,
                         failure: DeviceToolError? = nil) -> (DeviceToolsService, Settings, [JSONValue]) {
        let defaults = UserDefaults(suiteName: "keep-a-copy-\(UUID().uuidString)")!
        let settings = Settings(defaults: defaults)
        settings.phoneTools.on = true
        settings.phoneTools.set(.calendar, .allow)
        settings.phoneTools.set(.reminders, .allow)
        settings.phoneTools.copy = copy
        let asked = Box<[JSONValue]>([])
        let service = DeviceToolsService(settings: settings, defaults: defaults, command: { plugin.commands.append($0); return plugin.reply($0) },
                                         run: { tool, args, _ in
            if let failure { throw failure }
            asked.value.append(args)
            switch tool {
            case .calendarEvents: return calendar ?? .object(["events": .array([.object(["title": .string("Dentist"), "start": .string("2026-11-05T09:00:00-05:00")])]), "more": .number(0)])
            default: return .object(["reminders": .array([.object(["title": .string("Milk"), "completed": .bool(false)])])])
            }
        }, ask: { _ in .allow }, onScreen: { true })
        return (service, settings, asked.value)
    }

    final class Box<T> { var value: T; init(_ value: T) { self.value = value } }

    @Test func sendNowHandsOverBothAndSaysWhen() async {
        let plugin = Plugin()
        let (service, _, _) = service(plugin)
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        #expect(await service.refreshCopies(now: now))
        #expect(plugin.synced("calendar")?["events"]?.array?.first?["title"]?.string == "Dentist")
        #expect(plugin.synced("reminders")?["reminders"]?.array?.first?["title"]?.string == "Milk")
        #expect(service.copySentAt == now && service.copyFailure == nil)
    }

    /// A Keep a Copy service whose calendar answers the fetch ahead (from now) with `ahead` and the
    /// one behind with `behind`; what it was asked is in the box.
    private func copyService(_ plugin: Plugin, now: Date, ahead: [JSONValue], behind: [JSONValue])
        -> (DeviceToolsService, Box<[(args: JSONValue, info: JSONValue)]>) {
        let defaults = UserDefaults(suiteName: "keep-a-copy-\(UUID().uuidString)")!
        let settings = Settings(defaults: defaults)
        settings.phoneTools.on = true
        settings.phoneTools.set(.calendar, .allow)
        settings.phoneTools.copy = true
        let asked = Box<[(args: JSONValue, info: JSONValue)]>([])
        let service = DeviceToolsService(settings: settings, defaults: defaults, command: { plugin.commands.append($0); return plugin.reply($0) },
                                         run: { _, args, info in
                                             asked.value.append((args, info))
                                             let start = args["start"]?.string.flatMap { DeviceDates.parse($0) } ?? now
                                             return .object(["events": .array(start < now.addingTimeInterval(-60) ? behind : ahead)])
                                         },
                                         ask: { _ in .allow }, onScreen: { true })
        return (service, asked)
    }

    private func event(_ id: String, _ hours: Double, from now: Date) -> JSONValue {
        .object(["id": .string(id), "title": .string(id), "start": .string(DeviceDates.string(now.addingTimeInterval(hours * 3600)))])
    }

    @Test func theCalendarCopyIsTheComingTwoMonthsThenThePastWeek() async throws {
        let plugin = Plugin()
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        // "under way" began an hour ago: both fetches find it.
        let ahead = [event("under way", -1, from: now), event("tomorrow", 24, from: now), event("next month", 800, from: now)]
        let behind = [event("monday", -100, from: now), event("yesterday", -24, from: now), event("under way", -1, from: now)]
        let (service, asked) = copyService(plugin, now: now, ahead: ahead, behind: behind)
        #expect(await service.refreshCopies(now: now))
        let titles = plugin.synced("calendar")?["events"]?.array?.compactMap { $0["title"]?.string }
        #expect(titles == ["monday", "yesterday", "under way", "tomorrow", "next month"])
        try #require(asked.value.count == 2)
        let windows = asked.value.map { ask in
            ["start", "end"].map { ask.args[$0]?.string.flatMap { DeviceDates.parse($0) }?.timeIntervalSince(now) ?? .nan }
        }
        #expect(abs(windows[0][0]) < 2 && abs(windows[0][1] - 60 * 86400) < 2, "ahead first: now to two months on")
        #expect(abs(windows[1][0] + 7 * 86400) < 2 && abs(windows[1][1]) < 2, "then the past week")
        #expect(asked.value.allSatisfy { $0.args["limit"]?.int == 500 && $0.info["copy_most"]?.int == 500 })
    }

    @Test func aFullTwoMonthsLeavesThePastWeekOut() async {
        let plugin = Plugin()
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let ahead = (0..<500).map { event("a\($0)", Double($0), from: now) }
        let (service, asked) = copyService(plugin, now: now, ahead: ahead, behind: [event("old", -24, from: now)])
        await service.refreshCopies(now: now)
        #expect(plugin.synced("calendar")?["events"]?.array?.count == 500)
        #expect(asked.value.count == 1, "no room: the past week isn't fetched")
    }

    @Test func thePastWeekFillsTheRoomLeftWithItsLatest() async {
        let plugin = Plugin()
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let ahead = (0..<498).map { event("a\($0)", Double($0 + 1), from: now) }
        let behind = (1...5).reversed().map { event("b\($0)", Double(-$0 * 10), from: now) }
        let (service, _) = copyService(plugin, now: now, ahead: ahead, behind: behind)
        await service.refreshCopies(now: now)
        let events = plugin.synced("calendar")?["events"]?.array ?? []
        #expect(events.count == 500)
        #expect(events.prefix(2).compactMap { $0["title"]?.string } == ["b2", "b1"], "the two nearest now")
    }

    @Test func comingToTheFrontSendsAtMostEveryTenMinutes() async {
        let plugin = Plugin()
        let (service, _, _) = service(plugin)
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        await service.refreshCopies(staleAfter: 600, now: now)
        let first = plugin.commands.count
        await service.refreshCopies(staleAfter: 600, now: now.addingTimeInterval(300))
        #expect(plugin.commands.count == first, "five minutes on: not again")
        await service.refreshCopies(staleAfter: 600, now: now.addingTimeInterval(700))
        #expect(plugin.commands.count == first * 2, "past ten: again")
    }

    @Test func nothingGoesWithTheSettingOff() async {
        let plugin = Plugin()
        let (service, _, _) = service(plugin, copy: false)
        #expect(await service.refreshCopies() == false)
        #expect(plugin.commands.isEmpty && service.copySentAt == nil)
    }

    @Test func anOldPluginIsSaidNotSent() async {
        let plugin = Plugin()
        plugin.reply = { _ in "redde-push device: this command is for the Redde app." }
        let (service, _, _) = service(plugin)
        #expect(await service.refreshCopies() == false)
        #expect(service.copySentAt == nil)
        #expect(service.copyFailure?.contains("too old") == true, "\(service.copyFailure ?? "-")")
    }

    @Test func anUnreadableCalendarIsSaidNotSent() async {
        let plugin = Plugin()
        let (service, _, _) = service(plugin, failure: .refused(.calendar))
        #expect(await service.refreshCopies() == false)
        #expect(service.copySentAt == nil && service.copyFailure == DeviceToolError.refused(.calendar).message)
        #expect(!plugin.commands.contains { $0.hasPrefix("device sync") })
    }

    @Test func clearingTakesTheLastSentWithIt() async {
        let plugin = Plugin()
        let (service, _, _) = service(plugin)
        await service.refreshCopies()
        await service.wipeCopies()
        #expect(service.copySentAt == nil && plugin.commands.last == "device cache wipe")
    }
}
