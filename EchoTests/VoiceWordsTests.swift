import Foundation
import Testing
@testable import Echo

/// Voice in the language Redde listens in: its words heard beside the English ones, and what
/// Redde says said in it (`VoiceWords`, `VoiceWords.json`).
@MainActor
struct VoiceWordsTests {
    private let german = VoiceWords.table(for: Locale(identifier: "de-DE"))
    private let japanese = VoiceWords.table(for: Locale(identifier: "ja-JP"))
    private let chinese = VoiceWords.table(for: Locale(identifier: "zh-CN"))
    private let korean = VoiceWords.table(for: Locale(identifier: "ko-KR"))
    private let english = VoiceWords.table(for: Locale(identifier: "en-US"))
    private let command = ApprovalRequest(id: "a1", command: "rm -rf ~/builds", description: "Clear out the old builds",
                                          choices: ["once", "session", "always", "deny"])

    @Test func everyLanguageHasATable() {
        for code in ["da", "de", "es", "fr", "it", "ja", "ko", "nb", "nl", "pl", "pt-BR", "ru", "sv", "tr", "uk", "zh-Hans", "zh-Hant"] {
            let words = VoiceWords.table(for: Locale(identifier: code))
            #expect(words.hasTable, "\(code) has no voice words")
            #expect(words.numbers.count == 10 && words.spokenNumbers.count == 10, "\(code)'s numbers")
            #expect(!words.yes.isDisjoint(with: [StopPhrase.normalize(words.approveWord)]), "\(code) asks for a word it doesn't take")
        }
        #expect(!english.hasTable && english.approveWord == "approve" && english.denyWord == "deny")
        #expect(VoiceWords.table(for: Locale(identifier: "no")).hasTable, "Norwegian under nb")
    }

    @Test func stopPhrasesInTheLanguageAndInEnglish() {
        #expect(StopPhrase.matches("Also, stopp, danke.", words: german))
        #expect(StopPhrase.matches("Das war's.", words: german) == german.stop.contains("das war's"))
        #expect(StopPhrase.matches("That's all, thanks", words: german), "English still ends it")
        #expect(!StopPhrase.matches("Stopp den Wagen an der nächsten Ecke", words: german), "a sentence isn't a goodbye")
        #expect(!StopPhrase.matches("stopp", words: english), "only where Redde listens in German")
        #expect(StopPhrase.matches("えーと、ストップ。", words: japanese), "a filler written straight against it")
    }

    @Test func approvalsAreAskedAndAnsweredInTheLanguage() throws {
        let request = try #require(SpokenRequest(.approval(command), words: german))
        #expect(request.prompt.hasPrefix("Genehmigung nötig."))
        #expect(request.prompt.hasSuffix("Sag genehmigen oder ablehnen."))
        #expect(request.hint == "Say “genehmigen” or “ablehnen”.", "on the screen in its language, with the words it listens for")
        #expect(request.answer("Genehmigen, bitte.") == .approval("once"))
        #expect(request.answer("Ablehnen") == .approval("deny"))
        #expect(request.answer("approve") == .approval("once"), "English still answers")
        #expect(request.answer("na ja") == nil, "a shrug is no yes")
        #expect(request.confirmation(of: .approval("once")) == "Genehmigt.")
        #expect(request.reminder == "Sag genehmigen oder ablehnen.")
        // English, as before.
        let plain = try #require(SpokenRequest(.approval(command), words: english))
        #expect(plain.prompt == "Approval needed. Clear out the old builds. rm -rf ~/builds. Say approve, or deny.")
        #expect(plain.hint == "Say “approve” or “deny”.")
    }

    @Test func choicesByNumberInTheLanguage() {
        #expect(german.number("nummer zwei") == 2)
        #expect(german.number("die zweite") == 2)
        #expect(japanese.number("二番") == 2)
        #expect(japanese.number("3番目") == 3)
        #expect(japanese.number("ふたつ目") == 2)
        #expect(chinese.number("第二个") == 2)
        #expect(chinese.number("选三") == 3)
        #expect(korean.number("2번") == 2)
        #expect(korean.number("두 번째") == 2)
        #expect(german.number("elf") == nil)
        let question = Interrupt.clarify(ClarifyRequest(id: "c1", questions: [ClarifyQuestion(id: "", question: "Welche?", choices: ["Rot", "Blau", "Grün"], multiSelect: false)], isBatch: false))
        let asked = SpokenRequest(question, words: german)
        #expect(asked?.answer("die zweite, bitte") == .clarify(questionID: "", answer: "Blau"))
        #expect(asked?.answer("two") == .clarify(questionID: "", answer: "Blau"), "English numbers still count")
        #expect(asked?.prompt.contains("Eins: Rot. Zwei: Blau. Drei: Grün.") == true)
        #expect(asked?.reminder == "Sag eins, zwei oder drei.")
    }

    @Test func stopAndSkipOverAReply() {
        #expect(StopWord.heard(in: "Okay, hör auf damit", words: german))
        #expect(StopWord.heard(in: "stop", words: german), "English still stops")
        #expect(!StopWord.heard(in: "Du sollst nicht aufhören", words: german), "nicht before it")
        #expect(StopWord.heard(in: "别说了", words: chinese))
        #expect(!StopWord.heard(in: "我不要停止", words: chinese), "不要 before it, without a space")
        #expect(StopWord.heard(in: "ちょっとストップ", words: japanese))
        #expect(StopWord.skipHeard(in: "überspringen bitte", words: german))
        #expect(StopWord.skipHeard(in: "skip", words: german))
        #expect(!StopWord.skipHeard(in: "überspringen", words: english))
    }

    @Test func aListenersSoundsDontInterrupt() {
        #expect(Backchannel.isOnly("Mhm, genau", words: german) == german.sounds.contains("genau"))
        #expect(Backchannel.isOnly("うんうん", words: japanese))
        #expect(Backchannel.isOnly("嗯嗯", words: chinese))
        #expect(!Backchannel.isOnly("Stopp", words: german))
    }

    @Test func whatIsSaidComesFromTheListeningLanguage() {
        func folder(_ code: String) -> String { VoiceWords.table(for: Locale(identifier: code)).bundle.bundleURL.lastPathComponent }
        #expect(folder("de-AT") == "de.lproj")
        #expect(folder("zh-TW") == "zh-Hant.lproj")
        #expect(folder("zh-CN") == "zh-Hans.lproj")
        #expect(folder("pt-BR") == "pt-BR.lproj")
        #expect(folder("hi-IN") == "en.lproj", "a language Redde has no strings for speaks English")
        #expect(VoiceWords.table(for: Locale(identifier: "zh-TW")).denyWord == "拒絕")
        #expect(chinese.denyWord == "拒绝")
        #expect(german.spokenList(["eins", "zwei", "drei"]) == "eins, zwei oder drei")
        #expect(english.spokenList(["one", "two", "three"]) == "one, two or three")
    }
}
