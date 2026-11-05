import Foundation
import Testing
@testable import Echo

/// Watch templates (2.4): fixed ids found again, prompts that carry the watch's tag and, for email,
/// the exact answer when there's no way to read it; email servers told by their names.
struct WatchTemplatesTests {
    @Test func eachHasAFixedIdFoundAgain() {
        #expect(WatchTemplate.urgentEmail.id == "t-urgentmail")
        #expect(WatchTemplate.schoolMessages(from: "Lakeside").id == "t-school")
        let parcel = WatchTemplate.package(tracking: "1Z999AA10123456784")
        #expect(parcel.id == WatchTemplate.package(tracking: " 1z999aa10123456784 ").id, "the same parcel, however typed")
        #expect(parcel.id.hasPrefix("t-pkg-") && parcel.id != WatchTemplate.package(tracking: "9400").id)
        #expect(WatchTemplate.kind(ofWatch: parcel.id) == .package)
        #expect(WatchTemplate.kind(ofWatch: "t-urgentmail") == .urgentEmail)
        #expect(WatchTemplate.kind(ofWatch: "ab12cd34") == nil)
    }

    @Test func emailPromptsSayWhatToAnswerWithoutEmail() {
        let prompt = WatchTemplate.urgentEmail.prompt
        #expect(prompt.hasPrefix("[redde-watch:t-urgentmail] Watch, for the user: "))
        #expect(prompt.hasSuffix("If you have no tool that can read their email, answer exactly NO EMAIL ACCESS."))
        #expect(!WatchTemplate.priceDrop(url: "https://example.com/kettle", below: "$40").prompt.contains("NO EMAIL ACCESS"))
        #expect(WatchTemplate.priceDrop(url: "https://example.com/kettle", below: "$40").prompt.contains("below $40"))
        #expect(WatchTemplate.urgentEmail.needsEmail && !WatchTemplate.package(tracking: "1").needsEmail)
        #expect(WatchTemplate.package(tracking: "1").runs == 84 && WatchTemplate.urgentEmail.runs == nil)
    }

    @Test func anAnswerOfNoEmailIsWhatToDo() throws {
        let store = UserDefaults(suiteName: "templates-\(UUID().uuidString)")!
        let said = try JSONDecoder().decode(PushNote.self, from: Data(#"{"v":1,"k":"watch","t":"Urgent emails","b":"NO EMAIL ACCESS","i":"t-urgentmail"}"#.utf8))
        WatchReport.take(said, in: store)
        #expect(WatchReport.all(in: store)["t-urgentmail"]?.needsEmail == true, "any plugin: the exact words")
        let plugin = try JSONDecoder().decode(PushNote.self, from: Data(#"{"v":1,"k":"watch","t":"School","b":"No email tool","w":"noemail","i":"t-school"}"#.utf8))
        WatchReport.take(plugin, in: store)
        let school = try #require(WatchReport.all(in: store)["t-school"])
        #expect(school.needsEmail && school.failed, "1.15's own kind")
    }

    @Test func emailServersByTheirNames() {
        #expect(WatchTemplate.readsEmail(MCPServer(name: "gmail")))
        #expect(WatchTemplate.readsEmail(MCPServer(name: "Himalaya-IMAP")))
        #expect(WatchTemplate.readsEmail(MCPServer(name: "fastmail")))
        #expect(!WatchTemplate.readsEmail(MCPServer(name: "calendar")))
        #expect(!WatchTemplate.readsEmail(MCPServer(name: "gmail", enabled: false)), "switched off")
    }

    @Test func aTemplateWatchIsFoundAmongTheJobs() throws {
        let jobs = [
            try #require(CronJob(.object(["id": .string("1"), "name": .string("[redde-watch:ab12] Kettle"), "schedule": .string("0 * * * *")]))),
            try #require(CronJob(.object(["id": .string("2"), "name": .string("[redde-watch:t-school] Messages from the school"), "schedule": .string("*/30 * * * *")]))),
        ]
        #expect(WatchTemplate.find(.schoolMessages, in: jobs)?.id == "2")
        #expect(WatchTemplate.find(.urgentEmail, in: jobs) == nil)
    }
}
