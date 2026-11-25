import MetalUI
import MetalUITesting
import SiftCore
import SiftTestSupport
import Testing

@testable import SiftKit

/// What the Query tab costs a frame. Each pin counts work (builds, rows realised, lines shaped), never time, and first
/// asserts that what it measures is really there. Off Darwin a dirty mark hops through a `Task`: they run
/// `runUntilIdle()` and sum `frameWork`, never read `lastFrameWork`.
@MainActor
struct QueryCostTests {
    let view = QueryViewTests()

    static func longBuffer(_ lines: Int) -> String {
        (0..<lines).map { "select \($0) as n\($0), 'row \($0)' from t\($0 % 17) where x = \($0);" }.joined(separator: "\n")
    }

    /// The window with the query tab open, a result in the grid and history entries, settled.
    func rig(text: String = "select 1;", recordsLayout: Bool = false) async throws -> (Rig, TestWindow, QueryEditorModel, FakeQueryRunner) {
        let (rig, window, editor, runner) = try await view.openQuery(text: text, recordsLayout: recordsLayout)
        editor.caretBlink = .off
        runner.fallback = QueryViewTests.rows(40)
        editor.run(sql: "select 1")
        try await window.runUntil { !editor.isRunning && editor.result?.cachedPages.contains(0) == true }
        try await window.runUntilIdle()
        for _ in 0..<20 { await Task.yield() }
        try await window.runUntilIdle()
        return (rig, window, editor, runner)
    }

    func total(_ window: TestWindow) -> FrameWork { window.frameWork.reduce(FrameWork(), +) }

    @MainActor struct Bodies: Equatable {
        var editor = QueryEditorPane.bodyCount
        var results = QueryResultsPane.bodyCount
        var history = QueryHistoryList.bodyCount
        var toolbar = QueryToolbar.bodyCount
        var table = GridTable.bodyCount
        var gridToolbar = GridToolbar.bodyCount
    }

    @Test func typingInALongBufferCostsOnlyTheEditor() async throws {
        let (_, window, editor, _) = try await rig(text: Self.longBuffer(10_000))
        // Not vacuous: the buffer is long, the grid has rows on screen, the history has an entry, and the editor shows text.
        #expect(editor.buffer.lineCount == 10_000)
        #expect(try window.element(identifier: "grid.cell.3.0").value == "4")
        #expect(editor.history.count == 1 && window.hasElement(identifier: "query.history.0"))
        try window.click(window.element(identifier: "query.editor"))
        // Warm: the first redraw beside a settled grid records what later ones replay.
        window.typeText("a")
        try await window.runUntilIdle()
        let bodies = Bodies()
        window.resetFrameWork()
        window.typeText("bcde")
        try await window.runUntilIdle()
        let after = Bodies()
        let work = total(window)
        // The keystrokes landed and were drawn.
        #expect(editor.buffer.snapshot().text.contains("abcde"))
        #expect(window.frameWork.count > 0 && work.codeLinesPainted > 0, "frames \(window.frameWork.count) painted \(work.codeLinesPainted)")
        // Only the editor's leaf did work: no component rebuilt, no grid row realised, and a handful of lines were shaped.
        #expect(after == bodies, "bodies \(bodies) -> \(after)")
        #expect(work.tableRowsRealized == 0, "the grid realised \(work.tableRowsRealized) rows")
        #expect(work.codeLinesShaped <= 4 * 25, "shaped \(work.codeLinesShaped) lines")
    }

    @Test func theTypedTextReachedTheBuffer() async throws {
        let (_, window, editor, _) = try await rig(text: "select 1;")
        try window.click(window.element(identifier: "query.editor"))
        window.typeText("xyz")
        try await window.runUntilIdle()
        #expect(editor.buffer.snapshot().text.contains("xyz"))
    }

    @Test func anIdleQueryTabAsksNoFrames() async throws {
        let (_, window, editor, _) = try await rig(text: Self.longBuffer(300))
        // Not vacuous: rows are in the grid, the editor shows text, nothing runs, and the window drew frames to get here.
        #expect(try window.element(identifier: "grid.cell.2.1").value == "n38")
        #expect(!editor.isRunning && editor.history.count == 1)
        #expect(window.frameWork.count > 0)
        window.resetFrameWork()
        try await window.runUntilIdle()
        for _ in 0..<50 { await Task.yield() }
        try await window.runUntilIdle()
        // And the clock moving on asks for nothing: no animation runs (a spinner left on would draw each step).
        window.advanceFrames(60)
        #expect(window.frameWork.isEmpty, "an idle query tab drew \(window.frameWork.count) frames")
        // Focused with a steady caret it is just as quiet.
        try window.click(window.element(identifier: "query.editor"))
        try await window.runUntilIdle()
        window.resetFrameWork()
        for _ in 0..<50 { await Task.yield() }
        try await window.runUntilIdle()
        window.advanceFrames(60)
        #expect(window.frameWork.isEmpty, "a focused idle editor drew \(window.frameWork.count) frames")
    }

    @Test func aRunningSpinnerDoesNotRebuildTheEditor() async throws {
        let (_, window, editor, runner) = try await rig(text: Self.longBuffer(2_000))
        // Not vacuous: the editor shows a long buffer, and the toolbar is the one that says Run.
        #expect(editor.buffer.lineCount == 2_000)
        _ = try window.element(identifier: "query.run")
        let before = Bodies()
        window.resetFrameWork()
        runner.holds = true
        editor.run(sql: "select pg_sleep(30)")
        try await window.runUntil { runner.isHolding }
        try await window.runUntilIdle()
        #expect(editor.isRunning)
        _ = try window.element(identifier: "query.running")
        // The spinner turns: every step is a frame.
        let atStart = window.frameWork.count
        window.advanceFrames(60)
        #expect(window.frameWork.count - atStart >= 30, "the spinner drew \(window.frameWork.count - atStart) frames")
        runner.release(QueryViewTests.rows(1))
        try await window.runUntil { !editor.isRunning }
        try await window.runUntilIdle()
        let after = Bodies()
        let work = total(window)
        // The toolbar and the results rebuilt for the run (Cancel, the spinner, the new result): the editor did not, and
        // shaped no line, through the start, the spinner's frames and the end.
        #expect(after.toolbar > before.toolbar && after.results > before.results, "bodies \(before) -> \(after)")
        #expect(after.editor == before.editor, "the editor rebuilt: \(before.editor) -> \(after.editor)")
        #expect(work.codeLinesShaped == 0, "the editor shaped \(work.codeLinesShaped) lines")
    }
}
