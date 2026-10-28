import Foundation
import Observation
import os

/// The approvals answered on this device: what the agent wanted to run, why it was asked (the
/// rule Hermes gives), what was answered and where (asked 2026-10-28, after OpenDuet's record of
/// every decision). Kept on this device alone, in Application Support, the newest 500; nothing
/// is sent anywhere, and an incognito chat's are never kept. Every answer goes through
/// `Conversation.respond(approval:)` or a group chat's `GroupFeed.answer`, whichever screen,
/// banner, Live Activity, voice or watch gave it.
@MainActor
@Observable
final class ApprovalHistory {
    static let shared = ApprovalHistory()

    nonisolated struct Entry: Codable, Identifiable, Equatable, Sendable {
        var id = UUID()
        var at: Date
        /// Who asked: the main agent's name or a bot's.
        var agent: String
        /// The chat it was asked in.
        var chat: String?
        var command: String
        /// Why it was asked: Hermes's rule ("recursive delete").
        var reason: String?
        /// once, session, always or deny.
        var choice: String
    }

    private(set) var entries: [Entry] = []
    static let kept = 500
    private let file: URL
    private static let log = Logger(subsystem: "com.goosehouse.echo", category: "approvals")

    init(file: URL = URL.applicationSupportDirectory.appending(path: "approval-history.json")) {
        self.file = file
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        }
        #if DEBUG
        // `-echo.demoApprovals`: a few made-up answers, for screenshots (not saved).
        if DevHooks.has("-echo.demoApprovals") {
            entries = [Entry(at: .now.addingTimeInterval(-600), agent: "Coder", chat: "Fix the login page", command: "git apply claude-work-t_4f2a.patch", reason: "Puts Claude's change in place", choice: "once"),
                       Entry(at: .now.addingTimeInterval(-3_600), agent: "Sol", chat: "Clean up downloads", command: "rm -rf ~/Downloads/old-installers", reason: "recursive delete", choice: "deny"),
                       Entry(at: .now.addingTimeInterval(-90_000), agent: "Home", chat: "Hall lights", command: "systemctl restart homebridge", reason: "restarting a system service", choice: "always")]
        }
        #endif
    }

    func record(_ request: ApprovalRequest, choice: String, agent: String, chat: String?, at: Date = .now) {
        entries.insert(Entry(at: at, agent: agent, chat: chat, command: request.command,
                             reason: request.description?.nilIfEmpty, choice: choice), at: 0)
        if entries.count > Self.kept { entries.removeLast(entries.count - Self.kept) }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            Self.log.error("couldn't keep the approval history: \(error.localizedDescription)")
        }
    }
}
