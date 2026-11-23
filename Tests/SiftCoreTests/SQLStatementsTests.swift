import SiftCore
import Testing

private func pieces(_ text: String) -> [String] { SQLStatements.split(text).map { String(text[$0]) } }

private func statement(_ text: String, caret: Int) -> String? {
    let at = text.utf8.index(text.utf8.startIndex, offsetBy: caret)
    return SQLStatements.statement(at: at, in: text).map { String(text[$0]) }
}

@Suite struct SQLStatementsTests {
    @Test func splitsAtTopLevelSemicolons() {
        #expect(pieces("select 1; select 2;\n select 3") == ["select 1", "select 2", "select 3"])
        #expect(pieces("") == [])
        #expect(pieces("  \n ; ;") == [])
    }

    @Test func splitIgnoresSemicolonsInStringsCommentsAndDollarQuotes() {
        #expect(pieces("select ';'; select 2") == ["select ';'", "select 2"])
        #expect(pieces("select 1 -- a; b\n; select 2") == ["select 1 -- a; b", "select 2"])
        #expect(pieces("select \";\" from t; x") == ["select \";\" from t", "x"])
        // Review focus 1: a function body in a dollar quote, and nested comments.
        let block = "DO $fn$ begin perform 1; perform 2; end $fn$; select 3"
        #expect(pieces(block) == ["DO $fn$ begin perform 1; perform 2; end $fn$", "select 3"])
        #expect(pieces("DO $$ a; b; $$;\nselect 1") == ["DO $$ a; b; $$", "select 1"])
        #expect(pieces("/* /* ; */ ; */ select 1; select 2") == ["/* /* ; */ ; */ select 1", "select 2"])
        #expect(pieces("select E'a\\';b'; select 2") == ["select E'a\\';b'", "select 2"])
    }

    @Test func aMultiLineDollarQuoteIsOneStatement() {
        let text = "CREATE FUNCTION f() AS $body$\nselect 1;\nselect 2;\n$body$ LANGUAGE sql;\nselect 9;"
        #expect(pieces(text) == ["CREATE FUNCTION f() AS $body$\nselect 1;\nselect 2;\n$body$ LANGUAGE sql", "select 9"])
    }

    @Test func aStretchOfOnlyCommentsIsNotAStatement() {
        #expect(pieces("-- nothing\n/* here */; select 1") == ["select 1"])
    }

    @Test func statementAtCaretBetweenTwoStatements() {
        let text = "select 1;  select 2;"
        #expect(statement(text, caret: 0) == "select 1")
        #expect(statement(text, caret: 8) == "select 1")      // before the `;`
        #expect(statement(text, caret: 9) == "select 2")      // right after it belongs to the next
        #expect(statement(text, caret: 10) == "select 2")
        #expect(statement(text, caret: 15) == "select 2")
        #expect(statement(text, caret: 20) == "select 2")      // after the last `;`: nothing follows, so the one before
    }

    @Test func whitespaceOnlyGivesNil() {
        #expect(statement("", caret: 0) == nil)
        #expect(statement("  \n  ", caret: 2) == nil)
        #expect(statement(" -- note", caret: 3) == nil)
    }

    @Test func aNonASCIIStatementKeepsItsRange() {
        let text = "select 'héllo'; select 'wörld'"
        #expect(statement(text, caret: text.utf8.count) == "select 'wörld'")
        #expect(pieces(text) == ["select 'héllo'", "select 'wörld'"])
    }

    @Test func leadingKeywordSkipsCommentsAndParens() {
        func lead(_ s: String) -> String? { SQLStatements.leadingKeyword(Substring(s)) }
        #expect(lead("(SELECT 1)") == "SELECT")
        #expect(lead("((select 1))") == "SELECT")
        #expect(lead("/*x*/ with a as (select 1) select * from a") == "WITH")
        #expect(lead("-- c\n  values (1)") == "VALUES")
        #expect(lead("  show all") == "SHOW")
        #expect(lead("1 + 1") == nil)
        #expect(lead("") == nil)
        #expect(lead("/* only") == nil)
    }
}
