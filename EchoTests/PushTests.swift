import CryptoKit
import Foundation
import Testing
import UserNotifications
@testable import Echo

/// Values the plugin's own code produced (`companion/hermes-plugin/redde-push/core.py`) for fixed
/// private keys: the plugin's is bytes 0…31, the phone's bytes 32…63. If either end changes how it
/// derives or seals, these stop matching.
private nonisolated enum Vector {
    static let offered = PushSeal.data(base64URL: "j0DFrbaPJWJK5bIU6nZ6bslNgp09e14a0bpvPiE4KF8")!
    static let answered = "NYBy1jZYgNGu6jKa35EhODhR7SGijjt16WXQ0s0WYlQ"
    static let noteKey = data(hex: "cad4112e909263b723613b895715fabcce5c9d1f2a55284ecccfd66d5abd4c51")
    static let boxKey = data(hex: "4568438b3839ff1bc281370fb9bd943edc872677c7abaff81c0795db2ea633e1")
    static let rendezvous = "45178c46725bbf53272efb845dfb22e3"
    static let keyID = "ae202bee"
    static let deviceID = "dev-test-0001"
    /// {"v":1,"k":"reply","at":1791330000,"n":"studio","s":"20261006_101500_ab12cd","t":"Nightly build","b":"The build is **green**.\n\nAll 381 tests pass."}
    static let payload = "riAr7gcHBwcHBwcHBwcHB5XtQB18k8wLkb6EI7GxAo+pJKgpKO/vLbTOXDSqgIbsR+P5sxa1pSOLV8Ub6F3zCst82T7z4RXapXOswQWO7V4f7Y+tDMP4evQUERsSDxUg05If2LCUEpATsir0/C6EWKXnKKkLpGOu8QO7KP20rSQF7pVmX7wOtt264A2pLfXCYd/voFRUlFYwiamZBh9iBcTQOXS66E+DqQxTtifc9S2Rq0XPHBI="
    /// {"id":"dev-test-0001","send":"send-key","name":"Test phone"} sealed by the plugin's code.
    static let box = "BwcHBwcHBwcHBwcHbUcsrX4qX7YAQONRQa866RdxGZ9XIMcq2b2M8GZOu3yE1Wry7tpE4H87VWuPWmBCMn8SJZs5Lcw-N2jSGmIHm1l31twhzlfKMflwHwxrkJE1"

    static var phoneKey: Curve25519.KeyAgreement.PrivateKey { try! .init(rawRepresentation: Data(32 ..< 64)) }
    static var pluginKey: Curve25519.KeyAgreement.PrivateKey { try! .init(rawRepresentation: Data(0 ..< 32)) }
    static var pairing: PushPairing { PushPairing(id: deviceID, sendKey: "send-key", key: noteKey, relay: "https://relay.test") }

    static func data(hex: String) -> Data {
        var bytes = Data()
        var rest = Substring(hex)
        while rest.count >= 2 {
            bytes.append(UInt8(rest.prefix(2), radix: 16)!)
            rest = rest.dropFirst(2)
        }
        return bytes
    }
}

struct PushSealTests {
    @Test func thePhoneReachesTheKeyThePluginDoes() throws {
        #expect(Vector.pluginKey.publicKey.rawRepresentation == Vector.offered)
        #expect(PushSeal.rendezvous(offered: Vector.offered) == Vector.rendezvous)
        let answer = try PushSeal.answer(to: Vector.offered, deviceID: Vector.deviceID, sendKey: "send-key", name: "Test phone", with: Vector.phoneKey)
        #expect(answer.pub == Vector.answered)
        #expect(answer.noteKey == Vector.noteKey)
        #expect(PushSeal.hex(PushSeal.keyID(answer.noteKey)) == Vector.keyID)
        // The plugin opens the box with the other half of the derived key.
        let box = try #require(PushSeal.data(base64URL: answer.box))
        let inside = try PushSeal.open(box, key: SymmetricKey(data: Vector.boxKey), aad: PushSeal.pairingAAD)
        let fields = try #require(try JSONSerialization.jsonObject(with: inside) as? [String: String])
        #expect(fields == ["id": Vector.deviceID, "send": "send-key", "name": "Test phone"])
        #expect(throws: (any Error).self) { try PushSeal.open(box, key: SymmetricKey(data: Vector.noteKey), aad: PushSeal.pairingAAD) }
    }

    @Test func aBoxThePluginSealedOpensHere() throws {
        let box = try #require(PushSeal.data(base64URL: Vector.box))
        let inside = try PushSeal.open(box, key: SymmetricKey(data: Vector.boxKey), aad: PushSeal.pairingAAD)
        #expect(String(decoding: inside, as: UTF8.self).contains(#""send": "send-key""#))
    }

    @Test func aNoteThePluginSealedOpensWithItsPairingAndNoOther() throws {
        let stranger = PushPairing(id: "someone-else", sendKey: "x", key: Data(repeating: 9, count: 32), relay: "https://relay.test")
        let opened = try #require(PushSeal.note(from: Vector.payload, pairings: [stranger, Vector.pairing]))
        #expect(opened.pairing.id == Vector.deviceID)
        #expect(opened.note == PushNote(k: "reply", s: "20261006_101500_ab12cd", t: "Nightly build",
                                        b: "The build is **green**.\n\nAll 381 tests pass.", n: "studio", at: 1_791_330_000))
        #expect(opened.note.kind == .reply)

        #expect(PushSeal.note(from: Vector.payload, pairings: [stranger]) == nil)
        var renamed = Vector.pairing
        renamed.id = "dev-test-0002"   // sealed to the device: the same key under another id won't open it
        #expect(PushSeal.note(from: Vector.payload, pairings: [renamed]) == nil)
        var tampered = try #require(Data(base64Encoded: Vector.payload))
        tampered[tampered.count - 20] ^= 1
        #expect(PushSeal.note(from: tampered.base64EncodedString(), pairings: [Vector.pairing]) == nil)
        for junk in ["", "not base64 !", "AAAA", Data(repeating: 0, count: 200).base64EncodedString()] {
            #expect(PushSeal.note(from: junk, pairings: [Vector.pairing]) == nil)
        }
    }

    @Test func sealingAndOpeningRoundTrips() throws {
        let key = SymmetricKey(size: .bits256)
        let sealed = try PushSeal.seal(Data("hello".utf8), key: key, aad: Data("who".utf8))
        #expect(sealed.count == 12 + 5 + 16)
        #expect(try PushSeal.open(sealed, key: key, aad: Data("who".utf8)) == Data("hello".utf8))
        #expect(throws: (any Error).self) { try PushSeal.open(sealed, key: key, aad: Data("someone else".utf8)) }
        #expect(PushSeal.data(base64URL: PushSeal.base64URL(Data([0xfb, 0xff, 0xfe, 0x01]))) == Data([0xfb, 0xff, 0xfe, 0x01]))
    }

    /// The Keychain item the notification extension reads, under a name of the test's own.
    @Test func pairingsAreKeptInTheSharedKeychainAndConfirmedByTheFirstNote() {
        let account = "pairings.test.\(UUID().uuidString)"
        let pairing = Vector.pairing
        defer { PushVault.save([], account: account) }
        #expect(PushVault.load(account: account).isEmpty)
        #expect(PushVault.save([pairing], account: account))
        #expect(PushVault.load(account: account) == [pairing])
        #expect(!PushVault.load(account: account)[0].confirmed)
        PushVault.confirm(pairing, host: "studio", account: account)
        let kept = PushVault.load(account: account)
        #expect(kept.count == 1 && kept[0].confirmed && kept[0].host == "studio" && kept[0].key == Vector.noteKey)
        PushVault.confirm(PushPairing(id: "unknown", sendKey: "", key: Data(), relay: ""), host: "x", account: account)
        #expect(PushVault.load(account: account) == kept)
        #expect(PushVault.save([], account: account))
        #expect(PushVault.load(account: account).isEmpty)
    }
}

struct PushNoteContentTests {
    private func content(_ note: PushNote) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Redde"
        content.body = "Open Redde to see what's new."
        content.userInfo = ["e": "sealed"]
        note.fill(content)
        return content
    }

    @Test func aReplySaysWhatItSaysAndNamesItsConversation() {
        let shown = content(PushNote(k: "reply", s: "20261006_1", t: "Nightly build", b: "The build is **green**.\n\n- all `381` tests pass", n: "studio"))
        #expect(shown.title == "Nightly build")
        #expect(shown.body == "The build is green.\n• all 381 tests pass", "Markdown is for the transcript")
        #expect(shown.categoryIdentifier == PushNote.repliedCategory)
        #expect(shown.userInfo[PushNote.sessionKey] as? String == "20261006_1")
        #expect(shown.userInfo[PushNote.kindKey] as? String == "reply")
        #expect(shown.userInfo["e"] == nil, "the sealed blob has done its work")
        #expect(content(PushNote(k: "reply", s: "s", b: "Done.")).title == "Redde")
        #expect(content(PushNote(k: "reply", s: "s", b: String(repeating: "word ", count: 200))).body.count <= 300)
    }

    @Test func anApprovalShowsTheCommandAndWhy() {
        let shown = content(PushNote(k: "approval", s: "20261006_1", t: "Cleanup", b: "rm -rf build", d: "recursive delete"))
        #expect(shown.title == "Redde needs your approval")
        #expect(shown.subtitle == "Cleanup")
        #expect(shown.body == "recursive delete\nrm -rf build")
        #expect(shown.categoryIdentifier.isEmpty, "no Approve and Deny on a pushed approval yet")
        #expect(shown.userInfo[PushNote.sessionKey] as? String == "20261006_1")
    }

    @Test func pairingAndTestNotesNameTheMachine() {
        let paired = content(PushNote(k: "paired", n: "studio"))
        #expect(paired.title == "Paired with studio" && !paired.body.isEmpty)
        #expect(paired.userInfo[PushNote.sessionKey] == nil)
        #expect(content(PushNote(k: "paired")).title == "Paired")
        let test = content(PushNote(k: "test", b: "Notifications from this Hermes reach your phone.", n: "studio"))
        #expect(test.title == "Redde · studio" && test.body == "Notifications from this Hermes reach your phone.")
    }

    @Test func aKindFromANewerPluginLeavesTheRelaysWords() {
        let content = UNMutableNotificationContent()
        content.title = "Redde"
        content.body = "Open Redde to see what's new."
        #expect(!PushNote(k: "something-new", b: "x").fill(content))
        #expect(content.title == "Redde" && content.body == "Open Redde to see what's new.")
        #expect(PushNote(k: "something-new").kind == nil)
    }
}

struct PushOfferTests {
    private let code = "j0DFrbaPJWJK5bIU6nZ6bslNgp09e14a0bpvPiE4KF8"

    @Test func readsBothFormsOfThePairingLink() throws {
        let web = try #require(PushOffer(url: URL(string: "https://redde.goosehouse.org/connect#push=\(code)")!))
        #expect(web.publicKey == Vector.offered && web.relay == nil)
        let app = try #require(PushOffer(url: URL(string: "redde://connect?push=\(code)")!))
        #expect(app == web)
        let other = try #require(PushOffer(url: URL(string: "https://redde.goosehouse.org/connect#push=\(code)&relay=http%3A%2F%2F127.0.0.1%3A18980")!))
        #expect(other.relay == "http://127.0.0.1:18980")
        #expect(other != web)
    }

    @Test func findsTheLinkInWhatTheTerminalPrinted() throws {
        let printed = "Or open this link on the phone:\n\n  https://redde.goosehouse.org/connect#push=\(code)\n\nWaiting for the phone…"
        #expect(PushOffer(text: printed)?.publicKey == Vector.offered)
        #expect(PushOffer(text: "nothing here") == nil)
    }

    @Test func anythingElseIsNotAPairingLink() {
        for link in ["https://redde.goosehouse.org/connect#push=tooshort",
                     "https://redde.goosehouse.org/connect#push=",
                     "https://redde.goosehouse.org/connect#name=Home&api=https://hermes.example:8642",
                     "https://example.com/connect#push=\(code)",
                     "https://redde.goosehouse.org/elsewhere#push=\(code)",
                     "redde://listen?push=\(code)"] {
            #expect(PushOffer(url: URL(string: link)!) == nil, "\(link)")
        }
    }

    @Test func aPairingLinkIsNotTakenForASetupCode() {
        let link = URL(string: "https://redde.goosehouse.org/connect#push=\(code)")!
        #expect(SetupCodeOffer(url: link) == nil, "no \"this setup code has no server address\" for it")
        #expect(SetupCodeOffer(url: URL(string: "https://redde.goosehouse.org/connect#name=Home&api=https://hermes.example:8642&key=k")!) != nil)
    }
}

/// Answers the push service's calls to the relay in-process and keeps what it was sent.
nonisolated final class RelayStub: URLProtocol {
    struct Call: Sendable {
        var method: String
        var path: String
        var headers: [String: String]
        var body: [String: String]
    }

    nonisolated(unsafe) static var calls: [Call] = []
    nonisolated(unsafe) static var reply: (@Sendable (Call) -> (Int, String))?

    static func reset() { calls = []; reply = nil }

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelayStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
        }
        let call = Call(method: request.httpMethod ?? "GET", path: request.url?.path() ?? "",
                        headers: request.allHTTPHeaderFields ?? [:],
                        body: ((try? JSONSerialization.jsonObject(with: data)) as? [String: String]) ?? [:])
        Self.calls.append(call)
        let (status, text) = Self.reply?(call) ?? (204, "")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct PushServiceTests {
    private final class Box { var pairings: [PushPairing] = [] }

    private static let token = Data(repeating: 0xab, count: 32)
    private static let tokenHex = String(repeating: "ab", count: 32)

    /// A service whose Keychain is `box`, whose relay is `RelayStub`, and whose iPhone hands over
    /// its push address as soon as it is asked.
    private func service(_ box: Box, allowed: Bool = true, defaults: UserDefaults? = nil) -> PushService {
        let defaults = defaults ?? UserDefaults(suiteName: "push-test-\(UUID().uuidString)")!
        defaults.set("https://relay.test", forKey: "push.relay")
        nonisolated(unsafe) weak var made: PushService?
        let service = PushService(defaults: defaults, session: RelayStub.session,
                                  vault: ({ box.pairings }, { box.pairings = $0; return true }),
                                  askForToken: { Task { @MainActor in made?.received(token: Self.token) } },
                                  allowed: { allowed })
        made = service
        return service
    }

    private func offer() -> PushOffer { PushOffer(url: URL(string: "redde://connect?push=\(PushSeal.base64URL(Vector.offered))")!)! }

    private func relayThatRegisters() {
        RelayStub.reset()
        RelayStub.reply = { call in call.method == "POST" && call.path == "/v1/devices" ? (201, #"{"id":"relay-id-0123456789"}"#) : (204, "") }
    }

    @Test func pairingRegistersThisPhoneAndLeavesAnAnswerOnlyThePluginCanOpen() async throws {
        relayThatRegisters()
        defer { RelayStub.reset() }
        let box = Box()
        let service = service(box)
        let pairing = try await service.pair(offer())

        #expect(RelayStub.calls.map { "\($0.method) \($0.path)" } == ["POST /v1/devices", "PUT /v1/pairings/\(Vector.rendezvous)"])
        let registration = RelayStub.calls[0]
        #expect(registration.body["token"] == Self.tokenHex && registration.body["env"] == "dev")
        #expect(registration.body["auth"] == PushSeal.hex(SHA256.hash(data: Data(pairing.sendKey.utf8))), "the relay is given the secret's hash")
        #expect(!registration.body.values.contains(pairing.sendKey) && registration.headers["Authorization"] == nil)

        let left = RelayStub.calls[1]
        #expect(left.headers["Authorization"] == "Bearer \(pairing.sendKey)" && left.headers["X-Redde-Device"] == "relay-id-0123456789")
        // What the plugin does with it: its private key and the phone's public one give the keys.
        let theirs = try #require(PushSeal.data(base64URL: left.body["pub"] ?? ""))
        let shared = try Vector.pluginKey.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: theirs))
        let keys = PushSeal.keys(shared: shared, offered: Vector.offered, answered: theirs)
        let inside = try PushSeal.open(try #require(PushSeal.data(base64URL: left.body["box"] ?? "")), key: keys.box, aad: PushSeal.pairingAAD)
        let fields = try #require(try JSONSerialization.jsonObject(with: inside) as? [String: String])
        #expect(fields["id"] == "relay-id-0123456789" && fields["send"] == pairing.sendKey)
        #expect(keys.note == pairing.key, "both ends will seal notes with the same key")
        #expect(!left.body.values.joined().contains(pairing.sendKey), "and the relay can't read the answer")

        #expect(box.pairings == [pairing] && service.pairings == [pairing])
        #expect(!pairing.confirmed && pairing.relay == "https://relay.test")
    }

    @Test func aNoteFromThePluginConfirmsThePairing() async throws {
        relayThatRegisters()
        defer { RelayStub.reset() }
        let box = Box()
        let service = service(box)
        let pairing = try await service.pair(offer())
        #expect(await service.waitUntilConfirmed(pairing, seconds: 0.2) == false)
        // The notification extension, on the first note that opens:
        box.pairings[0].confirmed = true
        box.pairings[0].host = "studio"
        #expect(await service.waitUntilConfirmed(pairing, seconds: 2))
        #expect(service.pairings.first?.host == "studio")
    }

    @Test func nothingIsSentWhenNotificationsAreOffOrTheCodeIsForAnotherRelay() async {
        relayThatRegisters()
        defer { RelayStub.reset() }
        await #expect(throws: PushError.notAllowed) { try await service(Box(), allowed: false).pair(offer()) }
        let elsewhere = PushOffer(url: URL(string: "redde://connect?push=\(PushSeal.base64URL(Vector.offered))&relay=https%3A%2F%2Fother.example")!)!
        await #expect(throws: PushError.otherRelay("other.example")) { try await service(Box()).pair(elsewhere) }
        #expect(RelayStub.calls.isEmpty)
    }

    @Test func aPairingThatCannotFinishLeavesNothingAtTheRelay() async {
        RelayStub.reset()
        defer { RelayStub.reset() }
        RelayStub.reply = { call in
            if call.method == "POST" { return (201, #"{"id":"relay-id-0123456789"}"#) }
            return call.method == "PUT" ? (500, #"{"error":"storage"}"#) : (204, "")
        }
        let box = Box()
        await #expect(throws: PushError.relay("storage")) { try await service(box).pair(offer()) }
        #expect(RelayStub.calls.map(\.method) == ["POST", "PUT", "DELETE"])
        #expect(RelayStub.calls[2].path == "/v1/devices/relay-id-0123456789")
        #expect(box.pairings.isEmpty)
    }

    @Test func removingAPairingRemovesItAtTheRelayToo() async throws {
        relayThatRegisters()
        defer { RelayStub.reset() }
        let box = Box()
        let service = service(box)
        let pairing = try await service.pair(offer())
        RelayStub.calls = []
        await service.unpair(pairing)
        #expect(RelayStub.calls.map { "\($0.method) \($0.path)" } == ["DELETE /v1/devices/relay-id-0123456789"])
        #expect(RelayStub.calls[0].headers["Authorization"] == "Bearer \(pairing.sendKey)")
        #expect(box.pairings.isEmpty && service.pairings.isEmpty)
    }

    @Test func theRelayHearsOfANewAddressOnceAndForgetsAreFollowed() async throws {
        RelayStub.reset()
        defer { RelayStub.reset() }
        let box = Box()
        box.pairings = [Vector.pairing, PushPairing(id: "second", sendKey: "k2", key: Data(repeating: 2, count: 32), relay: "https://relay.test", confirmed: true)]
        let defaults = UserDefaults(suiteName: "push-test-\(UUID().uuidString)")!
        let service = service(box, defaults: defaults)
        RelayStub.reply = { call in call.path.hasSuffix("/second") ? (404, #"{"error":"no such device"}"#) : (204, "") }

        service.refreshAtLaunch()
        try await waitFor { RelayStub.calls.count == 2 }
        #expect(Set(RelayStub.calls.map { "\($0.method) \($0.path)" }) == ["PUT /v1/devices/dev-test-0001", "PUT /v1/devices/second"])
        #expect(RelayStub.calls.allSatisfy { $0.body["token"] == Self.tokenHex })
        try await waitFor { box.pairings.count == 1 }
        #expect(box.pairings.map(\.id) == ["dev-test-0001"], "a pairing the relay no longer has is dropped here")

        RelayStub.calls = []
        RelayStub.reply = nil
        service.received(token: Self.token)
        try await waitFor { RelayStub.calls.count == 1 }   // the set of pairings changed: said once more
        RelayStub.calls = []
        service.received(token: Self.token)
        try await Task.sleep(for: .milliseconds(300))
        #expect(RelayStub.calls.isEmpty, "the same address is not sent again and again")
        service.received(token: Data(repeating: 0xcd, count: 32))
        try await waitFor { RelayStub.calls.count == 1 }
        #expect(RelayStub.calls[0].body["token"] == String(repeating: "cd", count: 32))
    }

    @Test func aPhoneThatIsNotPairedNeverAsksForAPushAddress() async throws {
        RelayStub.reset()
        defer { RelayStub.reset() }
        var asked = 0
        let service = PushService(defaults: UserDefaults(suiteName: "push-test-\(UUID().uuidString)")!, session: RelayStub.session,
                                  vault: ({ [] }, { _ in true }), askForToken: { asked += 1 }, allowed: { true })
        service.refreshAtLaunch()
        #expect(asked == 0 && RelayStub.calls.isEmpty)
        #expect(service.followCommand(stored: "20261006_1", server: "A") == nil)
    }

    @Test func eachConversationIsAnnouncedToThePluginOnce() {
        let box = Box()
        var unconfirmed = Vector.pairing
        unconfirmed.id = "pending"
        box.pairings = [unconfirmed]
        let service = service(box)
        #expect(service.followCommand(stored: "20261006_1", server: "A") == nil, "nothing to follow with until a pairing is confirmed")
        var confirmed = Vector.pairing
        confirmed.confirmed = true
        box.pairings = [unconfirmed, confirmed]
        service.reload()
        #expect(service.followCommand(stored: "20261006_1", server: "A") == "watch 20261006_1 dev-test-0001")
        #expect(service.followCommand(stored: "20261006_1", server: "A") == nil)
        #expect(service.followCommand(stored: "20261006_2", server: "A") == "watch 20261006_2 dev-test-0001")
        #expect(service.followCommand(stored: "20261006_1", server: "B") != nil, "another server has its own conversations")
        #expect(service.followCommand(stored: "", server: "A") == nil)
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0 ..< 100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        Issue.record("timed out waiting")
    }
}

/// A sealed note that reaches the app unopened while it is in front (the notification extension
/// didn't run, as on a simulator, or couldn't read the key): the app opens it.
@MainActor
struct UnopenedNoteTests {
    @Test func theAppOpensItAndShowsABannerOfItsOwn() throws {
        let h = NotifierTests.Harness(appActive: true)
        var confirmed: [String] = []
        let options = h.notifier.presentUnopened(Vector.payload, vault: { [Vector.pairing] }, confirm: { pairing, host in confirmed.append("\(pairing.id) \(host ?? "")") })
        #expect(options == [], "the banner that says nothing isn't shown")
        let request = try #require(h.center.added.first)
        #expect(request.content.title == "Nightly build")
        #expect(request.content.body == "The build is green.\n\nAll 381 tests pass.")
        #expect(request.content.userInfo[PushNote.sessionKey] as? String == "20261006_101500_ab12cd")
        #expect(request.content.categoryIdentifier == PushNote.repliedCategory)
        #expect(confirmed == ["dev-test-0001 studio"], "a note that opens proves the pairing")
    }

    @Test func oneAboutTheConversationOnScreenShowsNothing() {
        let h = NotifierTests.Harness(appActive: true)
        let conversation = Conversation(settings: h.settings,
                                        store: ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "n-\(UUID().uuidString)")))
        conversation.replaceForDemo(serverSessionID: "20261006_101500_ab12cd", messages: [])
        h.notifier.attach(conversation: conversation)
        #expect(h.notifier.presentUnopened(Vector.payload, vault: { [Vector.pairing] }, confirm: { _, _ in }) == [])
        #expect(h.center.added.isEmpty)
    }

    @Test func oneItCannotOpenIsShownAsItCame() {
        let h = NotifierTests.Harness(appActive: true)
        #expect(h.notifier.presentUnopened(Vector.payload, vault: { [] }, confirm: { _, _ in }).contains(.banner))
        #expect(h.notifier.presentUnopened("garbage", vault: { [Vector.pairing] }, confirm: { _, _ in }).contains(.banner))
        #expect(h.center.added.isEmpty)
    }
}
