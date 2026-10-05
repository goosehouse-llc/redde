import CoreImage
import Foundation
import Testing
import UIKit
@testable import Echo

@Suite(.serialized)
@MainActor
struct SetupCodeTests {
    private func settings() -> Settings { Settings(defaults: UserDefaults(suiteName: "setup-code-test-\(UUID().uuidString)")!) }

    private func read(_ link: String) throws -> SetupCode? { try SetupCode.read(URL(string: link)!) }

    /// Secrets a test filed under a server, removed again.
    private func forget(_ server: UUID) {
        let suffix = "@\(server.uuidString)"
        for account in Keychain.allAccounts() where account.hasSuffix(suffix) { Keychain.delete(account: account) }
    }

    // MARK: - Reading a link

    @Test func readsEveryParameter() throws {
        let code = try #require(try read("redde://connect?v=1&name=Home&dashboard=http://hermes.home.test:9119/&user=redde&password=pw"
            + "&api=https://hermes.home.test:8642/v1&key=k1&profile=work&profile-key=k2&access-id=id.access&access-secret=s"
            + "&model-url=http://llama.home.test:8080&model-key=mk&model=qwen&use=api"))
        #expect(code.name == "Home")
        #expect(code.dashboardURL == "http://hermes.home.test:9119")   // as Setup stores it: no trailing slash
        #expect(code.dashboardUser == "redde")
        #expect(code.dashboardPassword == "pw")
        #expect(code.apiURL == "https://hermes.home.test:8642")        // …and no /v1
        #expect(code.apiKey == "k1")
        #expect(code.profile == "work")
        #expect(code.profileKey == "k2")
        #expect(code.accessID == "id.access")
        #expect(code.accessSecret == "s")
        #expect(code.modelURL == "http://llama.home.test:8080")
        #expect(code.modelKey == "mk")
        #expect(code.model == "qwen")
        #expect(code.use == .hermesSessions)
        #expect(code.transport == .hermesSessions)
        #expect(code.hasServer)
        #expect(code.hasSecrets)
    }

    @Test func otherLinksArentSetupLinks() throws {
        for link in ["echo://listen", "echo://connect?api=http://a.test", "redde://listen", "https://redde.goosehouse.org/connect?api=http://a.test"] {
            #expect(try read(link) == nil, "\(link)")
            #expect(SetupCodeOffer(url: URL(string: link)!) == nil)
        }
        // The scheme and the word after it in any case.
        #expect(try read("REDDE://Connect?api=http://a.test")?.apiURL == "http://a.test")
    }

    @Test func refusesWhatItCantUse() {
        #expect(throws: SetupCode.ParseError.newerVersion) { try read("redde://connect?v=2&api=http://a.test") }
        #expect(throws: SetupCode.ParseError.noAddress) { try read("redde://connect?name=Home&user=redde&password=pw") }
        #expect(throws: SetupCode.ParseError.noAddress) { try read("redde://connect") }
        // Not http or https, no scheme at all, or a user name posing as the host.
        for bad in ["ftp://a.test", "javascript:alert(1)", "hermes.home.test:9119", "file:///etc/hosts", "http://my-server@elsewhere.test", "http://"] {
            #expect(throws: SetupCode.ParseError.badAddress(bad)) {
                try SetupCode.read(URL(string: "redde://connect?dashboard=\(bad.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)")!)
            }
        }
        // One bad address spoils the code, even beside a good one.
        #expect(throws: SetupCode.ParseError.badAddress("ftp://b.test")) { try read("redde://connect?api=http://a.test&model-url=ftp://b.test") }
        #expect(throws: SetupCode.ParseError.tooLong) {
            try read("redde://connect?api=http://a.test&key=" + String(repeating: "k", count: SetupCode.maximumLength))
        }
    }

    @Test func aLinkThatCantBeUsedIsStillAnOffer() throws {
        let offer = try #require(SetupCodeOffer(url: URL(string: "redde://connect?v=9&api=http://a.test")!))
        #expect(offer.result == .failure(.newerVersion))
    }

    @Test func theFirstOfARepeatedParameterCounts() throws {
        let code = try #require(try read("redde://connect?api=http://a.test&api=http://b.test&key=&key=second"))
        #expect(code.apiURL == "http://a.test")
        #expect(code.apiKey == "second")   // a blank one is no value
    }

    @Test func useFallsBackToWhatTheCodeCarries() throws {
        #expect(try read("redde://connect?api=http://a.test&use=dashboard")?.transport == .hermesSessions)
        #expect(try read("redde://connect?api=http://a.test&dashboard=http://d.test")?.transport == .hermesServe)
        #expect(try read("redde://connect?api=http://a.test&dashboard=http://d.test&use=api")?.transport == .hermesSessions)
        let model = try #require(try read("redde://connect?model-url=http://m.test&model=qwen"))
        #expect(model.transport == .chatCompletions)
        #expect(!model.hasServer)
    }

    @Test func awkwardCharactersSurviveTheLink() throws {
        var code = SetupCode()
        code.name = "Sol's house & café"
        code.dashboardURL = "http://hermes.home.test:9119"
        code.dashboardUser = "redde+phone@home"
        code.dashboardPassword = "p&ss=w+rd #1% /?é 🔑"
        code.apiURL = "https://hermes.home.test:8642"
        code.apiKey = "sk-AbC/+==&x"
        code.use = .hermesServe
        let link = code.url.absoluteString
        #expect(!link.contains("+"), "a plus sign must be escaped: other readers take it for a space")
        #expect(!link.contains(" "))
        #expect(try read(link) == code)
        #expect(try SetupCode.read(code.withoutSecrets.url)?.hasSecrets == false)
    }

    /// The output of `scripts/setup-code.py` for these values (Python escapes more than
    /// URLComponents does; both must read the same).
    @Test func aLinkMadeByTheScriptReads() throws {
        let code = try #require(try read("redde://connect?name=Sol%27s%20house%20%26%20caf%C3%A9&dashboard=http%3A%2F%2Fhermes.home.test%3A9119"
            + "&user=redde%2Bphone%40home&password=p%26ss%3Dw%2Brd%20%231%25%20%2F%3F%C3%A9&api=https%3A%2F%2Fhermes.home.test%3A8642"
            + "&key=sk-AbC%2F%2B%3D%3D%26x&use=dashboard"))
        #expect(code.name == "Sol's house & café")
        #expect(code.dashboardURL == "http://hermes.home.test:9119")
        #expect(code.dashboardUser == "redde+phone@home")
        #expect(code.dashboardPassword == "p&ss=w+rd #1% /?é")
        #expect(code.apiURL == "https://hermes.home.test:8642")
        #expect(code.apiKey == "sk-AbC/+==&x")
        #expect(code.transport == .hermesServe)
    }

    @Test func findsTheLinkInText() throws {
        let link = "redde://connect?api=http://a.test&key=k"
        #expect(SetupCode.link(in: link)?.absoluteString == link)
        #expect(SetupCode.link(in: "Here you go:\n\(link)\nSee you")?.absoluteString == link)
        #expect(SetupCode.link(in: "<\(link)>")?.absoluteString == link)
        #expect(SetupCode.link(in: "https://example.com/?q=redde") == nil)
        #expect(SetupCodeOffer(text: "nothing here") == nil)
        #expect(try SetupCodeOffer(text: "  \(link)  ")?.result.get().apiKey == "k")
    }

    // MARK: - Saving one

    @Test func fillsInABlankServer() throws {
        let settings = settings()
        let server = settings.activeServerID
        defer { forget(server) }
        let code = try #require(try read("redde://connect?name=Home&dashboard=http://d.test:9119&user=redde&password=pw&api=http://a.test:8642&key=k&profile=work&profile-key=pk&access-id=cid&access-secret=cs"))
        #expect(settings.activeServerIsUnused)
        #expect(code.plan(for: settings) == SetupCode.Plan(server: .fill, sameAs: nil, replacesModelURL: nil, transport: .hermesServe))

        let receipt = code.install(in: settings) { _ in Issue.record("a blank server is filled in, not switched away from") }
        #expect(receipt.added == nil)
        #expect(settings.servers.count == 1)
        #expect(settings.activeServerID == server)
        #expect(settings.activeServer?.name == "Home")
        #expect(settings.serveURL == "http://d.test:9119")
        #expect(settings.serveUsername == "redde")
        #expect(settings.gatewayURL == "http://a.test:8642")
        #expect(settings.hermesProfile == "work")
        #expect(settings.cfAccessClientID == "cid")
        #expect(settings.transport == .hermesServe)
        #expect(settings.activeServer?.transport == .hermesServe)
        let id = server.uuidString
        #expect(Keychain.read(account: Keychain.account(.serveDashboardPassword, server: id)) == "pw")
        #expect(Keychain.read(account: Keychain.account(.gatewayAPIKey, server: id)) == "k")
        #expect(Keychain.read(account: Keychain.account(.cfAccessClientSecret, server: id)) == "cs")
        #expect(Keychain.read(account: Keychain.profileAccount("work", server: id)) == "pk")
        #expect(!settings.activeServerIsUnused)
    }

    /// An address typed and left, a model picked for it: without a stored secret the server has
    /// never connected, and the code takes its place whole.
    @Test func aServerThatNeverConnectedIsFilledInWhole() throws {
        let settings = settings()
        let server = settings.activeServerID
        defer { forget(server) }
        settings.transport = .hermesSessions
        settings.gatewayURL = "http://typed.test:8642"
        settings.serveUsername = "someone"
        settings.cfAccessClientID = "typed-id"
        settings.gatewayModel = "typed-model"
        settings.hermesProfile = "typed"
        let code = try #require(try read("redde://connect?dashboard=http://d.test:9119&user=redde&password=pw"))
        #expect(code.plan(for: settings).server == .fill)
        code.install(in: settings) { _ in Issue.record("filled in, not switched away from") }
        #expect(settings.servers.count == 1)
        #expect(settings.gatewayURL == "")
        #expect(settings.serveURL == "http://d.test:9119")
        #expect(settings.serveUsername == "redde")
        #expect(settings.cfAccessClientID == "")
        #expect(settings.gatewayModel == "")
        #expect(settings.hermesProfile == "")
        #expect(settings.transport == .hermesServe)
    }

    /// Any stored secret makes a server one that is set up, whichever secret it is.
    @Test func anyStoredSecretKeepsAServerFromBeingFilledIn() throws {
        let code = try #require(try read("redde://connect?api=http://a.test:8642&key=k&profile=other"))
        let accounts: [(String) -> String] = [
            { Keychain.account(.cfAccessClientSecret, server: $0) },
            { Keychain.profileAccount("other", server: $0) },
            { Keychain.account(.serveDashboardPassword, server: $0) },
        ]
        for account in accounts {
            let settings = settings()
            let server = settings.activeServerID
            defer { forget(server) }
            Keychain.write(account: account(server.uuidString), value: "kept")
            #expect(code.plan(for: settings).server == .add)
            let receipt = code.install(in: settings) { settings.activateServer($0) }
            let added = try #require(receipt.added)
            defer { forget(added) }
            // The secret stayed with its own server and didn't follow the code.
            #expect(Keychain.read(account: account(server.uuidString)) == "kept")
            #expect(Keychain.read(account: account(added.uuidString)) == nil)
        }
    }

    @Test func aSecondCodeForTheSameAddressSaysSo() throws {
        let settings = settings()
        let home = settings.activeServerID
        defer { forget(home) }
        let code = try #require(try read("redde://connect?name=Home&dashboard=http://d.test:9119/&user=redde&password=pw"))
        code.install(in: settings) { _ in }
        let again = code.plan(for: settings)
        #expect(again.server == .add)
        #expect(again.sameAs == "Home")
        #expect(try read("redde://connect?dashboard=http://elsewhere.test:9119&password=pw")?.plan(for: settings).sameAs == nil)
    }

    @Test func aSetUpServerIsNeverOverwritten() throws {
        let settings = settings()
        let home = settings.activeServerID
        settings.transport = .hermesSessions
        settings.gatewayURL = "http://home.test:8642"
        Keychain.write(account: Keychain.account(.gatewayAPIKey, server: home.uuidString), value: "home-key")
        defer { forget(home) }

        let code = try #require(try read("redde://connect?name=Office&dashboard=http://office.test:9119&user=redde&password=pw"))
        #expect(code.plan(for: settings).server == .add)
        let receipt = code.install(in: settings) { settings.activateServer($0) }
        let office = try #require(receipt.added)
        defer { forget(office) }

        #expect(settings.servers.count == 2)
        #expect(settings.activeServerID == office)
        #expect(settings.activeServer?.name == "Office")
        #expect(settings.serveURL == "http://office.test:9119")
        #expect(settings.gatewayURL == "")
        #expect(settings.transport == .hermesServe)
        #expect(Keychain.read(account: Keychain.account(.serveDashboardPassword, server: office.uuidString)) == "pw")
        // Home is as it was.
        let homeRecord = try #require(settings.servers.first { $0.id == home })
        #expect(homeRecord.gatewayURL == "http://home.test:8642")
        #expect(homeRecord.serveURL == "")
        #expect(homeRecord.transport == .hermesSessions)
        #expect(Keychain.read(account: Keychain.account(.gatewayAPIKey, server: home.uuidString)) == "home-key")
        #expect(Keychain.read(account: Keychain.account(.serveDashboardPassword, server: home.uuidString)) == nil)

        // Taking it back out: the server and its secrets go, Home is active again.
        SetupCode.remove(receipt, from: settings) { settings.activateServer($0) }
        #expect(settings.servers.map(\.id) == [home])
        #expect(settings.activeServerID == home)
        #expect(settings.gatewayURL == "http://home.test:8642")
        #expect(settings.transport == .hermesSessions)
        #expect(Keychain.read(account: Keychain.account(.serveDashboardPassword, server: office.uuidString)) == nil)
    }

    @Test func aCodeThatIsntSwitchedToLandsNowhere() throws {
        let settings = settings()
        settings.serveURL = "http://home.test:9119"
        Keychain.write(account: Keychain.account(.serveDashboardPassword, server: settings.activeServerID.uuidString), value: "home-pw")
        defer { forget(settings.activeServerID) }
        let code = try #require(try read("redde://connect?dashboard=http://office.test:9119&password=pw"))
        let receipt = code.install(in: settings) { _ in }
        #expect(receipt.added == nil)
        #expect(settings.servers.count == 1)
        #expect(settings.serveURL == "http://home.test:9119")
        #expect(Keychain.read(account: Keychain.account(.serveDashboardPassword, server: settings.activeServerID.uuidString)) == "home-pw")
    }

    @Test func aModelEndpointIsTheAppsNotAServers() throws {
        // A new endpoint forgets the old one's key, and that key is the app's own: put it back.
        let before = Keychain.read(.fastLaneAPIKey)
        defer { Keychain.write(.fastLaneAPIKey, value: before ?? "") }
        let settings = settings()
        settings.serveURL = "http://home.test:9119"
        settings.fastLaneURL = "http://old.test:8080/v1"
        settings.fastLaneModel = "old"
        let code = try #require(try read("redde://connect?model-url=http://new.test:8080&model=qwen"))
        let plan = code.plan(for: settings)
        #expect(plan.server == .none)
        #expect(plan.sameAs == nil)
        #expect(plan.replacesModelURL == "http://old.test:8080/v1")
        #expect(plan.transport == .chatCompletions)

        code.install(in: settings) { _ in Issue.record("no server to switch to") }
        #expect(settings.servers.count == 1)
        #expect(settings.serveURL == "http://home.test:9119")
        #expect(settings.fastLaneURL == "http://new.test:8080")
        #expect(settings.fastLaneModel == "qwen")
        #expect(settings.transport == .chatCompletions)
        // The same endpoint again replaces nothing.
        #expect(code.plan(for: settings).replacesModelURL == nil)
    }

    /// The key saved for one endpoint is never sent to another: a code for a new address brings
    /// its own key or leaves none. (The key is the app's own, so the test puts it back.)
    @Test func aNewEndpointDoesntInheritTheOldKey() throws {
        let before = Keychain.read(.fastLaneAPIKey)
        defer { Keychain.write(.fastLaneAPIKey, value: before ?? "") }
        let settings = settings()
        settings.fastLaneURL = "http://old.test:8080"
        Keychain.write(.fastLaneAPIKey, value: "old-key")

        // The same endpoint, no key in the code: the key stays.
        try #require(try read("redde://connect?model-url=http://old.test:8080/v1&model=qwen")).install(in: settings) { _ in }
        #expect(Keychain.read(.fastLaneAPIKey) == "old-key")
        // Another address, no key: the old key goes.
        try #require(try read("redde://connect?model-url=http://new.test:8080")).install(in: settings) { _ in }
        #expect(settings.fastLaneURL == "http://new.test:8080")
        #expect(Keychain.read(.fastLaneAPIKey) == nil)
        // Another address with a key: that key.
        try #require(try read("redde://connect?model-url=http://third.test:8080&model-key=third-key")).install(in: settings) { _ in }
        #expect(Keychain.read(.fastLaneAPIKey) == "third-key")
    }

    // MARK: - Making one

    @Test func aServersCodeSetsUpAnotherDeviceTheSame() throws {
        let phone = settings()
        let home = phone.activeServerID
        defer { forget(home) }
        phone.renameServer(home, to: "Home")
        phone.transport = .hermesSessions
        phone.gatewayURL = "https://hermes.home.test:8642/"
        phone.serveURL = "http://hermes.home.test:9119"
        phone.serveUsername = "redde"
        phone.hermesProfile = "work"
        phone.cfAccessClientID = "cid"
        let id = home.uuidString
        Keychain.write(account: Keychain.account(.gatewayAPIKey, server: id), value: "k")
        Keychain.write(account: Keychain.profileAccount("work", server: id), value: "pk")
        Keychain.write(account: Keychain.account(.serveDashboardPassword, server: id), value: "pw")
        Keychain.write(account: Keychain.account(.cfAccessClientSecret, server: id), value: "cs")
        let server = try #require(phone.activeServer)

        // Without the secrets: addresses and names only.
        let bare = SetupCode(server: server, settings: phone, secrets: false)
        #expect(!bare.hasSecrets)
        #expect(bare.name == "Home")
        #expect(bare.apiURL == "https://hermes.home.test:8642")
        #expect(bare.dashboardUser == "redde")
        #expect(bare.profile == "work")
        #expect(bare.use == .hermesSessions)

        // With them, through a link, into a fresh install.
        let full = SetupCode(server: server, settings: phone, secrets: true)
        #expect(full.apiKey == "k")
        #expect(full.profileKey == "pk")
        #expect(full.dashboardPassword == "pw")
        #expect(full.accessSecret == "cs")
        let pad = settings()
        defer { forget(pad.activeServerID) }
        let arrived = try #require(try SetupCode.read(full.url))
        #expect(arrived == full)
        arrived.install(in: pad) { _ in }
        var copy = try #require(pad.activeServer)
        copy.id = server.id
        var original = server
        original.gatewayURL = "https://hermes.home.test:8642"   // the code carries addresses tidied
        #expect(copy == original)
        #expect(pad.transport == .hermesSessions)
        #expect(Keychain.read(account: Keychain.profileAccount("work", server: pad.activeServerID.uuidString)) == "pk")
    }

    @Test func aServerWithNoAddressHasNoCode() {
        let settings = settings()
        let code = SetupCode(server: settings.activeServer!, settings: settings, secrets: true)
        #expect(code.transport == nil)
        #expect(code.use == nil)
    }

    @Test func theQRCodeReadsBackAsTheLink() throws {
        var code = SetupCode()
        code.name = "Home"
        code.dashboardURL = "http://hermes.home.test:9119"
        code.dashboardUser = "redde"
        code.dashboardPassword = String(repeating: "pässwörd-", count: 8)
        code.apiURL = "https://hermes.home.test:8642"
        code.apiKey = String(repeating: "k", count: 64)
        let link = code.url.absoluteString
        let picture = try #require(QRCode.image(for: link)?.cgImage)
        // Scaled up as the screen shows it, on a white margin.
        let scale = 8, margin = 32
        let size = CGSize(width: picture.width * scale + margin * 2, height: picture.height * scale + margin * 2)
        let shown = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            context.cgContext.interpolationQuality = .none
            context.cgContext.draw(picture, in: CGRect(x: margin, y: margin, width: picture.width * scale, height: picture.height * scale))
        }
        let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let found = detector.features(in: CIImage(image: shown)!).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        #expect(found == [link])
        #expect(try SetupCode.read(URL(string: found[0])!) == code)
    }
}
