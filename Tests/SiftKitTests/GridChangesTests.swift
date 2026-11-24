import Foundation
import Observation
import SiftCore
import SiftTestSupport
import Testing

@testable import SiftKit

/// Refresh, change marks and newest-first in `GridModel`, over a fake source.
@MainActor
struct GridChangesTests {
    func settle(_ what: String = "condition", _ condition: () -> Bool) async throws {
        for _ in 0..<3000 where !condition() { await Task.yield() }
        if !condition() { throw GridTestError.timedOut(what) }
    }

    func source(rows: Int = 50, changed: Set<Int> = []) -> FakeGridSource {
        let s = FakeGridSource(trueCount: rows)
        s.supportsChanges = true
        s.keyColumns = [0]
        s.setChanged(changed)
        return s
    }

    /// A model whose opening marker and first page have landed.
    func opened(_ source: FakeGridSource, initialQuery: GridQuery = GridQuery()) async throws -> GridModel {
        let model = GridModel(source: source, initialQuery: initialQuery)
        try await settle("idle") { !model.isLoading && model.count != .estimated(0) }
        _ = model.value(row: 0, column: 0)
        try await settle("page 0") { model.cachedPages == [0] }
        try await settle("idle") { !model.isLoading }
        return model
    }

    func refreshed(_ model: GridModel, _ source: FakeGridSource, markers: Int) async throws {
        model.refresh()
        try await settle("marker") { source.markerCalls == markers }
        try await settle("idle") { !model.isLoading }
        _ = model.value(row: 0, column: 0)
        try await settle("page") { model.cachedPages.contains(0) && !model.isLoading }
    }

    @Test func openingTakesAMarkerBeforeTheFirstPage() async throws {
        let source = source()
        source.holdsMarkers = true
        let model = GridModel(source: source)
        _ = model.value(row: 0, column: 0)
        try await settle("marker call") { source.markerCalls == 1 }
        for _ in 0..<50 { await Task.yield() }
        #expect(source.calls == [.marker], "nothing else starts while the marker is out: \(source.calls)")
        source.releaseAll()
        try await settle("page 0") { model.cachedPages == [0] }
        guard case .marker = source.calls[0] else { Issue.record("marker first: \(source.calls)"); return }
        let pageAt = source.calls.firstIndex { if case .page = $0 { true } else { false } }
        #expect(pageAt != nil && pageAt! > 0)
    }

    @Test func refreshTakesAMarkerThenReadsWithChangesSinceThePreviousOne() async throws {
        let source = source(changed: [3])
        source.setMarkers(["10", "20", "30"])
        let model = try await opened(source)
        #expect(model.query.changes == nil)
        try await refreshed(model, source, markers: 2)
        #expect(model.query.changes == ChangeFilter(since: "10"))
        #expect(model.changesSince != nil)
        try await refreshed(model, source, markers: 3)
        #expect(model.query.changes == ChangeFilter(since: "20"))
        // Every look reads its pages after its marker.
        var markerSeen = false
        for call in source.calls {
            if case .marker = call { markerSeen = true }
            if case .page = call { #expect(markerSeen) }
        }
        let last = try #require(source.pageCalls.last)
        #expect(last.query.changes?.since == "20")
    }

    @Test func flaggedRowsAreMarkedAndUnflaggedAreNot() async throws {
        let source = source(changed: [2, 5])
        let model = try await opened(source)
        try await refreshed(model, source, markers: 2)
        #expect(model.mark(row: 2) != nil)
        #expect(model.mark(row: 5) != nil)
        #expect(model.mark(row: 3) == nil)
        #expect(model.mark(row: 1000) == nil)
    }

    @Test func aChangedRowWithAKnownKeyMarksOnlyItsChangedCells() async throws {
        let source = source(changed: [2])
        let model = try await opened(source)
        source.setValue(.text("new"), row: 2, column: 3)
        source.setValue(.text("new"), row: 2, column: 1)
        try await refreshed(model, source, markers: 2)
        #expect(model.mark(row: 2) == .changed(cells: [1, 3]))
    }

    @Test func aFlaggedRowWithNoCopyIsNewOrChanged() async throws {
        let source = source(rows: 50, changed: [2, 49])
        source.setChanged([2, 60])
        source.trueCount = 50
        let model = try await opened(source)
        source.trueCount = 61
        source.setChanged([2, 60])
        try await refreshed(model, source, markers: 2)
        // Row 2 had a copy and is unchanged: a changed row with no cells (a no-op update).
        #expect(model.mark(row: 2) == .changed(cells: []))
        _ = model.value(row: 60, column: 0)
        try await settle("page 0 still") { model.cachedPages.contains(0) }
        // Row 60 is in page 0 only because the count is 61 and the page holds 500: it has no old copy.
        #expect(model.mark(row: 60) == .newOrChanged)
    }

    @Test func noKeyColumnsMeansRowMarksOnly() async throws {
        let source = source(changed: [2])
        source.keyColumns = []
        let model = try await opened(source)
        source.setValue(.text("new"), row: 2, column: 1)
        try await refreshed(model, source, markers: 2)
        #expect(model.mark(row: 2) == .newOrChanged)
    }

    @Test func aStaleMarkerAfterClearOrASecondRefreshNeverLands() async throws {
        let source = source(changed: [1])
        source.setMarkers(["10", "20", "30", "40"])
        let model = try await opened(source)
        source.holdsMarkers = true
        model.refresh()
        try await settle("marker 2") { source.markerCalls == 2 }
        model.refresh()
        try await settle("marker 3") { source.markerCalls == 3 }
        // Answer the newer one first, then the superseded one.
        source.release(callAt: source.calls.count - 1)
        try await settle("landed") { model.query.changes != nil }
        #expect(model.query.changes == ChangeFilter(since: "10"))
        source.release(callAt: source.calls.count - 2)
        for _ in 0..<50 { await Task.yield() }
        // The superseded marker answered ("30") and was dropped: the look is still the one the newer marker made.
        #expect(model.query.changes == ChangeFilter(since: "10"))
        source.holdsMarkers = false
        try await settle("idle") { !model.isLoading }
        model.refresh()
        try await settle("marker 4") { source.markerCalls == 4 }
        try await settle("next look") { model.query.changes?.since != "10" }
        // The stale answer did not become the previous marker: the newer one ("20") did.
        #expect(model.query.changes?.since == "20")

        // Clear while a refresh is pending drops its marker.
        let source2 = self.source(changed: [1])
        let model2 = try await opened(source2)
        source2.holdsMarkers = true
        model2.refresh()
        try await settle("marker") { source2.markerCalls == 2 }
        model2.clearChanges()
        source2.releaseAll()
        for _ in 0..<50 { await Task.yield() }
        #expect(model2.query.changes == nil)
        #expect(model2.changesSince == nil)
    }

    @Test func sortAndFilterKeepTheHighlight() async throws {
        let source = source(changed: [2])
        let model = try await opened(source)
        try await refreshed(model, source, markers: 2)
        var next = model.query
        next.sort = GridSort(column: 1, ascending: true)
        model.apply(next)
        #expect(model.query.changes != nil)
        next.filters = [GridFilter(column: 1, op: .contains, value: "r")]
        model.apply(next)
        #expect(model.query.changes != nil)
        #expect(model.changesSince != nil)
        #expect(source.markerCalls == 2)
    }

    @Test func clearDropsTheHighlight() async throws {
        let source = source(changed: [2])
        source.setMarkers(["10", "20", "30"])
        let model = try await opened(source)
        try await refreshed(model, source, markers: 2)
        model.clearChanges()
        #expect(model.query.changes == nil)
        #expect(model.changesSince == nil)
        try await settle("page") { model.cachedPages.isEmpty || !model.isLoading }
        _ = model.value(row: 2, column: 0)
        try await settle("page 0") { model.cachedPages == [0] }
        #expect(model.mark(row: 2) == nil)
        // The marker is kept: the next refresh covers everything since the last look.
        try await refreshed(model, source, markers: 3)
        #expect(model.query.changes?.since == "20")
    }

    @Test func onlyChangesNarrowsAndRecounts() async throws {
        let source = source(rows: 50, changed: [2, 7, 9])
        let model = try await opened(source)
        try await refreshed(model, source, markers: 2)
        model.setOnlyChanges(true)
        #expect(model.query.changes?.only == true)
        try await settle("count") { model.count == .exact(3) }
        _ = model.value(row: 0, column: 0)
        try await settle("page") { model.cachedPages == [0] }
        #expect(model.value(row: 1, column: 0) == .int(7))
        model.setOnlyChanges(false)
        try await settle("count") { model.count == .exact(50) }
    }

    @Test func anUnsupportedSourceRefreshesWithoutMarkers() async throws {
        let source = FakeGridSource(trueCount: 50)
        let model = try await opened(source)
        let before = source.pageCalls.count
        model.refresh()
        try await settle("reread") { source.pageCalls.count == before + 1 || (model.isLoading == false && model.cachedPages.isEmpty) }
        _ = model.value(row: 0, column: 0)
        try await settle("page") { source.pageCalls.count == before + 1 && model.cachedPages == [0] }
        #expect(source.markerCalls == 0)
        #expect(model.query.changes == nil)
        #expect(model.changesSince == nil)
    }

    @Test func theTrailingFlagNeverReachesValueReads() async throws {
        let source = source(changed: [2])
        let model = try await opened(source)
        try await refreshed(model, source, markers: 2)
        for c in 0..<5 { #expect(model.value(row: 2, column: c) != nil) }
        #expect(model.value(row: 2, column: 5) == nil)
        #expect(model.value(row: 2, column: 1) == .text("r2c1"))
        #expect(model.columns.count == 5)
    }

    @Test func markReadsNoObservableState() async throws {
        let source = source(changed: [2])
        let model = try await opened(source)
        try await refreshed(model, source, markers: 2)
        let changed = Flag()
        withObservationTracking {
            _ = model.mark(row: 2)
            _ = model.mark(row: 3)
            _ = model.mark(row: 900)
        } onChange: { changed.set() }
        model.refresh()
        try await settle("marker") { source.markerCalls == 3 }
        try await settle("idle") { !model.isLoading }
        #expect(!changed.value, "mark(row:) read observable state")
    }

    @Test func newestFirstToggleSetsAndClearsTheDescNullsLastSort() async throws {
        let source = source()
        let model = GridModel(source: source)
        let nullable = GridSort(column: 3, ascending: false, nullsLast: true)
        let notNull = GridSort(column: 0, ascending: false, nullsLast: false)
        model.recencySorts = [nullable, notNull]
        #expect(model.recencyColumns == [3, 0])
        #expect(model.newestColumn == 3)
        #expect(!model.isNewestFirst)
        model.setNewestFirst(true)
        #expect(model.query.sort == nullable)
        #expect(model.isNewestFirst)
        model.setNewestColumn(0)
        #expect(model.query.sort == notNull)
        #expect(model.newestColumn == 0)
        model.setNewestFirst(false)
        #expect(model.query.sort == nil)
        #expect(!model.isNewestFirst)
        #expect(model.newestColumn == 0)
    }

    @Test func aHeaderSortTurnsNewestFirstOff() async throws {
        let source = source()
        let newest = GridSort(column: 0, ascending: false, nullsLast: false)
        let model = GridModel(source: source, initialQuery: GridQuery(sort: newest))
        model.recencySorts = [newest]
        #expect(model.isNewestFirst)
        var next = model.query
        next.sort = GridSort(column: 1, ascending: true)
        model.apply(next)
        #expect(!model.isNewestFirst)
        next.sort = GridSort(column: 0, ascending: true)
        model.apply(next)
        #expect(!model.isNewestFirst)
    }

    @Test func theSessionOpensACheapRecencyGridNewestFirst() async throws {
        let customers = RelationID("shop", "customers")
        let rig = Rig()
        let key = ConnectionKey.container(name: "shop-db")
        await rig.model.refreshDiscovery()
        await rig.model.open(key)
        let session = try #require(rig.model.sessions[key])
        #expect(session.existingGrid(for: customers) == nil)
        let relation = try #require(session.snapshot?.relation(customers))
        let grid = try #require(session.grid(for: customers))
        #expect(session.existingGrid(for: customers) === grid)
        let expected = RecencyColumns.newestSort(column: RecencyColumns.candidates(for: relation)[0], in: relation)
        #expect(grid.query.sort == expected)
        #expect(grid.isNewestFirst)
        #expect(!grid.recencyColumns.isEmpty)
    }

    @Test func aDiffOfAFullPageCostsOnePassOverIt() async throws {
        let source = source(rows: 500, changed: Set(0..<500))
        let model = try await opened(source)
        for row in 0..<500 { source.setValue(.text("x"), row: row, column: 2) }
        // The count read for the model's own use before the refresh.
        let before = model.diffComparisons
        try await refreshed(model, source, markers: 2)
        #expect(model.mark(row: 10) == .changed(cells: [2]))
        let spent = model.diffComparisons - before
        #expect(spent > 0 && spent <= 500 * model.columns.count, "\(spent)")
    }
}
