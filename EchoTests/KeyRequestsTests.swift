import CryptoKit
import Foundation
import Testing
import UserNotifications
@testable import Echo

/// Keys a bot asks for (2026-10-29): the key sealed exactly as Redde's plugin opens it, handed over
/// only as that box, the request's card from the call, the notification, and the refusals.
@MainActor
struct KeyRequestsTests {
    /// The plugin's `keys.opened` derivation, run in Python with these keys and this nonce, gave this box
    /// (companion/hermes-plugin/redde-push/keys.py): the same bytes from here mean the plugin opens them.
    private let serverPublic = "B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9_AsrhtHHw"
    private let ephemeralPrivate = "ISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0-P0A"
    private let ephemeralPublic = "WGmv9FBUlzLLqu1eXfmzCm2jHLDldCutWtShp2jxpns"
    private let pythonBox = "ZGVmZ2hpamtsbW5vIDcOV7YuBkClnj8aFN93EjB8WWpVLds3kw4gCnF_2g"

    private func request(publicKey: Data? = nil) -> KeyRequest {
        KeyRequest(id: "abcdef0123456789", name: "JELLYFIN_API_KEY", profile: "jellyfin", why: "So the Jellyfin bot can search",
                   asker: "claude", askerName: "Coder", replace: false,
                   publicKey: publicKey ?? PushSeal.data(base64URL: serverPublic)!, until: .now.addingTimeInterval(3600))
    }

    @Test func aKeyIsSealedByteForByteAsThePluginOpensIt() throws {
        let ephemeral = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: PushSeal.data(base64URL: ephemeralPrivate)!)
        let nonce = try AES.GCM.Nonce(data: Data(100 ..< 112))
        let sealed = try KeySeal.seal("jf-test-key-123", to: request(), ephemeral: ephemeral, nonce: nonce)
        #expect(sealed.publicKey == ephemeralPublic)
        #expect(sealed.box == pythonBox)
    }

    @Test func aBoxOpensForItsOwnRequestOnly() throws {
        let server = Curve25519.KeyAgreement.PrivateKey()
        let mine = request(publicKey: server.publicKey.rawRepresentation)
        let sealed = try KeySeal.seal("secret-value-0001", to: mine)
        func open(_ asked: KeyRequest) throws -> String {
            let theirs = PushSeal.data(base64URL: sealed.publicKey)!
            let shared = try server.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: theirs))
            let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: theirs + asked.publicKey, sharedInfo: KeySeal.info, outputByteCount: 32)
            let box = try AES.GCM.SealedBox(combined: PushSeal.data(base64URL: sealed.box)!)
            return String(decoding: try AES.GCM.open(box, using: key, authenticating: KeySeal.associatedData(asked)), as: UTF8.self)
        }
        #expect(try open(mine) == "secret-value-0001")
        let elsewhere = KeyRequest(id: mine.id, name: mine.name, profile: "default", why: "", asker: "", askerName: "",
                                   replace: false, publicKey: mine.publicKey, until: mine.until)
        #expect(throws: (any Error).self) { try open(elsewhere) }
    }

    @Test func onlyTheBoxIsHandedOverAndTheRequestIsSettled() async throws {
        let requests = KeyRequests()
        var said: [String] = []
        requests.reachable = { true }
        requests.plugin = { arguments in
            said.append(arguments)
            return arguments == "keys list" ? "redde-push keys []" : "redde-push keys set JELLYFIN_API_KEY"
        }
        let outcome = try await requests.answer(request(), with: "  jf-test-key-123\n")
        #expect(outcome == .set("JELLYFIN_API_KEY"))
        #expect(said.count == 1)
        #expect(said[0].hasPrefix("keys set abcdef0123456789 "))
        #expect(!said[0].contains("jf-test-key-123"), "the key never goes in clear")
        #expect(said[0].split(separator: " ").count == 5)
    }

    @Test func withoutTheDashboardNothingIsSent() async {
        let requests = KeyRequests()
        var asked = false
        requests.reachable = { false }
        requests.plugin = { _ in asked = true; return "" }
        await #expect(throws: KeyRequestError.noDashboard) { try await requests.answer(request(), with: "value-123456") }
        await #expect(throws: KeyRequestError.notOneLine) { try await requests.answer(request(), with: "one\ntwo") }
        await #expect(throws: KeyRequestError.empty) { try await requests.answer(request(), with: "   ") }
        #expect(!asked)
        await requests.reload()
        #expect(requests.canAnswer == false)
    }

    @Test func answeredElsewhereOrRefusedIsSaidSo() async {
        let requests = KeyRequests()
        requests.reachable = { true }
        requests.plugin = { _ in "redde-push keys gone" }
        await #expect(throws: KeyRequestError.gone) { try await requests.answer(request(), with: "value-123456") }
        requests.plugin = { _ in "redde-push keys refused seal" }
        await #expect(throws: KeyRequestError.refused("seal")) { try await requests.answer(request(), with: "value-123456") }
    }

    @Test func thePluginsListBecomesRequests() async {
        let requests = KeyRequests()
        requests.reachable = { true }
        requests.plugin = { _ in
            #"redde-push keys [{"i":"abcdef0123456789","t":"JELLYFIN_API_KEY","g":"jellyfin","b":"So the Jellyfin bot can search","p":"claude","d":"Coder","r":true,"k":"B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9_AsrhtHHw","u":1900000000},{"i":"bad","t":"NO_KEY"}]"#
        }
        await requests.reload()
        #expect(requests.pending.map(\.name) == ["JELLYFIN_API_KEY"], "one without a public key is left out")
        #expect(requests.pending.first?.replace == true)
        #expect(requests.pending.first?.who == "Coder")
        #expect(requests.pending.first?.destination.contains("jellyfin") == true)
    }

    @Test func theCallsAnswerIsTheChatsCardAndHoldsNoKey() {
        var step = ToolActivity(name: ReplyCards.keyTool, preview: nil, status: .completed)
        step.output = #"{"status":"pending","id":"abcdef0123456789","name":"JELLYFIN_API_KEY","profile":"jellyfin","why":"So it can search","phones":1}"#
        #expect(ReplyCards.cards(from: step) == [.key(.init(id: "abcdef0123456789", name: "JELLYFIN_API_KEY", profile: "jellyfin", why: "So it can search"))])
        step.output = #"{"error":"There is no profile called x here."}"#
        #expect(ReplyCards.cards(from: step) == nil, "a request the plugin turned down has no card")
        #expect(ReplyCards.carriesCards(ReplyCards.keyTool))
    }

    @Test func theNotificationNamesTheKeyAndOpensItsCard() throws {
        let json = #"{"v":1,"k":"key","i":"abcdef0123456789","t":"JELLYFIN_API_KEY","g":"jellyfin","p":"claude","d":"Coder","b":"So the Jellyfin bot can search"}"#
        let note = try JSONDecoder().decode(PushNote.self, from: Data(json.utf8))
        let content = UNMutableNotificationContent()
        #expect(note.fill(content))
        #expect(content.title.contains("Coder"))
        #expect(content.subtitle == "JELLYFIN_API_KEY")
        #expect(content.userInfo[PushNote.keyRequestKey] as? String == "abcdef0123456789")
    }
}
