import Foundation
import Testing
@testable import Echo

/// Watches and follow-ups (asked 2026-10-28): the jobs Redde makes are found again by their tags,
/// their prompt carries the tag the plugin looks for, and what a watch saw is kept per watch.
struct WatchesTests {
    /// A watch's settings (a hold on its row, 2026-11-05) read its words back from its prompt and
    /// put new ones in, keeping what a template added after them; the way it reports, rewritten.
    @Test func aWatchsSettingsRewriteItsPromptAndKeepATemplatesAdditions() throws {
        let extra = " Also: answer NO EMAIL ACCESS if you can't read mail."
        let prompt = Watches.prompt("ab12cd34", what: "the UniFi G4 Instant below $97") + extra
        let job = try #require(CronJob(.object(["id": .string("j"), "name": .string("[redde-watch:ab12cd34] UniFi G4 Instant"),
                                                "schedule": .string("0 */4 * * *"), "prompt": .string(prompt), "deliver": .string("local")])))
        #expect(WatchSettingsView.what(in: job.prompt) == "the UniFi G4 Instant below $97")
        #expect(WatchSettingsView.then(of: job, takers: []) == .tell)
        let new = WatchSettingsView.prompt(for: job, id: "ab12cd34", what: "the UniFi G4 Instant below $90", then: .call, was: .tell)
        #expect(new == Watches.prompt("ab12cd34", what: "the UniFi G4 Instant below $90", then: .call) + extra)
        var called = job
        called.prompt = new
        #expect(WatchSettingsView.then(of: called, takers: []) == .call)
        #expect(WatchSettingsView.what(in: "Something else entirely") == nil, "a prompt it can't read is left as it is")
        #expect(FollowUpSettingsView.schedule(Date(timeIntervalSince1970: 0)).count == "2026-11-05T09:00".count)
    }

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
