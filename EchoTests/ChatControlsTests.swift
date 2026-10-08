import Foundation
import Testing
@testable import Echo

/// A conversation's own switches on the Dashboard (auto-approve, fast mode) and moving it to a
/// project: what the server's answers mean. The shapes are what Hermes 0.21.0, 0.21.3 and 0.21.5
/// sent the lab; the calls themselves are checked there (`scripts/hermes-lab/lab.sh controls`).
struct ChatControlsTests {
    private func json(_ text: String) throws -> JSONValue { try JSONValue.parse(Data(text.utf8)) }

    @Test func aSessionsInfoSaysHowItRuns() throws {
        var controls = ChatControls()
        controls.merge(try json(#"{"model": "alpha", "yolo": false, "fast": false, "service_tier": "", "approval_mode": "manual", "stored_session_id": "s1"}"#))
        #expect(controls == ChatControls(autoApprove: false, approvalMode: "manual", fast: false))
        #expect(!controls.serverNeverAsks)

        controls.merge(try json(#"{"yolo": true, "fast": true, "service_tier": "priority", "approval_mode": "manual"}"#))
        #expect(controls.autoApprove && controls.fast)
    }

    @Test func aShortInfoLeavesTheRestAsItWas() throws {
        // Hermes also sends an info that only says where the session now works (after a move).
        var controls = ChatControls(autoApprove: true, approvalMode: "manual", fast: true)
        controls.merge(try json(#"{"cwd": "/srv/project", "branch": "main"}"#))
        #expect(controls == ChatControls(autoApprove: true, approvalMode: "manual", fast: true))
        controls.merge(.null)
        #expect(controls.autoApprove && controls.fast)
        // An older shape that names only the tier.
        controls.merge(try json(#"{"service_tier": ""}"#))
        #expect(!controls.fast)
    }

    @Test func aServerThatNeverAsksSaysSoInPlaceOfASwitch() throws {
        var controls = ChatControls()
        controls.merge(try json(#"{"yolo": true, "approval_mode": "off"}"#))
        #expect(controls.autoApprove && controls.serverNeverAsks)
        #expect(ChatControlsSection.footer(controls).contains("This server never asks"))
        #expect(ChatControlsSection.footer(ChatControls(approvalMode: "manual")).contains("until you switch it back or Hermes restarts"))
        #expect(ChatControlsSection.footer(nil).hasPrefix("Fast mode asks the provider"))
    }

    @Test func aRefusedFastModeIsSaidPlainly() {
        #expect(ChatControls.fastRefusal("fast mode is not available for this model") == "This model has no fast mode.")
        #expect(ChatControls.fastRefusal("fast mode is not available without a selected model") == "Pick a model first: fast mode belongs to a model.")
        #expect(ChatControls.fastRefusal("the connection to Hermes Dashboard closed") == "the connection to Hermes Dashboard closed")
    }

    @Test func theStoreKeepsEachSessionsAndChangesOnlyWhenTheyDo() throws {
        let store = ChatControlStore()
        #expect(store.controls(for: nil) == nil)
        #expect(store.controls(for: "s1") == nil)
        store.note(try json(#"{"yolo": true, "approval_mode": "manual", "fast": false}"#), for: "s1")
        store.note(try json(#"{"yolo": false, "approval_mode": "manual", "fast": false}"#), for: "s2")
        #expect(store.controls(for: "s1")?.autoApprove == true)
        #expect(store.controls(for: "s2")?.autoApprove == false)
        // A short info for s1 keeps what was known.
        let kept = store.note(try json(#"{"cwd": "/srv/x"}"#), for: "s1")
        #expect(kept.autoApprove)
        store.set(ChatControls(autoApprove: false, approvalMode: "manual"), for: "s1")
        #expect(store.controls(for: "s1")?.autoApprove == false)
        store.removeAll()
        #expect(store.bySession.isEmpty)
    }

    @Test func aConversationCanMoveToAnyFolderButItsOwn() throws {
        func project(_ text: String) throws -> HermesServeClient.Project { try #require(HermesServeClient.Project(try json(text))) }
        let home = try project(#"{"id": "__no_project__", "label": "Home", "path": null, "isNoProject": true, "sessionCount": 4}"#)
        let app = try project(#"{"id": "/srv/app", "label": "app", "path": "/srv/app", "isNoProject": false, "sessionCount": 2}"#)
        let site = try project(#"{"id": "/srv/site", "label": "site", "path": "/srv/site", "isNoProject": false, "sessionCount": 0}"#)
        let all = [home, app, site]
        // Home is no folder: there is nothing to move into.
        #expect(HermesServeClient.Project.moveTargets(in: all, from: nil).map(\.label) == ["app", "site"])
        #expect(HermesServeClient.Project.moveTargets(in: all, from: "").map(\.label) == ["app", "site"])
        // Not the project it is in, whether at its root or below it.
        #expect(HermesServeClient.Project.moveTargets(in: all, from: "/srv/app").map(\.label) == ["site"])
        #expect(HermesServeClient.Project.moveTargets(in: all, from: "/srv/app/ios").map(\.label) == ["site"])
        // A folder that only begins the same is another folder.
        #expect(HermesServeClient.Project.moveTargets(in: all, from: "/srv/app-old").map(\.label) == ["app", "site"])
        #expect(HermesServeClient.Project.moveTargets(in: [home], from: nil).isEmpty)
    }

    @Test func theListReadsASessionsFolderWhenItIsGiven() throws {
        let rows = try JSONDecoder().decode([HermesSessionsAPI.SessionSummary].self, from: Data(#"""
        [{"id": "a", "title": "one", "cwd": "/srv/app"}, {"id": "b", "title": "two"}]
        """#.utf8))
        #expect(rows.map(\.cwd) == ["/srv/app", nil])
    }
}
