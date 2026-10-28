import Foundation
import Testing
@testable import Echo

/// Watches and follow-ups (asked 2026-10-28): the jobs Redde makes are found again by their tags,
/// their prompt carries the tag the plugin looks for, and what a watch saw is kept per watch.
struct WatchesTests {
    @Test func aWatchsPromptCarriesItsTagAndTheRule() {
        let prompt = Watches.prompt("ab12cd34", what: "the price of the blue kettle")
        #expect(prompt.hasPrefix("[redde-watch:ab12cd34] Watch, for the user: the price of the blue kettle."))
        #expect(prompt.contains("NOTHING NEW"))
    }

    @Test func aJobsIdAndTitleComeFromItsName() throws {
        func job(_ name: String) throws -> CronJob {
            try #require(CronJob(.object(["id": .string("j1"), "name": .string(name), "prompt": .string(""), "schedule": .string("0 * * * *")])))
        }
        #expect(Watches.id(of: try job("[redde-watch:ab12cd34] Blue kettle")) == "ab12cd34")
        #expect(Watches.title(of: try job("[redde-watch:ab12cd34] Blue kettle")) == "Blue kettle")
        #expect(Watches.id(of: try job("[redde-followup:0123456789ab] Call the plumber")) == "0123456789ab")
        #expect(Watches.id(of: try job("Backups")) == nil)
    }

    @Test func whatAWatchSawIsKeptPerWatch() throws {
        let store = UserDefaults(suiteName: "watches-\(UUID().uuidString)")!
        let note = try JSONDecoder().decode(PushNote.self, from: Data(#"{"v":1,"k":"watch","p":"default","d":"Sol","t":"Blue kettle","b":"It dropped to $39.","i":"ab12cd34","at":1000}"#.utf8))
        #expect(WatchReport.take(note, in: store))
        #expect(WatchReport.all(in: store)["ab12cd34"]?.text == "It dropped to $39.")
        let failed = try JSONDecoder().decode(PushNote.self, from: Data(#"{"v":1,"k":"watch","t":"Blue kettle","b":"The page didn't load","w":"failed","i":"ab12cd34"}"#.utf8))
        WatchReport.take(failed, in: store)
        #expect(WatchReport.all(in: store)["ab12cd34"]?.failed == true, "the latest is the one kept")
        WatchReport.forget("ab12cd34", in: store)
        #expect(WatchReport.all(in: store).isEmpty)
        #expect(!WatchReport.take(try JSONDecoder().decode(PushNote.self, from: Data(#"{"v":1,"k":"widget"}"#.utf8)), in: store))
    }
}
