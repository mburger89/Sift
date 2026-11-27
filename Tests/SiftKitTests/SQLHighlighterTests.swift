import MetalUI
import MetalUICodeBuffer
import MetalUITesting
import SiftCore
import Testing

@testable import SiftKit

/// An editor's buffer, decorations and highlighter in a headless window, with the caret steady.
@MainActor
struct EditorRig {
    let buffer: CodeBuffer
    let decorations: CodeDecorations
    let highlighter: SQLHighlighter
    let window: TestWindow

    init(_ text: String, size: Size<Pixels> = Size(width: Pixels(600), height: Pixels(300))) throws {
        let buffer = CodeBuffer(text)
        let decorations = CodeDecorations(buffer: buffer)
        let highlighter = SQLHighlighter(buffer: buffer, decorations: decorations)
        self.buffer = buffer
        self.decorations = decorations
        self.highlighter = highlighter
        window = try siftTestWindow(size: size, recordsLayout: false) {
            CodeView(buffer: buffer, decorations: decorations).font(size: 12).codeCaretBlink(.off).gutterMarkerLane(true)
        }
    }

    func settle() async throws {
        try await window.runUntilIdle()
        for _ in 0..<20 { await Task.yield() }
        try await window.runUntilIdle()
    }

    /// The syntax runs over the whole buffer as (text, colour).
    func runs(layer: CodeHighlightLayer = .syntax) -> [(String, Color?)] {
        let snapshot = buffer.snapshot()
        return decorations.highlights(in: 0..<buffer.utf8Count, layer: layer).map {
            (snapshot.text(in: $0.range), decorations.style($0.style).foreground)
        }
    }

    func offset(row: Int, column: Int) -> Int { buffer.snapshot().offset(of: CodePoint(row: row, column: column)) }

    func total() -> FrameWork { window.frameWork.reduce(FrameWork(), +) }
}

@MainActor
struct SQLHighlighterTests {
    static func lines(_ count: Int) -> String {
        (0..<count).map { "select \($0) from t\($0) where x = 'a';" }.joined(separator: "\n")
    }

    @Test func keywordsStringsAndCommentsGetTheirStyles() async throws {
        let rig = try EditorRig("select 'a', 1, $1 -- note\nwhere id = 2 /* c */\n")
        try await rig.settle()
        let runs = rig.runs()
        func colour(_ text: String) -> Color? { runs.first { $0.0 == text }?.1 }
        #expect(colour("select") == SQLTheme.keyword)
        #expect(colour("where") == SQLTheme.keyword)
        #expect(colour("'a'") == SQLTheme.string)
        #expect(colour("1") == SQLTheme.number)
        #expect(colour("2") == SQLTheme.number)
        #expect(colour("$1") == SQLTheme.parameter)
        #expect(colour("-- note") == SQLTheme.comment)
        #expect(colour("/* c */") == SQLTheme.comment)
        // Comments are italic; the other kinds leave the slope alone.
        #expect(SQLTheme.style(for: .comment)?.italic == true)
        #expect(SQLTheme.style(for: .keyword)?.italic == nil)
        // Identifiers, operators and punctuation keep the text colour.
        #expect(!runs.contains { $0.0 == "id" || $0.0 == "=" || $0.0 == "," })
        // Not vacuous: every colour is a different one.
        #expect(Set([SQLTheme.keyword, SQLTheme.string, SQLTheme.number, SQLTheme.parameter, SQLTheme.comment].map { "\($0)" }).count == 5)
    }

    @Test func aKeystrokeReLexesOneLineAndAsksForNoOtherRows() async throws {
        let rig = try EditorRig(Self.lines(10_000))
        try await rig.settle()
        // Not vacuous: the whole buffer was lexed once, and the window shows rows that were answered.
        #expect(rig.highlighter.lexedLines == 10_000)
        #expect(rig.runs().contains { $0.0 == "select" })
        // Go to line 5000 and let the view show it.
        let at = rig.offset(row: 5000, column: 6)
        rig.buffer.select(at..<at)
        try await rig.settle()
        let before = rig.highlighter.lexedLines
        let asked = rig.highlighter.requests.count
        _ = rig.buffer.replace(at..<at, with: "x", origin: .typing)
        try await rig.settle()
        #expect(rig.highlighter.lexedLines - before == 1, "lexed \(rig.highlighter.lexedLines - before) lines for one keystroke")
        let requests = Array(rig.highlighter.requests.dropFirst(asked))
        #expect(requests == [5000..<5001], "asked for \(requests)")
        // The edited row is coloured again.
        #expect(rig.runs().filter { $0.0 == "selectx" }.isEmpty)
    }

    @Test func openingABlockCommentRestylesTheRowsBelowWhenTheyAreShown() async throws {
        let rig = try EditorRig(Self.lines(200))
        try await rig.settle()
        let at = rig.offset(row: 1, column: 0)
        _ = rig.buffer.replace(at..<at, with: "/*", origin: .typing)
        try await rig.settle()
        // Everything below is now comment: the visible rows say so, though the edit touched one line.
        let snapshot = rig.buffer.snapshot()
        let comment = rig.decorations.highlights(in: snapshot.lineRange(3).lowerBound..<snapshot.lineRange(4).upperBound, layer: .syntax)
            .map { rig.decorations.style($0.style).foreground }
        #expect(!comment.isEmpty && comment.allSatisfy { $0 == SQLTheme.comment }, "\(comment)")
        let slopes = rig.decorations.highlights(in: snapshot.lineRange(3).lowerBound..<snapshot.lineRange(4).upperBound, layer: .syntax)
            .map { rig.decorations.style($0.style).italic }
        #expect(!slopes.isEmpty && slopes.allSatisfy { $0 == true }, "\(slopes)")
        #expect(rig.highlighter.cache.startState(line: 3) == .blockComment(depth: 1))
        // Closing it again restores the colours.
        _ = rig.buffer.replace(at..<(at + 2), with: "", origin: .typing)
        try await rig.settle()
        let again = rig.decorations.highlights(in: snapshot.lineRange(3).lowerBound..<snapshot.lineRange(3).upperBound, layer: .syntax)
            .map { rig.decorations.style($0.style).foreground }
        #expect(again.first == SQLTheme.keyword)
    }

    @Test func anErrorUnderlineLandsOnTheTokenAtACharacterPosition() async throws {
        let text = "select 'héllo' ,, 1"
        let rig = try EditorRig(text)
        try await rig.settle()
        // The server's position for the second comma is character 17; its byte offset is 17 too, one more than the
        // character count before it because of the é.
        rig.highlighter.showError(position: 17, in: text, startingAt: 0, asOf: rig.buffer.version)
        try await rig.settle()
        let underlined = rig.highlighter.errorRanges
        #expect(underlined.count == 1)
        #expect(underlined.first.map { rig.buffer.snapshot().text(in: $0) } == ",")
        #expect(underlined.first == 17..<18)
        #expect(rig.highlighter.errorRow == 0)
        // The style is a wavy red underline.
        let style = try #require(
            rig.decorations.highlights(in: 0..<rig.buffer.utf8Count, layer: .diagnostics, owner: SQLHighlighter.owner).first)
        #expect(rig.decorations.style(style.style).underline == CodeUnderline.wavy(SQLTheme.error))
    }

    @Test func anErrorUnderlineFromASelectionRunIsOffsetBySelectionStart() async throws {
        let text = "select 1;\nselect 'x' ,, 2;\nselect 3;"
        let rig = try EditorRig(text)
        try await rig.settle()
        // The second line was selected and run: the server's position counts from its first character.
        let start = rig.offset(row: 1, column: 0)
        let sent = "select 'x' ,, 2;"
        rig.highlighter.showError(position: 13, in: sent, startingAt: start, asOf: rig.buffer.version)
        let range = try #require(rig.highlighter.errorRanges.first)
        #expect(rig.buffer.snapshot().text(in: range) == ",")
        #expect(range == (start + 12)..<(start + 13))
        #expect(rig.highlighter.errorRow == 1)
        // A run that began at an older version still lands: an edit above shifts it.
        let version = rig.buffer.version
        _ = rig.buffer.replace(0..<0, with: "-- top\n", origin: .typing)
        rig.highlighter.showError(position: 13, in: sent, startingAt: start, asOf: version)
        let moved = try #require(rig.highlighter.errorRanges.first)
        #expect(moved == (start + 7 + 12)..<(start + 7 + 13))
        #expect(rig.buffer.snapshot().text(in: moved) == ",")
    }

    @Test func editingTheErrorLineClearsTheUnderline() async throws {
        let rig = try EditorRig("select 1;\nselect ,, 2;\nselect 3;")
        try await rig.settle()
        rig.highlighter.showError(position: 9, in: "select ,, 2;", startingAt: rig.offset(row: 1, column: 0), asOf: rig.buffer.version)
        try await rig.settle()
        #expect(rig.highlighter.errorRanges.count == 1)
        // An edit on another line leaves it, and moves it with the text.
        _ = rig.buffer.replace(0..<0, with: "-- a\n", origin: .typing)
        try await rig.settle()
        #expect(rig.highlighter.errorRanges.count == 1)
        #expect(rig.highlighter.errorRow == 2)
        // An edit on its own line clears it.
        let on = rig.offset(row: 2, column: 0)
        _ = rig.buffer.replace(on..<on, with: " ", origin: .typing)
        try await rig.settle()
        #expect(rig.highlighter.errorRanges.isEmpty)
        #expect(rig.highlighter.errorRow == nil)
    }

    @Test func aNewRunClearsTheUnderlineAndASecondErrorReplacesTheFirst() async throws {
        let rig = try EditorRig("select ,, 1;\nselect ,, 2;")
        try await rig.settle()
        rig.highlighter.showError(position: 8, in: "select ,, 1;", startingAt: 0, asOf: rig.buffer.version)
        rig.highlighter.showError(position: 8, in: "select ,, 2;", startingAt: rig.offset(row: 1, column: 0), asOf: rig.buffer.version)
        #expect(rig.highlighter.errorRanges.count == 1)
        #expect(rig.highlighter.errorRow == 1)
        rig.highlighter.clearError()
        #expect(rig.highlighter.errorRanges.isEmpty)
    }

    @Test func anIdleEditorAsksNoFrames() async throws {
        let rig = try EditorRig(Self.lines(300))
        try await rig.settle()
        // Not vacuous: rows are on screen, coloured, and the window drew them.
        #expect(rig.runs().contains { $0.0 == "select" })
        #expect(rig.window.frameWork.count > 0)
        rig.window.resetFrameWork()
        try await rig.window.runUntilIdle()
        for _ in 0..<50 { await Task.yield() }
        try await rig.window.runUntilIdle()
        #expect(rig.window.frameWork.isEmpty, "an idle editor drew \(rig.window.frameWork.count) frames")
    }
}
