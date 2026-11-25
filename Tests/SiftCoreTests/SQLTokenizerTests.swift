import SiftCore
import Testing

/// Lexes one line from the normal state and renders `kind:text` pairs, whitespace left out, so a test reads as the SQL does.
private func lex(_ text: String, from state: SQLLexState = .normal) -> (tokens: [String], end: SQLLexState) {
    let bytes = Array(text.utf8)
    let result = SQLLineLexer.lex(Substring(text).utf8, from: state)
    let rendered = result.tokens.filter { $0.kind != .whitespace }.map { "\($0.kind):\(String(decoding: bytes[$0.range], as: UTF8.self))" }
    return (rendered, result.end)
}

@Suite struct SQLTokenizerTests {
    @Test func aKeywordIsAKeywordInAnyCase() {
        #expect(lex("select").tokens == ["keyword:select"])
        #expect(lex("SeLeCt From").tokens == ["keyword:SeLeCt", "keyword:From"])
    }

    @Test func keywordsAreCaseInsensitive() {
        for word in ["where", "WHERE", "Where"] { #expect(lex(word).tokens == ["keyword:\(word)"]) }
        #expect(SQLKeywords.contains("join") && SQLKeywords.contains("JOIN"))
        #expect(!SQLKeywords.contains("customers"))
    }

    @Test func anIdentifierIsNotAKeyword() {
        #expect(lex("customers").tokens == ["identifier:customers"])
        #expect(lex("héllo_1$x").tokens == ["identifier:héllo_1$x"])
    }

    @Test func aQuotedIdentifierKeepsItsDoubledQuote() {
        #expect(lex(#""we""ird" x"#).tokens == [#"quotedIdentifier:"we""ird""#, "identifier:x"])
        #expect(lex(#""open"#).end == .quotedIdent)
    }

    @Test func aStringKeepsItsDoubledQuote() {
        #expect(lex("'it''s' x").tokens == ["string:'it''s'", "identifier:x"])
        #expect(lex("'' ''").tokens == ["string:''", "string:''"])
    }

    @Test func eStringsHonourBackslashEscapes() {
        // The escaped quote does not end the string; in a plain string the backslash is an ordinary byte.
        #expect(lex(#"E'it\'s' x"#).tokens == [#"string:E'it\'s'"#, "identifier:x"])
        #expect(lex(#"'it\' x"#).tokens == [#"string:'it\'"#, "identifier:x"])
        #expect(lex(#"e'a\\' b"#).tokens == [#"string:e'a\\'"#, "identifier:b"])
        #expect(lex(#"E'abc\"#).end == .string(.escape))
    }

    @Test func unicodeBitAndHexStringsAreStrings() {
        #expect(lex("U&'d\\0061t' x").tokens == ["string:U&'d\\0061t'", "identifier:x"])
        #expect(lex("B'101' X'1F' N'x'").tokens == ["string:B'101'", "string:X'1F'", "string:N'x'"])
        // A longer word ending in e is an identifier, then a string.
        #expect(lex("price 'x'").tokens == ["identifier:price", "string:'x'"])
    }

    @Test func unterminatedStringRunsToTheEnd() {
        let r = lex("select 'abc")
        #expect(r.tokens == ["keyword:select", "string:'abc"])
        #expect(r.end == .string(.standard))
        // The next line continues it.
        let next = lex("def' , 1", from: r.end)
        #expect(next.tokens == ["string:def'", "punctuation:,", "number:1"])
        #expect(next.end == .normal)
    }

    @Test func dollarQuotesWithTagsDoNotEndAtADifferentTag() {
        #expect(lex("$$ a ; b $$ x").tokens == ["string:$$ a ; b $$", "identifier:x"])
        #expect(lex("$fn$ a $$ b $f$ c $fn$ x").tokens == ["string:$fn$ a $$ b $f$ c $fn$", "identifier:x"])
        let open = lex("DO $fn$ begin")
        #expect(open.tokens == ["keyword:DO", "string:$fn$ begin"])
        #expect(open.end == .dollar(tag: "fn"))
        let rest = lex("end $other$ $fn$ ;", from: open.end)
        #expect(rest.tokens == ["string:end $other$ $fn$", "punctuation:;"])
    }

    @Test func aDollarThatOpensNothingIsNotAString() {
        #expect(lex("$1 + $12").tokens == ["parameter:$1", "operator_:+", "parameter:$12"])
        #expect(lex("a$b").tokens == ["identifier:a$b"])
    }

    @Test func nestedBlockCommentsCloseAtDepthZero() {
        let r = lex("/* a /* b */ still */ x")
        #expect(r.tokens == ["comment:/* a /* b */ still */", "identifier:x"])
        #expect(lex("/* open /* inner").end == .blockComment(depth: 2))
        let next = lex("*/ still */ y", from: .blockComment(depth: 2))
        #expect(next.tokens == ["comment:*/ still */", "identifier:y"])
        #expect(next.end == .normal)
    }

    @Test func aLineCommentRunsToTheEndOfTheLine() {
        #expect(lex("select 1 -- note /* not nested").tokens == ["keyword:select", "number:1", "comment:-- note /* not nested"])
    }

    @Test func numbersCoverIntegersDecimalsExponentsAndHex() {
        #expect(lex("1 12.5 .5 1e10 2.5E-3 0x1F 1_000").tokens == [
            "number:1", "number:12.5", "number:.5", "number:1e10", "number:2.5E-3", "number:0x1F", "number:1_000"
        ])
        // `.1` is a number even after a name, as in PostgreSQL.
        #expect(lex("t.1").tokens == ["identifier:t", "number:.1"])
    }

    @Test func parametersAreDollarNumbers() {
        #expect(lex("where id = $1").tokens == ["keyword:where", "identifier:id", "operator_:=", "parameter:$1"])
    }

    @Test func operatorsGroupAndStopAtAComment() {
        #expect(lex("a::int <> b").tokens == ["identifier:a", "operator_:::", "keyword:int", "operator_:<>", "identifier:b"])
        #expect(lex("a ->> 'k'").tokens == ["identifier:a", "operator_:->>", "string:'k'"])
        #expect(lex("a+--b").tokens == ["identifier:a", "operator_:+", "comment:--b"])
    }

    @Test func punctuationIsCommaSemicolonParensAndDot() {
        #expect(lex("f(a, b);").tokens == [
            "identifier:f", "punctuation:(", "identifier:a", "punctuation:,", "identifier:b", "punctuation:)", "punctuation:;"
        ])
    }

    @Test func whitespaceIsATokenWithExactRanges() {
        let tokens = SQLLineLexer.lex(Substring("ab  c").utf8, from: .normal).tokens
        #expect(tokens == [SQLToken(.identifier, 0..<2), SQLToken(.whitespace, 2..<4), SQLToken(.identifier, 4..<5)])
    }

    @Test func rangesAreUTF8OffsetsNotCharacters() {
        let tokens = SQLLineLexer.lex(Substring("'héllo' ,, 1").utf8, from: .normal).tokens
        // 'héllo' is 8 bytes (é is two): the comma follows after one space.
        #expect(tokens.first == SQLToken(.string, 0..<8))
        #expect(tokens.dropFirst(2).first == SQLToken(.punctuation, 9..<10))
    }
}

/// A buffer of `count` lines, the way the cache reads one.
private struct Lines {
    var rows: [String]
    func text(_ i: Int) -> Substring { Substring(rows[i]) }
}

@Suite struct SQLTokenCacheTests {
    private func filled(_ count: Int = 10_000) -> (SQLTokenCache, Lines) {
        let lines = Lines(rows: Array(repeating: "select 1;", count: count))
        let cache = SQLTokenCache()
        let all = cache.update(lines: lines.text, lineCount: count, editedFrom: 0)
        #expect(all == 0..<count)
        return (cache, lines)
    }

    @Test func theFirstUpdateLexesEveryLine() {
        let (cache, _) = filled(50)
        #expect(cache.lineCount == 50)
        #expect(cache.tokens(line: 7).map(\.kind) == [.keyword, .whitespace, .number, .punctuation])
    }

    @Test func anEditOnOneLineReLexesOnlyThatLine() {
        var (cache, lines) = filled()
        lines.rows[5000] = "select 2, 3;"
        let relexed = cache.update(lines: lines.text, lineCount: 10_000, editedFrom: 5000)
        #expect(relexed == 5000..<5001)
        #expect(cache.tokens(line: 5000).count == 7)
    }

    @Test func openingABlockCommentReLexesToTheEnd() {
        var (cache, lines) = filled()
        lines.rows[5000] = "select /* open"
        let relexed = cache.update(lines: lines.text, lineCount: 10_000, editedFrom: 5000)
        #expect(relexed == 5000..<10_000)
        #expect(cache.tokens(line: 9999).map(\.kind) == [.comment])
        #expect(cache.startState(line: 5001) == .blockComment(depth: 1))
    }

    @Test func closingItAgainReLexesOnlyUntilTheStateConverges() {
        var (cache, lines) = filled()
        // A later `*/` already closes the comment: the lines between are comment, the rest are as before.
        lines.rows[5100] = "*/ select 1;"
        _ = cache.update(lines: lines.text, lineCount: 10_000, editedFrom: 5100)
        lines.rows[5000] = "select /* open"
        let opened = cache.update(lines: lines.text, lineCount: 10_000, editedFrom: 5000)
        #expect(opened == 5000..<5101)
        #expect(cache.startState(line: 5101) == .normal)
        // Closing it again (the opener goes) converges at the same place, and no further.
        lines.rows[5000] = "select 1;"
        let closed = cache.update(lines: lines.text, lineCount: 10_000, editedFrom: 5000)
        #expect(closed == 5000..<5101)
        #expect(cache.tokens(line: 5050).map(\.kind) == [.keyword, .whitespace, .number, .punctuation])
    }

    @Test func insertingALineShiftsTheLinesAfterItWithoutLexingThem() {
        var (cache, lines) = filled(100)
        lines.rows[10] = "select"
        lines.rows.insert("1;", at: 11)
        // Return pressed after `select` on line 10: line 10 became two lines.
        let relexed = cache.update(lines: lines.text, lineCount: 101, editedFrom: 10, replacing: 1)
        #expect(relexed == 10..<12)
        #expect(cache.lineCount == 101)
        #expect(cache.tokens(line: 100).map(\.kind) == [.keyword, .whitespace, .number, .punctuation])
    }

    @Test func removingALineShiftsTheLinesAfterItWithoutLexingThem() {
        var (cache, lines) = filled(100)
        lines.rows[10] = "select 1; select 2;"
        lines.rows.remove(at: 11)
        let relexed = cache.update(lines: lines.text, lineCount: 99, editedFrom: 10, replacing: 2)
        #expect(relexed == 10..<11)
        #expect(cache.lineCount == 99)
    }

    @Test func aLineCountChangeWithoutASpanLexesEverythingAfter() {
        var (cache, lines) = filled(100)
        lines.rows.insert("-- new", at: 40)
        let relexed = cache.update(lines: lines.text, lineCount: 101, editedFrom: 40)
        #expect(relexed == 40..<101)
        #expect(cache.tokens(line: 40).map(\.kind) == [.comment])
    }

    @Test func anUnterminatedStringRunsOnAndALaterQuoteEndsIt() {
        var (cache, lines) = filled(20)
        lines.rows[3] = "select 'abc"
        lines.rows[6] = "def' ;"
        let relexed = cache.update(lines: lines.text, lineCount: 20, editedFrom: 3)
        // Converges at line 7: its start state is normal both before and after.
        #expect(relexed == 3..<7)
        #expect(cache.startState(line: 5) == .string(.standard))
        #expect(cache.startState(line: 7) == .normal)
    }
}
