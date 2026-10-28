import Foundation
import Testing
@testable import Echo

/// The approvals answered on this device (asked 2026-10-28): each kept with why it was asked and
/// the answer, newest first, the newest 500, still there when the app opens again.
@MainActor
struct ApprovalHistoryTests {
    private func file() -> URL { FileManager.default.temporaryDirectory.appending(path: "approvals-\(UUID().uuidString).json") }
    private let request = ApprovalRequest(id: "r1", command: "rm -rf build/", description: "recursive delete", choices: ["once", "session", "always", "deny"])

    @Test func anAnswerIsKeptWithWhyAndWho() {
        let url = file()
        let history = ApprovalHistory(file: url)
        history.record(request, choice: "once", agent: "Sol", chat: "Clean the build")
        history.record(ApprovalRequest(id: "r2", command: "git push", description: nil, choices: ["once", "deny"]), choice: "deny", agent: "Coder", chat: nil)
        #expect(history.entries.map(\.choice) == ["deny", "once"], "newest first")
        #expect(history.entries.last?.reason == "recursive delete" && history.entries.last?.agent == "Sol")
        // Opened again: still there.
        #expect(ApprovalHistory(file: url).entries == history.entries)
        history.clear()
        #expect(ApprovalHistory(file: url).entries.isEmpty)
    }

    @Test func onlyTheNewestAreKept() {
        let history = ApprovalHistory(file: file())
        for n in 0 ..< ApprovalHistory.kept + 20 { history.record(request, choice: "once", agent: "Sol", chat: "\(n)") }
        #expect(history.entries.count == ApprovalHistory.kept)
        #expect(history.entries.first?.chat == "\(ApprovalHistory.kept + 19)")
    }
}
