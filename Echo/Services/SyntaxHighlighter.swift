import SwiftUI

/// Small, dependency-free highlighter for fenced code blocks. Covers the languages Hermes
/// tends to emit (Swift, Python, JS/TS, shell, JSON, YAML, Go, Rust, SQL, HTML, C-family);
/// anything else still gets strings, numbers and comments.
nonisolated struct SyntaxHighlighter {
    enum Token { case plain, keyword, string, comment, number, type, attribute, key }

    struct Palette: Equatable, Sendable {
        let keyword: Color, string: Color, comment: Color, number: Color, type: Color, attribute: Color, key: Color

        static let light = Palette(
            keyword: Color(red: 0.61, green: 0.13, blue: 0.53),
            string: Color(red: 0.77, green: 0.10, blue: 0.09),
            comment: Color(red: 0.42, green: 0.47, blue: 0.51),
            number: Color(red: 0.11, green: 0.00, blue: 0.81),
            type: Color(red: 0.24, green: 0.48, blue: 0.55),
            attribute: Color(red: 0.58, green: 0.35, blue: 0.09),
            key: Color(red: 0.24, green: 0.48, blue: 0.55))

        static let dark = Palette(
            keyword: Color(red: 0.99, green: 0.47, blue: 0.66),
            string: Color(red: 0.99, green: 0.53, blue: 0.40),
            comment: Color(red: 0.49, green: 0.55, blue: 0.60),
            number: Color(red: 0.84, green: 0.76, blue: 0.47),
            type: Color(red: 0.60, green: 0.86, blue: 0.99),
            attribute: Color(red: 0.75, green: 0.72, blue: 0.99),
            key: Color(red: 0.60, green: 0.86, blue: 0.99))

        // The Terminal theme's palettes: the hues Claude Code paints in the Mac terminal —
        // rose keywords, lavender numbers, red-orange types, periwinkle attributes.
        static let terminalDark = Palette(
            keyword: Color(red: 0.92, green: 0.36, blue: 0.48),
            string: Color(red: 0.87, green: 0.77, blue: 0.45),
            comment: Color(red: 0.50, green: 0.58, blue: 0.50),
            number: Color(red: 0.71, green: 0.66, blue: 0.93),
            type: Color(red: 0.90, green: 0.42, blue: 0.38),
            attribute: Color(red: 0.60, green: 0.71, blue: 1.00),
            key: Color(red: 0.60, green: 0.71, blue: 1.00))

        // The Hermes docs-site look: gold keywords/flags, green commands, warm white.
        static let hermesDark = Palette(
            keyword: Color(red: 1.00, green: 0.84, blue: 0.00),
            string: Color(red: 0.27, green: 0.85, blue: 0.42),
            comment: Color(red: 0.55, green: 0.55, blue: 0.50),
            number: Color(red: 0.95, green: 0.72, blue: 0.25),
            type: Color(red: 0.86, green: 0.86, blue: 0.80),
            attribute: Color(red: 1.00, green: 0.84, blue: 0.00),
            key: Color(red: 0.27, green: 0.85, blue: 0.42))

        static let hermesLight = Palette(
            keyword: Color(red: 0.55, green: 0.45, blue: 0.00),
            string: Color(red: 0.13, green: 0.55, blue: 0.25),
            comment: Color(red: 0.45, green: 0.47, blue: 0.42),
            number: Color(red: 0.60, green: 0.45, blue: 0.05),
            type: Color(red: 0.20, green: 0.20, blue: 0.22),
            attribute: Color(red: 0.55, green: 0.45, blue: 0.00),
            key: Color(red: 0.13, green: 0.55, blue: 0.25))

        static let terminalLight = Palette(
            keyword: Color(red: 0.72, green: 0.18, blue: 0.32),
            string: Color(red: 0.60, green: 0.48, blue: 0.10),
            comment: Color(red: 0.42, green: 0.50, blue: 0.42),
            number: Color(red: 0.42, green: 0.35, blue: 0.72),
            type: Color(red: 0.70, green: 0.25, blue: 0.20),
            attribute: Color(red: 0.22, green: 0.38, blue: 0.72),
            key: Color(red: 0.22, green: 0.38, blue: 0.72))
    }

    struct Language: Sendable {
        var keywords: Set<String>
        // Markers as character arrays, built once here: the scanner compares them per character.
        var lineComment: [[Character]]
        var blockComment: ([Character], [Character])?
        var tripleQuotes: Bool
        var capitalizedTypes: Bool
        var attributePrefix: Character?  // @ for Swift/Python/TS, # for Rust
        var yamlKeys: Bool
        var jsonKeys: Bool
        var tags: Bool

        init(keywords: Set<String>, lineComment: [String], blockComment: (String, String)?, tripleQuotes: Bool, capitalizedTypes: Bool,
             attributePrefix: Character?, yamlKeys: Bool, jsonKeys: Bool, tags: Bool) {
            self.keywords = keywords
            self.lineComment = lineComment.map(Array.init)
            self.blockComment = blockComment.map { (Array($0.0), Array($0.1)) }
            self.tripleQuotes = tripleQuotes
            self.capitalizedTypes = capitalizedTypes
            self.attributePrefix = attributePrefix
            self.yamlKeys = yamlKeys
            self.jsonKeys = jsonKeys
            self.tags = tags
        }

        static func resolve(_ name: String?) -> Language {
            switch (name ?? "").lowercased() {
            case "swift":
                Language(keywords: swiftKW, lineComment: ["//"], blockComment: ("/*", "*/"), tripleQuotes: true, capitalizedTypes: true, attributePrefix: "@", yamlKeys: false, jsonKeys: false, tags: false)
            case "python", "py":
                Language(keywords: pythonKW, lineComment: ["#"], blockComment: nil, tripleQuotes: true, capitalizedTypes: true, attributePrefix: "@", yamlKeys: false, jsonKeys: false, tags: false)
            case "js", "javascript", "jsx", "ts", "typescript", "tsx":
                Language(keywords: jsKW, lineComment: ["//"], blockComment: ("/*", "*/"), tripleQuotes: false, capitalizedTypes: true, attributePrefix: "@", yamlKeys: false, jsonKeys: false, tags: false)
            case "sh", "bash", "zsh", "shell", "console", "fish":
                Language(keywords: shellKW, lineComment: ["#"], blockComment: nil, tripleQuotes: false, capitalizedTypes: false, attributePrefix: "$", yamlKeys: false, jsonKeys: false, tags: false)
            case "json", "jsonc":
                Language(keywords: ["true", "false", "null"], lineComment: ["//"], blockComment: nil, tripleQuotes: false, capitalizedTypes: false, attributePrefix: nil, yamlKeys: false, jsonKeys: true, tags: false)
            case "yaml", "yml", "toml", "ini":
                Language(keywords: ["true", "false", "null", "yes", "no"], lineComment: ["#"], blockComment: nil, tripleQuotes: false, capitalizedTypes: false, attributePrefix: nil, yamlKeys: true, jsonKeys: false, tags: false)
            case "go", "golang":
                Language(keywords: goKW, lineComment: ["//"], blockComment: ("/*", "*/"), tripleQuotes: false, capitalizedTypes: true, attributePrefix: nil, yamlKeys: false, jsonKeys: false, tags: false)
            case "rust", "rs":
                Language(keywords: rustKW, lineComment: ["//"], blockComment: ("/*", "*/"), tripleQuotes: false, capitalizedTypes: true, attributePrefix: "#", yamlKeys: false, jsonKeys: false, tags: false)
            case "sql", "psql", "mysql", "sqlite":
                Language(keywords: sqlKW, lineComment: ["--"], blockComment: ("/*", "*/"), tripleQuotes: false, capitalizedTypes: false, attributePrefix: nil, yamlKeys: false, jsonKeys: false, tags: false)
            case "html", "xml", "svg", "vue", "svelte":
                Language(keywords: [], lineComment: [], blockComment: ("<!--", "-->"), tripleQuotes: false, capitalizedTypes: false, attributePrefix: nil, yamlKeys: false, jsonKeys: false, tags: true)
            case "c", "cpp", "c++", "h", "hpp", "objc", "objective-c", "java", "kotlin", "kt", "cs", "csharp", "php", "scala", "dart":
                Language(keywords: cKW, lineComment: ["//"], blockComment: ("/*", "*/"), tripleQuotes: false, capitalizedTypes: true, attributePrefix: "@", yamlKeys: false, jsonKeys: false, tags: false)
            case "ruby", "rb":
                Language(keywords: rubyKW, lineComment: ["#"], blockComment: nil, tripleQuotes: false, capitalizedTypes: true, attributePrefix: "@", yamlKeys: false, jsonKeys: false, tags: false)
            case "css", "scss":
                Language(keywords: [], lineComment: ["//"], blockComment: ("/*", "*/"), tripleQuotes: false, capitalizedTypes: false, attributePrefix: "@", yamlKeys: true, jsonKeys: false, tags: false)
            default:
                Language(keywords: [], lineComment: ["//", "#"], blockComment: ("/*", "*/"), tripleQuotes: false, capitalizedTypes: false, attributePrefix: nil, yamlKeys: false, jsonKeys: false, tags: false)
            }
        }
    }

    /// Runs the scanner and returns coloured text. Cheap enough to run on the main thread for
    /// typical reply-sized blocks; the view caches it per (code, language, scheme).
    static func highlight(_ code: String, language: String?, palette: Palette) -> AttributedString {
        var out = AttributedString()
        for (text, token) in tokenize(code, language: Language.resolve(language)) {
            var run = AttributedString(text)
            switch token {
            case .plain: break
            case .keyword: run.foregroundColor = palette.keyword
            case .string: run.foregroundColor = palette.string
            case .comment: run.foregroundColor = palette.comment
            case .number: run.foregroundColor = palette.number
            case .type: run.foregroundColor = palette.type
            case .attribute: run.foregroundColor = palette.attribute
            case .key: run.foregroundColor = palette.key
            }
            out.append(run)
        }
        return out
    }

    // MARK: - Scanner

    static func tokenize(_ code: String, language lang: Language) -> [(String, Token)] {
        let chars = Array(code)
        var tokens: [(String, Token)] = []
        var i = 0
        var plain = ""
        var atLineStart = true

        func flushPlain() {
            if !plain.isEmpty { tokens.append((plain, .plain)); plain = "" }
        }
        func emit(_ s: String, _ t: Token) { flushPlain(); tokens.append((s, t)) }
        func starts(_ p: [Character], at j: Int) -> Bool {
            j + p.count <= chars.count && chars[j..<j + p.count].elementsEqual(p)
        }
        func readUntil(_ terminator: [Character], from j: Int) -> Int {
            var k = j
            while k < chars.count {
                if starts(terminator, at: k) { return k + terminator.count }
                k += 1
            }
            return chars.count
        }
        func isIdent(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

        while i < chars.count {
            let c = chars[i]

            // Block comment
            if let (open, close) = lang.blockComment, starts(open, at: i) {
                let end = readUntil(close, from: i + open.count)
                emit(String(chars[i..<end]), .comment); i = end; continue
            }
            // Line comment (shell/YAML `#` must not be inside a word; `//` never is)
            if let lc = lang.lineComment.first(where: { starts($0, at: i) }),
               lc != ["#"] || i == 0 || !isIdent(chars[i - 1]) {
                var end = i
                while end < chars.count, chars[end] != "\n" { end += 1 }
                emit(String(chars[i..<end]), .comment); i = end; continue
            }
            // Triple-quoted strings
            if lang.tripleQuotes, starts(Self.tripleQuote, at: i) {
                let end = readUntil(Self.tripleQuote, from: i + 3)
                emit(String(chars[i..<end]), .string); i = end; continue
            }
            // Quoted strings
            if c == "\"" || c == "'" || c == "`" {
                var j = i + 1
                while j < chars.count, chars[j] != c {
                    if chars[j] == "\\" { j += 1 }
                    if j < chars.count, chars[j] == "\n", c != "`" { break }
                    j += 1
                }
                let end = min(j + 1, chars.count)
                let text = String(chars[i..<end])
                // JSON: a string followed by a colon is a key.
                var k = end
                while k < chars.count, chars[k] == " " { k += 1 }
                let isKey = lang.jsonKeys && k < chars.count && chars[k] == ":"
                emit(text, isKey ? .key : .string); i = end; atLineStart = false; continue
            }
            // Tags
            if lang.tags, c == "<", i + 1 < chars.count, chars[i + 1].isLetter || chars[i + 1] == "/" {
                var j = i + 1
                if chars[j] == "/" { j += 1 }
                while j < chars.count, isIdent(chars[j]) || chars[j] == "-" || chars[j] == ":" { j += 1 }
                emit(String(chars[i..<j]), .keyword); i = j; continue
            }
            // Attributes / decorators / shell variables
            if let p = lang.attributePrefix, c == p, i + 1 < chars.count, isIdent(chars[i + 1]) || chars[i + 1] == "[" || chars[i + 1] == "{" {
                var j = i + 1
                if chars[j] == "[" { j = readUntil(["]"], from: j) }
                else if chars[j] == "{" { j = readUntil(["}"], from: j) }
                else { while j < chars.count, isIdent(chars[j]) { j += 1 } }
                emit(String(chars[i..<j]), .attribute); i = j; continue
            }
            // Numbers
            if c.isNumber, i == 0 || !isIdent(chars[i - 1]) {
                var j = i
                while j < chars.count, chars[j].isHexDigit || chars[j] == "." || chars[j] == "x" || chars[j] == "_" { j += 1 }
                emit(String(chars[i..<j]), .number); i = j; continue
            }
            // Identifiers
            if c.isLetter || c == "_" {
                var j = i
                while j < chars.count, isIdent(chars[j]) { j += 1 }
                let word = String(chars[i..<j])
                // YAML key: first word on the line followed by a colon.
                var k = j
                while k < chars.count, chars[k] == " " || chars[k] == "-" || isIdent(chars[k]) { k += 1 }
                if lang.yamlKeys, atLineStart, k < chars.count, chars[k] == ":" {
                    emit(String(chars[i..<k]), .key); i = k; atLineStart = false; continue
                }
                if lang.keywords.contains(word) || lang.keywords.contains(word.lowercased()) {
                    emit(word, .keyword)
                } else if lang.capitalizedTypes, let f = word.first, f.isUppercase, word.count > 1 {
                    emit(word, .type)
                } else if lang.tags, i > 0, chars[i - 1] == " " || chars[i - 1] == "\n" {
                    // attribute name inside a tag
                    var m = j
                    while m < chars.count, chars[m] == " " { m += 1 }
                    if m < chars.count, chars[m] == "=" { emit(word, .attribute) } else { plain += word }
                } else {
                    plain += word
                }
                i = j; atLineStart = false; continue
            }

            plain.append(c)
            if c == "\n" { atLineStart = true } else if c != " " && c != "\t" && c != "-" { atLineStart = false }
            i += 1
        }
        flushPlain()
        return tokens
    }

    private static let tripleQuote: [Character] = ["\"", "\"", "\""]

    // MARK: - Keyword sets

    private static let swiftKW: Set<String> = ["import", "let", "var", "func", "return", "if", "else", "guard", "for", "in", "while", "repeat", "switch", "case", "default", "break", "continue", "struct", "class", "enum", "protocol", "extension", "actor", "init", "deinit", "self", "Self", "super", "true", "false", "nil", "throws", "throw", "try", "catch", "async", "await", "some", "any", "where", "as", "is", "static", "private", "public", "internal", "fileprivate", "open", "override", "final", "mutating", "nonisolated", "lazy", "weak", "unowned", "inout", "typealias", "associatedtype", "defer", "do", "fallthrough", "subscript", "operator", "precedencegroup", "indirect", "convenience", "required", "dynamic", "willSet", "didSet", "get", "set"]
    private static let pythonKW: Set<String> = ["def", "class", "return", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "is", "import", "from", "as", "try", "except", "finally", "raise", "with", "yield", "lambda", "pass", "break", "continue", "global", "nonlocal", "assert", "del", "async", "await", "True", "False", "None", "self", "print"]
    private static let jsKW: Set<String> = ["const", "let", "var", "function", "return", "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "new", "delete", "typeof", "instanceof", "in", "of", "class", "extends", "super", "this", "import", "export", "from", "as", "async", "await", "try", "catch", "finally", "throw", "true", "false", "null", "undefined", "interface", "type", "enum", "implements", "public", "private", "protected", "readonly", "static", "yield", "void", "declare", "namespace"]
    private static let shellKW: Set<String> = ["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "until", "case", "esac", "function", "return", "exit", "export", "local", "source", "echo", "cd", "ls", "cat", "grep", "sed", "awk", "curl", "sudo", "apt", "brew", "pip", "npm", "git", "docker", "python", "python3", "ssh", "chmod", "mkdir", "rm", "cp", "mv", "set", "true", "false", "xargs", "find", "tail", "head", "hermes", "systemctl"]
    private static let goKW: Set<String> = ["package", "import", "func", "return", "var", "const", "type", "struct", "interface", "map", "chan", "go", "defer", "if", "else", "for", "range", "switch", "case", "default", "break", "continue", "select", "fallthrough", "goto", "nil", "true", "false", "make", "new", "len", "cap", "append", "error", "string", "int", "int64", "bool", "byte", "float64"]
    private static let rustKW: Set<String> = ["fn", "let", "mut", "pub", "use", "mod", "struct", "enum", "impl", "trait", "for", "in", "while", "loop", "if", "else", "match", "return", "self", "Self", "super", "crate", "as", "ref", "where", "async", "await", "move", "dyn", "const", "static", "unsafe", "type", "true", "false", "Some", "None", "Ok", "Err", "break", "continue"]
    private static let sqlKW: Set<String> = ["select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create", "table", "drop", "alter", "add", "join", "left", "right", "inner", "outer", "on", "group", "by", "order", "having", "limit", "offset", "as", "and", "or", "not", "null", "is", "in", "like", "distinct", "union", "primary", "key", "foreign", "references", "index", "view", "with", "case", "when", "then", "else", "end", "count", "sum", "avg", "min", "max", "begin", "commit", "rollback", "returning", "exists", "between", "asc", "desc", "true", "false"]
    private static let cKW: Set<String> = ["int", "char", "float", "double", "void", "long", "short", "unsigned", "signed", "bool", "struct", "union", "enum", "typedef", "const", "static", "extern", "inline", "return", "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "goto", "sizeof", "class", "public", "private", "protected", "virtual", "override", "new", "delete", "this", "namespace", "using", "template", "typename", "throw", "try", "catch", "true", "false", "nullptr", "NULL", "auto", "import", "package", "interface", "implements", "extends", "final", "abstract", "var", "val", "fun", "when", "object", "String", "let", "in", "is", "as", "null"]
    private static let rubyKW: Set<String> = ["def", "end", "class", "module", "if", "elsif", "else", "unless", "while", "until", "for", "in", "do", "return", "yield", "begin", "rescue", "ensure", "raise", "require", "include", "attr_accessor", "attr_reader", "self", "nil", "true", "false", "and", "or", "not", "then", "case", "when", "puts", "lambda", "proc"]
}
