import MetalUI
import MetalUICodeBuffer
import MetalUITesting
import SiftCore
import SiftTestSupport
import Testing

@testable import SiftKit

/// The Query tab in the real app window, over a fake runner.
@MainActor
struct QueryViewTests {
    let key = ConnectionKey.container(name: "shop-db")

    /// The app window with the connection open and its Query tab showing.
    func openQuery(
        text: String = "", recordsLayout: Bool = true, size: Size<Pixels>? = nil
    ) async throws -> (Rig, TestWindow, QueryEditorModel, FakeQueryRunner) {
        let rig = Rig()
        await rig.model.refreshDiscovery()
        await rig.model.open(key)
        rig.model.selection = .container(name: "shop-db")
        let window = try siftWindow(model: rig.model, size: size ?? siftWindowSize, recordsLayout: recordsLayout)
        rig.model.openQuery()
        try await window.runUntilIdle()
        let editor = try #require(rig.model.sessions[key]?.queryEditor())
        if !text.isEmpty { editor.buffer.replace(0..<0, with: text) }
        try await window.runUntilIdle()
        return (rig, window, editor, rig.sources[0].runner)
    }

    static func rows(_ n: Int) -> QueryOutcome.Kind {
        .rows(
            columns: [ResultColumn(name: "id", typeOID: 20, typeName: "int8"), ResultColumn(name: "name", typeOID: 25, typeName: "text")],
            rows: (0..<n).map { [SiftValue.int(Int64($0 + 1)), .text("n\(n - $0)")] }, truncated: false)
    }

    @Test func primaryTOpensTheQueryTabOfTheSelectedConnection() async throws {
        let rig = Rig()
        await rig.model.refreshDiscovery()
        await rig.model.open(key)
        rig.model.selection = .container(name: "shop-db")
        let (_, window) = try siftApp(model: rig.model)
        #expect(rig.model.detailMode == .map)
        window.typeKey("t", modifierFlags: .primary)
        try await window.runUntilIdle()
        #expect(rig.model.detailMode == .query)
        _ = try window.element(identifier: "query.editor")
        _ = try window.element(identifier: "query.run")
        // The same switch from a table's header button.
        rig.model.select(RelationID("shop", "orders"), in: key)
        try await window.runUntilIdle()
        #expect(rig.model.detailMode == .table)
        try window.click(window.element(identifier: "detail.query"))
        try await window.runUntilIdle()
        #expect(rig.model.detailMode == .query)
        _ = try window.element(identifier: "query.editor")
    }

    @Test func primaryTWithNothingOpenDoesNothing() async throws {
        let rig = Rig()
        rig.model.openQuery()
        #expect(rig.model.detailMode == .table)
    }

    @Test func primaryReturnInTheEditorRunsAndTheRowsShowInTheGrid() async throws {
        let (_, window, editor, runner) = try await openQuery()
        runner.fallback = Self.rows(5)
        try window.click(window.element(identifier: "query.editor"))
        window.typeText("select id, name from t;")
        window.typeKey(.return)
        window.typeText("select 2;")
        window.typeKey(.upArrow)
        window.typeKey(.return, modifierFlags: .primary)
        try await window.runUntil { editor.result != nil }
        try await window.runUntilIdle()
        #expect(runner.sql == ["select id, name from t"])
        // The grid is the table's grid, over the captured rows.
        #expect(try window.element(identifier: "grid.cell.0.0").value == "1")
        #expect(try window.element(identifier: "grid.cell.4.1").value == "n1")
        #expect(try window.element(identifier: "query.status.rows").value == "5 rows in 10 ms")
        // A result is not a relation's rows: Refresh would only re-read the same captured rows, so there is no button.
        #expect(window.hasElement(identifier: "grid.toolbar"))
        #expect(!window.hasElement(identifier: "grid.refresh"))
        // The key did not type a newline.
        #expect(editor.buffer.snapshot().text == "select id, name from t;\nselect 2;")
    }

    @Test func aHeaderSortSortsTheCapturedRowsInMemory() async throws {
        let (_, window, editor, runner) = try await openQuery(text: "select 1")
        runner.fallback = Self.rows(6)
        editor.runCurrent()
        try await window.runUntil { editor.result != nil && editor.result?.cachedPages.contains(0) == true }
        try await window.runUntilIdle()
        let grid = try #require(editor.result)
        #expect(try window.element(identifier: "grid.cell.0.1").value == "n6")
        try window.click(window.element(label: "name"))
        try await window.runUntil { grid.query.sort != nil && grid.cachedPages.contains(0) }
        try await window.runUntilIdle()
        #expect(grid.query.sort == GridSort(column: 1, ascending: true))
        #expect(try window.element(identifier: "grid.cell.0.1").value == "n1")
        // Sorting asked the runner for nothing: it is the grid over memory.
        #expect(runner.calls.count == 1)
    }

    @Test func runningDisablesRunAndShowsCancel() async throws {
        let (_, window, editor, runner) = try await openQuery(text: "select pg_sleep(30)")
        _ = try window.element(identifier: "query.run")
        #expect(!window.hasElement(identifier: "query.cancel"))
        runner.holds = true
        try window.click(window.element(identifier: "query.run"))
        try await window.runUntil { runner.isHolding }
        try await window.runUntilIdle()
        #expect(editor.isRunning)
        _ = try window.element(identifier: "query.cancel")
        #expect(!window.hasElement(identifier: "query.run"))
        _ = try window.element(identifier: "query.running")
        // ⌘Return does nothing while it runs.
        try window.click(window.element(identifier: "query.editor"))
        window.typeKey(.return, modifierFlags: .primary)
        try await window.runUntilIdle()
        #expect(runner.calls.count == 1)
        // The button cancels.
        try window.click(window.element(identifier: "query.cancel"))
        try await window.runUntil { !editor.isRunning }
        try await window.runUntilIdle()
        #expect(runner.cancelCalls == 1)
        _ = try window.element(identifier: "query.status.cancelled")
        _ = try window.element(identifier: "query.run")
    }

    @Test func escapeInTheEditorCancelsARunningQuery() async throws {
        let (_, window, editor, runner) = try await openQuery(text: "select pg_sleep(30)")
        runner.holds = true
        try window.click(window.element(identifier: "query.editor"))
        window.typeKey(.return, modifierFlags: .primary)
        try await window.runUntil { runner.isHolding }
        window.typeKey(.escape)
        try await window.runUntil { !editor.isRunning }
        #expect(runner.cancelCalls == 1)
        #expect(editor.summary == .cancelled)
    }

    @Test func anErrorShowsItsMessageDetailAndHintInThePane() async throws {
        let (_, window, editor, runner) = try await openQuery(text: "select ,, 1")
        runner.fallback = .failed(QueryFailure(
            message: "syntax error at or near \",\"", sqlState: "42601", position: 9, detail: "a detail", hint: "a hint"))
        editor.runCurrent()
        try await window.runUntil { !editor.isRunning }
        try await window.runUntilIdle()
        #expect(try window.element(identifier: "query.status.error").value == "syntax error at or near \",\"")
        #expect(try window.element(identifier: "query.status.errorDetail.1").value == "DETAIL: a detail")
        #expect(try window.element(identifier: "query.status.errorDetail.2").value == "HINT: a hint")
        #expect(editor.highlighter.errorRanges == [8..<9])
    }

    @Test func theHistoryColumnListsRunsAndAClickLoadsOneAndADoubleClickRunsIt() async throws {
        let (_, window, editor, runner) = try await openQuery(text: "select 1;")
        runner.fallback = Self.rows(2)
        editor.runCurrent()
        try await window.runUntil { !editor.isRunning }
        editor.buffer.replace(0..<editor.buffer.utf8Count, with: "select 2;")
        editor.runCurrent()
        try await window.runUntil { !editor.isRunning }
        try await window.runUntilIdle()
        #expect(editor.history.map(\.sql) == ["select 2", "select 1"])
        #expect(try window.element(identifier: "query.history.0").value == "select 2")
        // A click loads the entry into the editor.
        try window.click(window.element(identifier: "query.history.1"))
        window.advance(by: 1)    // the double-click window passes: the click is a single one
        try await window.runUntilIdle()
        #expect(editor.buffer.snapshot().text == "select 1")
        #expect(runner.calls.count == 2)
        // A double click runs it.
        try window.doubleClick(window.element(identifier: "query.history.0"))
        try await window.runUntil { runner.calls.count == 3 && !editor.isRunning }
        #expect(runner.sql.last == "select 2")
        // Collapsing the column removes it.
        try window.click(window.element(identifier: "query.historyToggle"))
        try await window.runUntilIdle()
        #expect(!window.hasElement(identifier: "query.history"))
    }

    @Test func theHistorySearchFiltersTheList() async throws {
        let (_, window, editor, runner) = try await openQuery(text: "select 1;\nselect 'needle';")
        runner.fallback = Self.rows(1)
        editor.runAll()
        try await window.runUntil { !editor.isRunning }
        try await window.runUntilIdle()
        #expect(window.hasElement(identifier: "query.history.1"))
        try window.click(window.element(identifier: "query.history.search"))
        window.typeText("needle")
        try await window.runUntilIdle()
        #expect(try window.element(identifier: "query.history.0").value == "select 'needle'")
        #expect(!window.hasElement(identifier: "query.history.1"))
    }

    @Test func theTimeoutMenuChoosesFromTheFixedList() async throws {
        let (_, window, editor, runner) = try await openQuery(text: "select 1")
        editor.timeout = .m5
        runner.fallback = Self.rows(1)
        try window.click(window.element(identifier: "query.run"))
        try await window.runUntil { !editor.isRunning }
        #expect(runner.calls.last?.statementTimeout == "5min")
        #expect(QueryTimeout.allCases.map(\.title) == ["15 s", "60 s", "5 min", "No timeout"])
    }

    @Test func theSplitDividerPositionIsKeptForTheSession() async throws {
        let (rig, window, _, _) = try await openQuery()
        let session = try #require(rig.model.sessions[key])
        let before = try window.element(identifier: "query.editor").frame.size.height.value
        #expect(before > 100)
        // Drag the divider 100 points down: the editor grows by that, and the session's store holds the sizes.
        let divider = try window.element(identifier: "query.divider.0")
        let from = window.centre(of: divider)
        window.click(at: from, forDuration: 0.1, thenDragTo: Point(x: from.x, y: from.y + 100))
        try await window.runUntilIdle()
        let after = try window.element(identifier: "query.editor").frame.size.height.value
        #expect(abs(after - (before + 100)) < 2, "\(before) -> \(after)")
        let sizes = try #require(session.querySplitStore.paneSizes(forName: "sift.query"))
        #expect(sizes.count == 2 && abs(sizes[0] - Double(after)) < 2)
        // Away to the map and back: the divider is where it was left.
        rig.model.setDetailMode(.map)
        try await window.runUntilIdle()
        rig.model.openQuery()
        try await window.runUntilIdle()
        let back = try window.element(identifier: "query.editor").frame.size.height.value
        #expect(abs(back - after) < 2, "\(after) -> \(back)")
    }
}
