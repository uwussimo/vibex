import AppKit
import SwiftUI

/// A small, dependency-free highlighter for diffs: keywords, types, strings, comments, numbers,
/// attributes, markup tags and keys. Line-based with state carried between lines, so block
/// comments and multi-line strings stay coloured across a hunk. Not a parser; it only has to be
/// right often enough to make a diff easier to read.
nonisolated enum SyntaxToken: Sendable {
    case keyword, type, string, comment, number, attribute, literal, tag, key, function
}

nonisolated struct SyntaxSpan: Equatable, Sendable {
    let start: Int
    let length: Int
    let token: SyntaxToken
}

nonisolated struct Language: Sendable {
    struct StringRule: Sendable, Equatable {
        let open: String
        let close: String
        let multiline: Bool
        var escapes = true
    }

    let name: String
    var keywords: Set<String> = []
    var literals: Set<String> = []
    var lineComments: [String] = []
    var blockComment: (open: String, close: String)?
    var strings: [StringRule] = [.init(open: "\"", close: "\"", multiline: false)]
    /// `@Observable`, `#if`, `@decorator`.
    var attributePrefixes: [Character] = []
    var capitalizedAreTypes = true
    var caseInsensitive = false
    /// `"key":` in JSON, `key:` in YAML and CSS.
    var keysBeforeColon = false
    /// `<tag attr="…">` in HTML and XML.
    var markup = false
    /// `name(` is a function call.
    var calls = true
    /// `$VAR` in shells.
    var dollarVariables = false

    /// The language for a file, by extension or well-known name.
    static func forPath(_ path: String) -> Language? {
        let name = (path as NSString).lastPathComponent.lowercased()
        switch name {
        case "makefile", "gnumakefile": return .shell
        case "dockerfile": return .shell
        case "podfile", "gemfile", "fastfile", "appfile": return .ruby
        case "package.resolved", ".eslintrc", ".prettierrc": return .json
        default: break
        }
        switch (name as NSString).pathExtension {
        case "swift": return .swift
        case "js", "jsx", "mjs", "cjs", "ts", "tsx", "mts", "cts": return .javaScript
        case "py", "pyi": return .python
        case "go": return .go
        case "rs": return .rust
        case "kt", "kts", "java", "scala", "groovy", "gradle": return .kotlin
        case "c", "h", "m", "mm", "cpp", "cc", "cxx", "hpp", "hh", "metal": return .cFamily
        case "cs": return .cSharp
        case "dart": return .dart
        case "rb", "rake", "podspec": return .ruby
        case "php": return .php
        case "sh", "bash", "zsh", "fish", "command", "env": return .shell
        case "json", "jsonc", "json5", "xcstrings", "babelrc": return .json
        case "yml", "yaml": return .yaml
        case "toml", "ini", "cfg", "conf", "properties": return .toml
        case "css", "scss", "sass", "less": return .css
        case "html", "htm", "xml", "svg", "plist", "storyboard", "xib", "entitlements", "vue", "svelte", "xcscheme": return .markup
        case "sql": return .sql
        case "md", "markdown", "mdx": return .markdown
        default: return nil
        }
    }

    // MARK: - Languages

    static let swift = Language(
        name: "Swift",
        keywords: ["actor", "any", "as", "associatedtype", "async", "await", "borrowing", "break", "case", "catch", "class", "consume", "consuming", "continue", "convenience", "default", "defer", "deinit", "didSet", "do", "dynamic", "each", "else", "enum", "extension", "fallthrough", "fileprivate", "final", "for", "func", "get", "guard", "if", "import", "in", "indirect", "init", "inout", "internal", "is", "isolated", "lazy", "let", "macro", "mutating", "nonisolated", "nonmutating", "open", "operator", "optional", "override", "package", "precedencegroup", "private", "protocol", "public", "repeat", "required", "rethrows", "return", "self", "Self", "set", "some", "static", "struct", "subscript", "super", "switch", "throw", "throws", "try", "typealias", "unowned", "var", "weak", "where", "while", "willSet"],
        literals: ["true", "false", "nil"],
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        strings: [.init(open: "\"\"\"", close: "\"\"\"", multiline: true), .init(open: "\"", close: "\"", multiline: false)],
        attributePrefixes: ["@", "#"]
    )

    static let javaScript = Language(
        name: "JavaScript",
        keywords: ["abstract", "as", "async", "await", "break", "case", "catch", "class", "const", "constructor", "continue", "debugger", "declare", "default", "delete", "do", "else", "enum", "export", "extends", "finally", "for", "from", "function", "get", "if", "implements", "import", "in", "instanceof", "interface", "keyof", "let", "namespace", "new", "of", "private", "protected", "public", "readonly", "return", "satisfies", "set", "static", "super", "switch", "this", "throw", "try", "type", "typeof", "var", "void", "while", "with", "yield"],
        literals: ["true", "false", "null", "undefined", "NaN", "Infinity"],
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        strings: [.init(open: "`", close: "`", multiline: true), .init(open: "\"", close: "\"", multiline: false), .init(open: "'", close: "'", multiline: false)],
        attributePrefixes: ["@"]
    )

    static let python = Language(
        name: "Python",
        keywords: ["and", "as", "assert", "async", "await", "break", "case", "class", "continue", "def", "del", "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "match", "nonlocal", "not", "or", "pass", "raise", "return", "self", "try", "while", "with", "yield"],
        literals: ["True", "False", "None"],
        lineComments: ["#"],
        strings: [
            .init(open: "\"\"\"", close: "\"\"\"", multiline: true), .init(open: "'''", close: "'''", multiline: true),
            .init(open: "\"", close: "\"", multiline: false), .init(open: "'", close: "'", multiline: false),
        ],
        attributePrefixes: ["@"]
    )

    static let go = Language(
        name: "Go",
        keywords: ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct", "switch", "type", "var", "string", "int", "int64", "int32", "uint", "uint64", "byte", "rune", "bool", "error", "float64", "float32", "any"],
        literals: ["true", "false", "nil", "iota"],
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        strings: [.init(open: "`", close: "`", multiline: true), .init(open: "\"", close: "\"", multiline: false), .init(open: "'", close: "'", multiline: false)]
    )

    static let rust = Language(
        name: "Rust",
        keywords: ["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super", "trait", "type", "unsafe", "use", "where", "while"],
        literals: ["true", "false", "None", "Some", "Ok", "Err"],
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        attributePrefixes: ["#"]
    )

    static let kotlin = Language(
        name: "Kotlin",
        keywords: ["abstract", "as", "break", "by", "catch", "class", "companion", "const", "continue", "data", "do", "else", "enum", "extends", "final", "finally", "for", "fun", "if", "implements", "import", "in", "init", "inline", "interface", "internal", "is", "lateinit", "new", "object", "open", "override", "package", "private", "protected", "public", "return", "sealed", "static", "super", "suspend", "switch", "this", "throw", "throws", "try", "val", "var", "void", "when", "while", "int", "boolean", "long", "double", "float", "char"],
        literals: ["true", "false", "null"],
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        strings: [.init(open: "\"\"\"", close: "\"\"\"", multiline: true), .init(open: "\"", close: "\"", multiline: false), .init(open: "'", close: "'", multiline: false)],
        attributePrefixes: ["@"]
    )

    static let cFamily = Language(
        name: "C",
        keywords: ["auto", "break", "case", "char", "class", "const", "constexpr", "continue", "default", "delete", "do", "double", "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long", "namespace", "new", "nullptr", "private", "protected", "public", "register", "return", "short", "signed", "sizeof", "static", "struct", "switch", "template", "this", "typedef", "typename", "union", "unsigned", "using", "virtual", "void", "volatile", "while", "self", "super", "id", "instancetype", "nonatomic", "strong", "weak", "readonly", "property", "interface", "implementation", "end", "BOOL", "YES", "NO"],
        literals: ["true", "false", "NULL", "nil"],
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        strings: [.init(open: "\"", close: "\"", multiline: false), .init(open: "'", close: "'", multiline: false)],
        attributePrefixes: ["#", "@"]
    )

    static let cSharp = Language(
        name: "C#",
        keywords: ["abstract", "as", "async", "await", "base", "bool", "break", "case", "catch", "class", "const", "continue", "decimal", "default", "delegate", "do", "double", "else", "enum", "event", "explicit", "extern", "finally", "float", "for", "foreach", "get", "if", "implicit", "in", "int", "interface", "internal", "is", "lock", "long", "namespace", "new", "object", "operator", "out", "override", "params", "private", "protected", "public", "readonly", "record", "ref", "return", "sealed", "set", "static", "string", "struct", "switch", "this", "throw", "try", "typeof", "using", "var", "virtual", "void", "while"],
        literals: ["true", "false", "null"],
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        strings: [.init(open: "\"", close: "\"", multiline: false), .init(open: "'", close: "'", multiline: false)],
        attributePrefixes: ["#"]
    )

    static let dart = Language(
        name: "Dart",
        keywords: ["abstract", "as", "async", "await", "break", "case", "catch", "class", "const", "continue", "default", "do", "dynamic", "else", "enum", "export", "extends", "extension", "factory", "final", "finally", "for", "get", "if", "implements", "import", "in", "is", "late", "library", "mixin", "new", "on", "operator", "part", "required", "return", "set", "static", "super", "switch", "this", "throw", "try", "typedef", "var", "void", "while", "with", "yield"],
        literals: ["true", "false", "null"],
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        strings: [.init(open: "'''", close: "'''", multiline: true), .init(open: "\"", close: "\"", multiline: false), .init(open: "'", close: "'", multiline: false)],
        attributePrefixes: ["@"]
    )

    static let ruby = Language(
        name: "Ruby",
        keywords: ["alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else", "elsif", "end", "ensure", "for", "if", "in", "module", "next", "not", "or", "redo", "require", "rescue", "retry", "return", "self", "super", "then", "undef", "unless", "until", "when", "while", "yield", "attr_accessor", "attr_reader", "private"],
        literals: ["true", "false", "nil"],
        lineComments: ["#"],
        strings: [.init(open: "\"", close: "\"", multiline: false), .init(open: "'", close: "'", multiline: false)],
        attributePrefixes: [":"]
    )

    static let php = Language(
        name: "PHP",
        keywords: ["abstract", "array", "as", "break", "case", "catch", "class", "const", "continue", "default", "do", "echo", "else", "elseif", "extends", "final", "finally", "fn", "for", "foreach", "function", "if", "implements", "interface", "namespace", "new", "private", "protected", "public", "return", "static", "switch", "throw", "trait", "try", "use", "var", "while"],
        literals: ["true", "false", "null"],
        lineComments: ["//", "#"],
        blockComment: ("/*", "*/"),
        strings: [.init(open: "\"", close: "\"", multiline: false), .init(open: "'", close: "'", multiline: false)],
        dollarVariables: true
    )

    static let shell = Language(
        name: "Shell",
        keywords: ["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "until", "case", "esac", "function", "return", "local", "export", "set", "unset", "readonly", "shift", "exit", "source", "echo", "cd", "test", "trap", "eval", "exec", "sudo", "FROM", "RUN", "COPY", "CMD", "ENV", "WORKDIR", "ARG", "ENTRYPOINT", "EXPOSE"],
        literals: ["true", "false"],
        lineComments: ["#"],
        strings: [.init(open: "\"", close: "\"", multiline: true), .init(open: "'", close: "'", multiline: true, escapes: false)],
        capitalizedAreTypes: false,
        calls: false,
        dollarVariables: true
    )

    static let json = Language(
        name: "JSON",
        literals: ["true", "false", "null"],
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        capitalizedAreTypes: false,
        keysBeforeColon: true,
        calls: false
    )

    static let yaml = Language(
        name: "YAML",
        literals: ["true", "false", "null", "yes", "no", "on", "off", "~"],
        lineComments: ["#"],
        strings: [.init(open: "\"", close: "\"", multiline: false), .init(open: "'", close: "'", multiline: false, escapes: false)],
        attributePrefixes: ["&", "*", "!"],
        capitalizedAreTypes: false,
        keysBeforeColon: true,
        calls: false
    )

    static let toml = Language(
        name: "TOML",
        literals: ["true", "false"],
        lineComments: ["#", ";"],
        strings: [.init(open: "\"\"\"", close: "\"\"\"", multiline: true), .init(open: "\"", close: "\"", multiline: false), .init(open: "'", close: "'", multiline: false, escapes: false)],
        capitalizedAreTypes: false,
        calls: false
    )

    static let css = Language(
        name: "CSS",
        keywords: ["important", "media", "import", "keyframes", "supports", "font-face", "root", "hover", "focus", "active", "before", "after", "not", "has", "where", "is"],
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        strings: [.init(open: "\"", close: "\"", multiline: false), .init(open: "'", close: "'", multiline: false)],
        attributePrefixes: ["@", "$", "--"].compactMap(\.first),
        capitalizedAreTypes: false,
        keysBeforeColon: true
    )

    static let markup = Language(
        name: "Markup",
        blockComment: ("<!--", "-->"),
        strings: [.init(open: "\"", close: "\"", multiline: false), .init(open: "'", close: "'", multiline: false)],
        capitalizedAreTypes: false,
        markup: true,
        calls: false
    )

    static let sql = Language(
        name: "SQL",
        keywords: ["select", "from", "where", "and", "or", "not", "insert", "into", "values", "update", "set", "delete", "create", "table", "index", "view", "drop", "alter", "add", "column", "primary", "key", "foreign", "references", "join", "left", "right", "inner", "outer", "on", "as", "group", "by", "order", "having", "limit", "offset", "distinct", "union", "all", "case", "when", "then", "else", "end", "is", "in", "like", "between", "exists", "default", "unique", "constraint", "integer", "text", "varchar", "boolean", "timestamp", "begin", "commit", "rollback"],
        literals: ["true", "false", "null"],
        lineComments: ["--"],
        blockComment: ("/*", "*/"),
        strings: [.init(open: "'", close: "'", multiline: false), .init(open: "\"", close: "\"", multiline: false)],
        capitalizedAreTypes: false,
        caseInsensitive: true
    )

    static let markdown = Language(
        name: "Markdown",
        strings: [.init(open: "`", close: "`", multiline: false, escapes: false)],
        capitalizedAreTypes: false,
        calls: false
    )
}

/// Tokenizes one line at a time; `State` carries an open block comment or string to the next line.
nonisolated struct SyntaxHighlighter: Sendable {
    struct State: Equatable, Sendable {
        var inBlockComment = false
        var openString: Language.StringRule?
    }

    let language: Language

    func spans(for line: String, state: inout State) -> [SyntaxSpan] {
        let chars = Array(line.utf16)
        var spans: [SyntaxSpan] = []
        var i = 0
        let count = chars.count

        func matches(_ token: String, at index: Int) -> Bool {
            let utf = Array(token.utf16)
            guard index + utf.count <= count else { return false }
            for (offset, unit) in utf.enumerated() where chars[index + offset] != unit { return false }
            return true
        }
        func add(_ start: Int, _ end: Int, _ token: SyntaxToken) {
            if end > start { spans.append(SyntaxSpan(start: start, length: end - start, token: token)) }
        }
        /// Scans to the closing delimiter; returns the index after it, or nil when the line ends first.
        func closeString(_ rule: Language.StringRule, from start: Int) -> Int? {
            var j = start
            while j < count {
                if rule.escapes, chars[j] == 0x5C { j += 2; continue } // backslash
                if matches(rule.close, at: j) { return j + rule.close.utf16.count }
                j += 1
            }
            return nil
        }

        // Continue whatever the previous line left open.
        if state.inBlockComment, let block = language.blockComment {
            var j = 0
            while j < count, !matches(block.close, at: j) { j += 1 }
            if j < count {
                add(0, j + block.close.utf16.count, .comment)
                i = j + block.close.utf16.count
                state.inBlockComment = false
            } else {
                add(0, count, .comment)
                return spans
            }
        } else if let rule = state.openString {
            if let end = closeString(rule, from: 0) {
                add(0, end, .string)
                i = end
                state.openString = nil
            } else {
                add(0, count, .string)
                return spans
            }
        }

        // Markdown headings and quotes colour the whole line.
        if language.name == "Markdown", i == 0 {
            let trimmed = line.drop { $0 == " " }
            if trimmed.hasPrefix("#") { add(0, count, .keyword); return spans }
            if trimmed.hasPrefix(">") { add(0, count, .comment); return spans }
        }

        // YAML / TOML style `key:` at the start of a line, and TOML [sections].
        if language.keysBeforeColon || language.name == "TOML", i == 0 {
            var j = 0
            while j < count, chars[j] == 0x20 || chars[j] == 0x09 || chars[j] == 0x2D { j += 1 } // spaces, tabs, "- "
            if language.name == "TOML", j < count, chars[j] == 0x5B { add(j, count, .type); return spans }
            var k = j
            while k < count, isIdentifier(chars[k]) || chars[k] == 0x2D || chars[k] == 0x2E { k += 1 }
            if k > j, k < count, chars[k] == 0x3A || (language.name == "TOML" && chars[k] == 0x3D) || (language.name == "TOML" && chars[k] == 0x20) {
                if language.name != "JSON" { add(j, k, .key); i = k }
            }
        }

        while i < count {
            let c = chars[i]

            if let block = language.blockComment, matches(block.open, at: i) {
                var j = i + block.open.utf16.count
                while j < count, !matches(block.close, at: j) { j += 1 }
                if j < count {
                    add(i, j + block.close.utf16.count, .comment)
                    i = j + block.close.utf16.count
                    continue
                }
                add(i, count, .comment)
                state.inBlockComment = true
                return spans
            }
            if language.lineComments.contains(where: { matches($0, at: i) }) {
                // `#` inside a word (e.g. a URL fragment) is not a comment in shells.
                if !(language.name == "Shell" && i > 0 && chars[i - 1] != 0x20 && chars[i - 1] != 0x09) {
                    add(i, count, .comment)
                    return spans
                }
            }
            if let rule = language.strings.first(where: { matches($0.open, at: i) }) {
                let start = i
                if let end = closeString(rule, from: i + rule.open.utf16.count) {
                    // JSON-style keys: a string followed by `:`.
                    var k = end
                    while k < count, chars[k] == 0x20 { k += 1 }
                    let isKey = language.keysBeforeColon && k < count && chars[k] == 0x3A
                    add(start, end, isKey ? .key : .string)
                    i = end
                    continue
                }
                add(start, count, .string)
                if rule.multiline { state.openString = rule }
                return spans
            }
            if language.markup, c == 0x3C { // <
                var j = i + 1
                if j < count, chars[j] == 0x2F || chars[j] == 0x3F || chars[j] == 0x21 { j += 1 } // / ? !
                let nameStart = j
                while j < count, isIdentifier(chars[j]) || chars[j] == 0x2D || chars[j] == 0x3A || chars[j] == 0x2E { j += 1 }
                if j > nameStart {
                    add(nameStart, j, .tag)
                    i = j
                    continue
                }
            }
            if language.dollarVariables, c == 0x24 { // $
                var j = i + 1
                if j < count, chars[j] == 0x7B { // ${…}
                    while j < count, chars[j] != 0x7D { j += 1 }
                    j = min(j + 1, count)
                } else {
                    while j < count, isIdentifier(chars[j]) { j += 1 }
                }
                if j > i + 1 { add(i, j, .attribute); i = j; continue }
            }
            if let prefix = language.attributePrefixes.first(where: { $0.utf16.first == c }), i + 1 < count,
               isIdentifierStart(chars[i + 1]) || (prefix == "-" && chars[i + 1] == 0x2D) {
                var j = i + 1
                while j < count, isIdentifier(chars[j]) || chars[j] == 0x2D { j += 1 }
                add(i, j, .attribute)
                i = j
                continue
            }
            if isDigit(c) || (c == 0x2E && i + 1 < count && isDigit(chars[i + 1]) && (i == 0 || !isIdentifier(chars[i - 1]))) {
                guard i == 0 || !isIdentifier(chars[i - 1]) else { i += 1; continue }
                var j = i + 1
                while j < count, isIdentifier(chars[j]) || chars[j] == 0x2E || chars[j] == 0x5F { j += 1 }
                add(i, j, .number)
                i = j
                continue
            }
            if isIdentifierStart(c) {
                var j = i + 1
                while j < count, isIdentifier(chars[j]) || (language.name == "CSS" && chars[j] == 0x2D) { j += 1 }
                let word = String(utf16CodeUnits: Array(chars[i..<j]), count: j - i)
                let lookup = language.caseInsensitive ? word.lowercased() : word
                if language.keysBeforeColon, language.name == "CSS", j < count, chars[j] == 0x3A, !language.keywords.contains(lookup) {
                    add(i, j, .key)
                } else if language.keywords.contains(lookup) {
                    add(i, j, .keyword)
                } else if language.literals.contains(lookup) {
                    add(i, j, .literal)
                } else if language.markup, j < count, chars[j] == 0x3D { // attr=
                    add(i, j, .attribute)
                } else if language.capitalizedAreTypes, let first = word.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first) {
                    add(i, j, .type)
                } else if language.calls, j < count, chars[j] == 0x28 { // (
                    add(i, j, .function)
                }
                i = j
                continue
            }
            i += 1
        }
        return spans
    }

    private func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }
    private func isIdentifierStart(_ c: UInt16) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c > 0x7F
    }
    private func isIdentifier(_ c: UInt16) -> Bool { isIdentifierStart(c) || isDigit(c) }
}

/// Highlights both sides of a diff, keeping old-file and new-file state separate so a comment
/// opened in a removed line doesn't colour the added lines after it.
nonisolated enum DiffHighlighter {
    static func highlight(_ diff: FileDiff, path: String) -> [Int: [SyntaxSpan]] {
        guard let language = Language.forPath(path) else { return [:] }
        let highlighter = SyntaxHighlighter(language: language)
        var result: [Int: [SyntaxSpan]] = [:]
        for hunk in diff.hunks {
            var old = SyntaxHighlighter.State()
            var new = SyntaxHighlighter.State()
            for line in hunk.lines {
                switch line.kind {
                case .context:
                    // Both files see context lines; follow the new file's state and keep the old in step.
                    result[line.id] = highlighter.spans(for: line.text, state: &new)
                    old = new
                case .removed:
                    result[line.id] = highlighter.spans(for: line.text, state: &old)
                case .added:
                    result[line.id] = highlighter.spans(for: line.text, state: &new)
                }
            }
        }
        return result
    }
}

/// Xcode's default palette, in light and dark.
enum SyntaxPalette {
    static func color(_ token: SyntaxToken) -> Color {
        Color(nsColor: nsColor(token))
    }

    static func nsColor(_ token: SyntaxToken) -> NSColor {
        switch token {
        case .keyword: dynamic(light: 0xAD3DA4, dark: 0xFF7AB2)
        case .type: dynamic(light: 0x3E8087, dark: 0xDABAFF)
        case .string: dynamic(light: 0xC41A16, dark: 0xFF8170)
        case .comment: dynamic(light: 0x5D6C79, dark: 0x7F8C98)
        case .number: dynamic(light: 0x1C00CF, dark: 0xD9C97C)
        case .attribute: dynamic(light: 0x947100, dark: 0xFD8F3F)
        case .literal: dynamic(light: 0xAD3DA4, dark: 0xFF7AB2)
        case .tag: dynamic(light: 0x0B4F79, dark: 0x6BDFFF)
        case .key: dynamic(light: 0x326D74, dark: 0x67B7A4)
        case .function: dynamic(light: 0x326D74, dark: 0x67B7A4)
        }
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        }
    }
}
