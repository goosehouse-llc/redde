#if DEBUG
import SwiftUI

/// Faces for bots with one job (asked 2026-11-08), made of the picked-only eyes, mouth and marks,
/// large and as small as in the chat list (`-echo.screen roleFaces`).
struct RoleFaces: View {
    static let roles: [(name: String, face: BotFace)] = [
        ("Researcher", BotFace(shape: .round, eyes: .lens, mouth: .none, mark: .none, glance: 1, tilt: 0, color: 4)),
        ("Coder", BotFace(shape: .square, eyes: .sleepy, mouth: .prompt, mark: .none, glance: 0, tilt: 0, color: BotFace.white + 1)),
        ("Paperwork", BotFace(shape: .square, eyes: .round, mouth: .smile, mark: .paperclip, glance: 2, tilt: 0, color: BotFace.white)),
        ("Lookout", BotFace(shape: .capsule, eyes: .round, mouth: .none, mark: .mast, glance: 3, tilt: 0, color: 6)),
        ("Ops", BotFace(shape: .round, eyes: .round, mouth: .smile, mark: .hardHat, glance: 0, tilt: 0, color: 0)),
        ("Writer", BotFace(shape: .egg, eyes: .happy, mouth: .smile, mark: .pencil, glance: 1, tilt: 0, color: 5)),
        ("Scheduler", BotFace(shape: .square, eyes: .round, mouth: .smile, mark: .calendar, glance: 1, tilt: 0, color: BotFace.white)),
        ("Mail", BotFace(shape: .pill, eyes: .round, mouth: .smile, mark: .envelope, glance: 2, tilt: 0, color: 8)),
        ("Home", BotFace(shape: .house, eyes: .sleepy, mouth: .smile, mark: .chimney, glance: 1, tilt: 0, color: 7)),
        ("Teacher", BotFace(shape: .round, eyes: .round, mouth: .smile, mark: .mortarboard, glance: 1, tilt: 0, color: 9)),
    ]
    /// Each new mark on other shapes, colours and leans, to see it sit right on any.
    static let mixed: [BotFace] = BotFace.Mark.allCases.filter { !BotFace.Mark.seeded.contains($0) }.enumerated().flatMap { i, mark in
        [BotFace.Shape.egg, .pick, .ghost, .star, .blob, .hex].enumerated().map { j, shape in
            BotFace(shape: shape, eyes: j == 0 ? .lens : .round, mouth: j == 1 ? .prompt : .smile, mark: mark, glance: j % 4, tilt: Double((i + j) % 5 * 2 - 4),
                    color: BotFace.pickable[(i * 3 + j) % BotFace.pickable.count])
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                ForEach([Color.white, Color.black], id: \.self) { ground in
                    HStack(spacing: 6) {
                        ForEach(Self.roles, id: \.name) { BotAvatar(face: $0.face, size: 30) }
                    }
                    .padding(10)
                    .background(ground, in: .rect(cornerRadius: 12))
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 10) {
                    ForEach(Self.roles, id: \.name) { role in
                        VStack(spacing: 2) {
                            BotAvatar(face: role.face, size: 62)
                            Text(role.name).font(.caption2).foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 6) {
                    ForEach(Array(Self.mixed.enumerated()), id: \.offset) { BotAvatar(face: $0.element, size: 50) }
                }
                .padding(8)
                .background(Color.white.opacity(0.06), in: .rect(cornerRadius: 12))
            }
            .padding()
        }
        .background(Color(white: 0.1))
    }
}
#endif
