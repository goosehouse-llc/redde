import Foundation
import Testing
@testable import Echo

/// Sound a reply delivers (the agent's speech tool writes a file and names it with `MEDIA:`):
/// fetched like a picture, played where it stands, and fetched again when the chat is reopened.
/// Reported from the field as "it renders the path instead of playable audio".
@MainActor
struct ReplyAudioTests {
    /// A tone as a WAV file: sound this phone can certainly play, made without a fixture.
    static func wav(seconds: Double, rate: Int = 8000) -> Data {
        let count = Int(seconds * Double(rate))
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + count * 2)); data.append(contentsOf: Array("WAVEfmt ".utf8))
        put(UInt32(16)); put(UInt16(1)); put(UInt16(1)); put(UInt32(rate)); put(UInt32(rate * 2)); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(UInt32(count * 2))
        for i in 0 ..< count { put(Int16(sin(Double(i) / Double(rate) * 2 * .pi * 440) * 8000)) }
        return data
    }

    private func dataURL(_ mime: String, _ data: Data = ReplyAudioTests.wav(seconds: 0.2)) -> String {
        "data:\(mime);base64,\(data.base64EncodedString())"
    }

    // MARK: Finding and naming it

    @Test func soundFilesAReplyPointsToAreFetched() {
        let text = """
        Here is the summary, read aloud.
        [[audio_as_voice]]
        MEDIA:/home/hermes/.hermes/audio_cache/tts_20261012_101500_123456.ogg
        And the recording: MEDIA:/tmp/call.mp3 MEDIA:/tmp/memo.m4a MEDIA:/tmp/take.WAV
        Not sound, not fetched: MEDIA:/tmp/tool.bin
        """
        #expect(ServeMedia.candidates(in: text).map(\.filename) == ["tts_20261012_101500_123456.ogg", "call.mp3", "memo.m4a", "take.WAV"])
    }

    @Test func aFetchedSoundIsSoundWhateverTheServerCallsIt() throws {
        let mp3 = try #require(ServeMedia.attachment(dataURL: dataURL("audio/mpeg"), name: "tts_1.mp3"))
        #expect(mp3.isAudio && mp3.kind == .other && mp3.filename == "tts_1.mp3")
        // A server that only knows it as "a file".
        let opus = try #require(ServeMedia.attachment(dataURL: dataURL("application/octet-stream"), name: "voice.opus"))
        #expect(opus.isAudio && opus.mimeType == "audio/ogg")
        // A name without an ending gets one that says what it is.
        #expect(ServeMedia.attachment(dataURL: dataURL("audio/mpeg"), name: "reply")?.filename == "reply.mp3")
        // And what isn't sound isn't.
        #expect(ServeMedia.attachment(dataURL: dataURL("application/pdf", Data("%PDF-1.4".utf8)), name: "report.pdf")?.isAudio == false)
        #expect(ServeMedia.attachment(dataURL: dataURL("image/png", Data([1, 2, 3])), name: "cam")?.isAudio == false)
    }

    @Test func aSoundFileIsNeverReadOutAsAPath() {
        let reply = "Here you go.\n[[audio_as_voice]]\nMEDIA:/home/hermes/.hermes/audio_cache/tts_1.ogg"
        #expect(PlainText.spoken(reply) == "Here you go.\naudio attached")
        #expect(PlainText.display(reply) == "Here you go.")
        #expect(PlainText.spoken("MEDIA:/tmp/report.pdf") == "file attached")
    }

    // MARK: In a conversation

    @MainActor final class Server {
        var files: [String: String] = [:]
        private(set) var asked: [String] = []
        func fetch(_ path: String) -> String? { asked.append(path); return files[path] }
    }

    private func conversation(_ events: [TurnEvent] = [], server: Server) -> Conversation {
        let settings = Settings(defaults: UserDefaults(suiteName: "audio-\(UUID().uuidString)")!)
        settings.transport = .hermesServe
        let store = ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "audio-\(UUID().uuidString)"))
        let conversation = Conversation(settings: settings, store: store, transportOverride: ConversationLifecycleTests.ScriptedTransport(events))
        conversation.fetchServerFile = { server.fetch($0) }
        return conversation
    }

    private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            if Date() > deadline { Issue.record("timed out waiting for \(what)"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func aReplysSoundArrivesAsAnAttachmentAndItsPathGoes() async throws {
        let server = Server()
        let path = "/home/hermes/.hermes/audio_cache/tts_1.ogg"
        server.files[path] = dataURL("audio/ogg")
        let c = conversation([.textDelta("Here is the summary, read aloud.\n[[audio_as_voice]]\nMEDIA:\(path)"), .done], server: server)
        for await _ in c.send("Read me the summary") {}
        try await waitUntil("the reply to settle") { !c.isStreaming }
        let reply = try #require(c.messages.last)
        #expect(reply.text == "Here is the summary, read aloud.", "no path, and no request for a voice bubble")
        #expect(reply.attachments.map(\.filename) == ["tts_1.ogg"])
        #expect(reply.attachments.first?.isAudio == true)
        #expect(server.asked == [path])
    }

    @Test func aSoundThatCannotBeFetchedStaysAsItWasWritten() async throws {
        let server = Server()
        let c = conversation([.textDelta("Here you go: MEDIA:/tmp/gone.mp3"), .done], server: server)
        for await _ in c.send("Read me the summary") {}
        try await waitUntil("the reply to settle") { !c.isStreaming }
        #expect(c.messages.last?.text == "Here you go: MEDIA:/tmp/gone.mp3" && c.messages.last?.attachments.isEmpty == true)
    }

    /// A chat opened from the server is text again: pictures and sound are bare paths. The
    /// newest are fetched once more.
    @Test func aChatOpenedAgainGetsItsNewestFilesBack() async throws {
        let server = Server()
        var messages: [Message] = []
        for n in 1 ... 10 {
            messages.append(Message(role: .user, text: "Question \(n)"))
            messages.append(Message(role: .assistant, text: "Answer \(n).\nMEDIA:/tmp/voice\(n).mp3"))
            server.files["/tmp/voice\(n).mp3"] = dataURL("audio/mpeg")
        }
        messages.append(Message(role: .assistant, text: "And a picture: MEDIA:/tmp/cam.png"))
        server.files["/tmp/cam.png"] = dataURL("image/png", Data([1, 2, 3]))
        let c = conversation(server: server)
        c.load(ConversationRecord(id: UUID(), title: "Daily briefing", createdAt: .now, updatedAt: .now, transport: .hermesServe,
                                  serverSessionID: "s1", messages: messages))
        c.resolveReopenedMedia()
        try await waitUntil("the files") { server.asked.count == Conversation.reopenedMediaReach }
        try await waitUntil("the last of them to land") { c.messages.filter { !$0.attachments.isEmpty }.count == Conversation.reopenedMediaReach }
        // Newest first, the picture among them; the oldest stay as they are written.
        #expect(server.asked.first == "/tmp/cam.png" && server.asked.dropFirst().first == "/tmp/voice10.mp3")
        #expect(c.messages.last?.text == "And a picture:" && c.messages.last?.attachments.first?.kind == .image)
        let tenth = try #require(c.messages.first { $0.text.hasPrefix("Answer 10") })
        #expect(tenth.text == "Answer 10." && tenth.attachments.first?.isAudio == true)
        #expect(c.messages.first { $0.text.hasPrefix("Answer 1.") }?.text == "Answer 1.\nMEDIA:/tmp/voice1.mp3")
        #expect(!server.asked.contains("/tmp/voice1.mp3") && !server.asked.contains("/tmp/voice3.mp3"))
    }

    // MARK: Playing it

    @Test func aSoundThePhoneCanPlayHasALength() throws {
        let tone = try #require(ServeMedia.attachment(dataURL: dataURL("audio/wav", Self.wav(seconds: 1.5)), name: "tone.wav"))
        let length = try #require(AttachmentAudio.duration(of: tone))
        #expect(abs(length - 1.5) < 0.05)
        // Bytes that aren't sound, whatever they are called: offered as a file, not a player.
        let broken = try #require(ServeMedia.attachment(dataURL: dataURL("audio/mpeg", Data("not audio at all".utf8)), name: "broken.mp3"))
        #expect(AttachmentAudio.duration(of: broken) == nil)
        #expect(AudioBubble.clock(7.9) == "0:07" && AudioBubble.clock(760) == "12:40" && AudioBubble.clock(0) == "0:00")
    }

    @Test func oneSoundPlaysAtATime() throws {
        let audio = AttachmentAudio.shared
        defer { audio.stop() }
        let first = try #require(ServeMedia.attachment(dataURL: dataURL("audio/wav", Self.wav(seconds: 2)), name: "first.wav"))
        let second = try #require(ServeMedia.attachment(dataURL: dataURL("audio/wav", Self.wav(seconds: 2)), name: "second.wav"))
        audio.toggle(first)
        #expect(audio.current == first.id)
        audio.seek(first, to: 1.2)
        #expect(abs(audio.position(of: first.id) - 1.2) < 0.3)
        #expect(audio.position(of: second.id) == 0, "where the other one stands is its own business")
        // The other one: the first is over.
        audio.toggle(second)
        #expect(audio.current == second.id)
        audio.stop()
        #expect(audio.current == nil && !audio.isPlaying)
        // Moved along before it was ever played: it is the current one, standing there.
        audio.seek(first, to: 0.5)
        #expect(audio.current == first.id && !audio.isPlaying)
    }
}
