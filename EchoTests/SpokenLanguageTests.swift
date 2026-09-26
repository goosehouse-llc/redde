import Testing
@testable import Echo

struct SpokenLanguageTests {
    @Test func detectsTheReplysLanguage() {
        #expect(SpokenLanguage.detect("Mañana tienes dos cosas en el calendario: la reunión y el almuerzo con Dana.", hint: "en") == "es")
        #expect(SpokenLanguage.detect("Demain, tu as deux rendez-vous dans ton agenda.", hint: "en") == "fr")
        #expect(SpokenLanguage.detect("Tomorrow you have two things on the calendar.", hint: "en") == "en")
    }

    /// Chinese, Japanese and Korean are clear in a few characters.
    @Test func detectsShortCJK() {
        #expect(SpokenLanguage.detect("はい、わかりました。", hint: "en") == "ja")
        #expect(SpokenLanguage.detect("好的，没问题。", hint: "en") == "zh")
        #expect(SpokenLanguage.detect("네, 알겠습니다.", hint: "en") == "ko")
    }

    /// A foreign opener doesn't hand an English reply to another voice; leaving the listening
    /// language takes more text.
    @Test func aForeignOpenerIsNotEnough() {
        #expect(SpokenLanguage.detect("Bon appétit, Dana!", hint: "en") == nil)
        #expect(SpokenLanguage.detect("Buen provecho, Dana!", hint: "en") == nil)
        #expect(SpokenLanguage.detect("Bon appétit, Dana! Your table is booked for eight tonight.", hint: "en") == "en")
    }

    /// Too little to go on: the listening language reads it rather than a guessed voice.
    @Test func shortTextIsUndecided() {
        #expect(SpokenLanguage.detect("OK.", hint: "en") == nil)
        #expect(SpokenLanguage.detect("", hint: "en") == nil)
    }

    @Test func baseDropsTheRegionAndScript() {
        #expect(SpokenLanguage.base("es-MX") == "es")
        #expect(SpokenLanguage.base("zh-Hans") == "zh")
        #expect(SpokenLanguage.base("en_GB") == "en")
    }

    private let voices: [SpokenLanguage.AppleVoice] = [
        .init(identifier: "en-us-compact", language: "en-US", quality: 1),
        .init(identifier: "en-us-premium", language: "en-US", quality: 3),
        .init(identifier: "en-gb-enhanced", language: "en-GB", quality: 2),
        .init(identifier: "es-es-compact", language: "es-ES", quality: 1),
        .init(identifier: "es-mx-enhanced", language: "es-MX", quality: 2),
        .init(identifier: "fr-ca-compact", language: "fr-CA", quality: 1),
        .init(identifier: "de-novelty", language: "de-DE", quality: 1, novelty: true),
    ]

    @Test func picksTheBestVoiceInThePreferredDialect() {
        #expect(SpokenLanguage.appleVoice(for: "en", preferred: "en-US", among: voices)?.identifier == "en-us-premium")
        #expect(SpokenLanguage.appleVoice(for: "en", preferred: "en-GB", among: voices)?.identifier == "en-gb-enhanced")
        #expect(SpokenLanguage.appleVoice(for: "es", preferred: "es-MX", among: voices)?.identifier == "es-mx-enhanced")
    }

    /// No preferred dialect installed: the language's home dialect, or failing that any.
    @Test func fallsBackToAnotherDialect() {
        let spanish = SpokenLanguage.appleVoice(for: "es", preferred: "es-US", among: voices)
        #expect(spanish?.language == "es-ES")
        #expect(spanish?.identifier == nil)   // only a compact voice: the system default for es-ES
        #expect(SpokenLanguage.appleVoice(for: "fr", preferred: "fr-US", among: voices)?.language == "fr-CA")
    }

    /// No voice for the iPhone's region: US English, not whichever dialect sorts first.
    @Test func homeDialectForEnglish() {
        let english: [SpokenLanguage.AppleVoice] = [
            .init(identifier: "au", language: "en-AU", quality: 1),
            .init(identifier: "us", language: "en-US", quality: 1),
        ]
        #expect(SpokenLanguage.appleVoice(for: "en", preferred: "en-DE", among: english)?.language == "en-US")
    }

    @Test func noVoiceForTheLanguage() {
        #expect(SpokenLanguage.appleVoice(for: "ja", preferred: "ja-US", among: voices) == nil)
        #expect(SpokenLanguage.appleVoice(for: "de", preferred: "de-US", among: voices) == nil)   // novelty only
    }

    private let kokoro = ["af_heart", "am_onyx", "bf_emma", "ef_dora", "em_alex", "ff_siwis", "jf_alpha"]

    @Test func kokoroKeepsYourVoiceForItsLanguage() {
        #expect(SpokenLanguage.kokoroVoice(for: "en", current: "am_onyx", available: kokoro) == "am_onyx")
        #expect(SpokenLanguage.kokoroVoice(for: "en", current: "am_onyx(2)+bm_george(1)", available: kokoro) == "am_onyx(2)+bm_george(1)")
    }

    @Test func kokoroSwitchesLanguageKeepingTheGender() {
        #expect(SpokenLanguage.kokoroVoice(for: "es", current: "am_onyx", available: kokoro) == "em_alex")
        #expect(SpokenLanguage.kokoroVoice(for: "es", current: "af_heart", available: kokoro) == "ef_dora")
        #expect(SpokenLanguage.kokoroVoice(for: "fr", current: "am_onyx", available: kokoro) == "ff_siwis")   // no male French
    }

    /// Other OpenAI-style servers' voices say nothing about their language.
    @Test func onlyKokoroNamesCarryALanguage() {
        #expect(SpokenLanguage.kokoroLanguage(of: "ef_dora") == "es")
        #expect(SpokenLanguage.kokoroLanguage(of: "am_onyx(2)+bm_george(1)") == "en")
        #expect(SpokenLanguage.kokoroLanguage(of: "echo") == nil)
        #expect(SpokenLanguage.kokoroLanguage(of: "fable") == nil)
    }

    @Test func kokoroHasNoVoiceForTheLanguage() {
        #expect(SpokenLanguage.kokoroVoice(for: "de", current: "am_onyx", available: kokoro) == nil)
        #expect(SpokenLanguage.kokoroVoice(for: "it", current: "am_onyx", available: kokoro) == nil)   // none installed
        #expect(SpokenLanguage.kokoroVoice(for: "es", current: "am_onyx", available: []) == nil)       // list not loaded
    }
}
