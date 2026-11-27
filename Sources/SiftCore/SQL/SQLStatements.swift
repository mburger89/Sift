/// Statement boundaries in a SQL text, found with the tokenizer so a `;` inside a string, a comment, a dollar quote or
/// a quoted identifier never splits.
public enum SQLStatements {
    /// A top-level `;` ends a statement. The ranges leave out the `;` and the whitespace around the statement, and a
    /// stretch with nothing but whitespace and comments is not a statement.
    public static func split(_ text: String) -> [Range<String.Index>] {
        segments(of: text).filter { !$0.isBlank }.map { range(of: $0.trimmed, in: text) }
    }

    /// The statement the caret at `offset` belongs to: the one it is inside or touching the end of; a caret right after
    /// a `;` belongs to the next statement. When that one is blank (the caret follows the last `;`) it is the statement
    /// before. Nil when there is no statement at all.
    public static func statement(at offset: String.Index, in text: String) -> Range<String.Index>? {
        let caret = text.utf8.distance(from: text.utf8.startIndex, to: offset)
        let all = segments(of: text)
        guard let here = all.firstIndex(where: { caret >= $0.start && caret <= $0.end }) else { return nil }
        if !all[here].isBlank { return range(of: all[here].trimmed, in: text) }
        guard let before = all[..<here].last(where: { !$0.isBlank }) else { return nil }
        return range(of: before.trimmed, in: text)
    }

    /// The first word of a statement, upper-cased, skipping whitespace, comments and opening parentheses
    /// (`(SELECT 1)` gives `SELECT`). Nil when the statement starts with anything else.
    public static func leadingKeyword(_ statement: Substring) -> String? {
        var state = SQLLexState.normal
        for lineText in statement.split(separator: "\n", omittingEmptySubsequences: false) {
            let (tokens, end) = SQLLineLexer.lex(lineText.utf8, from: state)
            state = end
            let bytes = Array(lineText.utf8)
            for token in tokens {
                switch token.kind {
                case .whitespace, .comment: continue
                case .punctuation where bytes[token.range.lowerBound] == 0x28: continue
                case .keyword, .identifier:
                    return String(decoding: bytes[token.range], as: UTF8.self).uppercased()
                default: return nil
                }
            }
        }
        return nil
    }

    /// The UTF-8 offset in `text` of the 1-based position the server reports for an error. The server counts characters
    /// (code points) of the text it was sent, so a multi-byte character before the error counts once. A position past
    /// the end clamps to the end.
    public static func utf8Offset(ofPosition position: Int, in text: String) -> Int {
        let scalars = text.unicodeScalars
        let index = scalars.index(scalars.startIndex, offsetBy: max(0, position - 1), limitedBy: scalars.endIndex) ?? scalars.endIndex
        return text.utf8.distance(from: text.utf8.startIndex, to: index)
    }

    /// What an error underlines: the token the 1-based character `position` falls in (or, in whitespace, the next one),
    /// as UTF-8 offsets into `sent`, the text the server was sent. A position at the end of the text underlines nothing
    /// there: an empty range at the end.
    public static func errorRange(position: Int, in sent: String) -> Range<Int> {
        let offset = utf8Offset(ofPosition: position, in: sent)
        return tokenRange(atUTF8: offset, in: sent) ?? offset..<offset
    }

    /// The token at a UTF-8 offset, as a range of UTF-8 offsets: the token that contains it, or, when the offset is
    /// in whitespace, the next token. Nil when there is none (the offset is at or past the last token). Comments are
    /// tokens too: an error never points into one, but a position at the end of the text does not fall on them.
    public static func tokenRange(atUTF8 offset: Int, in text: String) -> Range<Int>? {
        let bytes = Array(text.utf8)
        var state = SQLLexState.normal
        var lineStart = 0
        while lineStart <= bytes.count {
            var lineEnd = lineStart
            while lineEnd < bytes.count, bytes[lineEnd] != 0x0A { lineEnd += 1 }
            let (tokens, end) = bytes.withUnsafeBufferPointer { all in
                SQLLineLexer.lex(bytes: UnsafeBufferPointer(rebasing: all[lineStart..<lineEnd]), from: state)
            }
            state = end
            // From the offset's own line on, the first token that ends after the offset.
            if offset <= lineEnd {
                let local = max(0, offset - lineStart)
                if let hit = tokens.first(where: { $0.kind != .whitespace && $0.range.upperBound > local }) {
                    return (lineStart + hit.range.lowerBound)..<(lineStart + hit.range.upperBound)
                }
            }
            lineStart = lineEnd + 1
        }
        return nil
    }

    // MARK: Internals

    /// A stretch between top-level semicolons, as UTF-8 offsets: `start..<end` without its `;`, and the part of it that is
    /// not whitespace.
    struct Segment {
        var start: Int
        var end: Int
        var trimmed: Range<Int>
        /// Nothing but whitespace and comments.
        var isBlank: Bool
    }

    static func segments(of text: String) -> [Segment] {
        let bytes = Array(text.utf8)
        var semicolons: [Int] = []
        var content: [Bool] = []      // per byte: part of a token that is not whitespace or a comment
        content.reserveCapacity(bytes.count)
        var state = SQLLexState.normal
        var lineStart = 0
        bytes.withUnsafeBufferPointer { all in
            while lineStart <= all.count {
                var lineEnd = lineStart
                while lineEnd < all.count, all[lineEnd] != 0x0A { lineEnd += 1 }
                let line = UnsafeBufferPointer(rebasing: all[lineStart..<lineEnd])
                let (tokens, end) = SQLLineLexer.lex(bytes: line, from: state)
                state = end
                var covered = [Bool](repeating: false, count: line.count)
                for token in tokens {
                    switch token.kind {
                    case .whitespace, .comment: break
                    default:
                        for k in token.range { covered[k] = true }
                        if token.kind == .punctuation, line[token.range.lowerBound] == 0x3B { semicolons.append(lineStart + token.range.lowerBound) }
                    }
                }
                content.append(contentsOf: covered)
                if lineEnd < all.count { content.append(false) }    // the newline
                lineStart = lineEnd + 1
            }
        }
        var result: [Segment] = []
        var from = 0
        func add(_ start: Int, _ end: Int) {
            var first = start, last = end
            // Trim to the first and last byte that is content or a comment; the blank test looks at content only.
            var hasContent = false
            for k in start..<end where content[k] { hasContent = true; break }
            while first < last, isSpace(bytes[first]) { first += 1 }
            while last > first, isSpace(bytes[last - 1]) { last -= 1 }
            result.append(Segment(start: start, end: end, trimmed: first..<last, isBlank: !hasContent))
        }
        for s in semicolons {
            add(from, s)
            from = s + 1
        }
        add(from, bytes.count)
        return result
    }

    private static func isSpace(_ c: UInt8) -> Bool { c == 0x20 || (c >= 0x09 && c <= 0x0D) }

    private static func range(of offsets: Range<Int>, in text: String) -> Range<String.Index> {
        let utf8 = text.utf8
        let a = utf8.index(utf8.startIndex, offsetBy: offsets.lowerBound)
        let b = utf8.index(utf8.startIndex, offsetBy: offsets.upperBound)
        return a..<b
    }
}
