// Redde's String Catalogs, kept from the command line: the work Xcode does when it builds with a
// catalog open, which `xcodebuild` doesn't (and `xcodebuild -exportLocalizations` can't, here: it
// builds every target for iOS, and the watch's widgets don't build for iOS).
//
//   swift scripts/strings.swift sync              each target's text, from its last simulator build,
//                                                 into the catalog beside its code (new keys added,
//                                                 keys gone marked stale, as Xcode marks them)
//   swift scripts/strings.swift status            per catalog: its keys, and how many each language has
//   swift scripts/strings.swift export <lang> <out.json>
//                                                 the text a language still lacks, from every catalog
//                                                 at once (the same English once), with comments
//   swift scripts/strings.swift shortcuts       Siri's phrases (the AppShortcutsProviders) into the
//                                                 AppShortcuts catalogs; translated as lists
//   swift scripts/strings.swift plist           the Info.plist texts in project.yml into the InfoPlist
//                                                 catalogs (after a change to one there)
//   swift scripts/strings.swift check <lang> <in.json>    import's checks, nothing written
//   swift scripts/strings.swift import <lang> <in.json>
//                                                 translations into every catalog that has the key:
//                                                 {"English": "translation"} or, for a plural,
//                                                 {"English": {"one": "...", "other": "..."}}; one whose
//                                                 %@, %lld … don't match the English is refused
//
// Build first, for the simulator (the scheme Echo builds the app, its extensions and the watch):
//   xcodebuild build -project Echo.xcodeproj -scheme Echo -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData
//
// Written as Xcode writes them (JSONSerialization, keys in `localizedStandardCompare` order, no
// newline at the end), so Xcode opening a catalog afterwards changes nothing.

import Foundation

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let derived = repo.appending(path: "DerivedData/Build/Intermediates.noindex/Echo.build")

/// Each target, its catalog, and where its simulator build leaves the text it found.
let targets: [(name: String, catalog: String, build: String)] = [
    ("Echo", "Echo/Resources/Localizable.xcstrings", "Debug-iphonesimulator/Echo.build/Objects-normal/arm64"),
    ("EchoControls", "EchoControls/Localizable.xcstrings", "Debug-iphonesimulator/EchoControls.build/Objects-normal/arm64"),
    ("EchoPush", "EchoPush/Localizable.xcstrings", "Debug-iphonesimulator/EchoPush.build/Objects-normal/arm64"),
    ("EchoShare", "EchoShare/Localizable.xcstrings", "Debug-iphonesimulator/EchoShare.build/Objects-normal/arm64"),
    ("EchoWatch", "Watch/Localizable.xcstrings", "Debug-watchsimulator/EchoWatch.build/Objects-normal/arm64"),
    ("EchoWatchWidgets", "WatchWidgets/Localizable.xcstrings", "Debug-watchsimulator/EchoWatchWidgets.build/Objects-normal/arm64"),
]

/// Catalogs no build fills: the Info.plist texts (the permission texts, an extension's name), keyed
/// by their Info.plist key with the English as its value. Exported and imported with the rest.
let plistCatalogs = ["Echo/Resources/InfoPlist.xcstrings", "EchoControls/InfoPlist.xcstrings"]
var allCatalogs: [String] { targets.map(\.catalog) + plistCatalogs }
/// Siri's phrases: each provider's file, and its AppShortcuts catalog (keyed by each shortcut's
/// first phrase, every phrase in a language's `stringSet`).
let shortcutCatalogs = [("Echo/Intents/AskHermesIntent.swift", "Echo/Resources/AppShortcuts.xcstrings"),
                        ("Watch/AskReddeIntent.swift", "Watch/AppShortcuts.xcstrings")]

/// The phrase sets a provider declares, in order: `"Hey \(.applicationName)"` as Siri's catalogs
/// write it, `"Hey ${applicationName}"`.
func phraseSets(in source: String) -> [[String]] {
    let code = try! String(contentsOf: repo.appending(path: source), encoding: .utf8)
    var sets: [[String]] = []
    var rest = code[...]
    while let start = rest.range(of: "phrases: [") {
        let after = rest[start.upperBound...]
        guard let end = after.range(of: "],") ?? after.range(of: "]") else { break }
        let block = after[..<end.lowerBound]
        let phrases = block.split(separator: "\n").compactMap { line -> String? in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("\"") else { return nil }
            var phrase = String(text.dropFirst())
            if let close = phrase.lastIndex(of: "\"") { phrase = String(phrase[..<close]) }
            return phrase.replacingOccurrences(of: "\\(.applicationName)", with: "${applicationName}")
                .replacingOccurrences(of: "\\(\\.$profile)", with: "${profile}")
        }
        if !phrases.isEmpty { sets.append(phrases) }
        rest = after[end.upperBound...]
    }
    return sets
}

/// The `${…}` a phrase names.
func placeholders(_ phrase: String) -> Set<String> {
    Set(phrase.matches(of: #/\$\{[A-Za-z]+\}/#).map { String($0.output) })
}

typealias JSON = [String: Any]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func load(_ path: String) -> JSON {
    let url = repo.appending(path: path)
    guard let data = try? Data(contentsOf: url),
          let object = try? JSONSerialization.jsonObject(with: data) as? JSON else { fail("can't read \(path)") }
    return object
}

func save(_ catalog: JSON, _ path: String) {
    guard let data = try? JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
        fail("can't write \(path)")
    }
    try! data.write(to: repo.appending(path: path))
}

/// The keys a target's last build found, with their comments and English (a key written as an
/// identifier, `String(localized: "task.done", defaultValue: "Done")`, has its English apart).
func found(in build: String) -> [String: (comment: String, english: String)] {
    let folder = derived.appending(path: build)
    guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
        fail("no build at \(folder.path): build for the simulator first")
    }
    var keys: [String: (comment: String, english: String)] = [:]
    for file in files where file.pathExtension == "stringsdata" {
        guard let data = try? Data(contentsOf: file), let object = try? JSONSerialization.jsonObject(with: data) as? JSON,
              let tables = object["tables"] as? [String: [JSON]] else { continue }
        for entry in tables["Localizable"] ?? [] {
            guard let key = entry["key"] as? String else { continue }
            let comment = entry["comment"] as? String ?? ""
            if keys[key]?.comment.isEmpty ?? true { keys[key] = (comment, entry["value"] as? String ?? key) }
        }
    }
    return keys
}

/// The format specifiers a string has, in order of argument: `%@`, `%lld`, `%1$@` taken as their
/// type alone, so a translation may reorder them with positions.
func specifiers(_ text: String) -> [String] {
    let pattern = try! NSRegularExpression(pattern: #"%(?:(\d+)\$)?([-+ 0#]*\d*(?:\.\d+)?(?:ll|l|h)?[@dDuUxXoOfeEgGcCsSpaA])"#)
    var positional: [Int: String] = [:], plain: [String] = []
    for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
        let type = String(text[Range(match.range(at: 2), in: text)!]).filter { "@dDuUxXoOfeEgGcCsSpaA".contains($0) || $0 == "l" }
        if let position = Range(match.range(at: 1), in: text).flatMap({ Int(text[$0]) }) { positional[position] = type } else { plain.append(type) }
    }
    if positional.isEmpty { return plain }
    return positional.keys.sorted().map { positional[$0]! }
}

/// Worth translating: has a letter in it. ("·", "%@", "/" aren't.)
func hasWords(_ key: String) -> Bool { key.unicodeScalars.contains { CharacterSet.letters.contains($0) } && key != "%@" }

/// The English a translator sees: the catalog's own English where it has one (an Info.plist text,
/// or a key whose English puts its values by position), else the key itself.
func english(_ key: String, _ entry: JSON) -> String {
    let unit = ((entry["localizations"] as? JSON)?["en"] as? JSON)?["stringUnit"] as? JSON
    return unit?["value"] as? String ?? key
}

func translated(_ entry: JSON, _ language: String) -> Bool {
    guard let local = (entry["localizations"] as? JSON)?[language] as? JSON else { return false }
    if let unit = local["stringUnit"] as? JSON { return (unit["state"] as? String) == "translated" }
    return local["variations"] != nil
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "sync":
    for target in targets {
        var catalog = load(target.catalog)
        var strings = catalog["strings"] as? JSON ?? [:]
        let keys = found(in: target.build)
        var added = 0, gone = 0, back = 0
        for (key, (comment, english)) in keys {
            var entry = strings[key] as? JSON ?? { added += 1; return [:] }()
            if entry["extractionState"] as? String == "stale" { entry["extractionState"] = nil; back += 1 }
            entry["comment"] = comment.isEmpty ? nil : comment
            if english != key {
                var localizations = entry["localizations"] as? JSON ?? [:]
                var en = localizations["en"] as? JSON ?? [:]
                if en["stringUnit"] == nil && en["variations"] == nil {
                    en["stringUnit"] = ["state": "new", "value": english]
                    localizations["en"] = en
                    entry["localizations"] = localizations
                }
            }
            if !hasWords(key) { entry["shouldTranslate"] = false }
            strings[key] = entry
        }
        for (key, value) in strings where keys[key] == nil {
            guard var entry = value as? JSON, entry["extractionState"] as? String != "manual",
                  entry["extractionState"] as? String != "stale" else { continue }
            entry["extractionState"] = "stale"
            strings[key] = entry
            gone += 1
        }
        catalog["strings"] = strings
        save(catalog, target.catalog)
        print("\(target.catalog): \(keys.count) found, \(added) new, \(gone) gone (stale), \(back) back")
    }

case "plist":
    // project.yml's Info.plist texts: the permission texts of the app, and an extension's own name.
    let wanted: [String: (catalog: String, keys: (String) -> Bool)] = [
        "Echo": ("Echo/Resources/InfoPlist.xcstrings", { $0.hasPrefix("NS") && $0.hasSuffix("UsageDescription") }),
        "EchoControls": ("EchoControls/InfoPlist.xcstrings", { $0 == "CFBundleDisplayName" }),
    ]
    let yaml = try! String(contentsOf: repo.appending(path: "project.yml"), encoding: .utf8)
    var target = "", inTargets = false
    var texts: [String: [String: String]] = [:]
    for line in yaml.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        if line == "targets:" { inTargets = true; continue }
        guard inTargets else { continue }
        if let match = line.wholeMatch(of: #/  ([A-Za-z]+):/#) { target = String(match.1); continue }
        guard let match = line.wholeMatch(of: #/\s+([A-Za-z]+):\s+(.+)/#), let rule = wanted[target], rule.keys(String(match.1)) else { continue }
        var value = String(match.2)
        if value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
        texts[target, default: [:]][String(match.1)] = value
    }
    for (name, rule) in wanted {
        let url = repo.appending(path: rule.catalog)
        var catalog = FileManager.default.fileExists(atPath: url.path) ? load(rule.catalog) : ["sourceLanguage": "en", "strings": JSON(), "version": "1.0"]
        var strings = catalog["strings"] as? JSON ?? [:]
        for (key, value) in texts[name] ?? [:] {
            var entry = strings[key] as? JSON ?? [:]
            var localizations = entry["localizations"] as? JSON ?? [:]
            let was = ((localizations["en"] as? JSON)?["stringUnit"] as? JSON)?["value"] as? String
            localizations["en"] = ["stringUnit": ["state": "new", "value": value]]
            // Changed English: the translations are of the old one, and are dropped.
            if let was, was != value { localizations = ["en": localizations["en"]!] }
            entry["localizations"] = localizations
            entry["extractionState"] = "extracted_with_value"
            entry["comment"] = key == "CFBundleDisplayName" ? "The name iOS shows for it (Controls, widgets)" : "Why Redde asks for this permission"
            strings[key] = entry
        }
        catalog["strings"] = strings
        save(catalog, rule.catalog)
        print("\(rule.catalog): \((texts[name] ?? [:]).count) texts")
    }

case "shortcuts":
    for (source, catalogPath) in shortcutCatalogs {
        let url = repo.appending(path: catalogPath)
        var catalog = FileManager.default.fileExists(atPath: url.path) ? load(catalogPath) : ["sourceLanguage": "en", "strings": JSON(), "version": "1.0"]
        var strings = catalog["strings"] as? JSON ?? [:]
        let sets = phraseSets(in: source)
        for (key, value) in strings where !sets.contains(where: { $0.first == key }) {
            var entry = value as? JSON ?? [:]
            entry["extractionState"] = "stale"
            strings[key] = entry
        }
        for phrases in sets {
            var entry = strings[phrases[0]] as? JSON ?? [:]
            var localizations = entry["localizations"] as? JSON ?? [:]
            localizations["en"] = ["stringSet": ["state": "new", "values": phrases]]
            entry["localizations"] = localizations
            entry["extractionState"] = nil
            strings[phrases[0]] = entry
        }
        catalog["strings"] = strings
        save(catalog, catalogPath)
        print("\(catalogPath): \(sets.count) shortcuts, \(sets.map(\.count).reduce(0, +)) phrases")
    }

case "status":
    for catalogPath in allCatalogs {
        let strings = load(catalogPath)["strings"] as? JSON ?? [:]
        let live = strings.filter { key, value in
            let entry = value as? JSON ?? [:]
            return entry["extractionState"] as? String != "stale" && entry["shouldTranslate"] as? Bool != false && hasWords(key)
        }
        var languages: [String: Int] = [:]
        for (_, value) in live {
            for language in ((value as? JSON)?["localizations"] as? JSON ?? [:]).keys where translated(value as! JSON, language) {
                languages[language, default: 0] += 1
            }
        }
        let counts = languages.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        print("\(catalogPath): \(live.count) to translate\(counts.isEmpty ? "" : "; " + counts)")
    }

case "export":
    guard arguments.count == 3 else { fail("usage: export <lang> <out.json>") }
    let language = arguments[1]
    var missing: [String: String] = [:]
    for catalogPath in allCatalogs {
        for (key, value) in load(catalogPath)["strings"] as? JSON ?? [:] {
            guard let entry = value as? JSON, entry["extractionState"] as? String != "stale",
                  entry["shouldTranslate"] as? Bool != false, hasWords(key), !translated(entry, language) else { continue }
            let text = english(key, entry)
            let comment = entry["comment"] as? String ?? ""
            if missing[text]?.isEmpty ?? true { missing[text] = comment }
        }
    }
    var rows = missing.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { key -> JSON in
        var row: JSON = ["english": key]
        if let comment = missing[key], !comment.isEmpty { row["comment"] = comment }
        // One count and nothing else: translated with a form for each number the language
        // tells apart, as {"one": …, "few": …, "many": …, "other": …}.
        let found = specifiers(key)
        if found.count == 1, found[0].hasSuffix("d") || found[0].hasSuffix("u") { row["count"] = true }
        return row
    }
    // Siri's phrases: a set each, translated as a set (as many as read naturally, each with the
    // same ${…} as the English).
    var seen = Set<String>()
    for (_, catalogPath) in shortcutCatalogs where FileManager.default.fileExists(atPath: repo.appending(path: catalogPath).path) {
        for (key, value) in load(catalogPath)["strings"] as? JSON ?? [:] {
            guard let entry = value as? JSON, entry["extractionState"] as? String != "stale",
                  (entry["localizations"] as? JSON)?[language] == nil, seen.insert(key).inserted,
                  let phrases = (((entry["localizations"] as? JSON)?["en"] as? JSON)?["stringSet"] as? JSON)?["values"] as? [String] else { continue }
            rows.append(["english": key, "phrases": phrases,
                         "comment": "Siri phrases: translate as a list of phrases people would say; keep each ${…} exactly"])
        }
    }
    let data = try! JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .withoutEscapingSlashes])
    try! data.write(to: URL(fileURLWithPath: arguments[2]))
    print("\(rows.count) strings for \(language) in \(arguments[2])")

case "import", "check":
    // check: the same tests as import, nothing written (a translator's own check).
    let writing = arguments.first == "import"
    guard arguments.count == 3 else { fail("usage: \(arguments[0]) <lang> <in.json>") }
    let language = arguments[1]
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: arguments[2])),
          let given = try? JSONSerialization.jsonObject(with: data) as? JSON else { fail("can't read \(arguments[2])") }
    var refused: [String] = []
    var accepted: [String: Any] = [:]
    for (key, value) in given {
        // "key:<catalog key>": that one entry, whatever its English (two meanings of one English:
        // "task.done" is "Done" as a status, beside the Done button). Its English is its key's.
        let english = specifiers(key.hasPrefix("key:") ? String(key.dropFirst(4)) : key)
        if let text = value as? String {
            if specifiers(text) != english { refused.append(key); continue }
            accepted[key] = ["stringUnit": ["state": "translated", "value": text]]
        } else if let forms = value as? [String: String], !forms.isEmpty,
                  Set(forms.keys).isSubset(of: ["zero", "one", "two", "few", "many", "other"]), forms["other"] != nil {
            if forms.values.contains(where: { specifiers($0) != english && !(specifiers($0).isEmpty && english.count == 1) }) {
                refused.append(key); continue
            }
            let plural = forms.mapValues { ["stringUnit": ["state": "translated", "value": $0]] }
            accepted[key] = ["variations": ["plural": plural]]
        } else if let phrases = value as? [String], !phrases.isEmpty {
            let needed = placeholders(key)
            if phrases.contains(where: { placeholders($0) != needed }) { refused.append(key); continue }
            accepted[key] = ["stringSet": ["state": "translated", "values": phrases]]
        } else {
            refused.append(key)
        }
    }
    var placed = 0
    for catalogPath in writing ? allCatalogs + shortcutCatalogs.map(\.1) : [] {
        var catalog = load(catalogPath)
        var strings = catalog["strings"] as? JSON ?? [:]
        var changed = false
        let isShortcuts = catalogPath.hasSuffix("AppShortcuts.xcstrings")
        for (key, value) in strings {
            guard var entry = value as? JSON,
                  let localization = (accepted["key:" + key] ?? accepted[isShortcuts ? key : english(key, entry)]) as? JSON,
                  (localization["stringSet"] != nil) == isShortcuts else { continue }
            var localizations = entry["localizations"] as? JSON ?? [:]
            localizations[language] = localization
            entry["localizations"] = localizations
            strings[key] = entry
            changed = true
            placed += 1
        }
        if changed { catalog["strings"] = strings; save(catalog, catalogPath) }
    }
    print(writing ? "\(accepted.count) translations for \(language), placed \(placed) times across the catalogs"
                  : "\(accepted.count) translations for \(language) pass the checks")
    if !refused.isEmpty {
        print("refused \(refused.count) (their %@, %lld … don't match the English, or not a string or plural):")
        for key in refused.prefix(20) { print("  \(key)") }
        exit(2)
    }

default:
    fail("usage: swift scripts/strings.swift sync | status | export <lang> <out.json> | import <lang> <in.json>")
}
