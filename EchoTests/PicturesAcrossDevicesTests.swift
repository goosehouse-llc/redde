import Foundation
import Testing
@testable import Echo

/// GitHub issue 18: a picture sent from one device showed on no other. Hermes keeps no picture's
/// bytes in a session; it keeps an `@image:<path on the server>` line where its Dashboard saved
/// the picture, else only "[screenshot]". Redde shows the pictures such lines name, and on the
/// Hermes API names its own pictures that way through the Dashboard's login.
@MainActor
struct PicturesAcrossDevicesTests {
    // MARK: Reading what Hermes kept

    @Test func aMessageShowsThePicturesItNamesInsteadOfTheirLines() {
        // As Hermes keeps a picture attached through its Dashboard (Hermes Desktop's, Redde's).
        let kept = "What's this bird?\n@image:/home/redde/.hermes/images/upload_20261024_101500_1.jpg\n[screenshot]"
        let named = ServeMedia.named(in: kept)
        #expect(named.text == "What's this bird?")
        #expect(named.files.map(\.path) == ["/home/redde/.hermes/images/upload_20261024_101500_1.jpg"])
        #expect(named.files.first?.isPicture == true && named.files.first?.filename == "upload_20261024_101500_1.jpg")
        // A picture alone leaves nothing to say.
        #expect(ServeMedia.named(in: "@image:/srv/a.png\n[screenshot]").text.isEmpty)
    }

    @Test func eachWayOfWritingThePathIsRead() {
        let windows = #"@image:C:\Users\ana\AppData\Roaming\Hermes\composer-images\image_3f2a1b.png"#
        let file = ServeMedia.named(in: "Look\n" + windows + "\n[screenshot]").files.first
        #expect(file?.path == #"C:\Users\ana\AppData\Roaming\Hermes\composer-images\image_3f2a1b.png"#)
        #expect(file?.filename == "image_3f2a1b.png" && file?.isRelative == false, "a Windows server's path is absolute")
        #expect(ServeMedia.named(in: "@image:`/home/ana/My Pictures/cat (1).jpg`").files.first?.path == "/home/ana/My Pictures/cat (1).jpg")
        #expect(ServeMedia.named(in: #"@image:"/tmp/a b.png""#).files.first?.path == "/tmp/a b.png")
        // Older rows.
        let older = ServeMedia.named(in: "Caption\n\n[Image attached at: /tmp/shot.png]\n[screenshot]")
        #expect(older.text == "Caption" && older.files.map(\.path) == ["/tmp/shot.png"])
    }

    @Test func onlyALineOfItsOwnNamesAPicture() {
        #expect(ServeMedia.named(in: "Use @image:/tmp/a.png in a sentence").files.isEmpty)
        // With no picture named, the placeholder is all there is of it, and stays.
        #expect(ServeMedia.named(in: "Here\n[screenshot]").text == "Here\n[screenshot]")
    }

    @Test func theChatListPreviewStopsAtThePicture() {
        #expect(ServeMedia.preview("What's this bird? @image:/home/redde/.hermes/ima") == "What's this bird?", "cut short by the server")
        #expect(ServeMedia.preview("What's this bird?\n@image:/srv/a.jpg\n[screenshot]") == "What's this bird?")
        #expect(ServeMedia.preview("@image:/srv/a.jpg") == "Picture" && ServeMedia.preview("[screenshot]") == "Picture")
        #expect(ServeMedia.preview("Plain words") == "Plain words")
    }

    @Test func aPictureIsNamedAsHermesDesktopReadsItBack() {
        #expect(ServeMedia.pictureRef("/home/redde/.hermes/images/dashboard_1_ab12cd34_photo.jpg") == "@image:/home/redde/.hermes/images/dashboard_1_ab12cd34_photo.jpg")
        #expect(ServeMedia.pictureRef("/home/ana/My Pictures/a.jpg") == "@image:`/home/ana/My Pictures/a.jpg`")
        #expect(ServeMedia.pictureRef("/tmp/odd`name.jpg") == "@image:\"/tmp/odd`name.jpg\"")
        // And reads back as the path.
        for path in ["/srv/plain.jpg", "/home/ana/My Pictures/a.jpg", "/tmp/odd`name.jpg"] {
            #expect(ServeMedia.named(in: "x\n" + ServeMedia.pictureRef(path)).files.first?.path == path)
        }
    }

    @Test func aChatOpenedAgainFetchesThePicturesItsMessagesName() async throws {
        let settings = Settings(defaults: UserDefaults(suiteName: "pictures-\(UUID().uuidString)")!)
        settings.transport = .hermesServe
        let store = ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "pictures-\(UUID().uuidString)"))
        let c = Conversation(settings: settings, store: store, transportOverride: ConversationLifecycleTests.ScriptedTransport([]))
        var asked: [String] = []
        let jpeg = "data:image/jpeg;base64," + Data([0xFF, 0xD8, 0xFF, 0xE0]).base64EncodedString()
        c.fetchServerFile = { path, _ in asked.append(path); return path.hasSuffix("gone.jpg") ? nil : jpeg }
        c.load(ConversationRecord(id: UUID(), title: "Birds", createdAt: .now, updatedAt: .now, transport: .hermesServe, serverSessionID: "s1", messages: [
            Message(role: .user, text: "From the desktop\n@image:/srv/images/upload_1.jpg\n[screenshot]"),
            Message(role: .assistant, text: "A robin."),
            Message(role: .user, text: "And this one\n@image:/srv/images/gone.jpg\n[screenshot]"),
        ]))
        c.resolveReopenedMedia()
        let deadline = Date().addingTimeInterval(3)
        while asked.count < 2 || c.messages[0].attachments.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(Set(asked) == ["/srv/images/upload_1.jpg", "/srv/images/gone.jpg"])
        #expect(c.messages[0].text == "From the desktop" && c.messages[0].attachments.first?.kind == .image)
        // One the server no longer has stays named: its row offers it, and says why on a tap.
        #expect(c.messages[2].text.contains("@image:/srv/images/gone.jpg") && c.messages[2].attachments.isEmpty)
    }

    // MARK: Naming Redde's own on the Hermes API

    @Test func onTheHermesAPIEachPictureIsPutOnTheServerAndNamed() async {
        let photo = Attachment(kind: .image, filename: "IMG_0412.jpg", mimeType: "image/jpeg", data: Data([0xFF, 0xD8]))
        let note = Attachment(kind: .text, filename: "notes.txt", mimeType: "text/plain", data: Data("hi".utf8))
        var request = TurnRequest(userText: "What's this bird?", history: [], sessionID: "s1", model: nil, provider: nil, reasoningEffort: nil, instructions: nil)
        request.attachments = [photo, note, photo]
        var uploaded = 0
        let named = await Conversation.namingPictures(request) { picture in
            uploaded += 1
            if uploaded == 2 { throw TransportError.http(status: 413, body: "too big") }
            return "/home/redde/.hermes/images/dashboard_\(uploaded)_\(picture.filename)"
        }
        #expect(uploaded == 2, "pictures only")
        #expect(named.userText == "What's this bird?\n@image:/home/redde/.hermes/images/dashboard_1_IMG_0412.jpg",
                "one that couldn't be put there goes unnamed")
        #expect(named.attachments.count == 3, "the pictures still go with the run, for the model")
        // Hermes keeps the message as text and "[screenshot]": the line it needs to show the picture is in it.
        #expect(ServeMedia.named(in: named.userText + "\n[screenshot]\n[screenshot]").files.count == 1)
    }

    // MARK: Names

    @Test func aPictureIsNamedForTheJPEGItBecame() {
        #expect(Attachment.jpegName("IMG_0412.HEIC") == "IMG_0412.jpg", "Hermes turns a .heic down")
        #expect(Attachment.jpegName("photo.jpg") == "photo.jpg" && Attachment.jpegName("scan.JPEG") == "scan.JPEG")
        #expect(Attachment.jpegName("screenshot.png") == "screenshot.jpg" && Attachment.jpegName("scan") == "scan.jpg")
    }
}
