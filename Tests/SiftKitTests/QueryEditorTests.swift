import Foundation
import MetalUI
import MetalUICodeBuffer
import MetalUITesting
import SiftCore
import SiftTestSupport
import Testing

@testable import SiftKit

/// A `QueryEditorModel` over a fake runner and an in-memory history, no window.
@MainActor
struct ModelRig {
    let editor: QueryEditorModel
    let runner: FakeQueryRunner
    let store: InMemoryQueryHistoryStore
    let identity = "container:shop-db:shop"
    let clock: ManualClock
    let times: Times

    @MainActor final class Times {
        var next = Date(timeIntervalSince1970: 1_700_000_000)
        func tick() -> Date {
            defer { next += 10 }
            return next
        }
    }

    init(_ text: String = "", store: InMemoryQueryHistoryStore = InMemoryQueryHistoryStore()) {
        let runner = FakeQueryRunner()
        let times = Times()
        clock = ManualClock()
        self.runner = runner
        self.store = store
        self.times = times
        editor = QueryEditorModel(
            runner: { runner }, store: store, identity: "container:shop-db:shop", clock: clock, now: { times.tick() }, text: text)
    }

    /// Waits (bounded) until the run in flight ends.
    func finish() async throws {
        for _ in 0..<5000 where editor.isRunning { await Task.yield() }
        if editor.isRunning { throw RigError.timedOut("the run to end") }
    }

    func caret(_ offset: Int) { editor.buffer.select(offset..<offset) }

    func rows(_ n: Int, columns: Int = 1) -> QueryOutcome.Kind {
        .rows(
            columns: (0..<columns).map { ResultColumn(name: "c\($0)", typeOID: 20, typeName: "int8") },
            rows: (0..<n).map { r in (0..<columns).map { SiftValue.int(Int64(r * 10 + $0)) } }, truncated: false)
    }
}

@MainActor
struct QueryEditorTests {
    static let three = "select 1;\nselect 2;\nselect 3;"

    @Test func primaryReturnRunsTheStatementUnderTheCaret() async throws {
        let rig = ModelRig(Self.three)
        rig.caret(14)    // inside `select 2`
        #expect(rig.editor.handleKey(.return, modifiers: .primary))
        try await rig.finish()
        #expect(rig.runner.sql == ["select 2"])
        #expect(rig.runner.calls.first?.statementTimeout == "60s")
    }

    @Test func primaryReturnRunsTheSelectionWhenThereIsOne() async throws {
        let rig = ModelRig(Self.three)
        // From the middle of line 1 to the middle of line 2: the text as selected, not a whole statement.
        rig.editor.buffer.select(7..<16)
        _ = rig.editor.handleKey(.return, modifiers: .primary)
        try await rig.finish()
        #expect(rig.runner.sql == ["1;\nselect"])
    }

    @Test func aBlankSelectionOrBufferRunsNothing() async throws {
        let rig = ModelRig("  \n ")
        rig.editor.runCurrent()
        rig.editor.runAll()
        #expect(rig.runner.calls.isEmpty)
        #expect(!rig.editor.isRunning)
    }

    @Test func shiftPrimaryReturnRunsAllAndStopsAtTheFirstError() async throws {
        let rig = ModelRig(Self.three)
        rig.runner.answer { sql in
            sql == "select 2" ? .failed(QueryFailure(message: "boom", sqlState: "42601", position: 8)) : .command(tag: "SET", affected: nil)
        }
        #expect(rig.editor.handleKey(.return, modifiers: [.primary, .shift]))
        try await rig.finish()
        #expect(rig.runner.sql == ["select 1", "select 2"], "the third statement must not run")
        #expect(rig.editor.summary == .failed(QueryFailure(message: "boom", sqlState: "42601", position: 8)))
        #expect(rig.editor.batchSummary == "2 statements, 0 rows affected")
        #expect(rig.editor.batchLines == ["1. SET", "2. boom"])
        // The underline is on the failing statement's second line, offset by where that statement starts (10).
        #expect(rig.editor.highlighter.errorRanges.first.map { $0.lowerBound >= 10 && $0.upperBound <= 19 } == true)
    }

    @Test func runAllShowsTheLastRowReturningResultAndCountsAffectedRows() async throws {
        let rig = ModelRig("select 1;\nset x;\nselect 2, 3;\nupdate t;")
        rig.runner.answer { sql in
            switch sql {
            case "select 1": return .rows(columns: [ResultColumn(name: "a", typeOID: 20, typeName: "int8")], rows: [[.int(1)]], truncated: false)
            case "select 2, 3":
                return .rows(columns: [ResultColumn(name: "x", typeOID: 20, typeName: "int8"), ResultColumn(name: "y", typeOID: 20, typeName: "int8")], rows: [[.int(2), .int(3)], [.int(4), .int(5)]], truncated: false)
            case "set x": return .command(tag: "SET", affected: nil)
            default: return .command(tag: "UPDATE 4", affected: 4)
            }
        }
        rig.editor.runAll()
        try await rig.finish()
        #expect(rig.editor.batchSummary == "4 statements, 4 rows affected")
        let grid = try #require(rig.editor.result)
        #expect(grid.columns.map(\.name) == ["x", "y"], "the last row-returning statement's rows")
    }

    @Test func runningDisablesRunAndShowsCancel() async throws {
        let rig = ModelRig("select 1")
        rig.runner.holds = true
        rig.editor.runCurrent()
        try await Self.until { rig.runner.isHolding }
        #expect(rig.editor.isRunning)
        // A second run while one is in flight is ignored, from the keyboard and from the model.
        _ = rig.editor.handleKey(.return, modifiers: .primary)
        rig.editor.runCurrent()
        rig.editor.runAll()
        rig.editor.run(sql: "select 9")
        #expect(rig.runner.calls.count == 1)
        rig.runner.release(rig.rows(1))
        try await rig.finish()
        #expect(!rig.editor.isRunning)
        rig.runner.holds = false
        rig.editor.runCurrent()
        try await rig.finish()
        #expect(rig.runner.calls.count == 2)
    }

    @Test func escapeCancelsARunningQuery() async throws {
        let rig = ModelRig("select pg_sleep(30)")
        // Nothing runs: Escape is not ours.
        #expect(!rig.editor.handleKey(.escape, modifiers: []))
        rig.runner.holds = true
        rig.editor.runCurrent()
        try await Self.until { rig.runner.isHolding }
        #expect(rig.editor.handleKey(.escape, modifiers: []))
        #expect(rig.runner.cancelCalls == 1)
        try await rig.finish()
        #expect(rig.editor.summary == .cancelled)
    }

    @Test func aCancelBetweenStatementsStopsTheRest() async throws {
        let rig = ModelRig(Self.three)
        rig.runner.holds = true
        rig.editor.runAll()
        try await Self.until { rig.runner.isHolding }
        // Statement 1 finishes, and the cancel lands before the loop sends statement 2.
        rig.runner.release(rig.rows(1))
        rig.editor.cancel()
        try await rig.finish()
        #expect(rig.runner.sql.count == 1)
        #expect(rig.editor.summary == .cancelled)
        #expect(rig.editor.batchLines.last == "2. Cancelled")
    }

    @Test func closingDuringARunAllStopsItAndWritesNothingMore() async throws {
        let rig = ModelRig(Self.three)
        rig.runner.holds = true
        rig.editor.runAll()
        try await Self.until { rig.runner.isHolding }
        let before = rig.store.load(identity: rig.identity)
        rig.editor.close()
        rig.runner.release(rig.rows(1))
        // The task ends on its own; give it its turns.
        for _ in 0..<200 { await Task.yield() }
        #expect(rig.runner.sql.count == 1)
        #expect(rig.store.load(identity: rig.identity) == before)
        #expect(rig.editor.history.isEmpty)
        #expect(rig.editor.result == nil)
    }

    @Test func aCancelShowsCancelledNotAnError() async throws {
        let rig = ModelRig("select pg_sleep(30)")
        rig.runner.script(.cancelled)
        rig.editor.runCurrent()
        try await rig.finish()
        #expect(rig.editor.summary == .cancelled)
        #expect(rig.editor.highlighter.errorRanges.isEmpty)
        #expect(rig.editor.result == nil)
        #expect(rig.editor.history.first?.error == "Cancelled")
    }

    @Test func aReadOnlyRefusalShowsTheReadOnlyMessage() async throws {
        let rig = ModelRig("delete from t")
        rig.runner.script(.failed(QueryFailure(
            message: "cannot execute DELETE in a read-only transaction", sqlState: "25006")))
        rig.editor.runCurrent()
        try await rig.finish()
        guard case .failed(let failure) = rig.editor.summary else { Issue.record("no failure"); return }
        #expect(QueryEditorModel.display(failure) == ["Sift is read-only: this statement would change the database."])
        #expect(QueryEditorModel.readOnlyMessage == "Sift is read-only: this statement would change the database.")
        #expect(rig.editor.history.first?.error == QueryEditorModel.readOnlyMessage)
    }

    @Test func aTruncatedResultSaysFirst100000Rows() async throws {
        let rig = ModelRig("select g from generate_series(1, 200000) g")
        rig.runner.script(.rows(
            columns: [ResultColumn(name: "g", typeOID: 20, typeName: "int8")],
            rows: (0..<100_000).map { [SiftValue.int(Int64($0))] }, truncated: true))
        rig.editor.runCurrent()
        try await rig.finish()
        guard case .rows(let count, let truncated, _) = rig.editor.summary else { Issue.record("no rows"); return }
        #expect(count == 100_000 && truncated)
        #expect(QueryEditorModel.rowsText(count, truncated: truncated) == "first 100 000 rows")
        #expect(QueryEditorModel.rowsText(1, truncated: false) == "1 row")
        #expect(QueryEditorModel.rowsText(2_500, truncated: false) == "2,500 rows")
    }

    @Test func anErrorWithAPositionUnderlinesTheTokenAtIt() async throws {
        let rig = ModelRig("select 1;\nselect 'héllo' ,, 1;")
        rig.caret(20)
        rig.runner.script(.failed(QueryFailure(message: "syntax error at or near \",\"", sqlState: "42601", position: 17)))
        rig.editor.runCurrent()
        try await rig.finish()
        #expect(rig.runner.sql == ["select 'héllo' ,, 1"])
        let range = try #require(rig.editor.highlighter.errorRanges.first)
        #expect(rig.editor.buffer.snapshot().text(in: range) == ",")
        #expect(range == (10 + 17)..<(10 + 18))
        // The next run clears it.
        rig.runner.script(.command(tag: "SELECT", affected: nil))
        rig.editor.runCurrent()
        try await rig.finish()
        #expect(rig.editor.highlighter.errorRanges.isEmpty)
    }

    @Test func theTimeoutIsPassedToTheRunner() async throws {
        let rig = ModelRig("select 1")
        for (timeout, setting) in [(QueryTimeout.s15, "15s"), (.s60, "60s"), (.m5, "5min"), (.none, "0")] {
            rig.editor.timeout = timeout
            rig.editor.runCurrent()
            try await rig.finish()
            #expect(rig.runner.calls.last?.statementTimeout == setting)
        }
        #expect(QueryEditorModel(runner: { nil }, store: InMemoryQueryHistoryStore(), identity: nil).timeout == .s60)
    }

    @Test func aMissingRunnerSaysSo() async throws {
        let editor = QueryEditorModel(runner: { nil }, store: InMemoryQueryHistoryStore(), identity: nil, text: "select 1")
        editor.runCurrent()
        #expect(!editor.isRunning)
        #expect(editor.summary == .failed(QueryFailure(message: "This connection cannot run SQL.")))
    }

    // MARK: History

    @Test func historyRecordsEachRunNewestFirstAndDeduplicates() async throws {
        let rig = ModelRig("select 1;\nselect 2;")
        rig.runner.fallback = rig.rows(3)
        rig.caret(2)
        rig.editor.runCurrent()
        try await rig.finish()
        rig.caret(14)
        rig.editor.runCurrent()
        try await rig.finish()
        #expect(rig.editor.history.map(\.sql) == ["select 2", "select 1"])
        // The same SQL again moves its entry to the top; there is still one of it.
        rig.caret(2)
        rig.editor.runCurrent()
        try await rig.finish()
        #expect(rig.editor.history.map(\.sql) == ["select 1", "select 2"])
        let top = try #require(rig.editor.history.first)
        #expect(top.rowCount == 3 && top.error == nil)
        #expect(top.duration == 0.01)
        #expect(top.ranAt > rig.editor.history[1].ranAt, "the third run is the latest")
    }

    @Test func historyRecordsCommandsAndErrors() async throws {
        let rig = ModelRig("set x = 1;\nselect ,,")
        rig.runner.answer { $0.hasPrefix("set") ? .command(tag: "SET", affected: nil) : .failed(QueryFailure(message: "syntax error", sqlState: "42601")) }
        rig.editor.runAll()
        try await rig.finish()
        let entries = rig.editor.history
        #expect(entries.map(\.sql) == ["select ,,", "set x = 1"])
        #expect(entries[0].error == "syntax error" && entries[0].rowCount == nil)
        #expect(entries[1].error == nil && entries[1].affected == nil)
    }

    @Test func historySearchFiltersIgnoringCase() async throws {
        let rig = ModelRig("select 1;\nSELECT name FROM users;")
        rig.runner.fallback = rig.rows(1)
        rig.editor.runAll()
        try await rig.finish()
        rig.editor.historySearch = "USERS"
        #expect(rig.editor.visibleHistory.map(\.sql) == ["SELECT name FROM users"])
        rig.editor.historySearch = ""
        #expect(rig.editor.visibleHistory.count == 2)
        rig.editor.historySearch = "nothing"
        #expect(rig.editor.visibleHistory.isEmpty)
    }

    @Test func clickingHistoryLoadsItAsOneUndoableEdit() async throws {
        let rig = ModelRig("select 'original'")
        let entry = QueryHistoryEntry(sql: "select 1,\n  2", ranAt: Date(), duration: 0)
        rig.editor.load(entry)
        #expect(rig.editor.buffer.snapshot().text == "select 1,\n  2")
        // The caret is at the end, ready to run.
        #expect(rig.editor.buffer.primarySelection.head == entry.sql.utf8.count)
        // One undo brings the old text back whole.
        #expect(rig.editor.buffer.undo())
        #expect(rig.editor.buffer.snapshot().text == "select 'original'")
        #expect(rig.editor.buffer.redo())
        #expect(rig.editor.buffer.snapshot().text == "select 1,\n  2")
    }

    @Test func doubleClickingHistoryRunsExactlyThatSQL() async throws {
        let rig = ModelRig("select 'original'")
        rig.runner.fallback = rig.rows(1)
        let entry = QueryHistoryEntry(sql: "select 1;\nselect 2", ranAt: Date(), duration: 0)
        rig.editor.runHistory(entry)
        try await rig.finish()
        #expect(rig.runner.sql == ["select 1;\nselect 2"])
        #expect(rig.editor.buffer.snapshot().text == "select 1;\nselect 2")
    }

    @Test func historyPersistsAcrossLaunchesThroughTheStore() async throws {
        let rig = ModelRig("select 1")
        rig.runner.fallback = rig.rows(1)
        rig.editor.runCurrent()
        try await rig.finish()
        #expect(rig.store.saves == 1)
        #expect(rig.store.all[rig.identity]?.map(\.sql) == ["select 1"])
        // The next launch: a new model over the same store.
        let next = ModelRig("", store: rig.store)
        #expect(next.editor.history.map(\.sql) == ["select 1"])
    }

    @Test func historyCapsAt500() async throws {
        let seeded = InMemoryQueryHistoryStore(["container:shop-db:shop": (0..<500).map {
            QueryHistoryEntry(sql: "select \($0)", ranAt: Date(timeIntervalSince1970: Double($0)), duration: 0)
        }])
        let rig = ModelRig("select 'new'", store: seeded)
        rig.runner.fallback = rig.rows(1)
        #expect(rig.editor.history.count == 500)
        rig.editor.runCurrent()
        try await rig.finish()
        #expect(rig.editor.history.count == 500)
        #expect(rig.editor.history.first?.sql == "select 'new'")
        #expect(rig.editor.history.last?.sql == "select 498", "the oldest fell off")
    }

    @Test func aSessionWithoutAnIdentityKeepsNoHistoryFile() async throws {
        let store = InMemoryQueryHistoryStore()
        let runner = FakeQueryRunner()
        let editor = QueryEditorModel(runner: { runner }, store: store, identity: nil, text: "select 1")
        editor.runCurrent()
        for _ in 0..<2000 where editor.isRunning { await Task.yield() }
        #expect(editor.history.count == 1)
        #expect(store.saves == 0)
    }

    static func until(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<5000 where !condition() { await Task.yield() }
        if !condition() { throw RigError.timedOut("condition") }
    }
}
