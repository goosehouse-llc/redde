# Translations

Redde is translated into 17 languages besides English (asked for on 2026-10-26): Spanish, French,
German, Italian, Portuguese (Brazil), Japanese, Korean, Chinese (Simplified and Traditional), Dutch,
Swedish, Polish, Ukrainian, Russian, Turkish, Danish and Norwegian. The whole app is translated: every
screen on iPhone, iPad, Apple Watch and CarPlay, notifications, the Live Activity, widgets, Siri and
the permission texts. The App Store listing stays English.

Voice follows the language Redde listens in (Settings → Voice → Listening language), not the
screen's, since 2026-10-27: what Redde says itself ("Okay.", "Approval needed… Say approve, or
deny.") is looked up in that language's strings (`VoiceWords.bundle`), and the words it listens for
are heard in that language as well as in English (see "Voice words" below).

## Where the text lives

Each target has a String Catalog beside its code, which its build fills with the English:

| Target | Catalog |
|---|---|
| Echo (the app) | `Echo/Resources/Localizable.xcstrings` |
| EchoControls (widgets, Live Activity, controls) | `EchoControls/Localizable.xcstrings` |
| EchoPush (notifications opened while Redde is closed) | `EchoPush/Localizable.xcstrings` |
| EchoShare | `EchoShare/Localizable.xcstrings` |
| EchoWatch | `Watch/Localizable.xcstrings` |
| EchoWatchWidgets | `WatchWidgets/Localizable.xcstrings` |

Code in `Shared/` is built into several targets, and each looks its text up in its own bundle, so
the same English is in several catalogs; `scripts/strings.swift import` puts a translation in every
catalog that has it.

`xcodebuild` doesn't update the catalogs, as Xcode does; `scripts/strings.swift` does:

```
xcodebuild build -project Echo.xcodeproj -scheme Echo -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData
swift scripts/strings.swift sync      # new text in, text gone marked stale
swift scripts/strings.swift status    # what each catalog has, per language
swift scripts/strings.swift export de tmp/de.json
swift scripts/strings.swift import de tmp/de-done.json
```

## Writing text that can be translated

SwiftUI already translates a literal it is handed: `Text("Done")`, `Button("Save")`,
`Toggle("Bot faces", …)`, `Label("Copy", systemImage: …)`, `LabeledContent("Name", …)`,
`.navigationTitle("Settings")`, `Section("Voice")`. Nothing to do there.

Everything else that a person reads is a `String`, and isn't, until it goes through
`String(localized:)`:

- **Labels and titles kept in code** (`var label: String { switch self { case .x: "Bot faces" … } }`,
  `Item(title: "…", detail: "…")`, a struct's `blurb`): `String(localized: "Bot faces")`.
- **A choice between two texts** (`Text(on ? "On" : "Off")` passes a `String`): write
  `on ? Text("On") : Text("Off")`, or `String(localized:)` each side.
- **Text with values in it**: keep the interpolation inside, `String(localized: "\(name) is thinking")`;
  the catalog's key is "%@ is thinking", and a translation can move the value.
- **Counts**: never `count == 1 ? "1 message" : "\(count) messages"`. Write
  `String(localized: "\(count) messages")` and list the key in the plurals section below: the
  catalog then holds a form for each number the language distinguishes (Polish, Russian and
  Ukrainian have three or four).
- **Numbers, durations, dates, sizes**: through a format style (`.formatted()`, `Duration.formatted`,
  `ByteCountFormatStyle`, `Measurement`), never `String(format: "%.1f")` or a hand-written "min" or "s".
- **Errors**: `errorDescription` returns `String(localized: "…")`.
- **Notifications, notification actions, the Live Activity, widgets, CarPlay templates,
  accessibility labels**: all `String(localized:)`.
- **Where a short word could mean two things** ("Open", "Ask", "Off"), add a comment for the
  translator: `String(localized: "Open", comment: "Button: opens the conversation")`.

## What stays English

- **What goes to the model**: `ReplyLanguage`, `AttachedFileNote`, `IncognitoNote.instruction` and
  `.note` (its `title` and `replied` are shown, and are translated), `MentionNote`, `LiveVoiceNote`,
  `CallNote`, `CarBrevity` (all in `Echo/Models/ReplyLanguage.swift`), the live voice personas and
  instructions (`LiveSetup`, `LiveVoicePreview`, the dialects), `DeviceToolRunner`'s answers to the
  agent, bot templates' `soul:`, group rooms' instructions (`ServerGroups`), `SkillEditorView`'s
  prompt, `Capture`'s note text. Their `strip()` functions find them by their English.
- **The English voice words**, heard in every language beside the listening language's
  (`StopPhrase`, `SpokenRequest`, `StopWord`, `Backchannel`), and the default wake phrase ("Hey
  Sol", `Settings.defaultWakePhrase`). Where a screen's text quotes one of them ("say “stop”", the
  setting "Stop and Skip in the car"), it stays English inside it: it still works.
- **Logs** (`Logger`, `LiveMeasure`), keys, identifiers, URLs, JSON, DEBUG-only screens and the demo
  conversations (`ConversationDemo`, `DevHooks`).

## Plurals

Keys with a count whose English has a singular and a plural form (`import en` gives English its
`one`/`other` forms):

- `%lld attachments` (one: `%lld attachment`)
- `%lld changes behind` (one: `%lld change behind`)
- `%lld characters…` (one: `%lld character…`)
- `%lld chars` (one: `%lld char`)
- `%lld conversations` (one: `%lld conversation`)
- `%lld members` (one: `%lld member`)
- `%lld messages` (one: `%lld message`)
- `%lld minutes` (one: `%lld minute`)
- `%lld more characters` (one: `%lld more character`)
- `%lld notes waiting to be sent` (one: `%lld note waiting to be sent`)
- `%lld phrases` (one: `%lld phrase`)
- `%lld plugins` (one: `%lld plugin`)
- `%lld tools` (one: `%lld tool`)
- `%lld turns` (one: `%lld turn`)
- `%lld turns are running now.` (one: `%lld turn is running now.`)
- `Connected · %lld tools` (one: `Connected · %lld tool`)
- `Connected. %lld models available.` (one: `Connected. %lld model available.`)
- `Delete %lld conversations?` (one: `Delete %lld conversation?`)
- `Delete %lld photos` (one: `Delete %lld photo`)
- `Every %lld hours` (one: `Every %lld hour`)
- `Model · %lld bots` (one: `Model · %lld bot`)
- `Only the first %lld items were attached.` (one: `Only the first %lld item was attached.`)
- `Redde has %lld questions` (one: `Redde has %lld question`)
- `Shows the %lld bots hidden from this list` (one: `Shows the %lld bot hidden from this list`)
- `This runs hermes update, %lld changes, and restarts Hermes.` (one: `This runs hermes update, %lld change, and restarts Hermes.`)
- `its %lld custom headers` (one: `its custom header`)

Two counts sit in a sentence with other values and stay plural in English, since a whole-string
plural can't say which number it follows: `%lld files · +%lld −%lld` and `This runs hermes update
on %@, %lld changes, and restarts Hermes.`

## Translating

`swift scripts/strings.swift export <lang> <file>` gives every string a language still lacks, once
however many catalogs have it, with `count: true` on one with a single number (translated as a
form per plural category: Polish, Russian and Ukrainian have one, few, many and other) and Siri's
phrase sets as lists. `check` runs `import`'s tests (every `%@`, `%lld` and `${…}` kept) without
writing; `import` puts each translation into every catalog that has its English. The rules the
translations of 2026-10-26 followed are kept with the scripts: product names and technical
identifiers untouched, Apple's own iOS words for Apple's things, Redde's screen names decided once
and used wherever a text points to them.

## Voice words

`Echo/Resources/VoiceWords.json` has, per language (its base code; Chinese one table for both
scripts, Norwegian under `nb`), the words Redde hears beside the English: `stop` (whole utterances
that end the conversation), `before`/`after` (polite words peeled around one), `yes`/`no` (whole
answers to an approval; the first of each is the word the voice and the screen ask for),
`numbers` (every way of saying choice one to ten; the first is the one read out),
`numberBefore`/`numberAfter`, `interrupt` and `skip` (matched anywhere in a sentence, so never an
everyday word), `negations` (said right before those, they flip them) and `sounds` (a listener's
"mm-hm", which doesn't interrupt). What Redde says aloud is ordinary catalog text with
`bundle: VoiceWords.current.bundle`; its comment says it is said aloud.

## Decided once, for every language

- **Done**: the button that closes a screen is Apple's own word for it (fr, es, pt-BR "OK", de
  "Fertig", it "Fine", nl "Gereed", ja "完了"…); "done" as a state (a ticked task, the Kanban
  column, the title after a plugin change) is the key `task.done`, its own word ("Erledigt",
  "Terminé"…). A text that says "Tap Done" names the button's word.
- **Notes**: the chat quick capture files into is called "Notes" on the server
  (`Capture.title`), and every language calls it that.
- **Siri**: a phrase belongs to one shortcut only; `strings.swift` can't tell, so check after an
  import that no phrase appears in two of a language's sets.

## Siri and the permission texts

`swift scripts/strings.swift shortcuts` reads Siri's phrases from the two `AppShortcutsProvider`s
into `AppShortcuts.xcstrings` (the app's, the watch's); `plist` reads the permission texts and the
controls' name from `project.yml` into `InfoPlist.xcstrings`. Run them after changing either.
