import PhotosUI
import SwiftUI

/// Picking a bot's face (the chat list's Bots, and a bot's chat's ••• menu): its shape, eyes, mouth,
/// a mark and a colour, each choice drawn as the bot with that part changed. Kept on the server, so
/// every Redde on it shows the same face (`HermesServeClient.setFace`); "Its Own Face" goes back to
/// the one its name gives. Redde's own bubble isn't offered: no other bot can have it. For a bot
/// not made yet (New Bot), `choose` is given the face instead, and nothing is written.
/// A photo from this phone can stand in for the face (asked 2026-11-10): kept where Hermes Desktop
/// keeps the picture it sets (`setBotPicture`), so both show it.
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
    /// A photo picked here, made ready to send (`BotPictures.prepare`), and as shown.
    @State private var photoItem: PhotosPickerItem?
    @State private var photo: Data?
    @State private var photoImage: PlatformImage?
    @State private var readingPhoto = false
    /// The picture it has is to be taken away.
    @State private var removingPhoto = false
    @State private var settings = Settings.shared

    init(bot: HermesBot, name: String, current: BotFace, onSaved: @escaping () -> Void = {}, choose: ((BotFace?) -> Void)? = nil) {
        self.bot = bot
        self.name = name
        // The creature, not the picture from Hermes Desktop that may stand for it elsewhere.
        var current = current
        current.picture = nil
        self.current = current
        self.onSaved = onSaved
        self.choose = choose
        _face = State(initialValue: current)
    }

    nonisolated static let colorNames = [String(localized: "Blue"), String(localized: "Amber"), String(localized: "Pink"), String(localized: "Indigo"),
                             String(localized: "Teal"), String(localized: "Violet"), String(localized: "Green"), String(localized: "Orange"),
                             String(localized: "Sky", comment: "A bot face's colour: sky blue"), String(localized: "Coral"),
                             String(localized: "Lime", comment: "A bot face's colour: lime green"), String(localized: "White"),
                             String(localized: "Black"), String(localized: "Theme", comment: "A bot face's colour: the theme's own"),
                             String(localized: "Code Blue", comment: "A bot face's colour: the Code theme's pale blue"),
                             String(localized: "Soft Pink"), String(localized: "Yellow"), String(localized: "Gold")]

    /// A face part's name (a shape, eyes, a mouth or a mark), by its raw value.
    nonisolated static func partName(_ raw: String) -> String {
        switch raw {
        case "round": String(localized: "Round", comment: "A bot face's shape or eyes")
        case "egg": String(localized: "Egg", comment: "A bot face's shape")
        case "pill": String(localized: "Pill", comment: "A bot face's shape")
        case "capsule": String(localized: "Capsule", comment: "A bot face's shape")
        case "burst": String(localized: "Burst", comment: "A bot face's shape")
        case "pick": String(localized: "Pick", comment: "A bot face's shape: a guitar pick")
        case "hex": String(localized: "Hex", comment: "A bot face's shape: a hexagon")
        case "diamond": String(localized: "Diamond", comment: "A bot face's shape")
        case "bubble": String(localized: "Bubble", comment: "A bot face's shape: a message bubble")
        case "ghost": String(localized: "Ghost", comment: "A bot face's shape")
        case "square": String(localized: "Square", comment: "A bot face's shape")
        case "house": String(localized: "House", comment: "A bot face's shape")
        case "star": String(localized: "Star", comment: "A bot face's shape")
        case "blob": String(localized: "Blob", comment: "A bot face's shape")
        case "paper": String(localized: "Paper", comment: "Name of a color theme in Settings → Appearance, and a bot face's shape: a sheet of paper")
        case "mismatched": String(localized: "Mismatched", comment: "A bot face's eyes")
        case "sleepy": String(localized: "Sleepy", comment: "A bot face's eyes")
        case "happy": String(localized: "Happy", comment: "A bot face's eyes")
        case "sparkle": String(localized: "Sparkle", comment: "A bot face's eyes")
        case "none": String(localized: "None", comment: "A bot face with no mouth, or no mark")
        case "smile": String(localized: "Smile", comment: "A bot face's mouth")
        case "oh": String(localized: "Oh", comment: "A bot face's mouth: a small round “oh”")
        case "grin": String(localized: "Grin", comment: "A bot face's mouth")
        case "antenna": String(localized: "Antenna", comment: "A bot face's mark")
        case "spark": String(localized: "Spark", comment: "A bot face's mark")
        case "freckles": String(localized: "Freckles", comment: "A bot face's mark")
        case "blush": String(localized: "Blush", comment: "A bot face's mark")
        case "lens": String(localized: "Magnifier", comment: "A bot face's eyes: one seen through a magnifying glass (a researcher's)")
        case "glasses": String(localized: "Glasses", comment: "A bot face's eyes: round eyes behind a pair of glasses")
        case "sunglasses": String(localized: "Sunglasses", comment: "A bot face's eyes: dark sunglasses over them")
        case "prompt": String(localized: "Prompt", comment: "A bot face's mouth: a terminal's “>_” prompt (a coder's)")
        case "hardHat": String(localized: "Hard Hat", comment: "A bot face's mark")
        case "mortarboard": String(localized: "Mortarboard", comment: "A bot face's mark: a graduation cap")
        case "pencil": String(localized: "Pencil", comment: "A bot face's mark: a pencil behind its ear")
        case "mast": String(localized: "Mast", comment: "A bot face's mark: a mast on its head sending signal waves (a lookout's)")
        case "chimney": String(localized: "Chimney", comment: "A bot face's mark: a chimney with smoke")
        case "calendar": String(localized: "Calendar", comment: "A bot face's mark: a desk calendar's band and rings")
        case "paperclip": String(localized: "Paper Clip", comment: "A bot face's mark: a paper clip, a sheet behind")
        case "envelope": String(localized: "Envelope", comment: "A bot face's mark: an envelope's flap")
        default: raw.capitalized
        }
    }
    /// The colours offered: for the main agent, Redde's own two besides, the theme's first and the
    /// Code blue by Sky (`BotFace.themed`, `codeBlue`).
    private var offered: [Int] {
        guard bot.isDefault else { return BotFace.pickable }
        var colors = [BotFace.themed] + BotFace.pickable
        if let sky = colors.firstIndex(of: 8) { colors.insert(BotFace.codeBlue, at: sky + 1) }
        return colors
    }
    @Environment(\.theme) private var theme

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    preview
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .listRowBackground(Color.clear)
                if choose == nil { photoSection }
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
                    choose == nil ? Text("Kept on your Hermes server, so Redde on your other devices shows it too.")
                                  : Text("Kept on your Hermes server once the bot is made, so Redde on your other devices shows it too.")
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
                        Button("Save") { save(face) }.disabled(face == current && photo == nil && !removingPhoto || readingPhoto)
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
                            Text(Self.partName(part.rawValue))
                                .font(.caption2)
                                .foregroundStyle(picked ? .primary : .secondary)
                        }
                        .frame(minWidth: 64)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Self.partName(part.rawValue))
                    .accessibilityAddTraits(picked ? .isSelected : [])
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var colours: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(offered, id: \.self) { index in
                    let picked = face.color == index
                    Button { face.color = index } label: {
                        VStack(spacing: 2) {
                            Circle()
                                .fill(swatch(index))
                                .frame(width: 34, height: 34)
                                // White, black and a pale bubble would vanish on a page of their own colour.
                                .overlay(Circle().strokeBorder(.quaternary, lineWidth: index >= BotFace.seededColors ? 1 : 0))
                                .padding(4)
                                .overlay(Circle().strokeBorder(picked ? Color.accentColor : .clear, lineWidth: 2.5))
                                .frame(width: 44, height: 44)
                            Text(Self.colorNames[index])
                                .font(.caption2)
                                .foregroundStyle(picked ? .primary : .secondary)
                                .lineLimit(1)
                        }
                        .frame(minWidth: 52)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Self.colorNames[index])
                    .accessibilityAddTraits(picked ? .isSelected : [])
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// A colour's circle: the palette's gradient, or for Redde's own two their colour as the face
    /// has it (the theme's here, whichever theme is on).
    private func swatch(_ index: Int) -> LinearGradient {
        let pair: (light: Color, deep: Color)
        switch index {
        case BotFace.themed:
            let own = theme.promptPrefix != nil ? theme.promptColor : theme.userBubble
            pair = (own.mix(with: .white, by: 0.14), own)
        case BotFace.codeBlue:
            pair = (ThemeColors.RGB.codeBlue.color.mix(with: .white, by: 0.14), ThemeColors.RGB.codeBlue.color)
        default:
            pair = BotFace.pair(index)
        }
        return LinearGradient(colors: [pair.light, pair.deep], startPoint: .topLeading, endPoint: .bottomTrailing)
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
                if let photo {
                    try await HermesServeClient.shared.setBotPicture(photo, for: bot.name)
                    await BotPictures.shared.set(bot.name, photo)
                    self.photo = nil
                } else if removingPhoto {
                    try await HermesServeClient.shared.setBotPicture(nil, for: bot.name)
                    await BotPictures.shared.set(bot.name, nil)
                    removingPhoto = false
                }
                // The face too, when it changed (or goes back to its own).
                if picked == nil || picked != current {
                    try await HermesServeClient.shared.setFace(picked, for: bot)
                }
                onSaved()
                dismiss()
            } catch {
                problem = error.localizedDescription
                if error is BotFaceProblem { onSaved() }
            }
        }
    }

    /// It has a picture, or will once saved.
    private var hasPhoto: Bool { photo != nil || (bot.hasPicture && !removingPhoto) }

    /// The bot as it will be shown: the photo picked here, the picture it has, or the face.
    @ViewBuilder private var preview: some View {
        let size: CGFloat = 132
        if let photoImage {
            Image(uiImage: photoImage)
                .resizable()
                .scaledToFill()
                .frame(width: size * 0.9, height: size * 0.9)
                .clipShape(.rect(cornerRadius: size * 0.24, style: .continuous))
                .frame(width: size, height: size)
                .accessibilityLabel("\(name)'s photo")
        } else {
            BotAvatar(face: Self.with(face, \.picture, hasPhoto ? bot.name : nil), size: size)
                .accessibilityElement()
                .accessibilityLabel(hasPhoto ? Text("\(name)'s photo") : Text("\(name)'s face: \(Self.describe(face))"))
        }
    }

    private var photoSection: some View {
        Section {
            PhotosPicker(selection: $photoItem, matching: .images) {
                if hasPhoto { Label("Choose Another Photo", systemImage: "photo") } else { Label("Choose Photo", systemImage: "photo") }
            }
            .disabled(saving || readingPhoto)
            if hasPhoto {
                Button("Remove Photo", systemImage: "xmark.circle", role: .destructive) {
                    photo = nil
                    photoImage = nil
                    photoItem = nil
                    removingPhoto = bot.hasPicture
                }
                .disabled(saving || readingPhoto)
            }
        } header: {
            Text("Photo")
        } footer: {
            if settings.botPictures {
                Text("A photo shows instead of the face wherever Redde and Hermes Desktop show \(name). It's cropped to a square and sent without where it was taken.",
                     comment: "Bot face picker: what a bot's photo does; the bot's name")
            } else {
                Text("A photo shows instead of the face wherever Redde and Hermes Desktop show \(name). On this device, Pictures from Hermes is off in Settings, so the face shows.",
                     comment: "Bot face picker: what a bot's photo does, with bot pictures turned off on this device; the bot's name")
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            readingPhoto = true
            problem = nil
            Task {
                defer { readingPhoto = false }
                let data = try? await item.loadTransferable(type: Data.self)
                guard let data, let jpeg = await BotPictures.prepare(data) else {
                    problem = String(localized: "That photo couldn't be read. Try another one.")
                    return
                }
                photo = jpeg
                photoImage = ImageThumbnail.decode(jpeg, maxPixel: 400)
                removingPhoto = false
            }
        }
    }

    nonisolated static func with<Part>(_ face: BotFace, _ key: WritableKeyPath<BotFace, Part>, _ part: Part) -> BotFace {
        var face = face
        face[keyPath: key] = part
        return face
    }

    nonisolated static func describe(_ face: BotFace) -> String {
        let color = colorNames[face.color % colorNames.count].localizedLowercase
        let shape = partName(face.shape.rawValue).localizedLowercase, eyes = partName(face.eyes.rawValue).localizedLowercase
        var parts = [String(localized: "\(color) \(shape), \(eyes) eyes",
                            comment: "VoiceOver: a bot face's colour, shape and eyes, e.g. “blue round, happy eyes”")]
        if face.mouth != .none {
            parts.append(String(localized: "\(partName(face.mouth.rawValue).localizedLowercase) mouth", comment: "VoiceOver: a bot face's mouth, e.g. “smile mouth”"))
        }
        if face.mark != .none { parts.append(partName(face.mark.rawValue).localizedLowercase) }
        return parts.joined(separator: ", ")
    }

    /// Any face but Redde's, with the lean and the glance it has.
    nonisolated static func random(keeping face: BotFace) -> BotFace {
        BotFace(shape: BotFace.Shape.given.randomElement() ?? .round, eyes: BotFace.Eyes.allCases.randomElement() ?? .round,
                mouth: BotFace.Mouth.allCases.randomElement() ?? .none, mark: BotFace.Mark.allCases.randomElement() ?? .none,
                glance: face.glance, tilt: face.tilt, color: BotFace.pickable.randomElement() ?? 0)
    }
}
