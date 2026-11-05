import Foundation
import Testing
@testable import Echo

/// Apple Home as a phone tool (asked 2026-11-03): names as people say them, the changes that are
/// always put to the person, the person's units, and the home card's rows done in Apple Home.
@Suite(.serialized)
struct PhoneHomeTests {
    private let things = DemoHome.sample.things

    @Test func anAccessoryIsFoundAsAPersonNamesIt() {
        #expect(DeviceHome.match("Desk Lamp", in: things).map(\.id) == ["L2"], "its name")
        #expect(DeviceHome.match("desk lamps", in: things).map(\.id) == ["L2"], "a plural folds")
        #expect(DeviceHome.match("office ceiling light", in: things).map(\.id) == ["L1"], "with its room")
        #expect(DeviceHome.match("office light", in: things).map(\.id) == ["L1"], "the one called Light, not every lamp in the office")
        #expect(Set(DeviceHome.match("kitchen lights", in: things).map(\.id)) == ["L3", "L4"], "a room's lights by their kind")
        #expect(DeviceHome.match("homekit:light:L3", in: things).map(\.id) == ["L3"], "a card's entity")
        #expect(DeviceHome.match("the garage", in: things).map(\.id) == ["G1"])
        #expect(DeviceHome.match("sauna", in: things).isEmpty)
    }

    @Test func severalAtOnceOnlyWhereNothingCouldLetAnyoneIn() throws {
        #expect(throws: DeviceToolError.self) { try DeviceHome.pick("kitchen lights", in: things, all: false) }
        #expect(try DeviceHome.pick("kitchen lights", in: things, all: true).count == 2)
        // "door" means the garage door and the front door's lock: never both at once.
        #expect(throws: DeviceToolError.self) { try DeviceHome.pick("door", in: things, all: true) }
        do {
            _ = try DeviceHome.pick("kitchen lights", in: things, all: false)
        } catch let error as DeviceToolError {
            #expect(error.message.contains("Kitchen · Pendant") && error.message.contains("all: true"))
        }
    }

    @Test func aChangeIsDoneAndAnsweredWithTheNewState() async throws {
        let home = DemoHome()
        let done = try await DeviceHome.set(.object(["target": .string("desk lamp"), "on": .bool(true), "brightness": .number(55)]), layer: home, us: true)
        let row = try #require(done["done"]?.array?.first)
        #expect(row["state"]?.string == "on" && row["brightness"]?.number == 55 && row["entity"]?.string == "homekit:light:L2")
        #expect(home.applied.first?.1 == "L2" && home.applied.first?.0.brightness == 55)
        await #expect(throws: DeviceToolError.self) {
            try await DeviceHome.set(.object(["target": .string("desk lamp")]), layer: home, us: true)
        }
    }

    @Test func temperaturesAreInThePersonsUnits() async throws {
        let home = DemoHome()
        _ = try await DeviceHome.set(.object(["target": .string("thermostat"), "target_temperature": .number(72)]), layer: home, us: true)
        let celsius = try #require(home.applied.first?.0.targetTemperature)
        #expect(abs(celsius - 22.22) < 0.01, "72°F is set as 22.2°C")
        let listed = try await DeviceHome.list(.object(["query": .string("thermostat")]), layer: DemoHome(), us: true)
        let row = try #require(listed["accessories"]?.array?.first)
        #expect(row["temperature"]?.number == 69 && row["target"]?.number == 70 && row["unit"]?.string == "°F" && row["kind"]?.string == "climate")
        let metric = try await DeviceHome.list(.object(["query": .string("thermostat")]), layer: DemoHome(), us: false)
        #expect(metric["accessories"]?.array?.first?["target"]?.number == 21)
    }

    @Test func locksGarageDoorsAndScenesThatOpenAreAlwaysAsked() async {
        let home = DemoHome()
        #expect(await DeviceHome.sensitive(.homeSet, .object(["target": .string("front door"), "lock": .string("unlock")]), layer: home))
        #expect(await DeviceHome.sensitive(.homeSet, .object(["target": .string("garage door"), "door": .string("open")]), layer: home))
        #expect(await DeviceHome.sensitive(.homeSet, .object(["target": .string("garage"), "on": .bool(true)]), layer: home), "by its kind, whatever is asked")
        #expect(!(await DeviceHome.sensitive(.homeSet, .object(["target": .string("desk lamp"), "on": .bool(false)]), layer: home)))
        #expect(await DeviceHome.sensitive(.homeScene, .object(["scene": .string("arrive home")]), layer: home))
        #expect(!(await DeviceHome.sensitive(.homeScene, .object(["scene": .string("Good Night")]), layer: home)))
    }

    @Test func allowedChangesGoAheadUnaskedButALockIsAlwaysPutToThePerson() async throws {
        let defaults = UserDefaults(suiteName: "phone-home-\(UUID().uuidString)")!
        let settings = Settings(defaults: defaults)
        settings.phoneTools.on = true
        settings.phoneTools.set(.home, .allow)
        let home = DemoHome()
        var asked: [DeviceToolsService.Question] = []
        var screen = true
        let service = DeviceToolsService(settings: settings, defaults: defaults, command: { _ in "redde-push device done" },
                                         run: { tool, _, _ in .object(["ran": .string(tool.rawValue)]) },
                                         ask: { asked.append($0); return .deny }, onScreen: { screen },
                                         homeSensitive: { await DeviceHome.sensitive($0, $1, layer: home) })
        _ = try await service.perform(DeviceRequest(id: "a", tool: "phone_home_set", arguments: .object(["target": .string("desk lamp"), "on": .bool(true)])))
        #expect(asked.isEmpty, "a lamp, allowed: no question")
        await #expect(throws: DeviceToolError.denied) {
            try await service.perform(DeviceRequest(id: "b", tool: "phone_home_set", arguments: .object(["target": .string("front door"), "lock": .string("unlock")])))
        }
        #expect(asked.count == 1 && asked[0].ask.title == "Unlock “front door”" && !asked[0].offersAlways)

        settings.phoneTools.set(.home, .ask)
        await #expect(throws: DeviceToolError.denied) { try await service.perform(DeviceRequest(id: "c", tool: "phone_home_list")) }
        #expect(asked.count == 2 && !asked[1].offersAlways, "asking: reading too, and no 'always' (it would allow changes)")

        screen = false
        settings.phoneTools.set(.home, .allow)
        await #expect(throws: DeviceToolError.self) { try await service.perform(DeviceRequest(id: "d", tool: "phone_home_list")) }
    }

    @Test func aCardsAppleHomeRowIsDoneInAppleHome() throws {
        let row = ReplyCard.Home.Device(name: "Thermostat", area: "Hall", kind: .climate, state: "heat", target: 70, unit: "°F", entity: "homekit:thermostat:T1")
        #expect(row.homeKit?.kind == .thermostat && row.homeKit?.id == "T1")
        let change = try #require(HomeCard.change(.target(72), row))
        #expect(abs((change.targetTemperature ?? 0) - 22.22) < 0.01)
        #expect(HomeCard.change(.play(true), row) == nil, "media goes to the agent")
        let door = ReplyCard.Home.Device(name: "Back Door", kind: .cover, state: "closed", entity: "homekit:door:D1")
        #expect(door.risky && HomeCard.isRisky(.open(true), door), "opening a door asks first")
        #expect(ReplyCard.Home.Device(name: "Kitchen", kind: .light, entity: "light.kitchen").homeKit == nil, "Home Assistant's stay the agent's")
    }

    @Test func coloursAreReadAsHueAndSaturation() throws {
        let red = try #require(HomeChange.hueSaturation("#FF0000"))
        #expect(red.0 == 0 && red.1 == 100)
        let orange = try #require(HomeChange.hueSaturation("ff8800"))
        #expect(abs(orange.0 - 32) < 0.1 && orange.1 == 100)
        #expect(HomeChange.hueSaturation("#12") == nil)
    }

    @Test func theAreaIsNamedForTheAgentAndTheToolsAreItsOwn() {
        #expect(DeviceArea.home.agentLabel == "Apple Home")
        #expect([DeviceTool.homeList, .homeSet, .homeScene].allSatisfy { $0.area == .home })
        #expect(DeviceTool.homeSet.changesHome && !DeviceTool.homeList.changesHome && !DeviceTool.homeSet.changes)
    }
}
