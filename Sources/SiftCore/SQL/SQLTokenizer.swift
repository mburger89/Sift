/// What a stretch of SQL is, for colouring and for completion.
public enum SQLTokenKind: UInt8, Sendable {
    case keyword, identifier, quotedIdentifier, string, number, comment, parameter
    /// Named with a trailing underscore: `operator` is a Swift keyword.
    case operator_
    case punctuation, whitespace
}

/// One token. `range` holds UTF-8 offsets into the line (or the text) that was lexed.
public struct SQLToken: Sendable, Equatable {
    public var kind: SQLTokenKind
    public var range: Range<Int>

    public init(_ kind: SQLTokenKind, _ range: Range<Int>) {
        self.kind = kind
        self.range = range
    }
}

/// How a string literal ends: `'...'` closes at a lone quote (`''` is a quote); `E'...'` also takes `\` escapes.
public enum SQLStringKind: Sendable, Hashable {
    case standard, escape
}

/// What the lexer is inside at a line's end: the one thing the next line needs to know.
public enum SQLLexState: Sendable, Hashable {
    case normal
    /// Inside `/* ... */`, nested `depth` deep (at least 1).
    case blockComment(depth: Int)
    case string(SQLStringKind)
    /// Inside `$tag$ ... $tag$`; the tag may be empty (`$$`).
    case dollar(tag: String)
    case quotedIdent
}

/// A hand-written, regex-free lexer for PostgreSQL, one line at a time.
///
/// Unterminated strings, comments and dollar quotes run to the end of the line and hand their state on, so a line is
/// lexed from the state the line before it ended in.
public enum SQLLineLexer {
    public static func lex(_ line: Substring.UTF8View, from state: SQLLexState) -> (tokens: [SQLToken], end: SQLLexState) {
        if let result = line.withContiguousStorageIfAvailable({ lex(bytes: $0, from: state) }) { return result }
        let copy = Array(line)
        return copy.withUnsafeBufferPointer { lex(bytes: $0, from: state) }
    }

    /// The same, over bytes. The offsets in the tokens are indexes into `b`.
    public static func lex(bytes b: UnsafeBufferPointer<UInt8>, from state: SQLLexState) -> (tokens: [SQLToken], end: SQLLexState) {
        var tokens: [SQLToken] = []
        let n = b.count
        var i = 0
        var end = SQLLexState.normal

        // Continue what the previous line left open.
        switch state {
        case .normal:
            break
        case .blockComment(let depth):
            let (stop, left) = scanBlockComment(b, from: 0, depth: depth)
            if n > 0 { tokens.append(SQLToken(.comment, 0..<stop)) }
            i = stop
            if left > 0 { return (tokens, .blockComment(depth: left)) }
        case .string(let kind):
            let (stop, closed) = scanString(b, from: 0, kind: kind)
            if n > 0 { tokens.append(SQLToken(.string, 0..<stop)) }
            i = stop
            if !closed { return (tokens, .string(kind)) }
        case .quotedIdent:
            let (stop, closed) = scanQuoted(b, from: 0)
            if n > 0 { tokens.append(SQLToken(.quotedIdentifier, 0..<stop)) }
            i = stop
            if !closed { return (tokens, .quotedIdent) }
        case .dollar(let tag):
            let tagBytes = Array(tag.utf8)
            let (stop, closed) = scanDollar(b, from: 0, tag: tagBytes)
            if n > 0 { tokens.append(SQLToken(.string, 0..<stop)) }
            i = stop
            if !closed { return (tokens, .dollar(tag: tag)) }
        }

        while i < n {
            let c = b[i]
            let start = i
            let next: UInt8 = i + 1 < n ? b[i + 1] : 0
            if isSpace(c) {
                while i < n, isSpace(b[i]) { i += 1 }
                tokens.append(SQLToken(.whitespace, start..<i))
            } else if c == dash, next == dash {
                i = n
                tokens.append(SQLToken(.comment, start..<n))
            } else if c == slash, next == star {
                let (stop, left) = scanBlockComment(b, from: i + 2, depth: 1)
                i = stop
                tokens.append(SQLToken(.comment, start..<i))
                if left > 0 { end = .blockComment(depth: left) }
            } else if c == quote {
                let (stop, closed) = scanString(b, from: i + 1, kind: .standard)
                i = stop
                tokens.append(SQLToken(.string, start..<i))
                if !closed { end = .string(.standard) }
            } else if c == dquote {
                let (stop, closed) = scanQuoted(b, from: i + 1)
                i = stop
                tokens.append(SQLToken(.quotedIdentifier, start..<i))
                if !closed { end = .quotedIdent }
            } else if c == dollar {
                if isDigit(next) {
                    i += 1
                    while i < n, isDigit(b[i]) { i += 1 }
                    tokens.append(SQLToken(.parameter, start..<i))
                } else if let tagEnd = dollarTagEnd(b, at: i) {
                    let tag = Array(b[(i + 1)..<tagEnd])
                    let (stop, closed) = scanDollar(b, from: tagEnd + 1, tag: tag)
                    i = stop
                    tokens.append(SQLToken(.string, start..<i))
                    if !closed { end = .dollar(tag: String(decoding: tag, as: UTF8.self)) }
                } else {
                    i += 1
                    tokens.append(SQLToken(.operator_, start..<i))
                }
            } else if isDigit(c) || (c == dot && isDigit(next)) {
                i = scanNumber(b, from: i)
                tokens.append(SQLToken(.number, start..<i))
            } else if isIdentStart(c) {
                i += 1
                while i < n, isIdentPart(b[i]) { i += 1 }
                let after: UInt8 = i < n ? b[i] : 0
                let word = i - start
                let lead = c | 0x20
                if word == 1, after == quote, lead == 0x65 {            // E'...'
                    let (stop, closed) = scanString(b, from: i + 1, kind: .escape)
                    i = stop
                    tokens.append(SQLToken(.string, start..<i))
                    if !closed { end = .string(.escape) }
                } else if word == 1, after == quote, lead == 0x62 || lead == 0x78 || lead == 0x6E {   // B'..', X'..', N'..'
                    let (stop, closed) = scanString(b, from: i + 1, kind: .standard)
                    i = stop
                    tokens.append(SQLToken(.string, start..<i))
                    if !closed { end = .string(.standard) }
                } else if word == 1, lead == 0x75, after == amp, i + 1 < n, b[i + 1] == quote {     // U&'...'
                    let (stop, closed) = scanString(b, from: i + 2, kind: .standard)
                    i = stop
                    tokens.append(SQLToken(.string, start..<i))
                    if !closed { end = .string(.standard) }
                } else if word == 1, lead == 0x75, after == amp, i + 1 < n, b[i + 1] == dquote {    // U&"..."
                    let (stop, closed) = scanQuoted(b, from: i + 2)
                    i = stop
                    tokens.append(SQLToken(.quotedIdentifier, start..<i))
                    if !closed { end = .quotedIdent }
                } else {
                    let isKeyword = SQLKeywords.contains(bytes: b[start..<i])
                    tokens.append(SQLToken(isKeyword ? .keyword : .identifier, start..<i))
                }
            } else if isPunctuation(c) {
                i += 1
                tokens.append(SQLToken(.punctuation, start..<i))
            } else if isOperatorChar(c) {
                i += 1
                while i < n, isOperatorChar(b[i]) {
                    // A comment starts inside an operator run: `a+--b` is `a +` then a comment.
                    if b[i] == dash, i + 1 < n, b[i + 1] == dash { break }
                    if b[i] == slash, i + 1 < n, b[i + 1] == star { break }
                    i += 1
                }
                tokens.append(SQLToken(.operator_, start..<i))
            } else {
                i += 1
                tokens.append(SQLToken(.punctuation, start..<i))
            }
            if end != .normal { return (tokens, end) }
        }
        return (tokens, end)
    }

    // MARK: Scanners

    private static func scanBlockComment(_ b: UnsafeBufferPointer<UInt8>, from start: Int, depth startDepth: Int) -> (end: Int, depth: Int) {
        let n = b.count
        var i = start
        var depth = startDepth
        while i < n {
            if b[i] == slash, i + 1 < n, b[i + 1] == star {
                depth += 1
                i += 2
            } else if b[i] == star, i + 1 < n, b[i + 1] == slash {
                depth -= 1
                i += 2
                if depth == 0 { return (i, 0) }
            } else {
                i += 1
            }
        }
        return (n, depth)
    }

    private static func scanString(_ b: UnsafeBufferPointer<UInt8>, from start: Int, kind: SQLStringKind) -> (end: Int, closed: Bool) {
        let n = b.count
        var i = start
        while i < n {
            let c = b[i]
            if kind == .escape, c == backslash {
                i += 2
                continue
            }
            if c == quote {
                if i + 1 < n, b[i + 1] == quote {
                    i += 2
                    continue
                }
                return (i + 1, true)
            }
            i += 1
        }
        return (n, false)
    }

    private static func scanQuoted(_ b: UnsafeBufferPointer<UInt8>, from start: Int) -> (end: Int, closed: Bool) {
        let n = b.count
        var i = start
        while i < n {
            if b[i] == dquote {
                if i + 1 < n, b[i + 1] == dquote {
                    i += 2
                    continue
                }
                return (i + 1, true)
            }
            i += 1
        }
        return (n, false)
    }

    /// The offset of the `$` that closes `$tag$` at `b[i]`, or nil when `$` here does not open a dollar quote.
    private static func dollarTagEnd(_ b: UnsafeBufferPointer<UInt8>, at i: Int) -> Int? {
        let n = b.count
        var j = i + 1
        if j < n, isIdentStart(b[j]), b[j] != dollar {
            j += 1
            while j < n, isIdentPart(b[j]), b[j] != dollar { j += 1 }
        }
        return j < n && b[j] == dollar ? j : nil
    }

    private static func scanDollar(_ b: UnsafeBufferPointer<UInt8>, from start: Int, tag: [UInt8]) -> (end: Int, closed: Bool) {
        let n = b.count
        let width = tag.count + 2
        var i = start
        while i + width <= n {
            if b[i] == dollar, b[i + width - 1] == dollar {
                var same = true
                for k in 0..<tag.count where b[i + 1 + k] != tag[k] {
                    same = false
                    break
                }
                if same { return (i + width, true) }
            }
            i += 1
        }
        return (n, false)
    }

    private static func scanNumber(_ b: UnsafeBufferPointer<UInt8>, from start: Int) -> Int {
        let n = b.count
        var i = start
        if b[i] == 0x30, i + 1 < n, [0x78, 0x58, 0x6F, 0x4F, 0x62, 0x42].contains(b[i + 1]), i + 2 < n, isHex(b[i + 2]) {
            i += 2
            while i < n, isHex(b[i]) || b[i] == underscore { i += 1 }
            return i
        }
        while i < n, isDigit(b[i]) || (b[i] == underscore && i + 1 < n && isDigit(b[i + 1])) { i += 1 }
        if i < n, b[i] == dot, i + 1 < n, isDigit(b[i + 1]) {
            i += 1
            while i < n, isDigit(b[i]) || (b[i] == underscore && i + 1 < n && isDigit(b[i + 1])) { i += 1 }
        }
        if i < n, b[i] == 0x65 || b[i] == 0x45 {
            var j = i + 1
            if j < n, b[j] == 0x2B || b[j] == dash { j += 1 }
            if j < n, isDigit(b[j]) {
                while j < n, isDigit(b[j]) { j += 1 }
                i = j
            }
        }
        return i
    }

    // MARK: Bytes

    private static let dash: UInt8 = 0x2D
    private static let slash: UInt8 = 0x2F
    private static let star: UInt8 = 0x2A
    private static let quote: UInt8 = 0x27
    private static let dquote: UInt8 = 0x22
    private static let dollar: UInt8 = 0x24
    private static let dot: UInt8 = 0x2E
    private static let amp: UInt8 = 0x26
    private static let backslash: UInt8 = 0x5C
    private static let underscore: UInt8 = 0x5F

    private static func isSpace(_ c: UInt8) -> Bool { c == 0x20 || (c >= 0x09 && c <= 0x0D) }
    private static func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
    private static func isHex(_ c: UInt8) -> Bool { isDigit(c) || (c | 0x20 >= 0x61 && c | 0x20 <= 0x66) }
    private static func isIdentStart(_ c: UInt8) -> Bool { (c | 0x20 >= 0x61 && c | 0x20 <= 0x7A) || c == underscore || c >= 0x80 }
    private static func isIdentPart(_ c: UInt8) -> Bool { isIdentStart(c) || isDigit(c) || c == dollar }
    private static func isPunctuation(_ c: UInt8) -> Bool {
        c == 0x2C || c == 0x3B || c == 0x28 || c == 0x29 || c == dot || c == 0x5B || c == 0x5D
    }
    private static func isOperatorChar(_ c: UInt8) -> Bool {
        switch c {
        case 0x2B, dash, star, slash, 0x3C, 0x3D, 0x3E, 0x7E, 0x21, 0x40, 0x23, 0x25, 0x5E, amp, 0x7C, 0x60, 0x3F, 0x3A: return true
        default: return false
        }
    }
}

/// Per-line tokens of a buffer, kept between edits.
///
/// Each line remembers the state it starts in. After an edit the cache lexes the edited lines, then goes on only until a
/// line's start state equals what it had before (everything after is then unchanged), so a keystroke costs the lines it
/// touched and, when it opens or closes a comment or string, the lines whose state it changed.
public final class SQLTokenCache {
    private var starts: [SQLLexState] = []
    private var lineTokens: [[SQLToken]] = []
    private var finalState = SQLLexState.normal
    /// How many lines have been lexed since the cache was made: for cost tests.
    public private(set) var relexedTotal = 0

    public init() {}

    /// The number of lines the cache holds.
    public var lineCount: Int { starts.count }

    /// The state line `line` starts in.
    public func startState(line: Int) -> SQLLexState { starts[line] }

    /// The state the last line ends in.
    public var endState: SQLLexState { finalState }

    /// The tokens of a line, with offsets in the line's UTF-8 bytes. Empty for a line the cache does not hold.
    public func tokens(line: Int) -> [SQLToken] { lineTokens.indices.contains(line) ? lineTokens[line] : [] }

    /// Brings the cache up to the text after an edit and returns the lines it lexed again.
    ///
    /// - Parameters:
    ///   - lines: the text of line `n`, without its newline.
    ///   - lineCount: how many lines there are now.
    ///   - editedFrom: the first line the edit touched.
    ///   - replacing: how many of the old lines, starting at `editedFrom`, the edit replaced (the new count follows from
    ///     `lineCount`). Without it the edit is taken to have changed one line, or, when the line count changed, everything
    ///     from `editedFrom` on is lexed again.
    @discardableResult
    public func update(lines: (Int) -> Substring, lineCount: Int, editedFrom: Int, replacing oldSpan: Int? = nil) -> Range<Int> {
        guard lineCount > 0 else {
            starts = []
            lineTokens = []
            finalState = .normal
            return 0..<0
        }
        let oldCount = starts.count
        var first = max(0, min(editedFrom, lineCount - 1))
        let delta = lineCount - oldCount
        var spans: (old: Int, new: Int)?
        if oldCount > 0 {
            if let oldSpan, first + oldSpan <= oldCount, oldSpan + delta >= 0 {
                spans = (oldSpan, oldSpan + delta)
            } else if oldSpan == nil, delta == 0, first < oldCount {
                spans = (1, 1)
            }
        }
        let startState: SQLLexState
        let editedEnd: Int
        if let spans, first < oldCount {
            startState = starts[first]
            starts.replaceSubrange(first..<(first + spans.old), with: repeatElement(.normal, count: spans.new))
            lineTokens.replaceSubrange(first..<(first + spans.old), with: repeatElement([], count: spans.new))
            editedEnd = first + spans.new
        } else {
            // Unknown shape of the edit, or the first lexing: everything from `first` on is lexed again.
            if oldCount == 0 { first = 0 }
            startState = first == 0 || oldCount == 0 ? .normal : (first < oldCount ? starts[first] : finalState)
            let keep = min(first, oldCount)
            starts.removeSubrange(keep...)
            lineTokens.removeSubrange(keep...)
            starts.append(contentsOf: repeatElement(.normal, count: lineCount - keep))
            lineTokens.append(contentsOf: repeatElement([], count: lineCount - keep))
            first = min(first, keep)
            editedEnd = lineCount
        }
        var state = startState
        var i = first
        while i < lineCount {
            if i >= editedEnd, starts[i] == state { break }
            starts[i] = state
            let result = SQLLineLexer.lex(lines(i).utf8, from: state)
            lineTokens[i] = result.tokens
            state = result.end
            i += 1
        }
        if i == lineCount { finalState = state }
        relexedTotal += i - first
        return first..<i
    }
}
