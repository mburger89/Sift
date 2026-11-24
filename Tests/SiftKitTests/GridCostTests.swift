import MetalUI
import MetalUITesting
import SiftCore
import SiftTestSupport
import Testing

@testable import SiftKit

/// What the grid costs a frame. Each pin counts work (builds, rows realised, reads), never time, and first asserts that
/// what it measures is really there. Off Darwin a dirty mark hops through a `Task`: they run `runUntilIdle()` and
/// sum `frameWork`, never read `lastFrameWork`.
@MainActor
struct GridCostTests {
    let key = ConnectionKey.container(name: "shop-db")
    let orders = RelationID("shop", "orders")
    let view = GridViewTests()

    func rig(trueCount: Int = 100_000) async throws -> (Rig, TestWindow, GridModel, FakeGridSource) {
        let source = FakeGridSource(columns: GridViewTests.columns(), trueCount: trueCount)
        let (rig, window, model) = try await view.openLoaded(source, recordsLayout: false)
        return (rig, window, model, source)
    }

    func total(_ window: TestWindow) -> FrameWork { window.frameWork.reduce(FrameWork(), +) }

    @Test func anIdleGridAsksNoFrames() async throws {
        let (_, window, model, _) = try await rig()
        // Not vacuous: rows are on screen, loaded, and nothing is pending.
        #expect(try view.cell(window, 0, 0).value == "0")
        #expect(try view.cell(window, 20, 2).value == "r20c2")
        #expect(!model.isLoading && model.cachedPages == [0])
        window.resetFrameWork()
        try await window.runUntilIdle()
        for _ in 0..<50 { await Task.yield() }
        try await window.runUntilIdle()
        #expect(window.frameWork.isEmpty, "an idle grid drew \(window.frameWork.count) frames")
        #expect(total(window).tableRowsRealized == 0)
    }

    @Test func aScrollStepRealisesOnlyTheWindow() async throws {
        let (_, window, model, _) = try await rig(trueCount: 400)
        let table = try window.element(identifier: "grid.table")
        let centre = window.centre(of: table)
        window.resetFrameWork()
        model.resetReadCount()
        // Ten rows down: still inside page 0, so no fetch confuses the count.
        window.scroll(at: centre, byDeltaX: 0, deltaY: -240)
        try await window.runUntilIdle()
        let frames = window.frameWork
        let work = total(window)
        // Not vacuous: the table rebuilt, and the rows moved.
        #expect(work.tableRowsRealized > 0 && work.builds > 0, "rows \(work.tableRowsRealized) builds \(work.builds)")
        #expect(try view.cell(window, 12, 0).value == "12")
        let window30 = 30
        #expect(frames.allSatisfy { $0.tableRowsRealized <= window30 }, "rows per frame \(frames.map(\.tableRowsRealized))")
        // 4 data columns and the frozen # column: each realised row reads at most 4 cells.
        let visibleColumns = 4
        #expect(model.valueReads > 0)
        #expect(model.valueReads <= window30 * visibleColumns * max(1, work.builds),
                "reads \(model.valueReads) over \(work.builds) builds")
        // And never a read of the 400 rows' worth of data.
        #expect(work.tableDataReads <= window30 * max(1, work.builds), "data reads \(work.tableDataReads)")
    }

    @Test func aPageArrivingRebuildsOnlyTheTable() async throws {
        let (_, window, model, source) = try await rig(trueCount: 100_000)
        let table = try window.element(identifier: "grid.table")
        // Jump to a far page: its rows are placeholders until the page lands.
        source.holdsPages = true
        window.scroll(at: window.centre(of: table), byDeltaX: 0, deltaY: -24 * 5000)
        try await window.runUntil { source.pageCalls.count == 2 }
        try await window.runUntilIdle()
        #expect(model.cachedPages == [0], "the far page is still held")
        let toolbar = GridToolbar.bodyCount, inspector = ValueInspector.bodyCount
        let rows = SidebarRow.bodyCount, tableBodies = GridTable.bodyCount
        window.resetFrameWork()
                source.releaseAll()
        try await window.runUntil { model.cachedPages.count == 2 }
        try await window.runUntilIdle()
        // Not vacuous: the table rebuilt for the page, and it shows the page's rows.
        #expect(GridTable.bodyCount > tableBodies, "the table did not rebuild when its page landed")
        #expect(total(window).tableCellsRealized > 0)
        #expect(window.frameWork.count > 0)
        // The toolbar, the inspector and the sidebar rows did not. (The status bar may: it shows what is loading.)
        #expect(GridToolbar.bodyCount == toolbar, "the toolbar rebuilt")
        #expect(ValueInspector.bodyCount == inspector, "the inspector rebuilt")
        #expect(SidebarRow.bodyCount == rows, "the sidebar rebuilt")
    }

    @Test func aSiblingRedrawDoesNotRebuildAnUnfocusedGrid() async throws {
        let (_, window, model, _) = try await rig()
        // The search field has the caret: the toolbar redraws on every keystroke, the grid is not focused.
        try window.click(window.element(identifier: "grid.search"))
        try await window.runUntilIdle()
        // Not vacuous: the grid is on screen with rows, and the toolbar rebuilds for a keystroke.
        #expect(try view.cell(window, 5, 1).value == "r5c1")
        // Warm: the first redraw beside a settled table records what later ones replay (on Linux the first one re-requests
        // every element; on macOS it already replays).
        window.typeText("a")
        try await window.runUntilIdle()
        let toolbar = GridToolbar.bodyCount, tableBodies = GridTable.bodyCount
        window.resetFrameWork()
        window.typeText("bcde")
        try await window.runUntilIdle()
        #expect(model.searchText == "abcde")
        #expect(GridToolbar.bodyCount > toolbar, "the sibling did not redraw")
        let work = total(window)
        #expect(window.frameWork.count > 0 && work.builds > 0)
        #expect(work.tableRowsRealized == 0, "the table realised \(work.tableRowsRealized) rows for a sibling's redraw")
        #expect(GridTable.bodyCount == tableBodies, "the table body ran again")
    }

    /// A grid whose source flags changes, in a window with a refresh already landed (rows 2 and 7 highlighted).
    func highlighted(trueCount: Int = 400) async throws -> (Rig, TestWindow, GridModel, FakeGridSource) {
        let source = FakeGridSource(columns: GridViewTests.columns(), trueCount: trueCount)
        source.supportsChanges = true
        source.keyColumns = [0]
        source.setChanged([2, 7])
        let (rig, window, model) = try await view.openLoaded(source, recordsLayout: false)
        source.setValue(.text("new"), row: 2, column: 1)
        model.refresh()
        do { try await window.runUntil { model.mark(row: 2) != nil && !model.isLoading && model.cachedPages.contains(0) } }
        catch { print("DBG", model.mark(row: 2) as Any, model.isLoading, model.cachedPages, source.calls, model.query); throw error }
        try await window.runUntilIdle()
        return (rig, window, model, source)
    }

    @Test func anIdleGridWithAHighlightAsksNoFrames() async throws {
        let (_, window, model, _) = try await highlighted()
        // Not vacuous: the tint is there, on screen, and nothing is pending.
        #expect(model.mark(row: 2) == .changed(cells: [1]))
        #expect(try view.cell(window, 2, 1).value == "changed")
        #expect(!model.isLoading)
        window.resetFrameWork()
        try await window.runUntilIdle()
        for _ in 0..<50 { await Task.yield() }
        try await window.runUntilIdle()
        #expect(window.frameWork.isEmpty, "an idle highlighted grid drew \(window.frameWork.count) frames")
    }

    @Test func aScrollStepAsksTheFillOncePerRealisedCell() async throws {
        let (_, window, model, _) = try await highlighted()
        let table = try window.element(identifier: "grid.table")
        window.resetFrameWork()
        model.resetFillReads()
        window.scroll(at: window.centre(of: table), byDeltaX: 0, deltaY: -240)
        try await window.runUntilIdle()
        let work = total(window)
        // Not vacuous: cells were realised and the fill was asked.
        #expect(work.tableCellsRealized > 0, "cells \(work.tableCellsRealized)")
        #expect(model.fillReads > 0)
        #expect(model.fillReads <= work.tableCellsRealized,
                "fill asked \(model.fillReads) times for \(work.tableCellsRealized) realised cells")
    }

    @Test func aRefreshRebuildsOnlyTheGridsParts() async throws {
        let (_, window, model, source) = try await highlighted()
        let rows = SidebarRow.bodyCount, header = RelationHeader.bodyCount
        let tableBodies = GridTable.bodyCount, bars = ChangesBar.bodyCount
        window.resetFrameWork()
        try window.click(window.element(identifier: "grid.refresh"))
        try await window.runUntil { source.markerCalls == 3 && !model.isLoading && model.cachedPages.contains(0) }
        try await window.runUntilIdle()
        // Not vacuous: the refresh landed, and the table and the changes bar rebuilt for it.
        #expect(source.markerCalls == 3)
        #expect(GridTable.bodyCount > tableBodies, "the table did not rebuild")
        #expect(ChangesBar.bodyCount > bars, "the changes bar did not rebuild")
        #expect(SidebarRow.bodyCount == rows, "the sidebar rebuilt")
        #expect(RelationHeader.bodyCount == header, "the relation header rebuilt")
    }
}
