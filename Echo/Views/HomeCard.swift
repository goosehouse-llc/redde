import SwiftUI

/// The home's devices (`ReplyCard.home`, asked 2026-10-30: "turn off the lights", "is the garage
/// closed?", "set the house to 70"): each a row with its state as Home Assistant reported it, and
/// its control: a switch, a brightness or temperature stepper, Open or Close, Lock or Unlock. A
/// control asks the agent with a short message ("Turn off Kitchen lights", naming the entity), and
/// the agent does it with its own Home Assistant tools: Redde never talks to Home Assistant itself.
/// The row says so while the agent is at it, and what was asked after. Unlocking a door or opening
/// a garage asks here first. With several lights on, "All off" asks for them all.
struct HomeCard: View {
    let card: ReplyCard.Home
    let whole: ReplyCard
    /// What each device was asked to do, by its place, as the row says it ("Turn off").
    @State private var asked: [Int: Ask] = [:]
    /// A stepper's value not sent yet, by its place; it goes a moment after the last tap.
    @State private var drafts: [Int: Double] = [:]
    @State private var waiting: Task<Void, Never>?
    @State private var confirming: Confirm?
    @Environment(\.answerCard) private var answerer
    @Environment(\.pinnedCard) private var pinned

    struct Ask: Equatable {
        var label: String
        /// Where a switch now stands.
        var on: Bool?
    }

    struct Confirm: Identifiable {
        var index: Int
        var action: Action
        var id: Int { index }
    }

    /// What a control asks for.
    enum Action: Equatable {
        case power(Bool), brightness(Int), target(Double), open(Bool), lock(Bool), play(Bool)
    }

    private var lightsOn: [Int] { card.devices.indices.filter { card.devices[$0].kind == .light && isOn($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardBox(spacing: 12) {
                CardTitle(symbol: "house", title: card.title ?? String(localized: "Home", comment: "A home card's title when the agent gave none"),
                          subtitle: Self.summary(card))
                VStack(spacing: 0) {
                    ForEach(Array(card.devices.enumerated()), id: \.offset) { index, device in
                        if index > 0 { Divider().padding(.leading, 52) }
                        row(device, index: index)
                    }
                }
            }
            if let answerer, !pinned, lightsOn.count >= 2 {
                Button { allOff(answerer) } label: {
                    CardChip(title: String(localized: "All off", comment: "A chip under a home card: asks the agent to turn every light on it off"),
                             symbol: "lightbulb.slash", busy: answerer.busy)
                }
                .buttonStyle(.plain)
                .disabled(answerer.busy)
                .accessibilityHint(Text("Asks your agent to turn these lights off", comment: "VoiceOver hint: a home card's All off"))
                .padding(.horizontal, 2)
            }
        }
        .confirmationDialog(confirming.map { Self.title($0.action, card.devices[$0.index]) } ?? "",
                            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible) {
            if let confirming {
                Button(Self.verb(confirming.action), role: .destructive) { send(confirming.action, to: confirming.index) }
            }
        } message: {
            Text("Your agent will do it with Home Assistant.", comment: "Under the question before a home card unlocks a door or opens a garage")
        }
        .onDisappear { waiting?.cancel() }
    }

    // MARK: A device

    private func row(_ device: ReplyCard.Home.Device, index: Int) -> some View {
        let on = isOn(index)
        let pending = asked[index]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: Self.symbol(device, on: on))
                    .chatFont(.body, weight: .medium)
                    .foregroundStyle(on ? Self.glow(device.kind) : Color.secondary)
                    .frame(width: 40, height: 40)
                    .background(on ? Self.glow(device.kind).opacity(0.18) : Color.primary.opacity(0.06), in: .rect(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).chatFont(.subheadline, weight: .semibold).lineLimit(1)
                    if let pending {
                        HStack(spacing: 5) {
                            if answerer?.busy == true { ProgressView().controlSize(.mini) } else { Image(systemName: "checkmark.circle.fill").imageScale(.small) }
                            Text(answerer?.busy == true ? String(localized: "\(pending.label)…", comment: "A home card's device while the agent is asked to change it, e.g. Turn off…")
                                 : String(localized: "Asked: \(pending.label)", comment: "A home card's device once the agent was asked, e.g. Asked: Turn off"))
                        }
                        .chatFont(.caption, weight: .medium).foregroundStyle(.tint).lineLimit(1)
                    } else {
                        Text(Self.status(device)).chatFont(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                    }
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 8)
                control(device, index: index)
            }
            .padding(.vertical, 10)
            if device.kind == .light, on, let brightness = drafts[index].map({ Int($0) }) ?? device.brightness {
                stepper(value: "\(brightness)%", fraction: Double(brightness) / 100, index: index,
                        down: { step(index, from: Double(brightness), by: -10, in: 1 ... 100) },
                        up: { step(index, from: Double(brightness), by: 10, in: 1 ... 100) },
                        label: String(localized: "Brightness of \(device.name)", comment: "VoiceOver: a home card's brightness stepper"))
                    .padding(.leading, 52).padding(.bottom, 8)
            }
            if device.kind == .climate, let target = drafts[index] ?? device.target {
                let step = Self.step(device), range = Self.range(device)
                adjuster(index: index, down: { self.step(index, from: target, by: -step, in: range) }, up: { self.step(index, from: target, by: step, in: range) },
                         label: String(localized: "\(device.name) setting", comment: "VoiceOver: a home card's thermostat stepper, e.g. Thermostat setting"), value: Self.degrees(target)) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Set to", comment: "A home card's thermostat: what it is set to, before the temperature").chatFont(.footnote).foregroundStyle(.secondary)
                        Text(verbatim: Self.degrees(target)).chatFont(.title3, weight: .semibold).monospacedDigit()
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.leading, 52).padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private func control(_ device: ReplyCard.Home.Device, index: Int) -> some View {
        let busy = answerer == nil || answerer?.busy == true
        switch device.kind {
        case .light, .switch, .fan:
            Toggle(device.name, isOn: Binding(get: { isOn(index) }, set: { ask(.power($0), index) }))
                .labelsHidden()
                .disabled(busy)
                .accessibilityHint(Text("Asks your agent to turn it on or off", comment: "VoiceOver hint: a home card's switch"))
        case .media:
            pill(isOn(index) ? String(localized: "Pause", comment: "A home card's media player: pause") : String(localized: "Play", comment: "A home card's media player: play"),
                 symbol: isOn(index) ? "pause.fill" : "play.fill") { ask(.play(!isOn(index)), index) }
                .disabled(busy)
        case .climate:
            EmptyView()
        case .cover:
            pill(isOn(index) ? String(localized: "Close", comment: "A home card's door or blind: close it") : String(localized: "Open", comment: "A home card's door or blind: open it"),
                 symbol: isOn(index) ? "arrow.down.to.line" : "arrow.up.to.line") { ask(.open(!isOn(index)), index) }
                .disabled(busy)
        case .lock:
            let locked = !isOn(index)
            pill(locked ? String(localized: "Unlock", comment: "A home card's lock: unlock it") : String(localized: "Lock", comment: "A home card's lock: lock it"),
                 symbol: locked ? "lock.open" : "lock") { ask(.lock(!locked), index) }
                .disabled(busy)
        case .sensor:
            if let value = Self.reading(device) {
                Text(verbatim: value).chatFont(.title3, weight: .semibold).monospacedDigit()
            }
        }
    }

    private func pill(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .chatFont(.subheadline, weight: .semibold)
                .foregroundStyle(.tint)
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .background(.tint.opacity(0.12), in: .capsule)
                .frame(minHeight: 44)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }

    private func round(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .chatFont(.footnote, weight: .bold)
                .foregroundStyle(.tint)
                .frame(width: 30, height: 30)
                .background(.tint.opacity(0.12), in: .circle)
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
    }

    /// A light's brightness: a bar to scale between − and +.
    private func stepper(value: String, fraction: Double, index: Int, down: @escaping () -> Void, up: @escaping () -> Void, label: String) -> some View {
        adjuster(index: index, down: down, up: up, label: label, value: value) {
            HStack(spacing: 10) {
                GeometryReader { proxy in
                    Capsule().fill(Color.primary.opacity(0.08))
                        .overlay(alignment: .leading) {
                            Capsule().fill(Self.glow(.light)).frame(width: max(8, proxy.size.width * fraction))
                        }
                }
                .frame(height: 6)
                Text(verbatim: value).chatFont(.footnote, weight: .semibold).monospacedDigit().frame(minWidth: 40, alignment: .trailing)
            }
        }
    }

    /// − and + round what they change: a light's brightness, a thermostat's setting.
    private func adjuster<Middle: View>(index: Int, down: @escaping () -> Void, up: @escaping () -> Void, label: String, value: String,
                                        @ViewBuilder middle: () -> Middle) -> some View {
        HStack(spacing: 6) {
            round("minus", action: down)
            middle()
            round("plus", action: up)
        }
        .padding(.vertical, -6)
        .disabled(answerer == nil || answerer?.busy == true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
        .accessibilityAdjustableAction { $0 == .increment ? up() : down() }
    }

    // MARK: Asking

    private func isOn(_ index: Int) -> Bool { asked[index]?.on ?? card.devices[index].isOn }

    private func ask(_ action: Action, _ index: Int) {
        if Self.isRisky(action, card.devices[index]) { confirming = Confirm(index: index, action: action) } else { send(action, to: index) }
    }

    /// A stepper's tap: shown at once, sent a moment after the last.
    private func step(_ index: Int, from value: Double, by amount: Double, in range: ClosedRange<Double>) {
        let next = min(range.upperBound, max(range.lowerBound, value + amount))
        drafts[index] = next
        waiting?.cancel()
        let device = card.devices[index]
        waiting = Task {
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            send(device.kind == .climate ? .target(next) : .brightness(Int(next)), to: index)
        }
    }

    private func send(_ action: Action, to index: Int) {
        guard let answerer else { return }
        let device = card.devices[index]
        let message = Self.message(action, device)
        var now: Bool?
        switch action {
        case let .power(on), let .open(on), let .play(on): now = on
        case let .lock(locked): now = !locked
        case .brightness, .target: now = nil
        }
        asked[index] = Ask(label: Self.verb(action), on: now)
        answerer.answer(whole, message.shown, message.said)
    }

    private func allOff(_ answerer: CardAnswerer) {
        let lights = lightsOn.map { card.devices[$0] }
        for index in lightsOn { asked[index] = Ask(label: Self.verb(.power(false)), on: false) }
        let message = Self.allOff(lights)
        answerer.answer(whole, message.shown, message.said)
    }

    // MARK: Words

    /// "Turn off", "Set to 60%", "Unlock": what a control asks, as the row and the dialog say it.
    static func verb(_ action: Action) -> String {
        switch action {
        case let .power(on): on ? String(localized: "Turn on", comment: "A home card's device: turn it on") : String(localized: "Turn off", comment: "A home card's device: turn it off")
        case let .brightness(percent): String(localized: "Set to \(percent)%", comment: "A home card's light: set its brightness, e.g. Set to 60%")
        case let .target(degrees): String(localized: "Set to \(Self.degrees(degrees))", comment: "A home card's thermostat: set it, e.g. Set to 71°")
        case let .open(open): open ? String(localized: "Open", comment: "A home card's door or blind: open it") : String(localized: "Close", comment: "A home card's door or blind: close it")
        case let .lock(lock): lock ? String(localized: "Lock", comment: "A home card's lock: lock it") : String(localized: "Unlock", comment: "A home card's lock: unlock it")
        case let .play(play): play ? String(localized: "Play", comment: "A home card's media player: play") : String(localized: "Pause", comment: "A home card's media player: pause")
        }
    }

    /// "Unlock Front door?": the question before a risky one.
    static func title(_ action: Action, _ device: ReplyCard.Home.Device) -> String {
        String(localized: "\(verb(action)) \(device.name)?", comment: "The question before a home card unlocks a door or opens a garage, e.g. Unlock Front door?")
    }

    /// Unlocking, or opening a garage: asked here first.
    static func isRisky(_ action: Action, _ device: ReplyCard.Home.Device) -> Bool {
        switch action {
        case .lock(false): true
        case .open(true): device.risky
        default: false
        }
    }

    /// The person's message and the note to the agent: what to do, to which entity, with its own tools.
    static func message(_ action: Action, _ device: ReplyCard.Home.Device) -> (shown: String, said: String) {
        let shown = switch action {
        case let .power(on): on ? String(localized: "Turn on \(device.name)", comment: "The message a home card's switch sends, e.g. Turn on Kitchen lights")
            : String(localized: "Turn off \(device.name)", comment: "The message a home card's switch sends, e.g. Turn off Kitchen lights")
        case let .brightness(percent): String(localized: "Set \(device.name) to \(percent)%", comment: "The message a home card's brightness sends, e.g. Set Kitchen lights to 60%")
        case let .target(degrees): String(localized: "Set \(device.name) to \(Self.degrees(degrees))", comment: "The message a home card's thermostat sends, e.g. Set Thermostat to 71°")
        case let .open(open): open ? String(localized: "Open \(device.name)", comment: "The message a home card's door or blind sends, e.g. Open Garage door")
            : String(localized: "Close \(device.name)", comment: "The message a home card's door or blind sends, e.g. Close Garage door")
        case let .lock(lock): lock ? String(localized: "Lock \(device.name)", comment: "The message a home card's lock sends, e.g. Lock Front door")
            : String(localized: "Unlock \(device.name)", comment: "The message a home card's lock sends, e.g. Unlock Front door")
        case let .play(play): play ? String(localized: "Play \(device.name)", comment: "The message a home card's media player sends, e.g. Play Living room TV")
            : String(localized: "Pause \(device.name)", comment: "The message a home card's media player sends, e.g. Pause Living room TV")
        }
        let what = switch action {
        case let .power(on): on ? "turn on" : "turn off"
        case let .brightness(percent): "set the brightness to \(percent)% of"
        case let .target(degrees): "set to \(degrees.formatted(.number.precision(.fractionLength(0 ... 1))))°\(device.unit.map { " (\($0))" } ?? "") the target temperature of"
        case let .open(open): open ? "open" : "close"
        case let .lock(lock): lock ? "lock" : "unlock"
        case let .play(play): play ? "play" : "pause"
        }
        return (shown, "the user tapped on the home card: \(what) \"\(device.name)\"\(device.entity.map { " (\($0))" } ?? ""). " + doIt)
    }

    static func allOff(_ lights: [ReplyCard.Home.Device]) -> (shown: String, said: String) {
        let names = lights.map(\.name)
        return (String(localized: "Turn off \(names.formatted())", comment: "The message a home card's All off sends, with the lights' names"),
                "the user tapped All off on the home card: turn off " + lights.map { "\"\($0.name)\"" + ($0.entity.map { " (\($0))" } ?? "") }.joined(separator: ", ") + ". " + doIt)
    }

    private static let doIt = "Do it now with your Home Assistant tools, then say in a line what changed and show a fresh 'home' card with the new state."

    /// "3 lights on" or the areas.
    static func summary(_ card: ReplyCard.Home) -> String? {
        let lit = card.devices.filter { $0.kind == .light && $0.isOn }.count
        if lit == 1 { return String(localized: "1 light on", comment: "Under a home card's title: one of its lights is on") }
        if lit > 1 { return String(localized: "\(lit) lights on", comment: "Under a home card's title: how many of its lights are on") }
        let areas = card.devices.compactMap(\.area).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return areas.isEmpty ? nil : areas.prefix(3).joined(separator: ", ")
    }

    /// "On · 80%", "Off", "Heat · 68° now", "Closed", "Locked", "Kitchen" before it.
    static func status(_ device: ReplyCard.Home.Device) -> String {
        var parts: [String] = []
        if let area = device.area { parts.append(area) }
        let state = (device.state ?? "").lowercased()
        switch device.kind {
        case .light, .switch, .fan:
            parts.append(device.isOn ? String(localized: "On", comment: "A home card's device is on") : String(localized: "Off", comment: "A home card's device is off"))
            if device.kind == .light, device.isOn, let b = device.brightness { parts.append("\(b)%") }
        case .climate:
            if !state.isEmpty { parts.append(state.replacingOccurrences(of: "_", with: " ").capitalized) }
            if let now = device.temperature { parts.append(String(localized: "\(degrees(now)) now", comment: "A home card's thermostat: the room's temperature now, e.g. 68° now")) }
        case .cover:
            parts.append(device.isOn ? String(localized: "Open", comment: "A home card's door or blind is open") : String(localized: "Closed", comment: "A home card's door or blind is closed"))
        case .lock:
            parts.append(device.isOn ? String(localized: "Unlocked", comment: "A home card's lock is unlocked") : String(localized: "Locked", comment: "A home card's lock is locked"))
        case .media:
            parts.append(device.isOn ? String(localized: "Playing", comment: "A home card's media player is playing") : (state.isEmpty ? String(localized: "Off", comment: "A home card's device is off") : state.capitalized))
        case .sensor:
            if reading(device) == nil, !state.isEmpty { parts.append(state.capitalized) }
        }
        return parts.joined(separator: " · ")
    }

    /// A sensor's value with its unit ("21.5 °C", "48 %"), or its state where it is a number.
    static func reading(_ device: ReplyCard.Home.Device) -> String? {
        guard let value = device.temperature ?? device.state.flatMap({ Double($0) }) else { return nil }
        let number = value.formatted(.number.precision(.fractionLength(0 ... 1)))
        guard let unit = device.unit else { return number }
        return unit.hasPrefix("°") || unit == "%" ? number + unit : number + " " + unit
    }

    static func degrees(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0 ... 1))) + "°" }

    /// A thermostat's step: a degree in °F, half one in °C.
    static func step(_ device: ReplyCard.Home.Device) -> Double {
        let unit = (device.unit ?? MeasureUnits.temperature).uppercased()
        return unit.contains("C") ? 0.5 : 1
    }

    /// What a thermostat may be set to from the card.
    static func range(_ device: ReplyCard.Home.Device) -> ClosedRange<Double> { step(device) == 0.5 ? 7 ... 32 : 45 ... 90 }

    static func symbol(_ device: ReplyCard.Home.Device, on: Bool) -> String {
        let garage = [device.entity ?? "", device.name].joined(separator: " ").lowercased().contains("garage")
        return switch device.kind {
        case .light: on ? "lightbulb.fill" : "lightbulb"
        case .switch: on ? "powerplug.fill" : "powerplug"
        case .fan: "fan.fill"
        case .climate: "thermometer.medium"
        case .cover: garage ? (on ? "door.garage.open" : "door.garage.closed") : (on ? "blinds.horizontal.open" : "blinds.horizontal.closed")
        case .lock: on ? "lock.open.fill" : "lock.fill"
        case .sensor: (device.unit ?? "").contains("%") ? "humidity.fill" : (device.unit ?? "").contains("°") ? "thermometer.medium" : "sensor.fill"
        case .media: on ? "play.tv.fill" : "tv"
        }
    }

    /// A device's colour while on: a light's warm yellow, heat's orange, an open lock's orange.
    static func glow(_ kind: ReplyCard.Home.Device.Kind) -> Color {
        switch kind {
        case .light: Color(red: 0.98, green: 0.72, blue: 0.10)
        case .climate: .orange
        case .lock, .cover: .orange
        case .fan, .switch, .media, .sensor: .teal
        }
    }
}
