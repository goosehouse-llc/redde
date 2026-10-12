import Foundation
import Speech

/// The module that turns speech into text. `SpeechTranscriber` wherever the device can run it.
/// An iPhone 11 or SE 2 can't (`isAvailable` is false there and it knows no language at all), and
/// neither can the simulator: those listen with `DictationTranscriber`, the model behind keyboard
/// dictation, which is what Apple's documentation suggests for them. Both run on the device and
/// neither has a cloud path.
enum Transcriber {
    case speech(SpeechTranscriber)
    case dictation(DictationTranscriber)

    enum Kind: Sendable {
        case speech, dictation

        /// What this device listens with.
        static var onThisDevice: Kind {
            #if DEBUG
            if DevHooks.has("-echo.dictation") { return .dictation }
            #endif
            return SpeechTranscriber.isAvailable ? .speech : .dictation
        }

        var supportedLocales: [Locale] {
            get async {
                switch self {
                case .speech: await SpeechTranscriber.supportedLocales
                case .dictation: await DictationTranscriber.supportedLocales
                }
            }
        }

        var installedLocales: [Locale] {
            get async {
                switch self {
                case .speech: await SpeechTranscriber.installedLocales
                case .dictation: await DictationTranscriber.installedLocales
                }
            }
        }

        func supportedLocale(equivalentTo locale: Locale) async -> Locale? {
            switch self {
            case .speech: await SpeechTranscriber.supportedLocale(equivalentTo: locale)
            case .dictation: await DictationTranscriber.supportedLocale(equivalentTo: locale)
            }
        }
    }

    /// `locale` must be one the kind supports (`Kind.supportedLocale(equivalentTo:)`).
    init(_ kind: Kind, locale: Locale) {
        switch kind {
        case .speech:
            self = .speech(SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults, .fastResults],
                attributeOptions: []
            ))
        case .dictation:
            // Tentative results as the words come (endpointing reads them) and punctuation, for
            // audio of any length: dictation into the message field may run two minutes.
            self = .dictation(DictationTranscriber(locale: locale, preset: .progressiveLongDictation))
        }
    }

    var module: any SpeechModule {
        switch self {
        case let .speech(module): module
        case let .dictation(module): module
        }
    }

    /// Hands `body` each result as plain text, with whether it is final, until the results end
    /// or `body` returns false.
    func results(_ body: (String, Bool) -> Bool) async throws {
        switch self {
        case let .speech(module):
            for try await result in module.results {
                guard body(String(result.text.characters), result.isFinal) else { return }
            }
        case let .dictation(module):
            for try await result in module.results {
                guard body(String(result.text.characters), result.isFinal) else { return }
            }
        }
    }
}
