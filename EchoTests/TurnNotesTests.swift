import Foundation
import Testing
@testable import Echo

/// What goes to the agent with a message (`TurnNotes`, GitHub issue 72): handed to Redde's plugin
/// where it can take it, and kept out of a chat's first line where it rode on the message.
struct TurnNotesTests {
    private let thorntonPark = CurrentLocation.Here(words: "Thornton Park, Orlando, FL", latitude: 28.5421, longitude: -81.3672, at: .now)

    @Test func aTurnsNotesAreTheOnesTheMessageCarried() {
        var request = TurnRequest(userText: "Tell me a joke", history: [], sessionID: nil, model: nil, instructions: nil)
        request.units = nil
        #expect(TurnNotes.riding(request) == "", "a turn with nothing to say carries nothing")
        request.replyLanguage = "nl"
        request.units = .us
        request.brief = true
        request.incognito = true
        let notes = TurnNotes.riding(request)
        #expect(notes == ReplyLanguage.note("nl") + MeasureUnits.note(.us) + CarBrevity.note + IncognitoNote.note)
        // On the message, as before, every one of them comes off again.
        #expect(ReplyLanguage.stripNote("Tell me a joke" + notes) == "Tell me a joke")
    }

    @Test func theMarkIsTheMessagesWordsAsThePluginMarksThem() {
        // The plugin's own test (test_turnnote.py) has the same value: the two must agree.
        #expect(TurnNotes.mark("coffee near me") == "4ee9728ebb77bbbb")
        #expect(TurnNotes.mark("coffee\n\n near  me ") == TurnNotes.mark("coffee near me"), "whatever happens to its blank lines")
        #expect(TurnNotes.mark("coffee near you") != TurnNotes.mark("coffee near me"))
    }

    @Test func theCommandCarriesTheNotesForOneMessage() throws {
        let notes = ReplyLanguage.note("nl") + CurrentLocation.note(thorntonPark)
        let command = try #require(TurnNotes.command(stored: "20261109_224200_31ce6f", said: "coffee near me", notes: notes))
        let words = command.split(separator: " ").map(String.init)
        #expect(words.count == 4)
        #expect(Array(words.prefix(3)) == ["turn", "20261109_224200_31ce6f", "4ee9728ebb77bbbb"])
        var coded = words[3].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        coded += String(repeating: "=", count: (4 - coded.count % 4) % 4)
        let carried = String(decoding: try #require(Data(base64Encoded: coded)), as: UTF8.self)
        #expect(carried == "(Reply in Dutch (Nederlands).)\n\n(The user is near Thornton Park, Orlando, FL (28.542, -81.367). Use it for places, directions and weather unless they name somewhere else.)")
        // Nothing to hand over, too much of it, or a session id that isn't one: it rides on the message.
        #expect(TurnNotes.command(stored: "s1", said: "hi", notes: "") == nil)
        #expect(TurnNotes.command(stored: "s1", said: "hi", notes: String(repeating: "x", count: TurnNotes.longest + 1)) == nil)
        #expect(TurnNotes.command(stored: "s1 two", said: "hi", notes: "(Use US units.)") == nil)
        #expect(TurnNotes.command(stored: "", said: "hi", notes: "(Use US units.)") == nil)
    }

    /// Hermes's preview: the first message's start, sixty characters, line breaks made spaces.
    private func hermesPreview(_ message: String) -> String {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        return text.count > 60 ? String(text.prefix(60)) + "..." : text
    }

    @Test func aChatsFirstLineStopsBeforeTheNotes() {
        // As the lab's Hermes 0.22.7 gave it for Redde 2.4's message (2026-11-09).
        #expect(TurnNotes.preview("lab:heard coffee near me  (Reply in Dutch (Nederlands).)  (T...") == "lab:heard coffee near me")
        for note in [ReplyLanguage.note("nl"), MeasureUnits.note(.us), MeasureUnits.note(.metric), CalendarChoice.note(["Work", "Home"]),
                     CurrentLocation.note(thorntonPark), CarBrevity.note, IncognitoNote.note, LiveVoiceNote.note(context: ""),
                     CallNote.note("The garage door is open."), AttachedFileNote.note(path: "/tmp/a.pdf"), AttachedFileNote.note(picture: "/tmp/a.png"),
                     "\n\n[Redde: sent by a Shortcuts automation on the user's iPhone, not typed now.]"] {
            for asked in ["Coffee near me", "What is on my calendar tomorrow afternoon, after the dentist?"] {
                #expect(TurnNotes.preview(hermesPreview(asked + note)) == hermesPreview(asked).replacingOccurrences(of: "...", with: "")
                            .trimmingCharacters(in: .whitespaces) || TurnNotes.preview(hermesPreview(asked + note)) == hermesPreview(asked),
                        "\(note.prefix(30))")
            }
            #expect(TurnNotes.preview(hermesPreview(note)) == "", "a message that was only a note: \(note.prefix(30))")
        }
        // Cut anywhere in the note's opening, the message's own words are all that is left.
        let sent = hermesPreview("Is there a good bakery open near me right now?" + CurrentLocation.note(thorntonPark))
        #expect(sent.hasSuffix("..."))
        #expect(TurnNotes.preview(sent) == "Is there a good bakery open near me right now?")
        // (Cut after the one space, it reads as any message cut between two words, and is left alone.)
        #expect(TurnNotes.preview("Is there a good bakery open near me right now? ...") == "Is there a good bakery open near me right now? ...")
        for length in 48 ... 62 {
            let cut = String(("Is there a good bakery open near me right now?  (The user is near Thornton").prefix(length)) + "..."
            #expect(TurnNotes.preview(cut) == "Is there a good bakery open near me right now?", "\(cut)")
        }
    }

    @Test func aFirstLineWithNoNotesIsLeftAlone() {
        #expect(TurnNotes.preview("What's on tomorrow?") == "What's on tomorrow?")
        #expect(TurnNotes.preview("Compare the two plans  (see the table) and pick the cheaper ...") == "Compare the two plans  (see the table) and pick the cheaper ...")
        #expect(TurnNotes.preview("Reply in Dutch (please).") == "Reply in Dutch (please).")
        #expect(TurnNotes.preview("A long message that the preview cuts in the middle of a wor...") == "A long message that the preview cuts in the middle of a wor...")
        #expect(TurnNotes.preview("") == "")
    }

    @Test func aChatListRowShowsTheCleanedLine() {
        var row = HermesSessionsAPI.SessionSummary(id: "s1")
        row.preview = "coffee near me  (The user is near Thornton Park, Orlando, FL..."
        #expect(row.shownPreview == "coffee near me")
        #expect(row.displayTitle == "coffee near me", "an untitled chat is named by its first line")
        row.preview = "(Reply in Dutch (Nederlands).)"
        #expect(row.shownPreview == nil)
        #expect(row.displayTitle == "s1")
        row.title = "Coffee"
        #expect(row.displayTitle == "Coffee")
    }

    @Test @MainActor func aHermesThatRefusedIsntAskedAgainForAWhile() {
        let client = HermesServeClient(settings: Settings.shared)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(client.takesTurnNotes(at: now))
        client.turnNotesRefused(at: now)
        #expect(!client.takesTurnNotes(at: now.addingTimeInterval(60)))
        #expect(!client.takesTurnNotes(at: now.addingTimeInterval(TurnNotes.askAgainAfter - 1)))
        #expect(client.takesTurnNotes(at: now.addingTimeInterval(TurnNotes.askAgainAfter)))
        // A bot answers with its own copy of the plugin: its refusal is its own.
        client.noteProfile("scout", forStored: "bot-chat")
        client.turnNotesRefused(in: "bot-chat", at: now.addingTimeInterval(TurnNotes.askAgainAfter))
        #expect(!client.takesTurnNotes(in: "bot-chat", at: now.addingTimeInterval(TurnNotes.askAgainAfter + 1)))
        #expect(client.takesTurnNotes(in: "main-chat", at: now.addingTimeInterval(TurnNotes.askAgainAfter + 1)))
    }
}
