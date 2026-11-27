import Foundation
import MetalUI
import MetalUITesting
import SiftCore
import SiftTestSupport
import Testing

@testable import SiftKit

/// Newest first, the change highlight and Refresh in the real app window, over the fake source that flags changes.
@MainActor
struct GridChangesViewTests {
    let key = ConnectionKey.container(name: "shop-db")
    let orders = RelationID("shop", "orders")

    func source(rows: Int = 50, changed: Set<Int> = []) -> FakeGridSource {
        let s = FakeGridSource(columns: GridViewTests.columns(), trueCount: rows)
        s.supportsChanges = true
        s.keyColumns = [0]
        s.setChanged(changed)
        return s
    }

    /// The grid open in the app window (with the menu commands installed), first page and marker landed.
    func open(_ source: FakeGridSource, sorts: [GridSort] = []) async throws -> (Rig, TestWindow, GridModel) {
        let rig = Rig()
        rig.sources[0].setGrid(source, for: orders)
        await rig.model.refreshDiscovery()
        await rig.model.open(key)
        let session = try #require(rig.model.sessions[key])
        let model = try #require(session.grid(for: orders))
        model.apply(GridQuery())
        model.recencySorts = sorts
        let (_, window) = try siftApp(model: rig.model)
        rig.model.select(orders, in: key)
        try await window.runUntilIdle()
        try await window.runUntil { model.count != .estimated(0) && model.cachedPages.contains(0) }
        try await window.runUntilIdle()
        return (rig, window, model)
    }

    func refresh(_ window: TestWindow, _ model: GridModel, _ source: FakeGridSource, markers: Int) async throws {
        try window.click(window.element(identifier: "grid.refresh"))
        try await window.runUntil { source.markerCalls == markers && model.changesSince != nil && !model.isLoading }
        try await window.runUntilIdle()
    }

    static let newest0 = GridSort(column: 0, ascending: false)
    static let newest1 = GridSort(column: 1, ascending: false)

    @Test func theNewestToggleIsHiddenWithoutCandidatesAndShowsThePickerWithTwo() async throws {
        let (_, window, model) = try await open(source())
        #expect(!window.hasElement(identifier: "grid.newest"))
        #expect(try pickers(window).isEmpty)
        model.recencySorts = [Self.newest0]
        try await window.runUntilIdle()
        #expect(window.hasElement(identifier: "grid.newest"))
        #expect(try pickers(window).isEmpty, "one candidate needs no picker")
        model.recencySorts = [Self.newest0, Self.newest1]
        try await window.runUntilIdle()
        #expect(window.hasElement(identifier: "grid.newest"))
        // The picker is a label and a pop-up under one identifier.
        #expect(try pickers(window).count == 1)
    }

    func pickers(_ window: TestWindow) throws -> [TestElement] {
        try window.elements(where: { $0.identifier == "grid.newest.column" && $0.role == .popUpButton })
    }

    @Test func clickingNewestSortsAndAHeaderClickTurnsItOff() async throws {
        let src = source(rows: 2000)
        let (_, window, model) = try await open(src, sorts: [Self.newest0])
        #expect(try window.element(identifier: "grid.newest").value == "off")
        try window.click(window.element(identifier: "grid.newest"))
        try await window.runUntil { model.isNewestFirst && model.cachedPages.contains(0) }
        try await window.runUntilIdle()
        #expect(model.query.sort == Self.newest0)
        #expect(try window.element(identifier: "grid.newest").value == "on")
        // A header click sorts by another column: newest first is off, and the toggle says so.
        try window.click(window.element(label: "customer_id"))
        try await window.runUntil { model.query.sort == GridSort(column: 1, ascending: true) && model.cachedPages.contains(0) }
        try await window.runUntilIdle()
        #expect(!model.isNewestFirst)
        #expect(try window.element(identifier: "grid.newest").value == "off")
        // The toggle again turns it on, and once more off (no sort).
        try window.click(window.element(identifier: "grid.newest"))
        try await window.runUntil { model.isNewestFirst && model.cachedPages.contains(0) }
        try await window.runUntilIdle()
        try window.click(window.element(identifier: "grid.newest"))
        try await window.runUntil { model.query.sort == nil && model.cachedPages.contains(0) }
        #expect(!model.isNewestFirst)
    }

    @Test func refreshTintsChangedRowsAndCells() async throws {
        let src = source(changed: [2])
        let (_, window, model) = try await open(src)
        src.setValue(.text("new"), row: 2, column: 1)
        try await refresh(window, model, src, markers: 2)
        #expect(model.mark(row: 2) == .changed(cells: [1]))
        let view = GridViewTests()
        // The marks are in the cells' accessibility values: colour is not the only signal.
        #expect(try view.cell(window, 2, 1).value == "changed")
        #expect(try view.cell(window, 2, 0).value == "row changed")
        #expect(try view.cell(window, 2, 2).value == "row changed")
        #expect(try view.cell(window, 3, 1).value == "r3c1")
        // The fill: "#" is table column 0, data column c is table column c + 1.
        let cellFill = Color(ChangeCellFill.self), rowFill = Color(ChangeRowFill.self)
        #expect(GridTable.fill(model, TableCell(row: 2, column: 2)) == cellFill)
        #expect(GridTable.fill(model, TableCell(row: 2, column: 0)) == rowFill)
        #expect(GridTable.fill(model, TableCell(row: 2, column: 1)) == rowFill)
        #expect(GridTable.fill(model, TableCell(row: 3, column: 2)) == nil)
    }

    @Test func aNewOrChangedRowSaysSo() async throws {
        let src = source(changed: [2])
        src.keyColumns = []
        let (_, window, model) = try await open(src)
        try await refresh(window, model, src, markers: 2)
        #expect(model.mark(row: 2) == .newOrChanged)
        #expect(try GridViewTests().cell(window, 2, 1).value == "new or changed")
        #expect(GridTable.fill(model, TableCell(row: 2, column: 2)) == Color(ChangeRowFill.self))
    }

    @Test func theStatusBarSaysChangesSinceTheLookTime() async throws {
        // The text, in a fixed zone: 2026-11-23 10:42:13 UTC is 11:42:13 in Berlin.
        let date = Date(timeIntervalSince1970: 1_795_430_533)
        let utc = try #require(TimeZone(identifier: "UTC")), berlin = try #require(TimeZone(identifier: "Europe/Berlin"))
        #expect(ChangesBar.sinceText(date, in: utc) == "Changes since 10:42:13")
        #expect(ChangesBar.sinceText(date, in: berlin) == "Changes since 11:42:13")
        // And on screen, from the look's own time, in the window's zone.
        let src = source(changed: [2])
        let (_, window, model) = try await open(src)
        #expect(!window.hasElement(identifier: "grid.changes.since"))
        try await refresh(window, model, src, markers: 2)
        let since = try #require(model.changesSince)
        #expect(try window.element(identifier: "grid.changes.since").value == ChangesBar.sinceText(since, in: .current))
    }

    @Test func onlyChangesAndClearWork() async throws {
        let src = source(changed: [2, 7])
        let (_, window, model) = try await open(src)
        try await refresh(window, model, src, markers: 2)
        #expect(try window.element(identifier: "grid.status.count").value == "50 rows")
        try window.click(window.element(identifier: "grid.changes.only"))
        try await window.runUntil { model.query.changes?.only == true && model.cachedPages.contains(0) && !model.isLoading }
        try await window.runUntilIdle()
        #expect(try window.element(identifier: "grid.status.count").value == "2 rows")
        // Off again: the count is the whole relation's, not the narrowed one.
        try window.click(window.element(identifier: "grid.changes.only"))
        try await window.runUntil { model.query.changes?.only == false && model.cachedPages.contains(0) && !model.isLoading }
        try await window.runUntilIdle()
        #expect(try window.element(identifier: "grid.status.count").value == "50 rows")
        try window.click(window.element(identifier: "grid.changes.clear"))
        try await window.runUntil { model.query.changes == nil && model.cachedPages.contains(0) }
        try await window.runUntilIdle()
        #expect(model.changesSince == nil)
        #expect(!window.hasElement(identifier: "grid.changes.since"))
        #expect(!window.hasElement(identifier: "grid.changes.clear"))
        #expect(try GridViewTests().cell(window, 2, 1).value == "r2c1")
    }

    @Test func primaryRRefreshesTheShowingGrid() async throws {
        let src = source(changed: [2])
        let (rig, window, model) = try await open(src)
        #expect(src.markerCalls == 1)
        window.typeKey("r", modifierFlags: .primary)
        try await window.runUntil { src.markerCalls == 2 && model.changesSince != nil && !model.isLoading }
        try await window.runUntilIdle()
        #expect(model.mark(row: 2) != nil)
        // The Structure tab and the map do not refresh a grid.
        rig.model.relationTab = .structure
        try await window.runUntilIdle()
        window.typeKey("r", modifierFlags: .primary)
        try await window.runUntilIdle()
        for _ in 0..<50 { await Task.yield() }
        #expect(src.markerCalls == 2, "the structure tab refreshed the grid")
        rig.model.relationTab = .rows
        rig.model.detailMode = .map
        try await window.runUntilIdle()
        window.typeKey("r", modifierFlags: .primary)
        try await window.runUntilIdle()
        for _ in 0..<50 { await Task.yield() }
        #expect(src.markerCalls == 2, "the map refreshed the grid")
    }

    @Test func primaryRKeepsTheGridWhenOnlyTheEstimateMoved() async throws {
        let src = source(changed: [2])
        let (rig, window, model) = try await open(src)
        // Autovacuum moved reltuples between the open and the refresh; the structure is the same.
        var moved = rig.sources[0].schema
        let index = try #require(moved.relations.firstIndex { $0.id == orders })
        var relations = moved.relations
        relations[index].rowEstimate = .estimated(12345)
        moved = SchemaSnapshot(
            serverVersion: moved.serverVersion, schemas: moved.schemas, relations: relations, foreignKeys: moved.foreignKeys)
        rig.sources[0].schema = moved
        window.typeKey("r", modifierFlags: .primary)
        try await window.runUntil { src.markerCalls == 2 && model.changesSince != nil && !model.isLoading }
        try await window.runUntilIdle()
        for _ in 0..<50 { await Task.yield() }
        #expect(rig.model.sessions[key]?.existingGrid(for: orders) === model, "the grid was dropped")
        #expect(model.changesSince != nil)
        #expect(window.hasElement(identifier: "grid.changes.since"))
        #expect(model.mark(row: 2) != nil)
    }

    @Test func aChangedStructureStartsTheGridAgain() async throws {
        let src = source(changed: [2])
        let (rig, window, model) = try await open(src)
        var snapshot = rig.sources[0].schema
        var relations = snapshot.relations
        let index = try #require(relations.firstIndex { $0.id == orders })
        relations[index].columns.removeLast()
        snapshot = SchemaSnapshot(
            serverVersion: snapshot.serverVersion, schemas: snapshot.schemas, relations: relations, foreignKeys: snapshot.foreignKeys)
        rig.sources[0].schema = snapshot
        await rig.model.sessions[key]?.refreshSchema()
        #expect(rig.model.sessions[key]?.existingGrid(for: orders) == nil)
        _ = window
        _ = model
    }

    func selfFollow() -> GridFollow {
        GridFollow(
            target: orders, filters: [GridFilter(column: 0, op: .eq, value: "2")], title: "orders", targetColumn: 0)
    }

    @Test func aFollowIntoAHighlightedGridKeepsTheHighlightAndTheBar() async throws {
        let src = source(changed: [2])
        let (rig, window, model) = try await open(src)
        try await refresh(window, model, src, markers: 2)
        let since = try #require(model.changesSince)
        rig.model.follow(selfFollow(), in: key)
        try await window.runUntil { model.query.filters.count == 1 && model.cachedPages.contains(0) && !model.isLoading }
        try await window.runUntilIdle()
        #expect(model.query.changes != nil, "the follow dropped the changes")
        #expect(model.changesSince == since)
        #expect(window.hasElement(identifier: "grid.changes.since"))
    }

    @Test func aFollowIntoAnOnlyChangesGridKeepsTheHighlightButShowsAllRows() async throws {
        let src = source(changed: [2])
        let (rig, window, model) = try await open(src)
        try await refresh(window, model, src, markers: 2)
        model.setOnlyChanges(true)
        try await window.runUntil { model.query.changes?.only == true && model.cachedPages.contains(0) && !model.isLoading }
        // The followed row is not among the changed ones: "only changes" would land on nothing.
        src.setChanged([])
        rig.model.follow(selfFollow(), in: key)
        try await window.runUntil { model.query.filters.count == 1 && model.cachedPages.contains(0) && !model.isLoading }
        try await window.runUntilIdle()
        #expect(model.query.changes != nil, "the follow dropped the highlight")
        #expect(model.query.changes?.only == false, "the follow carried only-changes")
        #expect(model.count.value > 0)
        #expect(model.value(row: 0, column: 0) != nil, "the followed row is missing")
    }

    @Test func backAfterARefreshRestoresTheCurrentMarkerNotTheOlderOne() async throws {
        let src = source(changed: [2])
        src.setMarkers(["10", "20", "30", "40"])
        let (rig, window, model) = try await open(src)
        try await refresh(window, model, src, markers: 2)
        #expect(model.query.changes?.since == "10")
        rig.model.follow(selfFollow(), in: key)
        try await window.runUntil { model.query.filters.count == 1 && model.cachedPages.contains(0) && !model.isLoading }
        try await window.runUntilIdle()
        try await refresh(window, model, src, markers: 3)
        #expect(model.query.changes?.since == "20")
        let newer = try #require(model.changesSince)
        rig.model.goBack()
        try await window.runUntil { model.query.filters.isEmpty && model.cachedPages.contains(0) && !model.isLoading }
        try await window.runUntilIdle()
        #expect(model.query.changes?.since == "20", "Back restored the older marker: \(String(describing: model.query.changes))")
        #expect(model.changesSince == newer)
    }

    @Test func backIntoAGridWhoseChangesWereClearedShowsNeitherAHighlightNorABar() async throws {
        let src = source(changed: [2])
        let (rig, window, model) = try await open(src)
        try await refresh(window, model, src, markers: 2)
        rig.model.follow(selfFollow(), in: key)
        try await window.runUntil { model.query.filters.count == 1 && model.cachedPages.contains(0) && !model.isLoading }
        try window.click(window.element(identifier: "grid.changes.clear"))
        try await window.runUntil { model.query.changes == nil && model.cachedPages.contains(0) && !model.isLoading }
        try await window.runUntilIdle()
        rig.model.goBack()
        try await window.runUntil { model.query.filters.isEmpty && model.cachedPages.contains(0) && !model.isLoading }
        try await window.runUntilIdle()
        #expect(model.query.changes == nil, "Back restored a change filter into a grid with no highlight")
        #expect(model.changesSince == nil)
        #expect(!window.hasElement(identifier: "grid.changes.since"))
        #expect(model.mark(row: 2) == nil)
    }

    @Test func aRefreshDemotesAnExactCountToAnEstimate() async throws {
        let src = source(rows: 2000)
        let (_, window, model) = try await open(src)
        // The first refresh switches the changes on, which resets the count; the second is the plain one.
        try await refresh(window, model, src, markers: 2)
        model.countExactly()
        try await window.runUntil { model.count.isExact && !model.isCountingExactly }
        src.countAnswer = .estimated(1_000_000)
        try await refresh(window, model, src, markers: 3)
        #expect(model.count == .estimated(1_000_000), "\(model.count)")
    }

    @Test func theInspectorShowsTheNewValueAfterARefresh() async throws {
        let src = source(changed: [2])
        let (_, window, model) = try await open(src)
        try window.click(GridViewTests().cell(window, 2, 2))
        try await window.runUntilIdle()
        #expect(model.activePosition == GridPosition(row: 2, column: 2))
        #expect(try window.element(identifier: "inspector.value").value == "r2c2")
        src.setValue(.text("NEW"), row: 2, column: 2)
        try await refresh(window, model, src, markers: 2)
        #expect(model.value(row: 2, column: 2) == .text("NEW"))
        #expect(try GridViewTests().cell(window, 2, 2).value == "changed")
        #expect(try window.element(identifier: "inspector.value").value == "NEW", "the inspector kept the old value")
    }

    @Test func aFollowThatLandsOnTheSamePositionUpdatesTheInspector() async throws {
        let src = source()
        let (rig, window, model) = try await open(src)
        try window.click(GridViewTests().cell(window, 0, 0))
        try await window.runUntilIdle()
        #expect(model.activePosition == GridPosition(row: 0, column: 0))
        #expect(try window.element(identifier: "inspector.value").value == "0")
        // The follow sorts newest first (the first key, descending): the same position holds another row's value.
        rig.model.follow(selfFollow(), in: key)
        try await window.runUntil { model.query.filters.count == 1 && model.cachedPages.contains(0) && !model.isLoading }
        try await window.runUntilIdle()
        #expect(model.activePosition == GridPosition(row: 0, column: 0))
        #expect(model.value(row: 0, column: 0) == .int(49))
        #expect(try window.element(identifier: "inspector.value").value == "49", "the inspector kept the old value")
    }
}
