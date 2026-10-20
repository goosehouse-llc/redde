import SwiftUI

/// Picking a bot's face (the chat list's Bots, and a bot's chat's ••• menu): its shape, eyes, mouth,
/// a mark and a colour, each choice drawn as the bot with that part changed. Kept on the server, so
/// every Redde on it shows the same face (`HermesServeClient.setFace`); "Its Own Face" goes back to
/// the one its name gives. Redde's own bubble isn't offered: no other bot can have it. For a bot
/// not made yet (New Bot), `choose` is given the face instead, and nothing is written.
struct BotFacePicker: View {
    let bot: HermesBot
    /// What the bot is called here.
    let name: String
    var onSaved: () -> Void = {}
    var choose: ((BotFace?) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var face: BotFace
    private let current: BotFace
    @State private var saving = false
    @State private var problem: String?

    init(bot: HermesBot, name: String, current: BotFace, onSaved: @escaping () -> Void = {}, choose: ((BotFace?) -> Void)? = nil) {
        self.bot = bot
        self.name = name
        self.current = current
        self.onSaved = onSaved
        self.choose = choose
        _face = State(initialValue: current)
    }

    static let colorNames = ["Blue", "Amber", "Pink", "Indigo", "Teal", "Violet", "Green", "Orange", "Sky", "Coral", "Lime"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    BotAvatar(face: face, size: 132)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .accessibilityElement()
                        .accessibilityLabel("\(name)'s face: \(Self.describe(face))")
                }
                .listRowBackground(Color.clear)
                // Redde's own bubble is the main agent's alone.
                Section("Shape") { row(bot.isDefault ? [.bubble] + BotFace.Shape.given : BotFace.Shape.given, \.shape) }
                Section("Eyes") { row(BotFace.Eyes.allCases, \.eyes) }
                Section("Mouth") { row(BotFace.Mouth.allCases, \.mouth) }
                Section("Mark") { row(BotFace.Mark.allCases, \.mark) }
                Section("Colour") { colours }
                Section {
                    Button("Surprise Me", systemImage: "dice") { face = Self.random(keeping: face) }
                    if bot.face != nil {
                        Button("Its Own Face", systemImage: "arrow.uturn.backward") { save(nil) }
                            .disabled(saving)
                    }
                } footer: {
                    Text(choose == nil ? "Kept on your Hermes server, so Redde on your other devices shows it too."
                                       : "Kept on your Hermes server once the bot is made, so Redde on your other devices shows it too.")
                }
                if let problem {
                    Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }
            }
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save") { save(face) }.disabled(face == current)
                    }
                }
            }
        }
    }

    /// One part's choices in a row, each the whole face with that part changed.
    private func row<Part: RawRepresentable & Hashable>(_ parts: [Part], _ key: WritableKeyPath<BotFace, Part>) -> some View where Part.RawValue == String {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(parts, id: \.self) { part in
                    let picked = face[keyPath: key] == part
                    Button { face[keyPath: key] = part } label: {
                        VStack(spacing: 4) {
                            BotAvatar(face: Self.with(face, key, part), size: 50)
                                .padding(5)
                                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(picked ? Color.accentColor.opacity(0.14) : .clear))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(picked ? Color.accentColor : .clear, lineWidth: 2))
                            Text(part.rawValue.capitalized)
                                .font(.caption2)
                                .foregroundStyle(picked ? .primary : .secondary)
                        }
                        .frame(minWidth: 64)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(part.rawValue.capitalized)
                    .accessibilityAddTraits(picked ? .isSelected : [])
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var colours: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(BotFace.palette.indices, id: \.self) { index in
                    let picked = face.color == index
                    Button { face.color = index } label: {
                        Circle()
                            .fill(LinearGradient(colors: [BotFace.palette[index].light, BotFace.palette[index].deep], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 34, height: 34)
                            .padding(4)
                            .overlay(Circle().strokeBorder(picked ? Color.accentColor : .clear, lineWidth: 2.5))
                            .frame(width: 44, height: 44)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Self.colorNames[index])
                    .accessibilityAddTraits(picked ? .isSelected : [])
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func save(_ picked: BotFace?) {
        if let choose {
            choose(picked)
            dismiss()
            return
        }
        saving = true
        problem = nil
        Task {
            defer { saving = false }
            do {
                try await HermesServeClient.shared.setFace(picked, for: bot)
                onSaved()
                dismiss()
            } catch {
                problem = error.localizedDescription
                if error is BotFaceProblem { onSaved() }
            }
        }
    }

    nonisolated static func with<Part>(_ face: BotFace, _ key: WritableKeyPath<BotFace, Part>, _ part: Part) -> BotFace {
        var face = face
        face[keyPath: key] = part
        return face
    }

    nonisolated static func describe(_ face: BotFace) -> String {
        let mouth = face.mouth == .none ? "" : ", \(face.mouth.rawValue) mouth"
        let mark = face.mark == .none ? "" : ", \(face.mark.rawValue)"
        return "\(colorNames[face.color % colorNames.count].lowercased()) \(face.shape.rawValue), \(face.eyes.rawValue) eyes\(mouth)\(mark)"
    }

    /// Any face but Redde's, with the lean and the glance it has.
    nonisolated static func random(keeping face: BotFace) -> BotFace {
        BotFace(shape: BotFace.Shape.given.randomElement() ?? .round, eyes: BotFace.Eyes.allCases.randomElement() ?? .round,
                mouth: BotFace.Mouth.allCases.randomElement() ?? .none, mark: BotFace.Mark.allCases.randomElement() ?? .none,
                glance: face.glance, tilt: face.tilt, color: Int.random(in: 0 ..< BotFace.palette.count))
    }
}
