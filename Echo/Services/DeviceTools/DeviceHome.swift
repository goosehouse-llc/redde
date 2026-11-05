import Foundation
#if os(iOS)
import HomeKit
#endif

/// Apple Home through the phone (asked 2026-11-03: smart-home control for people without Home
/// Assistant): the agent lists the home's accessories and scenes, changes one, runs a scene, and
/// draws them as the `home` card, whose controls then work in Apple Home on the phone directly.
///
/// Locks, garage doors, doors, windows and the security system are always put to the person,
/// whatever the area allows (`DeviceHome.sensitive`); the rest go ahead unasked once the area is
/// allowed. HomeKit works only with Redde on the screen, and only on an iPhone or an iPad: a Mac
/// answers that Apple Home is on the user's iPhone.
nonisolated enum HomeKind: String, Codable, Sendable, CaseIterable {
    case light, `switch`, outlet, fan, thermostat, blind, window, door, garage, lock, security, sensor, other

    /// Opening or unlocking it could let someone in: asked about every time.
    var sensitive: Bool { [.lock, .garage, .door, .window, .security].contains(self) }

    /// The kind as the `home` card draws it (`ReplyCard.Home.Device.Kind`).
    var cardKind: String {
        switch self {
        case .light: "light"
        case .switch, .outlet: "switch"
        case .fan: "fan"
        case .thermostat: "climate"
        case .blind, .window, .door, .garage: "cover"
        case .lock: "lock"
        case .security, .sensor, .other: "sensor"
        }
    }

    /// Words a person uses for it, for matching "the office lights" or "the garage".
    var words: [String] {
        switch self {
        case .light: ["light", "lights", "lamp", "lamps", "bulb"]
        case .switch: ["switch"]
        case .outlet: ["plug", "outlet", "socket"]
        case .fan: ["fan"]
        case .thermostat: ["thermostat", "heat", "heating", "ac", "temperature"]
        case .blind: ["blind", "blinds", "shade", "shades", "curtain", "curtains"]
        case .window: ["window"]
        case .door: ["door"]
        case .garage: ["garage", "door"]
        case .lock: ["lock", "door"]
        case .security: ["alarm", "security"]
        case .sensor: ["sensor"]
        case .other: []
        }
    }
}

/// One accessory as it is now. Temperatures are kept in Celsius, as HomeKit gives them.
nonisolated struct HomeThing: Equatable, Sendable {
    var id: String
    var name: String
    var room: String?
    var home: String?
    var kind: HomeKind
    var reachable = true
    var on: Bool?
    var brightness: Int?
    var colorTemperature: Int?
    var currentTemperature: Double?
    var targetTemperature: Double?
    var mode: String?
    var fanSpeed: Int?
    var position: Int?
    var locked: Bool?
    /// A garage door: "open", "closed", "opening", "closing", "stopped".
    var door: String?
    /// The security system: "home", "away", "night", "off", "triggered".
    var security: String?
    /// A sensor's reading in words ("48%", "open", "motion").
    var reading: String?

    /// How the card names it: `homekit:<kind>:<id>`, so its controls know where to go.
    var entity: String { "homekit:\(kind.rawValue):\(id)" }
}

nonisolated struct HomeScene: Equatable, Sendable {
    var id: String
    var name: String
    var home: String?
    /// It unlocks or opens something, or arms or disarms the alarm.
    var sensitive: Bool
}

nonisolated struct HomeSnapshot: Equatable, Sendable {
    var homes: [String]
    var things: [HomeThing]
    var scenes: [HomeScene]
}

/// What is to change on an accessory, from the agent's arguments or a card's control.
nonisolated struct HomeChange: Equatable, Sendable {
    var on: Bool?
    var brightness: Int?
    /// Kelvin.
    var colorTemperature: Int?
    /// 0–360 and 0–100.
    var hue: Double?
    var saturation: Double?
    /// Celsius.
    var targetTemperature: Double?
    var mode: String?
    var fanSpeed: Int?
    var position: Int?
    var lock: Bool?
    var openDoor: Bool?
    var security: String?

    var isEmpty: Bool { self == HomeChange() }

    /// From `phone_home_set`'s arguments; a temperature is in the person's units (`us`: Fahrenheit).
    init(_ args: JSONValue, us: Bool) throws {
        on = args["on"]?.bool
        brightness = args["brightness"]?.int.map { min(max($0, 0), 100) }
        colorTemperature = args["color_temperature"]?.int.map { min(max($0, 1500), 7000) }
        if let hex = args["color"]?.string?.nilIfEmpty {
            guard let (h, s) = Self.hueSaturation(hex) else { throw DeviceToolError("\"color\" isn't a colour I can read: write it like #FF8800.") }
            hue = h; saturation = s
        }
        if let degrees = args["target_temperature"]?.number { targetTemperature = us ? (degrees - 32) * 5 / 9 : degrees }
        if let said = args["mode"]?.string?.lowercased() {
            guard ["heat", "cool", "auto", "off"].contains(said) else { throw DeviceToolError.missing("mode") }
            mode = said
        }
        fanSpeed = args["fan_speed"]?.int.map { min(max($0, 0), 100) }
        position = args["position"]?.int.map { min(max($0, 0), 100) }
        if let said = args["lock"]?.string?.lowercased() {
            guard ["lock", "unlock"].contains(said) else { throw DeviceToolError.missing("lock") }
            lock = said == "lock"
        }
        if let said = args["door"]?.string?.lowercased() {
            guard ["open", "close"].contains(said) else { throw DeviceToolError.missing("door") }
            openDoor = said == "open"
        }
        if let said = args["security"]?.string?.lowercased() {
            guard ["home", "away", "night", "off"].contains(said) else { throw DeviceToolError.missing("security") }
            security = said
        }
    }

    init(on: Bool? = nil, brightness: Int? = nil, targetTemperature: Double? = nil, position: Int? = nil, lock: Bool? = nil, openDoor: Bool? = nil) {
        self.on = on; self.brightness = brightness; self.targetTemperature = targetTemperature
        self.position = position; self.lock = lock; self.openDoor = openDoor
    }

    /// "#FF8800" as HomeKit's hue (0–360) and saturation (0–100).
    static func hueSaturation(_ hex: String) -> (Double, Double)? {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255, g = Double((value >> 8) & 0xFF) / 255, b = Double(value & 0xFF) / 255
        let high = max(r, g, b), low = min(r, g, b), span = high - low
        var h = 0.0
        if span > 0 {
            if high == r { h = 60 * ((g - b) / span).truncatingRemainder(dividingBy: 6) }
            else if high == g { h = 60 * ((b - r) / span + 2) }
            else { h = 60 * ((r - g) / span + 4) }
        }
        if h < 0 { h += 360 }
        return ((h * 10).rounded() / 10, high == 0 ? 0 : (span / high * 1000).rounded() / 10)
    }
}

/// HomeKit, or a stand-in for it (tests, demos, a Mac).
nonisolated protocol HomeLayer: Sendable {
    func snapshot() async throws -> HomeSnapshot
    func apply(_ change: HomeChange, to thing: HomeThing) async throws
    func run(_ scene: HomeScene) async throws
}

nonisolated enum DeviceHome {
    /// An iPhone or an iPad: a Mac has no HomeKit for Redde.
    #if os(iOS)
    static let available = true
    #else
    static let available = false
    #endif

    private static let lock = NSLock()
    nonisolated(unsafe) private static var chosen: (any HomeLayer)?

    /// A stand-in is in use (a test, `-echo.demoHome`): no HomeKit, no question from iOS.
    static var standIn: Bool { lock.lock(); defer { lock.unlock() }; return chosen != nil }

    /// The layer the tools and the card use: HomeKit, or the demo's under `-echo.demoHome`.
    static var layer: any HomeLayer {
        get {
            lock.lock(); defer { lock.unlock() }
            if let chosen { return chosen }
            #if os(iOS)
            return HomeKitLayer.shared
            #else
            return NoHome()
            #endif
        }
        set { lock.lock(); chosen = newValue; lock.unlock() }
    }

    /// Whether iOS lets Redde at the home, asking the first time.
    static func allowed() async -> Bool {
        #if os(iOS)
        if standIn { return true }
        return await HomeKitLayer.shared.allowed()
        #else
        return false
        #endif
    }

    static let offPhone = DeviceToolError("Apple Home is on the user's iPhone: this Mac can't reach it. Redde on the iPhone does it.")

    // MARK: The tools

    /// `phone_home_list`: `room`, `query`.
    static func list(_ args: JSONValue, layer: any HomeLayer = layer, us: Bool = MeasureUnits.usesUS()) async throws -> JSONValue {
        guard available || standIn else { throw offPhone }
        let home = try await layer.snapshot()
        var things = home.things
        if let room = args["room"]?.string?.nilIfEmpty {
            things = things.filter { ($0.room ?? "").caseInsensitiveCompare(room) == .orderedSame || Self.words($0.room ?? "").contains(Self.words(room)) }
        }
        if let query = args["query"]?.string?.nilIfEmpty {
            let found = match(query, in: things)
            things = found.isEmpty ? [] : found
        }
        let rows = things.prefix(60).map { row($0, us: us) }
        var out: [String: JSONValue] = [
            "accessories": .array(Array(rows)),
            "scenes": .array(home.scenes.prefix(30).map { .string($0.name) }),
        ]
        if home.homes.count > 1 { out["homes"] = .array(home.homes.map { .string($0) }) }
        if things.count > 60 { out["more"] = .number(Double(things.count - 60)) }
        if home.things.isEmpty { out["note"] = .string("Apple Home has no accessories here, or iOS hasn't let Redde see them.") }
        return .object(out)
    }

    /// `phone_home_set`: `target` (or an entity), `all`, then what changes.
    static func set(_ args: JSONValue, layer: any HomeLayer = layer, us: Bool = MeasureUnits.usesUS()) async throws -> JSONValue {
        guard available || standIn else { throw offPhone }
        let target = try args.required("target")
        let change = try HomeChange(args, us: us)
        guard !change.isEmpty else { throw DeviceToolError("Nothing to change: give on, brightness, target_temperature, position, lock, door or another.") }
        let home = try await layer.snapshot()
        let found = try pick(target, in: home.things, all: args["all"]?.bool == true)
        var done: [JSONValue] = []
        for thing in found {
            try await layer.apply(change, to: thing)
            done.append(row(thing.applying(change), us: us))
        }
        return .object(["done": .array(done)])
    }

    /// `phone_home_scene`: `scene`.
    static func scene(_ args: JSONValue, layer: any HomeLayer = layer) async throws -> JSONValue {
        guard available || standIn else { throw offPhone }
        let name = try args.required("scene")
        let scenes = try await layer.snapshot().scenes
        guard let scene = scenes.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
                ?? scenes.first(where: { words($0.name) == words(name) }) else {
            throw DeviceToolError("There is no scene called \"\(name)\". The scenes: \(scenes.map(\.name).joined(separator: ", ")).")
        }
        try await layer.run(scene)
        return .object(["ran": .string(scene.name)])
    }

    /// Whether this call has to be put to the person whatever the area allows: it touches a lock,
    /// a garage door, a door, a window or the security system. Unknown targets aren't (the call
    /// then fails on its own); a name that matches several counts if any of them is.
    static func sensitive(_ tool: DeviceTool, _ args: JSONValue, layer: any HomeLayer = layer) async -> Bool {
        if (args["lock"]?.string ?? args["door"]?.string ?? args["security"]?.string) != nil { return true }
        guard let home = try? await layer.snapshot() else { return false }
        switch tool {
        case .homeSet:
            guard let target = args["target"]?.string else { return false }
            return match(target, in: home.things).contains { $0.kind.sensitive }
        case .homeScene:
            guard let name = args["scene"]?.string else { return false }
            return home.scenes.contains { $0.sensitive && ($0.name.caseInsensitiveCompare(name) == .orderedSame || words($0.name) == words(name)) }
        default:
            return false
        }
    }

    // MARK: Finding an accessory

    /// The accessories a name means: the entity or id; else its name exactly ("Office Light"), or
    /// with its room ("office light" for Light in Office); else every word found in its room,
    /// name and kind ("kitchen lights"). Best tier only.
    static func match(_ target: String, in things: [HomeThing]) -> [HomeThing] {
        let said = target.trimmingCharacters(in: .whitespaces)
        if let exact = things.first(where: { $0.entity == said || $0.id == said }) { return [exact] }
        let wanted = words(said)
        guard !wanted.isEmpty else { return [] }
        let byName = things.filter { words($0.name) == wanted }
        if !byName.isEmpty { return byName }
        let withRoom = things.filter { thing in
            let room = words(thing.room ?? "")
            return room + words(thing.name) == wanted || words(thing.name) + room == wanted
                || (words(thing.name).starts(with: room) && words(thing.name) == wanted)
        }
        if !withRoom.isEmpty { return withRoom }
        // Every word in its room and name ("office ceiling"), then with its kind's words too
        // ("kitchen lights" for the kitchen's lamps): "office light" is the one called Light.
        let named = things.filter { Set(words($0.room ?? "") + words($0.name)).isSuperset(of: wanted) }
        if !named.isEmpty { return named }
        return things.filter { thing in
            Set(words(thing.room ?? "") + words(thing.name) + thing.kind.words.flatMap(words)).isSuperset(of: wanted)
        }
    }

    /// One accessory for a name, or all of them with `all`; else a clear error naming the choices.
    static func pick(_ target: String, in things: [HomeThing], all: Bool) throws -> [HomeThing] {
        let found = match(target, in: things)
        guard !found.isEmpty else {
            throw DeviceToolError("There is no accessory matching \"\(target)\" in Apple Home. Call phone_home_list to see them.")
        }
        if found.count == 1 { return found }
        let names = found.prefix(8).map { [$0.room, $0.name].compactMap { $0 }.joined(separator: " · ") }.joined(separator: "; ")
        // Several at once only where nothing could let anyone in: "all the lights", never "all the doors".
        if all, !found.contains(where: { $0.kind.sensitive }) { return found }
        throw DeviceToolError(all ? "\"\(target)\" matches doors or locks too, which go one at a time: \(names)."
                                  : "\"\(target)\" matches several: \(names). Name one, or say all: true for every one of them.")
    }

    /// Lowercased words without "the", plurals folded ("lights" → "light").
    static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { $0 != "the" && $0 != "my" && $0 != "in" }
            .map { $0.count > 3 && $0.hasSuffix("s") && !$0.hasSuffix("ss") ? String($0.dropLast()) : $0 }
    }

    // MARK: Words for the agent and the card

    /// An accessory as the agent reads it, and as a `home` card's device.
    static func row(_ thing: HomeThing, us: Bool) -> JSONValue {
        var out: [String: JSONValue] = [
            "name": .string(thing.name), "kind": .string(thing.kind.cardKind), "type": .string(thing.kind.rawValue),
            "state": .string(state(thing)), "entity": .string(thing.entity),
        ]
        if let room = thing.room { out["area"] = .string(room) }
        if !thing.reachable { out["reachable"] = .bool(false) }
        if let brightness = thing.brightness, thing.kind == .light { out["brightness"] = .number(Double(brightness)) }
        let unit = us ? "°F" : "°C"
        func degrees(_ celsius: Double) -> JSONValue { .number(((us ? celsius * 9 / 5 + 32 : celsius) * 2).rounded() / 2) }
        if let now = thing.currentTemperature { out["temperature"] = degrees(now); out["unit"] = .string(unit) }
        if let target = thing.targetTemperature, thing.kind == .thermostat { out["target"] = degrees(target); out["unit"] = .string(unit) }
        if let position = thing.position, [.blind, .window, .door].contains(thing.kind) { out["position"] = .number(Double(position)) }
        if let speed = thing.fanSpeed, thing.kind == .fan { out["fan_speed"] = .number(Double(speed)) }
        return .object(out)
    }

    /// Its state in the card's words: "on", "off", "open", "closed", "locked", "heat", "48%".
    static func state(_ thing: HomeThing) -> String {
        switch thing.kind {
        case .light, .switch, .outlet, .fan: thing.on == true ? "on" : thing.on == false ? "off" : "unknown"
        case .thermostat: thing.mode ?? "unknown"
        case .blind, .window, .door: thing.position.map { $0 > 0 ? "open" : "closed" } ?? "unknown"
        case .garage: thing.door ?? "unknown"
        case .lock: thing.locked == true ? "locked" : thing.locked == false ? "unlocked" : "unknown"
        case .security: thing.security ?? "unknown"
        case .sensor, .other: thing.reading ?? (thing.on.map { $0 ? "on" : "off" }) ?? "unknown"
        }
    }
}

nonisolated extension HomeThing {
    /// As it will be once `change` is done, for the answer.
    func applying(_ change: HomeChange) -> HomeThing {
        var next = self
        if let on = change.on { next.on = on }
        if let brightness = change.brightness { next.brightness = brightness; if brightness > 0 { next.on = true } }
        if let target = change.targetTemperature { next.targetTemperature = target }
        if let mode = change.mode { next.mode = mode }
        if let speed = change.fanSpeed { next.fanSpeed = speed }
        if let position = change.position { next.position = position }
        if let lock = change.lock { next.locked = lock }
        if let open = change.openDoor {
            if kind == .garage { next.door = open ? "open" : "closed" } else { next.position = open ? 100 : 0 }
        }
        if let security = change.security { next.security = security }
        return next
    }
}

nonisolated extension ReplyCard.Home.Device {
    /// The Apple Home accessory a card's row stands for (`homekit:<kind>:<id>`), whose controls
    /// work on the phone directly; nil for Home Assistant's.
    var homeKit: (kind: HomeKind, id: String)? {
        guard let entity, entity.hasPrefix("homekit:") else { return nil }
        let parts = entity.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, let kind = HomeKind(rawValue: parts[1]) else { return nil }
        return (kind, parts[2])
    }
}

/// No home at all: the Mac's.
nonisolated struct NoHome: HomeLayer {
    func snapshot() async throws -> HomeSnapshot { throw DeviceHome.offPhone }
    func apply(_ change: HomeChange, to thing: HomeThing) async throws { throw DeviceHome.offPhone }
    func run(_ scene: HomeScene) async throws { throw DeviceHome.offPhone }
}

/// A made-up home, for tests and `-echo.demoHome`: it remembers what was done to it.
nonisolated final class DemoHome: HomeLayer, @unchecked Sendable {
    private let lock = NSLock()
    private var state: HomeSnapshot
    private(set) var applied: [(HomeChange, String)] = []
    private(set) var ran: [String] = []

    init(_ state: HomeSnapshot = DemoHome.sample) { self.state = state }

    func snapshot() async throws -> HomeSnapshot { lock.withLock { state } }
    func apply(_ change: HomeChange, to thing: HomeThing) async throws {
        lock.withLock {
            applied.append((change, thing.id))
            if let index = state.things.firstIndex(where: { $0.id == thing.id }) { state.things[index] = state.things[index].applying(change) }
        }
    }
    func run(_ scene: HomeScene) async throws { lock.withLock { ran.append(scene.name) } }

    static let sample = HomeSnapshot(homes: ["Home"], things: [
        HomeThing(id: "L1", name: "Ceiling Light", room: "Office", home: "Home", kind: .light, on: true, brightness: 80),
        HomeThing(id: "L2", name: "Desk Lamp", room: "Office", home: "Home", kind: .light, on: false, brightness: 40),
        HomeThing(id: "L3", name: "Pendant", room: "Kitchen", home: "Home", kind: .light, on: true, brightness: 100),
        HomeThing(id: "L4", name: "Under Cabinet", room: "Kitchen", home: "Home", kind: .light, on: true, brightness: 60),
        HomeThing(id: "P1", name: "Coffee Maker", room: "Kitchen", home: "Home", kind: .outlet, on: false),
        HomeThing(id: "T1", name: "Thermostat", room: "Hall", home: "Home", kind: .thermostat, currentTemperature: 20.5, targetTemperature: 21, mode: "heat"),
        HomeThing(id: "B1", name: "Bedroom Blinds", room: "Bedroom", home: "Home", kind: .blind, position: 100),
        HomeThing(id: "G1", name: "Garage Door", room: "Garage", home: "Home", kind: .garage, door: "closed"),
        HomeThing(id: "K1", name: "Front Door", room: "Entry", home: "Home", kind: .lock, locked: true),
        HomeThing(id: "S1", name: "Basement Humidity", room: "Basement", home: "Home", kind: .sensor, reading: "48%"),
    ], scenes: [
        HomeScene(id: "N1", name: "Good Night", home: "Home", sensitive: false),
        HomeScene(id: "N2", name: "Arrive Home", home: "Home", sensitive: true),
    ])
}

#if os(iOS)
/// The real thing: HomeKit's own home manager, made once, on the main actor where HomeKit wants
/// it. iOS asks the person the first time it is made.
nonisolated final class HomeKitLayer: HomeLayer, @unchecked Sendable {
    static let shared = HomeKitLayer()

    @MainActor private var manager: HMHomeManager?
    @MainActor private var watcher: HomeWatcher?

    /// The manager with its homes loaded (HomeKit fills them in a moment after it is made).
    @MainActor private func ready() async -> HMHomeManager {
        if let manager { return manager }
        let watcher = HomeWatcher()
        let made = HMHomeManager()
        made.delegate = watcher
        self.watcher = watcher
        manager = made
        for _ in 0 ..< 80 where !watcher.updated { try? await Task.sleep(for: .milliseconds(100)) }
        return made
    }

    func allowed() async -> Bool {
        await mainAllowed()
    }

    @MainActor private func mainAllowed() async -> Bool {
        let manager = await ready()
        // The person may still be reading iOS's question: up to a minute for an answer.
        for _ in 0 ..< 600 where !manager.authorizationStatus.contains(.determined) { try? await Task.sleep(for: .milliseconds(100)) }
        return manager.authorizationStatus.contains(.authorized)
    }

    func snapshot() async throws -> HomeSnapshot { try await mainSnapshot() }

    @MainActor private func mainSnapshot() async throws -> HomeSnapshot {
        let manager = await ready()
        guard manager.authorizationStatus.contains(.authorized) else { throw DeviceToolError.refused(.home) }
        // A fresh reading of what each row shows, all at once; whatever hasn't answered in two
        // seconds is given as HomeKit last knew it.
        let wanted = manager.homes.flatMap(\.accessories).compactMap(Self.primary).flatMap { Self.shown($0).values }
        await Self.read(wanted, within: .seconds(2))
        var things: [HomeThing] = [], scenes: [HomeScene] = []
        for home in manager.homes {
            for accessory in home.accessories {
                guard let service = Self.primary(accessory) else { continue }
                things.append(Self.thing(accessory, service, home: home.name))
            }
            for set in home.actionSets where set.actionSetType == HMActionSetTypeUserDefined || set.actionSetType == HMActionSetTypeWakeUp
                || set.actionSetType == HMActionSetTypeSleep || set.actionSetType == HMActionSetTypeHomeArrival || set.actionSetType == HMActionSetTypeHomeDeparture {
                scenes.append(HomeScene(id: set.uniqueIdentifier.uuidString, name: set.name, home: home.name, sensitive: Self.sensitive(set)))
            }
        }
        return HomeSnapshot(homes: manager.homes.map(\.name), things: things, scenes: scenes)
    }

    func apply(_ change: HomeChange, to thing: HomeThing) async throws { try await mainApply(change, thing) }

    @MainActor private func mainApply(_ change: HomeChange, _ thing: HomeThing) async throws {
        let manager = await ready()
        guard let accessory = manager.homes.flatMap(\.accessories).first(where: { $0.uniqueIdentifier.uuidString == thing.id }),
              let service = Self.primary(accessory) else {
            throw DeviceToolError("\(thing.name) isn't in Apple Home any more.")
        }
        guard accessory.isReachable else { throw DeviceToolError("\(thing.name) isn't answering: Apple Home says it is unreachable.") }
        let c = Self.shown(service)
        var writes: [(HMCharacteristic, Any)] = []
        func put(_ type: String, _ value: Any?) {
            guard let value else { return }
            guard let characteristic = c[type] else { return }
            writes.append((characteristic, value))
        }
        if let on = change.on { put(c[HMCharacteristicTypeActive] != nil && c[HMCharacteristicTypePowerState] == nil ? HMCharacteristicTypeActive : HMCharacteristicTypePowerState, on ? 1 : 0) }
        put(HMCharacteristicTypeBrightness, change.brightness)
        put(HMCharacteristicTypeColorTemperature, change.colorTemperature.map { Int((1_000_000 / Double($0)).rounded()) })
        put(HMCharacteristicTypeHue, change.hue)
        put(HMCharacteristicTypeSaturation, change.saturation)
        put(HMCharacteristicTypeTargetTemperature, change.targetTemperature.map { ($0 * 2).rounded() / 2 })
        put(HMCharacteristicTypeTargetHeatingCooling, change.mode.map { ["off": 0, "heat": 1, "cool": 2, "auto": 3][$0] ?? 3 })
        put(HMCharacteristicTypeRotationSpeed, change.fanSpeed)
        put(HMCharacteristicTypeTargetPosition, change.position ?? (thing.kind == .garage ? nil : change.openDoor.map { $0 ? 100 : 0 }))
        put(HMCharacteristicTypeTargetLockMechanismState, change.lock.map { $0 ? 1 : 0 })
        if thing.kind == .garage { put(HMCharacteristicTypeTargetDoorState, change.openDoor.map { $0 ? 0 : 1 }) }
        put(HMCharacteristicTypeTargetSecuritySystemState, change.security.map { ["home": 0, "away": 1, "night": 2, "off": 3][$0] ?? 3 })
        guard !writes.isEmpty else { throw DeviceToolError("\(thing.name) can't do that: it has no such control in Apple Home.") }
        for (characteristic, value) in writes { try await Self.write(characteristic, value) }
    }

    func run(_ scene: HomeScene) async throws { try await mainRun(scene) }

    @MainActor private func mainRun(_ scene: HomeScene) async throws {
        let manager = await ready()
        for home in manager.homes {
            if let set = home.actionSets.first(where: { $0.uniqueIdentifier.uuidString == scene.id }) {
                try await Self.execute(home, set)
                return
            }
        }
        throw DeviceToolError("The scene \"\(scene.name)\" isn't in Apple Home any more.")
    }

    // MARK: HomeKit's pieces

    /// The service a row stands for: the first that does something, in this order.
    @MainActor private static func primary(_ accessory: HMAccessory) -> HMService? {
        let order = [HMServiceTypeLockMechanism, HMServiceTypeGarageDoorOpener, HMServiceTypeSecuritySystem, HMServiceTypeThermostat,
                     HMServiceTypeHeaterCooler, HMServiceTypeLightbulb, HMServiceTypeFan, HMServiceTypeWindowCovering, HMServiceTypeWindow,
                     HMServiceTypeDoor, HMServiceTypeOutlet, HMServiceTypeSwitch, HMServiceTypeTemperatureSensor, HMServiceTypeHumiditySensor,
                     HMServiceTypeContactSensor, HMServiceTypeMotionSensor]
        for type in order { if let service = accessory.services.first(where: { $0.serviceType == type }) { return service } }
        return nil
    }

    @MainActor private static func kind(_ service: HMService) -> HomeKind {
        switch service.serviceType {
        case HMServiceTypeLightbulb: .light
        case HMServiceTypeSwitch: .switch
        case HMServiceTypeOutlet: .outlet
        case HMServiceTypeFan: .fan
        case HMServiceTypeThermostat, HMServiceTypeHeaterCooler: .thermostat
        case HMServiceTypeWindowCovering: .blind
        case HMServiceTypeWindow: .window
        case HMServiceTypeDoor: .door
        case HMServiceTypeGarageDoorOpener: .garage
        case HMServiceTypeLockMechanism: .lock
        case HMServiceTypeSecuritySystem: .security
        case HMServiceTypeTemperatureSensor, HMServiceTypeHumiditySensor, HMServiceTypeContactSensor, HMServiceTypeMotionSensor: .sensor
        default: .other
        }
    }

    /// The service's characteristics a row reads or a change writes, by type.
    @MainActor private static func shown(_ service: HMService) -> [String: HMCharacteristic] {
        let types: Set<String> = [HMCharacteristicTypePowerState, HMCharacteristicTypeActive, HMCharacteristicTypeBrightness, HMCharacteristicTypeColorTemperature,
                                  HMCharacteristicTypeHue, HMCharacteristicTypeSaturation, HMCharacteristicTypeCurrentTemperature, HMCharacteristicTypeTargetTemperature,
                                  HMCharacteristicTypeTargetHeatingCooling, HMCharacteristicTypeCurrentHeatingCooling, HMCharacteristicTypeRotationSpeed,
                                  HMCharacteristicTypeTargetPosition, HMCharacteristicTypeCurrentPosition, HMCharacteristicTypeTargetLockMechanismState,
                                  HMCharacteristicTypeCurrentLockMechanismState, HMCharacteristicTypeTargetDoorState, HMCharacteristicTypeCurrentDoorState,
                                  HMCharacteristicTypeTargetSecuritySystemState, HMCharacteristicTypeCurrentSecuritySystemState,
                                  HMCharacteristicTypeCurrentRelativeHumidity, HMCharacteristicTypeContactState, HMCharacteristicTypeMotionDetected]
        var found: [String: HMCharacteristic] = [:]
        for characteristic in service.characteristics where types.contains(characteristic.characteristicType) {
            found[characteristic.characteristicType] = characteristic
        }
        return found
    }

    @MainActor private static func thing(_ accessory: HMAccessory, _ service: HMService, home: String) -> HomeThing {
        let c = shown(service)
        func int(_ type: String) -> Int? { (c[type]?.value as? NSNumber)?.intValue }
        func double(_ type: String) -> Double? { (c[type]?.value as? NSNumber)?.doubleValue }
        let kind = kind(service)
        var thing = HomeThing(id: accessory.uniqueIdentifier.uuidString, name: accessory.name, room: accessory.room?.name, home: home,
                              kind: kind, reachable: accessory.isReachable)
        if let power = int(HMCharacteristicTypePowerState) ?? int(HMCharacteristicTypeActive) { thing.on = power != 0 }
        thing.brightness = int(HMCharacteristicTypeBrightness)
        thing.colorTemperature = int(HMCharacteristicTypeColorTemperature).flatMap { $0 > 0 ? Int((1_000_000 / Double($0)).rounded()) : nil }
        thing.currentTemperature = double(HMCharacteristicTypeCurrentTemperature)
        thing.targetTemperature = double(HMCharacteristicTypeTargetTemperature)
        thing.mode = int(HMCharacteristicTypeTargetHeatingCooling).map { [0: "off", 1: "heat", 2: "cool", 3: "auto"][$0] ?? "auto" }
        thing.fanSpeed = int(HMCharacteristicTypeRotationSpeed)
        thing.position = int(HMCharacteristicTypeCurrentPosition)
        thing.locked = int(HMCharacteristicTypeCurrentLockMechanismState).flatMap { [0: false, 1: true][$0] }
        thing.door = int(HMCharacteristicTypeCurrentDoorState).map { [0: "open", 1: "closed", 2: "opening", 3: "closing"][$0] ?? "stopped" }
        thing.security = int(HMCharacteristicTypeCurrentSecuritySystemState).map { [0: "home", 1: "away", 2: "night", 3: "off"][$0] ?? "triggered" }
        if kind == .sensor {
            thing.reading = int(HMCharacteristicTypeCurrentRelativeHumidity).map { "\($0)%" }
                ?? int(HMCharacteristicTypeContactState).map { $0 == 0 ? "closed" : "open" }
                ?? int(HMCharacteristicTypeMotionDetected).map { $0 != 0 ? "motion" : "still" }
        }
        return thing
    }

    /// A scene that unlocks, opens or arms: put to the person first.
    @MainActor private static func sensitive(_ set: HMActionSet) -> Bool {
        let risky: Set<String> = [HMServiceTypeLockMechanism, HMServiceTypeGarageDoorOpener, HMServiceTypeSecuritySystem, HMServiceTypeDoor, HMServiceTypeWindow]
        return set.actions.contains { action in
            guard let write = action as? HMCharacteristicWriteAction<NSCopying> else { return false }
            return risky.contains(write.characteristic.service?.serviceType ?? "")
        }
    }

    /// Asks each characteristic for its value now, and waits at most `within` for them all.
    @MainActor private static func read(_ characteristics: [HMCharacteristic], within: Duration) async {
        let readable = characteristics.filter { $0.properties.contains(HMCharacteristicPropertyReadable) && $0.service?.accessory?.isReachable == true }
        let count = Counter(readable.count)
        start(readable, count)
        let deadline = ContinuousClock.now + within
        while !count.done, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
    }

    @MainActor private static func start(_ readable: [HMCharacteristic], _ count: Counter) {
        for characteristic in readable { characteristic.readValue(completionHandler: count.callback()) }
    }

    @MainActor private static func write(_ characteristic: HMCharacteristic, _ value: Any) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
            characteristic.writeValue(value, completionHandler: finish(done))
        }
    }

    @MainActor private static func execute(_ home: HMHome, _ set: HMActionSet) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
            home.executeActionSet(set, completionHandler: finish(done))
        }
    }

    /// A completion HomeKit calls on a queue of its own: made outside the main actor, so it can
    /// run there (a main-actor closure called off the main thread stops the app).
    nonisolated private static func finish(_ done: CheckedContinuation<Void, any Error>) -> @Sendable (Error?) -> Void {
        { error in
            if let error { done.resume(throwing: DeviceToolError("Apple Home said: \(error.localizedDescription)")) } else { done.resume() }
        }
    }

    /// How many reads are still out.
    nonisolated private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var left: Int
        init(_ count: Int) { left = count }
        var done: Bool { lock.lock(); defer { lock.unlock() }; return left <= 0 }
        func callback() -> @Sendable (Error?) -> Void { { [self] _ in lock.lock(); left -= 1; lock.unlock() } }
    }
}

/// HomeKit's word that the homes have loaded. Its calls come on HomeKit's queue: nothing here is
/// the main actor's.
nonisolated private final class HomeWatcher: NSObject, HMHomeManagerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var loaded = false
    var updated: Bool { lock.lock(); defer { lock.unlock() }; return loaded }
    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) { lock.lock(); loaded = true; lock.unlock() }
    func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) { lock.lock(); loaded = true; lock.unlock() }
}
#endif
