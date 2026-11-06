import Foundation
import Testing
@testable import Echo

/// Email (2.4): the plugin's answers read as tmp/mail-contract.md has them, the piles counted, a tap
/// done on the list at once and put back by Undo or a refusal, rules written and read back, a
/// drafted email's card, and an inbox card.
@MainActor
struct InboxTests {
    private func json(_ text: String) throws -> JSONValue { try JSONValue.parse(Data(text.utf8)) }

    /// A center answered by `reply`, which sees every command sent.
    private func center(_ reply: @escaping (String) -> String) -> MailCenter {
        let center = MailCenter()
        center.reachable = { true }
        center.plugin = { reply($0) }
        return center
    }

    private static let status = #"redde-push mail {"accounts":[{"id":"main","name":"Home","address":"me@example.com","provider":"icloud","via":"imap","usable":true,"problem":null,"last_sync":1762150000,"unread":4,"buckets":{"important":2,"needs_reply":3,"fyi":7,"newsletters":20,"unsorted":0}},{"id":"nous","name":"Gmail","address":"","provider":"gmail","via":"nous","usable":false}],"triage":"auto","sync_minutes":3}"#

    private static let list = #"redde-push mail {"account":"main","bucket":"all","page":0,"more":true,"threads":[{"id":"main:INBOX:1","thread":"main:t:1","from":"Ana Ruiz","address":"ana@example.com","subject":"Lunch Thursday?","snippet":"Are you free","date":1762149000,"unread":true,"bucket":"needs_reply","summary":"Ana asks about lunch.","has_attachments":false,"can_unsubscribe":false,"receipt":false,"flagged":false},{"id":"main:INBOX:2","from":"","address":"news@shop.example.com","subject":"","snippet":"Sale","date":1762140000,"unread":false,"bucket":"newsletters","summary":null,"has_attachments":true,"can_unsubscribe":true}]}"#

    // Removing an account (asked 11-03: "can I delete an email account").

    @Test func removingAnAccountForgetsItHereToo() async throws {
        var sent: [String] = []
        let center = center { words in
            sent.append(words)
            if words.hasPrefix("mail remove") { return #"redde-push mail {"removed":"main"}"# }
            if words.hasPrefix("mail list") { return Self.list }
            return sent.contains { $0.hasPrefix("mail remove") }
                ? #"redde-push mail {"accounts":[],"triage":"auto","sync_minutes":3}"# : Self.status
        }
        await center.refreshStatus()
        await center.load(nil)
        #expect(!center.threads(in: nil, account: "main").isEmpty)
        try await center.removeAccount("main")
        #expect(sent.contains("mail remove main"))
        #expect(center.threads(in: nil, account: "main").isEmpty)
        #expect(!center.accounts.contains { $0.id == "main" })
        #expect(!center.isSetUp)
    }

    @Test func aRefusedRemovalKeepsTheAccount() async {
        let center = center { words in
            words.hasPrefix("mail remove") ? #"redde-push mail {"error":"not_redde","message":"Gmail connected through Hermes: remove it in Hermes's Google setup."}"# : Self.status
        }
        await center.refreshStatus()
        await #expect(throws: (any Error).self) { try await center.removeAccount("main") }
        #expect(center.accounts.contains { $0.id == "main" })
    }

    @Test func onlyAccountsSetUpInReddeCanBeRemoved() throws {
        let status = MailStatus(json: try MailWire.parse(Self.status))
        #expect(status.accounts.map(MailCenter.removable) == [true, false], "Nous's Gmail isn't Redde's")
        let google = MailAccount(id: "google", name: "Gmail", address: "", provider: "gmail", via: "gmail_api")
        #expect(!MailCenter.removable(google))
    }

    @Test func theConfirmationSaysWhatGoesAndWhatStays() {
        let icloud = MailAccount(id: "main", name: "Home", address: "me@example.com", provider: "icloud")
        let said = MailSettingsView.removalMessage(icloud)
        #expect(said.contains("Home") && said.contains("iCloud") && said.contains("revoke"))
        let other = MailAccount(id: "work", name: "Work", address: "me@work.example.com", provider: "other")
        #expect(!MailSettingsView.removalMessage(other).contains("revoke"))
        #expect(MailProvider.gmail.revokePage != nil && MailProvider.other.revokePage == nil)
    }

    @Test func aRemovedAccountsLogCantBeUndone() throws {
        let entry = try #require(MailLogEntry(json: try json(#"{"id":"m1","at":1,"action":"archive","account":"main","ids":["x"],"title":"Archived","undone":false,"by":"rule","gone":true}"#)))
        #expect(!entry.undoable)
    }

    @Test func theStatusReadsAccountsAndTheirPiles() throws {
        let status = MailStatus(json: try MailWire.parse(Self.status))
        #expect(status.accounts.count == 2)
        let home = try #require(status.accounts.first)
        #expect(home.name == "Home" && home.usable && home.via == "imap")
        #expect(home.count(.important) == 2 && home.count(.needsReply) == 3 && home.count(.newsletters) == 20)
        #expect(home.lastSync == Date(timeIntervalSince1970: 1_762_150_000))
        #expect(status.usable.map(\.id) == ["main"], "Nous's connector is listed, not usable")
    }

    @Test func aListReadsEachEmailLeniently() throws {
        let page = MailPage(json: try MailWire.parse(Self.list))
        #expect(page.more)
        #expect(page.threads.count == 2)
        let ana = page.threads[0]
        #expect(ana.bucket == .needsReply && ana.unread && ana.line == "Ana asks about lunch.")
        let shop = page.threads[1]
        #expect(shop.from == "news@shop.example.com", "no name: the address")
        #expect(shop.subject == String(localized: "(no subject)", comment: "An email with no subject"))
        #expect(shop.summary == nil && shop.line == "Sale", "not sorted yet: its own first words")
        #expect(shop.hasAttachments && shop.canUnsubscribe)
    }

    @Test func anEmailWholeKeepsOnlyWebLinks() throws {
        let message = try #require(MailMessage(json: try json(#"{"id":"main:INBOX:1","from":"Ana","address":"ana@example.com","to":["me@example.com"],"cc":[],"subject":"Hi","date":1,"text":"Hello","links":[{"text":"Menu","url":"https://example.com/menu"},{"text":"Run","url":"javascript:alert(1)"},{"text":"App","url":"shortcuts://run"}],"attachments":[{"name":"a.pdf","size":10}],"can_unsubscribe":true,"unsubscribe":"one_click"}"#)))
        #expect(message.links.map(\.url.absoluteString) == ["https://example.com/menu"])
        #expect(message.attachments.first?.name == "a.pdf")
        #expect(message.unsubscribe == .oneClick)
    }

    @Test func errorsAndOldPluginsAreToldApart() {
        #expect(throws: MailError.server(code: "login_failed", message: "The password was refused.")) {
            try MailWire.parse(#"redde-push mail {"error":"login_failed","message":"The password was refused."}"#)
        }
        #expect(throws: MailError.noPlugin) { try MailWire.parse("usage: /redde-push pair|test|status") }
        #expect(throws: MailError.malformed) { try MailWire.parse("redde-push mail {not json") }
    }

    @Test func aTapIsDoneAtOnceAndUndoPutsItBack() async throws {
        var sent: [String] = []
        let center = center { words in
            sent.append(words)
            if words.hasPrefix("mail status") { return Self.status }
            if words.hasPrefix("mail list") { return Self.list }
            if words.hasPrefix("mail act archive") { return #"redde-push mail {"done":["main:INBOX:1"],"failed":[],"log":"m1-1"}"# }
            return #"redde-push mail {"done":[],"failed":[]}"#
        }
        await center.refresh(nil)
        #expect(center.threads(in: nil).count == 2)
        #expect(await center.act(.archive, on: ["main:INBOX:1"]))
        #expect(center.threads(in: nil).map(\.id) == ["main:INBOX:2"], "gone from the list at once")
        #expect(sent.contains("mail act archive main:INBOX:1"))
        let toast = try #require(center.toast)
        #expect(toast.undo == "m1-1")
        await center.undo(toast)
        #expect(center.threads(in: nil).count == 2, "back on Undo")
        #expect(sent.last == "mail act undo m1-1")
    }

    @Test func aRefusedTapIsPutBack() async {
        let center = center { words in
            if words.hasPrefix("mail status") { return Self.status }
            if words.hasPrefix("mail list") { return Self.list }
            return #"redde-push mail {"error":"server_unreachable","message":"Your mail server didn't answer."}"#
        }
        await center.refresh(nil)
        #expect(await center.act(.read, on: ["main:INBOX:1"]) == false)
        #expect(center.threads(in: nil).first?.unread == true, "as it was")
        #expect(center.toast?.text == "Your mail server didn't answer.")
        #expect(center.toast?.undo == nil)
    }

    @Test func snoozingSendsWhenAndLabelsSendTheName() {
        let until = Date(timeIntervalSince1970: 1_762_200_000)
        #expect(MailAction.snooze(until).words == "snooze" && MailAction.snooze(until).arg == "1762200000")
        #expect(MailAction.label("Bills").arg == "Bills")
        #expect(MailAction.archive.removes && MailAction.unsubscribe.removes && !MailAction.read.removes)
    }

    @Test func rulesAreWrittenAndReadBack() throws {
        let rule = MailRule(id: "r1", from: "receipts@shop.example.com", action: .archive, made: Date(timeIntervalSince1970: 100))
        let back = try #require(MailRule(json: try json(MailWire.json(rule.json))))
        #expect(back == rule)
        #expect(back.described.contains("receipts@shop.example.com"))
        let labelled = try #require(MailRule(json: try json(#"{"id":"r3","when":{"subject":"invoice"},"do":"label","arg":"Bills"}"#)))
        #expect(labelled.action == .label && labelled.arg == "Bills" && labelled.subject == "invoice")
        #expect(MailRule(json: try json(#"{"id":"r4","when":{},"do":"delete"}"#)) == nil, "rules never delete")
    }

    @Test func aTaggingRuleCanAddSeveralLabels() throws {
        let rule = try #require(MailRule(json: try json(#"{"id":"r5","when":{"domain":"shop.example.com"},"do":"label","arg":"Receipts","also":["Paperless","Receipts"]}"#)))
        #expect(rule.labels == ["Receipts", "Paperless"], "the first label first, each once")
        #expect(rule.json["also"] as? [String] == ["Paperless", "Receipts"])
        #expect(TagRuleText.line(rule).hasPrefix("Label Receipts, Paperless"))
        #expect(rule.described.hasSuffix("Receipts, Paperless"))
        var archiving = rule
        archiving.action = .archive
        #expect(archiving.json["also"] == nil && archiving.labels == ["Receipts"], "only a tagging rule has more labels")
        let one = try #require(MailRule(json: try json(#"{"id":"r6","when":{"from":"a"},"do":"label","arg":"Bills"}"#)))
        #expect(one.also.isEmpty && one.json["also"] == nil, "a one-label rule is written as before")
    }

    @Test func theLogSaysWhatCanBeUndone() throws {
        let log = try MailWire.parse(#"redde-push mail {"log":[{"id":"m1","at":10,"rule":"r1","action":"archive","account":"main","ids":["main:INBOX:9"],"title":"Archived a receipt","undone":false,"by":"rule"},{"id":"m2","at":9,"rule":"r2","action":"notify","account":"main","ids":[],"title":"Told you","by":"rule"}]}"#)
        let entries = (log["log"]?.array ?? []).compactMap(MailLogEntry.init(json:))
        #expect(entries.map(\.undoable) == [true, false], "a notification can't be taken back")
    }

    @Test func aDraftedEmailIsAReviewCardThatSendsByItsHash() throws {
        let cards = ReplyCards.parse(try json(#"{"cards":[{"type":"review","kind":"email","title":"Reply to Ana","draft":{"id":"d1","to":["ana@example.com"],"cc":["bo@example.com"],"subject":"Re: Lunch","body":"Thursday works.","reply_to":"main:INBOX:1","account":"main","hash":"abc"}}]}"#))
        guard case let .review(review)? = cards.first else { Issue.record("no review card"); return }
        #expect(review.draft?.hash == "abc" && review.draft?.cc == ["bo@example.com"])
        #expect(review.shownKind == .email)
        #expect(review.fields.map(\.label) == ["To", "Cc", "Subject", "Message"], "drawn from the draft when the agent gave no fields")
        #expect(review.layout.body == 3)
    }

    @Test func theContractsDraftCardKeepsItsOwnFields() throws {
        let cards = ReplyCards.parse(try json(#"{"cards":[{"type":"review","kind":"email","title":"Reply: Re: Lunch","action":"Send","fields":[{"label":"To","value":"ana@example.com"},{"label":"Subject","value":"Re: Lunch"},{"label":"Message","value":"Thursday works…","kind":"long"}],"draft":{"id":"d1a2","to":["ana@example.com"],"cc":[],"subject":"Re: Lunch","body":"Thursday works…","account":"main","hash":"9f2c"}}]}"#))
        guard case let .review(review)? = cards.first else { Issue.record("no review card"); return }
        #expect(review.fields.count == 3 && review.draft?.id == "d1a2")
    }

    @Test func sendingAnEditedDraftEditsItFirst() async throws {
        var sent: [String] = []
        let center = center { words in
            sent.append(words)
            if words.hasPrefix("mail draft-edit") { return #"redde-push mail {"id":"d1","to":["ana@example.com"],"cc":[],"subject":"Re: Lunch","body":"Friday instead.","hash":"new"}"# }
            return #"redde-push mail {"sent":true,"id":"d1"}"#
        }
        let draft = MailDraft(id: "d1", to: ["ana@example.com"], subject: "Re: Lunch", body: "Thursday works.", hash: "old")
        var edited = draft
        edited.body = "Friday instead."
        try await center.send(draft, edited: edited)
        #expect(sent.first?.hasPrefix("mail draft-edit d1 {") == true)
        #expect(sent.last == "mail draft-send d1 new")
        sent = []
        try await center.send(draft, edited: nil)
        #expect(sent == ["mail draft-send d1 old"], "unchanged: sent as drafted")
    }

    @Test func anInboxCardKeepsAtMostFourPilesOfFive() throws {
        let threads = (1...7).map { #"{"id":"t\#($0)","from":"S\#($0)","subject":"Hi","unread":true}"# }.joined(separator: ",")
        let piles = ["important", "needs_reply", "fyi", "newsletters", "unsorted"].map { #"{"bucket":"\#($0)","count":9,"threads":[\#(threads)]}"# }.joined(separator: ",")
        let cards = ReplyCards.parse(try json(#"{"cards":[{"type":"inbox","account":"main","buckets":[\#(piles),{"bucket":"spam","threads":[]}]}]}"#))
        guard case let .inbox(inbox)? = cards.first else { Issue.record("no inbox card"); return }
        #expect(inbox.buckets.count == 4)
        #expect(inbox.buckets.allSatisfy { $0.threads.count == 5 && $0.count == 9 })
    }
}
