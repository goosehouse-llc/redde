import AVFoundation
import Foundation
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Echo

/// Each conversation's own draft.
@MainActor
struct DraftsTests {
    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "drafts-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func eachConversationKeepsItsOwnAndItSurvivesARelaunch() async {
        let directory = directory()
        let drafts = Drafts(directory: directory)
        #expect(drafts.text(for: "a") == "")
        drafts.set(text: "half a thought", for: "a")
        drafts.set(text: "another, elsewhere", for: "b")
        drafts.set(text: "for a chat not started yet", for: Drafts.newConversation)
        #expect(drafts.text(for: "a") == "half a thought" && drafts.text(for: "b") == "another, elsewhere")
        await drafts.flush()
        let relaunched = Drafts(directory: directory)
        #expect(relaunched.text(for: "a") == "half a thought")
        #expect(relaunched.text(for: Drafts.newConversation) == "for a chat not started yet")
        // Sent, or deleted: nothing is left behind.
        relaunched.set(text: "", for: "a")
        relaunched.forget("b")
        await relaunched.flush()
        let again = Drafts(directory: directory)
        #expect(again.text(for: "a") == "" && again.text(for: "b") == "")
        #expect(again.text(for: Drafts.newConversation) == "for a chat not started yet")
        #expect(again.waiting == [Drafts.newConversation], "which conversations have a draft is what the list marks")
        #expect(relaunched.isWaiting(nil) == false)
        again.removeAll()
        #expect(again.waiting.isEmpty)
        #expect(Drafts(directory: directory).text(for: Drafts.newConversation) == "", "Erase everything takes the drafts too")
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "drafts.json").path))
    }

    @Test func attachmentsWaitWithTheirDraftForThisRunOnly() async {
        let directory = directory()
        let drafts = Drafts(directory: directory)
        let note = Attachment(kind: .text, filename: "notes.txt", mimeType: "text/plain", data: Data("x".utf8))
        drafts.set(text: "see attached", for: "a")
        drafts.set(attachments: [note], for: "a")
        #expect(drafts.attachments(for: "a") == [note] && drafts.attachments(for: "b").isEmpty)
        await drafts.flush()
        #expect(Drafts(directory: directory).attachments(for: "a").isEmpty, "their bytes belong to no transcript yet, so nothing is written")
        drafts.set(attachments: [], for: "a")
        #expect(drafts.attachments(for: "a").isEmpty)
    }

    @Test func theOldestDraftsMakeWayPastTheLimit() {
        let drafts = Drafts(directory: directory())
        let start = Date(timeIntervalSince1970: 1_791_330_000)
        for i in 0 ..< Drafts.limit + 5 {
            drafts.set(text: "draft \(i)", for: "c\(i)", at: start.addingTimeInterval(Double(i)))
        }
        #expect(drafts.text(for: "c0") == "" && drafts.text(for: "c4") == "")
        #expect(drafts.text(for: "c5") == "draft 5")
        #expect(drafts.text(for: "c\(Drafts.limit + 4)") == "draft \(Drafts.limit + 4)")
        // One written to again is no longer the oldest.
        drafts.set(text: "draft 5, gone on with", for: "c5", at: start.addingTimeInterval(1000))
        drafts.set(text: "one more", for: "new-one", at: start.addingTimeInterval(1001))
        #expect(drafts.text(for: "c5") == "draft 5, gone on with" && drafts.text(for: "c6") == "")
    }

    @Test func aConversationWithNothingSaidSharesTheNewDraft() {
        let settings = Settings(defaults: UserDefaults(suiteName: "drafts-\(UUID().uuidString)")!)
        let store = ConversationStore(directory: directory())
        let conversation = Conversation(settings: settings, store: store)
        #expect(Drafts.key(for: conversation) == Drafts.newConversation)
        conversation.replaceForDemo(messages: [Message(role: .user, text: "hello")])
        #expect(Drafts.key(for: conversation) == conversation.id.uuidString)
    }
}

/// What the composer makes of keys, pastes and files.
struct ComposerLogicTests {
    @Test func aDraftThatGrewByOneLineBreakWasAReturn() {
        let isReturn = ComposerView.isReturn
        #expect(isReturn("hello", "hello\n"))
        #expect(isReturn("hello world", "hello\n world"), "Return in the middle of the text")
        #expect(isReturn("one\ntwo", "one\n\ntwo"))
        #expect(isReturn("", "\n"))
        #expect(!isReturn("hello", "hello!"))
        #expect(!isReturn("hello", "hello\n\n"), "a paste of two lines isn't a key")
        #expect(!isReturn("hello\n", "hello"), "nor is deleting one")
        #expect(!isReturn("hello", "jello\n"))
        #expect(isReturn("thumbs 👍🏽 up", "thumbs 👍🏽 up\n"))
    }

    @Test func aPictureOnTheClipboardIsAPictureUnlessItReadsAsText() {
        #expect(ComposerPaste.isPicture(types: [.png], readsAsText: false))
        #expect(ComposerPaste.isPicture(types: [.jpeg, .tiff], readsAsText: false))
        #expect(!ComposerPaste.isPicture(types: [.url, .png], readsAsText: true), "a link copied with its preview is the link")
        #expect(!ComposerPaste.isPicture(types: [.utf8PlainText], readsAsText: true))
        #expect(!ComposerPaste.isPicture(types: [.pdf], readsAsText: false))
    }

    @Test func aFileStagedOnTheDashboardIsNamedInTheMessage() {
        let prompt = HermesServeTransport.prompt
        #expect(prompt("Summarise this.", []) == "Summarise this.")
        #expect(prompt("Summarise this.", ["@file:attachments/notes.txt"]) == "Summarise this.\n\n@file:attachments/notes.txt")
        #expect(prompt("", ["@file:attachments/clip.mp4"]) == "@file:attachments/clip.mp4", "a file sent with no words")
        #expect(prompt("Compare", ["@file:attachments/a.csv", "@file:`attachments/b 2.csv`"]) == "Compare\n\n@file:attachments/a.csv @file:`attachments/b 2.csv`")
    }

    @Test func whatIsDictatedJoinsTheDraftAsWords() {
        #expect(Dictation.joined("", "hello there") == "hello there")
        #expect(Dictation.joined("Remind me", "to call the vet") == "Remind me to call the vet")
        #expect(Dictation.joined("Line one.\n", "Line two.") == "Line one.\nLine two.")
        #expect(Dictation.joined("as it was", "  ") == "as it was")
    }

    @Test func theChatTextSizeIsStepsAlongTheSystemsScale() {
        #expect(ChatTextSize.size(.large, steps: 0) == .large)
        #expect(ChatTextSize.size(.large, steps: 1) == .xLarge)
        #expect(ChatTextSize.size(.large, steps: -2) == .small)
        #expect(ChatTextSize.size(.xSmall, steps: -2) == .xSmall, "it stops at the ends")
        #expect(ChatTextSize.size(.accessibility5, steps: 2) == .accessibility5)
        #expect(ChatTextSize.size(.accessibility1, steps: 2) == .accessibility3, "and still follows a large system size")
        #expect(Settings.chatTextSizes.map(ChatTextSize.label) == ["Smallest", "Smaller", "Same as iPhone", "Larger", "Largest"])
    }

    @Test @MainActor func theSettingsForWritingAndReadingStayAsSet() {
        let suite = UserDefaults(suiteName: "composer-\(UUID().uuidString)")!
        let settings = Settings(defaults: suite)
        #expect(!settings.returnSends && settings.chatTextSize == 0, "Return starts a line and the text is the iPhone's size until changed")
        settings.returnSends = true
        settings.chatTextSize = 2
        let again = Settings(defaults: suite)
        #expect(again.returnSends && again.chatTextSize == 2)
        suite.set(9, forKey: "chatTextSize")
        #expect(Settings(defaults: suite).chatTextSize == 2, "a value off the scale is brought back onto it")
    }
}

/// The ring in the header.
@MainActor
struct ContextUsageTests {
    private func reply(used: Int?, max: Int?, window: Int? = nil) -> Message {
        var message = Message(role: .assistant, text: "ok")
        var metrics = TurnMetrics(sentAt: .now)
        metrics.completedAt = .now
        metrics.usage = TokenUsage(input: 10, output: 3, cached: nil, contextUsed: used, contextMax: max)
        metrics.contextWindow = window
        message.metrics = metrics
        return message
    }

    @Test func theConversationKnowsHowFullItsContextIsFromTheLatestReplyThatSays() {
        let settings = Settings(defaults: UserDefaults(suiteName: "context-\(UUID().uuidString)")!)
        let conversation = Conversation(settings: settings,
                                        store: ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "c-\(UUID().uuidString)")))
        #expect(conversation.contextUsage == nil)
        conversation.replaceForDemo(messages: [Message(role: .user, text: "hi"), reply(used: 54_210, max: 128_000)])
        #expect(conversation.contextUsage == ContextUsage(used: 54_210, window: 128_000))
        // A reply that doesn't say (the Hermes API gives only session totals) leaves the last known.
        conversation.mutateMessagesForDemo { $0 += [Message(role: .user, text: "more"), reply(used: nil, max: nil)] }
        #expect(conversation.contextUsage == ContextUsage(used: 54_210, window: 128_000))
        conversation.mutateMessagesForDemo { $0 += [Message(role: .user, text: "more"), reply(used: 60_000, max: nil, window: 131_072)] }
        #expect(conversation.contextUsage == ContextUsage(used: 60_000, window: 131_072), "the window detected on the phone when the server names none")
        conversation.reset()
        #expect(conversation.contextUsage == nil)
    }

    @Test func theRingSaysItInTokens() {
        #expect(ContextRing.sentence(used: 54_210, window: 128_000) == "\(54_210.formatted()) of \(128_000.formatted()) tokens (\(0.42.formatted(.percent.precision(.fractionLength(0)))))")
        #expect(ContextRing.sentence(used: 200_000, window: 128_000).hasSuffix("(\(1.0.formatted(.percent.precision(.fractionLength(0)))))"), "never more than full")
    }
}

/// Conversations the server can't hand over, read from what this iPhone kept; and which of the
/// server's conversations have something written and not sent.
struct SavedCopiesTests {
    private func summary(_ title: String, session: String?, transport: Echo.Transport, server: UUID?) -> ConversationSummary {
        ConversationSummary(ConversationRecord(id: UUID(), title: title, createdAt: .now, updatedAt: .now, transport: transport,
                                               serverSessionID: session, messages: [Message(role: .user, text: title)], serverID: server))
    }

    @Test func onlyThisServersConversationsAreOffered() {
        let home = UUID(), work = UUID()
        let all = [summary("Vet and calendar", session: "s1", transport: .hermesServe, server: home),
                   summary("Release notes", session: "s2", transport: .hermesSessions, server: home),
                   summary("At work", session: "s3", transport: .hermesServe, server: work),
                   summary("Local model chat", session: nil, transport: .chatCompletions, server: nil),
                   summary("Never reached the server", session: nil, transport: .hermesServe, server: home),
                   summary("From before servers had names", session: "s0", transport: .hermesSessions, server: nil)]
        let copies = ConversationsList.savedCopies(in: all, server: home, matching: "")
        #expect(copies.map(\.title) == ["Vet and calendar", "Release notes", "From before servers had names"])
        #expect(ConversationsList.savedCopies(in: all, server: work, matching: "").map(\.title) == ["At work", "From before servers had names"])
        #expect(ConversationsList.savedCopies(in: all, server: home, matching: " vet ").map(\.title) == ["Vet and calendar"])
    }

    @Test func aDraftMarksItsConversationInTheServersList() {
        let home = UUID()
        let all = [summary("Vet and calendar", session: "s1", transport: .hermesServe, server: home),
                   summary("Release notes", session: "s2", transport: .hermesSessions, server: home),
                   summary("Local model chat", session: nil, transport: .chatCompletions, server: nil)]
        #expect(ConversationsList.drafted([], in: all).isEmpty)
        // Drafts are kept by a conversation's id on this iPhone; the server's list has its own.
        #expect(ConversationsList.drafted([all[1].id.uuidString, all[2].id.uuidString, Drafts.newConversation], in: all) == ["s2"])
    }
}

/// The composer's microphone.
@MainActor
struct DictationTests {
    private func waitFor(_ condition: @MainActor () -> Bool) async {
        for _ in 0 ..< 200 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    private func make(allowed: Bool = true) -> (Dictation, VoiceSessionTests.FakeRecognizer, VoiceSessionTests.FakeAudio) {
        let recognizer = VoiceSessionTests.FakeRecognizer(), audio = VoiceSessionTests.FakeAudio()
        return (Dictation(recognizer: { recognizer }, audio: audio, requestPermissions: { allowed }), recognizer, audio)
    }

    @Test func whatIsSaidIsHeardAndTheMicrophoneIsGivenBack() async {
        let (dictation, recognizer, audio) = make()
        dictation.start()
        #expect(dictation.phase == .starting && dictation.isActive)
        await waitFor { dictation.phase == .listening }
        #expect(recognizer.starts == 1 && audio.activations == 1)
        recognizer.deliver("remind me to call the vet")       // the speaker went quiet
        await waitFor { dictation.phase == .idle }
        #expect(dictation.heard == "remind me to call the vet")
        #expect(audio.deactivations == 1 && dictation.problem == nil)
    }

    @Test func aSecondTapEndsItWithWhatWasSaidSoFar() async {
        let (dictation, recognizer, audio) = make()
        dictation.toggle()
        await waitFor { dictation.phase == .listening }
        recognizer.pendingUtterance = "half a sentence"
        dictation.toggle()
        await waitFor { dictation.phase == .idle }
        #expect(dictation.heard == "half a sentence" && audio.deactivations == 1)
        // And it can be used again, from nothing.
        dictation.start()
        #expect(dictation.heard == "")
        await waitFor { dictation.phase == .listening }
        #expect(recognizer.starts == 2)
        dictation.cancel()
        #expect(dictation.phase == .idle && recognizer.cancels == 1)
    }

    @Test func withoutTheMicrophoneItSaysWhyAndStops() async {
        let (refused, recognizer, _) = make(allowed: false)
        refused.start()
        await waitFor { refused.phase == .idle }
        #expect(refused.problem == SpeechRecognizer.Failure.permissionDenied.localizedDescription && recognizer.starts == 0)

        let (dictation, broken, audio) = make()
        broken.startError = SpeechRecognizer.Failure.localeUnsupported
        dictation.start()
        await waitFor { dictation.phase == .idle }
        #expect(dictation.problem == SpeechRecognizer.Failure.localeUnsupported.localizedDescription)
        #expect(audio.deactivations == 1, "the audio session isn't left open for a listen that never happened")
    }

    @Test func aTapBeforeTheMicrophoneOpensCallsItOff() async {
        let (dictation, recognizer, _) = make()
        dictation.start()
        dictation.stop()
        #expect(dictation.phase == .idle)
        try? await Task.sleep(for: .milliseconds(60))
        #expect(dictation.phase == .idle && dictation.heard == "", "the start that was under way doesn't open the mic after all")
        _ = recognizer
    }
}

/// A video small enough to send.
struct VideoAttachmentTests {
    /// A clip of noise, which no encoder makes small: `seconds` at 640 by 480.
    private static func clip(seconds: Double) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "clip-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let (width, height) = (640, 480)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        var generator = SystemRandomNumberGenerator()
        for frame in 0 ..< Int(seconds * 30) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let count = CVPixelBufferGetBytesPerRow(buffer) * height
                let bytes = base.bindMemory(to: UInt64.self, capacity: count / 8)
                for i in 0 ..< count / 8 { bytes[i] = generator.next() }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }
        return url
    }

    @Test func aVideoThatFitsGoesAsItIsAndABiggerOneIsMadeSmaller() async throws {
        let url = try await Self.clip(seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let size = try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(size > 400_000, "the clip is big enough to be worth shrinking (\(size) bytes)")
        #expect(Attachment.isVideo(url) && !Attachment.isVideo(URL(filePath: "/tmp/notes.txt")))

        let whole = try await Attachment.video(fileURL: url, filename: "holiday.mov")
        #expect(whole.data.count == size && whole.mimeType == "video/quicktime" && whole.filename == "holiday.mov")
        #expect(whole.isVideo && whole.kind == .other, "a file like any other to the server")

        let cap = size / 3
        let smaller = try await Attachment.video(fileURL: url, filename: "holiday.mov", maxBytes: cap)
        #expect(smaller.data.count <= cap && smaller.data.count > 1000, "\(smaller.data.count) of \(size) bytes, under \(cap)")
        #expect(smaller.mimeType == "video/mp4" && smaller.filename == "holiday.mp4")
        // What came out is a video a player can open.
        let out = FileManager.default.temporaryDirectory.appending(path: "check-\(UUID().uuidString).mp4")
        try smaller.data.write(to: out)
        defer { try? FileManager.default.removeItem(at: out) }
        let duration = try await AVURLAsset(url: out).load(.duration).seconds
        #expect(abs(duration - 2) < 0.3, "all of it, smaller: \(duration) s")

        await #expect(throws: AttachmentError.self) {
            _ = try await Attachment.video(fileURL: url, filename: "holiday.mov", maxBytes: 2000)
        }
    }

    @Test func onAConnectionThatTakesNoFilesAVideoIsRefusedByName() throws {
        let video = Attachment(kind: .other, filename: "clip.mp4", mimeType: "video/mp4", data: Data([0, 1, 2]))
        #expect(throws: AttachmentError.self) { try HermesSessionsTransport.makeInput(text: "look", attachments: [video]) }
        do {
            _ = try HermesSessionsTransport.makeInput(text: "look", attachments: [video])
        } catch {
            #expect(error.localizedDescription.hasPrefix("Video attachments aren't supported on"))
        }
    }
}
