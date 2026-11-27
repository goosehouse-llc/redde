import Foundation
import Testing
@testable import Echo

/// Agents Bring Up (plugin 1.58.0): the dial as the plugin says it, set through the same command,
/// and an older plugin or an unreachable server told apart.
struct AgentsBringUpTests {
    @Test func theReplyIsReadAsALevel() {
        #expect(AgentsBringUp.parse("redde-push proactive less\n") == .less)
        #expect(AgentsBringUp.parse("redde-push proactive loud") == nil)
        #expect(AgentsBringUp.parse("redde-push status 2") == nil)
    }

    @Test func setThenReadThroughThePlugin() async {
        var asked: [String] = []
        let plugin: PushService.PluginCommand = { line in
            await MainActor.run { asked.append(line) }
            return line == "proactive" ? "redde-push proactive normal" : "redde-push proactive off"
        }
        #expect(await AgentsBringUp.read(through: plugin) == .level(.normal))
        #expect(await AgentsBringUp.read(setting: .off, through: plugin) == .level(.off))
        #expect(await MainActor.run { asked } == ["proactive", "proactive set off"])
    }

    @Test func anOlderPluginOrNoServer() async {
        #expect(await AgentsBringUp.read(through: { _ in throw PushError.noPlugin }) == .tooOld)
        #expect(await AgentsBringUp.read(through: { _ in "redde-push usage: …" }) == .tooOld, "a plugin before 1.58 answers something else")
        #expect(await AgentsBringUp.read(through: { _ in throw PushError.unreachable }) == .unreachable)
    }
}
