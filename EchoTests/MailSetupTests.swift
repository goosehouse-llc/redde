import Foundation
import Testing
@testable import Echo

/// Setting up email (2.4): each provider's servers as the plugin's presets have them, the names the
/// settings go under (tmp/mail-contract.md), an extra account's key, and each value sealed to its
/// own key request.
@MainActor
struct MailSetupTests {
    @Test func providersPointAtTheirOwnServers() {
        #expect(MailProvider.gmail.imap?.host == "imap.gmail.com" && MailProvider.gmail.smtp?.port == 465)
        #expect(MailProvider.icloud.smtp?.host == "smtp.mail.me.com" && MailProvider.icloud.smtp?.port == 587)
        #expect(MailProvider.fastmail.imap?.port == 993)
        #expect(MailProvider.other.imap == nil, "he names the servers himself")
        #expect(!MailProvider.outlook.appPasswordsWork, "Microsoft has mostly turned them off: said, not hidden")
        for provider in MailProvider.allCases where provider != .other {
            #expect(provider.appPasswordPage?.scheme == "https", "\(provider)")
        }
    }

    @Test func theFirstAccountsNamesAreTheMainOnes() {
        let values = MailSecrets.values(provider: .icloud, address: "me@example.com", password: "abcd-efgh", name: "Home", user: nil,
                                        imap: nil, smtp: nil, key: nil)
        #expect(values.map(\.name) == ["REDDE_MAIL_ADDRESS", "REDDE_MAIL_PROVIDER", "REDDE_MAIL_NAME", "REDDE_MAIL_PASSWORD"])
        #expect(values.last?.value == "abcd-efgh", "the password last")
        #expect(!values.contains { $0.name.hasPrefix("EMAIL_") }, "never Hermes's own email platform's")
    }

    @Test func anotherAccountCarriesItsKey() {
        #expect(MailSecrets.key(for: "Work") == "WORK")
        #expect(MailSecrets.key(for: "Side job!") == "SIDE_JOB")
        #expect(MailSecrets.key(for: "2nd") == "A2ND", "a name can't start with a figure")
        #expect(MailSecrets.accountID(key: "WORK") == "work" && MailSecrets.accountID(key: nil) == "main")
        let values = MailSecrets.values(provider: .other, address: "me@work.example.com", password: "pw", name: "Work", user: "me",
                                        imap: ("mail.work.example.com", 993), smtp: ("smtp.work.example.com", 587), key: "WORK")
        #expect(values.map(\.name) == ["REDDE_MAIL_WORK_ADDRESS", "REDDE_MAIL_WORK_PROVIDER", "REDDE_MAIL_WORK_NAME", "REDDE_MAIL_WORK_USER",
                                       "REDDE_MAIL_WORK_IMAP_HOST", "REDDE_MAIL_WORK_IMAP_PORT", "REDDE_MAIL_WORK_SMTP_HOST",
                                       "REDDE_MAIL_WORK_SMTP_PORT", "REDDE_MAIL_WORK_PASSWORD"])
        #expect(values.first { $0.name.hasSuffix("SMTP_PORT") }?.value == "587")
    }

    private func account(key: String? = nil) -> MailSetup {
        MailSetup(provider: .icloud, address: "me@example.com", password: "secret pw", name: key == nil ? "Home" : "Work", user: nil,
                  imap: nil, smtp: nil, key: key)
    }

    /// A center and the key cards answered by `reply`, which sees every command sent.
    private func harness(_ reply: @escaping (String) -> String) -> (MailCenter, () -> Void) {
        let center = MailCenter()
        center.reachable = { true }
        center.plugin = { reply($0) }
        let keys = KeyRequests.shared
        let oldPlugin = keys.plugin, oldReachable = keys.reachable
        keys.reachable = { true }
        keys.plugin = { reply($0) }
        return (center, { keys.plugin = oldPlugin; keys.reachable = oldReachable })
    }

    private static let pub = PushSeal.base64URL(Data(repeating: 9, count: 32))

    private static func asked(_ words: String) -> String {
        let name = words.split(separator: " ")[2]
        return #"redde-push keys {"i":"ask1","t":"\#(name)","g":"default","b":"why","p":"redde-app","d":"Redde","r":false,"k":"\#(pub)","u":9999999999}"#
    }

    @Test func settingsGoInOneGoAndOnlyThePasswordIsSealed() async throws {
        var sent: [String] = []
        let (center, restore) = harness { words in
            sent.append(words)
            if words.hasPrefix("mail status") { return #"redde-push mail {"accounts":[],"setup":{"command":true}}"# }
            if words.hasPrefix("mail setup ") { return #"redde-push mail {"written":["REDDE_MAIL_ADDRESS"],"status":{"accounts":[],"setup":{"command":true}}}"# }
            if words.hasPrefix("keys ask") { return Self.asked(words) }
            return "redde-push keys set REDDE_MAIL_PASSWORD"
        }
        defer { restore() }
        try await center.setUp(account())
        let setup = try #require(sent.first { $0.hasPrefix("mail setup ") })
        let json = try JSONValue.parse(Data(setup.dropFirst("mail setup ".count).utf8))
        #expect(json["address"]?.string == "me@example.com" && json["provider"]?.string == "icloud" && json["name"]?.string == "Home")
        #expect(json["password"] == nil, "the password never goes in mail setup")
        #expect(sent.filter { $0.hasPrefix("keys ask") }.count == 1)
        #expect(sent.contains { $0.hasPrefix("keys ask REDDE_MAIL_PASSWORD default ") })
        #expect(sent.filter { $0.hasPrefix("keys set ask1 ") }.count == 1)
        #expect(!sent.joined().contains("secret pw"), "sealed, never as text")
    }

    @Test func anotherAccountIsNamedInSetupAndItsPassword() async throws {
        var sent: [String] = []
        let (center, restore) = harness { words in
            sent.append(words)
            if words.hasPrefix("mail status") { return #"redde-push mail {"accounts":[],"setup":{"command":true}}"# }
            if words.hasPrefix("mail setup ") { return #"redde-push mail {"written":[]}"# }
            if words.hasPrefix("keys ask") { return Self.asked(words) }
            return "redde-push keys set x"
        }
        defer { restore() }
        try await center.setUp(account(key: "WORK"))
        #expect(sent.contains { $0.hasPrefix("mail setup ") && $0.contains(#""account":"work""#) })
        #expect(sent.contains { $0.hasPrefix("keys ask REDDE_MAIL_WORK_PASSWORD default ") })
    }

    @Test func anOlderPluginGetsEachValueSealed() async throws {
        var sent: [String] = []
        let (center, restore) = harness { words in
            sent.append(words)
            if words.hasPrefix("mail status") { return #"redde-push mail {"accounts":[]}"# }
            if words.hasPrefix("keys ask") { return Self.asked(words) }
            return "redde-push keys set x"
        }
        defer { restore() }
        try await center.setUp(account())
        #expect(!sent.contains { $0.hasPrefix("mail setup") })
        #expect(sent.filter { $0.hasPrefix("keys ask") }.count == 4, "address, provider, name, password")
    }

    @Test func aRefusedAskIsSaidPlainly() {
        #expect(throws: MailError.self) { try MailCenter.request(from: "redde-push keys refused busy") }
        #expect(throws: MailError.self) { try MailCenter.request(from: "usage: /redde-push keys list|set|decline") }
        let request = try? MailCenter.request(from: #"redde-push keys {"i":"a","t":"REDDE_MAIL_PASSWORD","g":"default","k":"\#(Self.pub)","u":1}"#)
        #expect(request?.name == "REDDE_MAIL_PASSWORD")
    }

    @Test func theBriefMakesTheDecksEmailPageOnceADay() throws {
        let status = MailStatus(json: try JSONValue.parse(Data(#"{"accounts":[],"brief":{"accounts":[{"id":"main","name":"Home","unread":12,"important":2,"needs_reply":3,"newsletters":20,"as_of":1762150000,"top":[{"id":"main:INBOX:1","from":"Ana Ruiz","subject":"Lunch?","summary":"Ana asks about lunch.","bucket":"needs_reply","date":1762149000}]}]}}"#.utf8)))
        let brief = try #require(status.brief)
        #expect(brief.important == 2 && brief.needsReply == 3 && brief.top.first?.from == "Ana Ruiz")
        #expect(brief.asOf == Date(timeIntervalSince1970: 1_762_150_000))
        #expect(MailBrief(json: .null) == nil, "no account works yet")
        let defaults = UserDefaults(suiteName: "mail-brief-\(UUID().uuidString)")!
        #expect(MailBriefPage.item(brief, defaults: defaults) != nil)
        MailBriefPage.done(defaults: defaults)
        #expect(MailBriefPage.item(brief, defaults: defaults) == nil, "put away until tomorrow")
        #expect(MailBriefPage.item(brief, now: .now.addingTimeInterval(86_400), defaults: defaults) != nil)
        let quiet = MailBrief(accounts: [.init(id: "main", name: "Home", unread: 0, important: 0, needsReply: 0, newsletters: 4, asOf: nil, top: [])])
        #expect(MailBriefPage.item(quiet, defaults: UserDefaults(suiteName: "mail-brief-\(UUID().uuidString)")!) == nil, "nothing waiting: no page")
    }

    @Test func snoozeChoicesComeBackLater() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let morning = calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 9))!
        #expect(SnoozeChoice.laterToday.date(now: morning, calendar: calendar) == morning.addingTimeInterval(3 * 3600))
        let tomorrow = SnoozeChoice.tomorrow.date(now: morning, calendar: calendar)
        #expect(calendar.component(.day, from: tomorrow) == 4 && calendar.component(.hour, from: tomorrow) == 8)
        let week = SnoozeChoice.nextWeek.date(now: morning, calendar: calendar)
        #expect(calendar.component(.weekday, from: week) == 2 && week > morning)
        let evening = calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 16))!
        #expect(SnoozeChoice.laterToday.date(now: evening, calendar: calendar) >= calendar.date(bySettingHour: 18, minute: 0, second: 0, of: evening)!)
    }

    // MARK: Gmail labels and tagging rules (11-03)

    private func json(_ text: String) throws -> JSONValue { try JSONValue.parse(Data(text.utf8)) }

    @Test func aTaggingRuleKeepsEveryFieldThroughASave() throws {
        let v = try json(#"{"id":"t1","name":"Shop receipts","when":{"domain":"shop.example.com","attachment":"pdf","cc":"lea@","body":"total","receipt":true,"newer_than_days":90},"do":"label","arg":"Paperless","archive":true,"match":"any","enabled":false,"account":"main","matches":4}"#)
        let rule = try #require(MailRule(json: v))
        #expect(rule.isTagging && rule.archive && rule.matchAny && !rule.enabled && rule.matches == 4)
        #expect(rule.attachment == .pdf && rule.newerThanDays == 90 && rule.account == "main")
        let back = try #require(MailRule(json: try json(MailWire.json(rule.json))))
        #expect(back == MailRule(json: v).map { var r = $0; r.matches = 0; return r })
        #expect(rule.json["matches"] == nil, "the count is the plugin's, never sent back")
    }

    @Test func archiveIsOnlyEverSentForATaggingRule() throws {
        var rule = MailRule(id: "r1", from: "ana@", action: .notify)
        rule.archive = true
        #expect(rule.json["archive"] as? Bool == false)
    }

    @Test func theReadyMadeRuleReadsAsPaperless() throws {
        let v = try json(#"{"id":"paperless","name":"Receipts with attachments → Paperless","enabled":false,"builtin":true,"match":"all","when":{"receipt":true,"attachment":"any"},"do":"label","arg":"Paperless","archive":false}"#)
        let rule = try #require(MailRule(json: v))
        #expect(rule.builtin && !rule.enabled && rule.arg == "Paperless")
        #expect(TagRuleText.line(rule).contains("Paperless"))
    }

    /// The ready-made Receipts rule (11-05): every receipt, labelled Receipts; and rules go to the
    /// plugin as the plain list `mail rules set` takes (wrapped, every save was turned down).
    @Test func theReceiptsPresetLabelsEveryReceiptAndRulesGoAsAList() throws {
        let rule = TagRulePresets.receipts(account: "main", now: Date(timeIntervalSince1970: 1_800_000_000))
        let wire = rule.json
        #expect(wire["do"] as? String == "label" && wire["arg"] as? String == "Receipts" && wire["enabled"] as? Bool == true)
        #expect((wire["when"] as? [String: Any])?["receipt"] as? Bool == true)
        #expect((wire["when"] as? [String: Any])?["attachment"] == nil, "attachment or not")
        #expect((wire["id"] as? String ?? "").count <= 24)
        #expect(MailWire.json([wire]).hasPrefix("["))
    }

    @Test func movingAnEmailToAnotherGroupIsGroupWithItsName() {
        #expect(MailAction.group(.important).words == "group" && MailAction.group(.needsReply).arg == "needs_reply")
        #expect(!MailAction.group(.fyi).removes)
    }

    @Test func anAccountSaysWhetherItCanLabelAndHowFarTheBackfillIs() throws {
        let v = try json(#"{"id":"main","name":"Home","address":"a@gmail.com","provider":"gmail","via":"imap","usable":true,"can_label":true,"labels":{"groups":true},"backfill":{"state":"running","done":200,"total":800},"labelled":12}"#)
        let account = try #require(MailAccount(json: v))
        #expect(account.canLabel && account.groupLabels && account.labelled == 12)
        #expect(account.backfill?.busy == true && account.backfill?.done == 200)
        let other = try #require(MailAccount(json: try json(#"{"id":"work","provider":"icloud","usable":true}"#)))
        #expect(!other.canLabel)
    }

    @Test func aSendersDomainForTagEmailsLikeThis() {
        #expect(TagRuleText.domain(of: "orders@shop.example.com") == "shop.example.com")
        #expect(TagRuleText.domain(of: "nobody") == nil)
    }

    @Test func aSuggestionReadsAsARuleWithItsWhy() throws {
        let v = try json(#"{"id":"a1b2c3","kind":"repeated","why":"You archived 6 emails from deals@shop.example.com this month.","rule":{"when":{"from":"deals@shop.example.com"},"do":"archive","account":"main"}}"#)
        let suggestion = try #require(MailSuggestion(json: v))
        #expect(suggestion.rule.action == .archive && suggestion.rule.from == "deals@shop.example.com")
        #expect(suggestion.why.contains("archived 6"))
        #expect(suggestion.rule.id == "sa1b2c3")
        let account = try #require(MailAccount(json: try json(#"{"id":"main","usable":true,"suggest":true,"suggestions":[{"id":"a","why":"x"}]}"#)))
        #expect(account.suggest && account.suggestionCount == 1)
    }
}
