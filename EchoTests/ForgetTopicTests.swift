import Foundation
import Testing
@testable import Echo

/// Forget a Topic (plugin 1.58.0): the plugin's answer read, everything ticked to start, and only what
/// stayed ticked sent back, agent by agent.
struct ForgetTopicTests {
    static let found = #"redde-push memory found {"topic": "old job", "agents": [{"profile": "default", "name": "Sol", "user": ["Works at the old job"], "memory": []}, {"profile": "media", "name": "Media", "user": [], "memory": ["Their old job's shift ended at 7"]}], "facts": ["Drive past the old job"], "provider": "Honcho"}"#

    @Test func foundAndAllTickedToStart() async throws {
        let found = try await ForgetTopic.find("old job", through: { line in
            #expect(line == "memory find \(PushSeal.base64URL(Data("old job".utf8)))")
            return Self.found
        })
        #expect(found.count == 3 && found.provider == "Honcho")
        #expect(ForgetTopic.picks(found).count == 3)
    }

    @Test func onlyWhatStaysTickedIsSent() throws {
        let picks: Set<ForgetTopic.Pick> = [.init(place: .user("default"), text: "Works at the old job"), .init(place: .fact, text: "Drive past the old job")]
        let sent = try #require(try JSONSerialization.jsonObject(with: ForgetTopic.request(picks, topic: "old job", block: true)) as? [String: Any])
        #expect(sent["topic"] as? String == "old job" && sent["block"] as? Bool == true)
        #expect(sent["facts"] as? [String] == ["Drive past the old job"])
        let agents = try #require(sent["agents"] as? [[String: Any]])
        #expect(agents.count == 1 && agents[0]["profile"] as? String == "default" && agents[0]["user"] as? [String] == ["Works at the old job"])
    }

    @Test func anOlderPluginOrNoServer() async {
        await #expect(throws: ForgetTopic.Failure.tooOld) { try await ForgetTopic.find("x", through: { _ in "redde-push memory stores {}" }) }
        await #expect(throws: ForgetTopic.Failure.unreachable) { try await ForgetTopic.find("x", through: { _ in throw PushError.unreachable }) }
        let forgot = try? await ForgetTopic.forget([], topic: "x", block: false, through: { _ in #"redde-push memory forgot {"removed": 2, "missed": 1, "blocked": false}"# })
        #expect(forgot == ForgetTopic.Forgot(removed: 2, missed: 1, blocked: false))
    }
}
