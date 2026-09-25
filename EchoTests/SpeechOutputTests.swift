import AVFoundation
import Foundation
import Testing
@testable import Echo

struct SpeechOutputTests {
    @Test func stripsMarkdownForSpeech() {
        let input = "## Title\n**Bold** and *italic* with `code` and [a link](https://x.y).\n- item one\n```swift\nlet x = 1\n```"
        let spoken = PlainText.spoken(input)
        #expect(spoken == "Title\nBold and italic with code and a link.\nitem one\ncode block omitted")
    }

    @Test func stripsMarkdownForDisplay() {
        let input = "## Title\n- item\n![chart](data:x)\n$$x^2$$\n| a | b |\n|---|---|\n\n\n\nDone ~~soon~~ [now](https://x.y)"
        #expect(PlainText.display(input) == "Title\n• item\n\n[formula]\n\nDone soon now")
    }

    /// A reply that sends a picture references it by server path; never read that aloud.
    @Test func mediaTagsAreSpokenAsAttachments() {
        #expect(PlainText.spoken("Here you go: MEDIA:/tmp/snap_front_door.JPG") == "Here you go: picture attached")
        #expect(PlainText.spoken("Saved. MEDIA:/tmp/report.pdf for you.") == "Saved. file attached for you.")
        #expect(PlainText.spoken("I saved it. [IMAGE: /tmp/snap2.jpeg]") == "I saved it. picture attached")
        #expect(PlainText.display("Look: MEDIA:/tmp/snap.jpg [IMAGE: /tmp/b.png]") == "Look:")
    }

    @Test func chunksSentencesAsTheyComplete() {
        var chunker = SentenceChunker()
        #expect(chunker.append("Paris is the capital").isEmpty)
        #expect(chunker.append(" of France. It has") == ["Paris is the capital of France."])
        #expect(chunker.append(" 2.1 million people!\nNext line") == ["It has 2.1 million people!"])
        #expect(chunker.flush() == "Next line")
        #expect(chunker.flush() == nil)
    }

    @Test func breaksLongClausesAtCommas() {
        var chunker = SentenceChunker()
        chunker.longClauseThreshold = 20
        let out = chunker.append("one, two, three, four, five and six")
        #expect(out == ["one, two, three, four,"])
        #expect(chunker.flush() == "five and six")
    }

    @Test func synthesizerStartsSpeakingQuickly() async throws {
        guard !AVSpeechSynthesisVoice.speechVoices().isEmpty else { print("SKIP: no voices"); return }
        let output = SpeechOutput()
        let started = Date()
        let firstSpeech: TimeInterval = await withCheckedContinuation { cont in
            var resumed = false
            output.onFirstSpeech = {
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: Date().timeIntervalSince(started))
            }
            output.beginReply()
            output.append("Hello from Echo. ")
            Task {
                try? await Task.sleep(for: .seconds(8))
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: -1)
            }
        }
        output.stop()
        print(String(format: "TTS startup %.2fs", firstSpeech))
        #expect(firstSpeech >= 0, "synthesizer never started speaking")
    }
}
