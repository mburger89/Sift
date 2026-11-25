import MetalUI
import MetalUITesting
import SiftCore
import SiftTestSupport
import Testing

@testable import SiftKit

/// The grid in the real app window, over a fake source.
@MainActor
struct GridViewTests {
    let key = ConnectionKey.container(name: "shop-db")
    let orders = RelationID("shop", "orders")

    static func columns() -> [ResultColumn] {
        [
            ResultColumn(name: "id", typeOID: 20, typeName: "int8"),
            ResultColumn(name: "customer_id", typeOID: 20, typeName: "int8"),
            ResultColumn(name: "status", typeOID: 25, typeName: "text"),
            ResultColumn(name: "meta", typeOID: 114, typeName: "json")
        ]
    }

    /// The app window with `orders` selected and its grid over `grid`, count loaded.
    func open(_ grid: FakeGridSource, recordsLayout: Bool = true) async throws -> (Rig, TestWindow, GridModel) {
        let rig = Rig()
        rig.sources[0].setGrid(grid, for: orders)
        await rig.model.refreshDiscovery()
        await rig.model.open(key)
        // A session opens `orders` newest first (its key sorts); these tests read the fake's rows in generated order.
        // Applied in the same turn the grid is made, before anything is asked of the source.
        try #require(rig.model.sessions[key]?.grid(for: orders)).apply(GridQuery())
        let window = try siftWindow(model: rig.model, recordsLayout: recordsLayout)
        rig.model.select(orders, in: key)
        try await window.runUntilIdle()
        let session = try #require(rig.model.sessions[key])
        let model = try #require(session.grid(for: orders))
        try await window.runUntil { model.count != .estimated(0) }
        try await window.runUntilIdle()
        return (rig, window, model)
    }

    func cell(_ window: TestWindow, _ row: Int, _ column: Int) throws -> TestElement {
        try window.element(identifier: "grid.cell.\(row).\(column)")
    }

    @Test func theGridShowsTheFirstWindowAndPlaceholdersUntilPagesArrive() async throws {
        let source = FakeGridSource(columns: Self.columns(), trueCount: 100_000)
        source.holdsPages = true
        let (_, window, model) = try await open(source)
        // The count is in, the page is held: the first rows are placeholders.
        try await window.runUntil { source.pageCalls.count == 1 }
        try await window.runUntilIdle()
        #expect(model.count == .exact(100_000))
        let first = try cell(window, 0, 0)
        #expect(first.value == "loading")
        #expect(try window.element(identifier: "grid.row.0").value == "1")
        #expect(window.hasElement(identifier: "grid.status.loading"))
        source.releaseAll()
        try await window.runUntil { model.cachedPages == [0] }
        try await window.runUntilIdle()
        #expect(try cell(window, 0, 0).value == "0")
        #expect(try cell(window, 2, 2).value == "r2c2")
        #expect(try window.element(identifier: "grid.status.count").value == "100,000 rows")
        #expect(!window.hasElement(identifier: "grid.status.loading"))
    }
}

extension GridViewTests {
    /// The grid with its first page loaded.
    func openLoaded(_ source: FakeGridSource, recordsLayout: Bool = true) async throws -> (Rig, TestWindow, GridModel) {
        let (rig, window, model) = try await open(source, recordsLayout: recordsLayout)
        try await window.runUntil { model.cachedPages.contains(0) }
        try await window.runUntilIdle()
        return (rig, window, model)
    }

    @Test func aHeaderClickSortsOnTheServer() async throws {
        let source = FakeGridSource(columns: Self.columns(), trueCount: 2000)
        let (_, window, model) = try await openLoaded(source)
        try window.click(window.element(label: "customer_id"))
        try await window.runUntil { model.query.sort != nil && model.cachedPages.contains(0) }
        #expect(model.query.sort == GridSort(column: 1, ascending: true))
        #expect(source.pageCalls.last?.query.sort == GridSort(column: 1, ascending: true))
        try await window.runUntilIdle()
        try window.click(window.element(label: "customer_id"))
        try await window.runUntil { model.query.sort?.ascending == false && model.cachedPages.contains(0) }
        #expect(source.pageCalls.last?.query.sort == GridSort(column: 1, ascending: false))
        // The rows are the server's descending order.
        try await window.runUntilIdle()
        #expect(try cell(window, 0, 0).value == "1999")
        // A json column has no comparator: its header does nothing.
        let calls = source.calls.count
        try window.click(window.element(label: "meta"))
        try await window.runUntilIdle()
        #expect(source.calls.count == calls)
        #expect(model.query.sort == GridSort(column: 1, ascending: false))
    }

    @Test func aFilterChipAppliesAndItsErrorShowsOnTheChip() async throws {
        let source = FakeGridSource(columns: Self.columns(), trueCount: 2000)
        let (_, window, model) = try await openLoaded(source)
        try window.click(window.element(identifier: "grid.filter.value"))
        window.typeText("abc")
        try await window.runUntilIdle()
        #expect(model.draftValue == "abc")
        source.trueCount = 7
        try window.click(window.element(identifier: "grid.filter.add"))
        try await window.runUntil { model.count == .exact(7) && model.cachedPages.contains(0) }
        #expect(model.query.filters == [GridFilter(column: 0, op: .contains, value: "abc")])
        try await window.runUntilIdle()
        #expect(try window.element(identifier: "grid.chip.0").value == "id contains abc")
        #expect(try window.element(identifier: "grid.status.count").value == "7 rows")
        #expect(source.pageCalls.last?.query.filters == model.query.filters)

        // A second chip the server refuses: it shows red, with the message, and the first chip's rows stay.
        source.failNext([SourceError(.server(sqlState: "22P02"), "invalid input syntax for type bigint: \"zz\"")])
        model.draftColumn = 1
        model.draftOp = .eq
        model.draftValue = "zz"
        model.addDraftFilter()
        try await window.runUntil { model.error != nil }
        try await window.runUntilIdle()
        let rejected = try window.element(identifier: "grid.chip.rejected.0")
        #expect(rejected.label == "customer_id = zz")
        #expect(rejected.value == "invalid input syntax for type bigint: \"zz\"")
        #expect(try window.element(identifier: "grid.status.error").value == "invalid input syntax for type bigint: \"zz\"")
        #expect(model.query.filters.count == 1 && model.count == .exact(7))
        #expect(try window.element(identifier: "grid.chip.0").value == "id contains abc")
        // Dismissing the red chip clears the message.
        try window.click(window.element(identifier: "grid.chip.rejected.0.remove"))
        try await window.runUntilIdle()
        #expect(!window.hasElement(identifier: "grid.chip.rejected.0"))
        #expect(model.error == nil)
    }

    @Test func searchRunsOnReturnNotPerKeystroke() async throws {
        let source = FakeGridSource(columns: Self.columns(), trueCount: 2000)
        let (_, window, model) = try await openLoaded(source)
        let before = source.calls.count
        window.typeKey("f", modifierFlags: .primary)
        try await window.runUntilIdle()
        window.typeText("abc")
        try await window.runUntilIdle()
        #expect(model.searchText == "abc")
        #expect(model.query.search == nil)
        #expect(source.calls.count == before, "a keystroke queried the server")
        window.typeKey(.return)
        try await window.runUntil { source.pageCalls.last?.query.search == "abc" }
        #expect(model.query.search == "abc")
        #expect(source.calls.contains(.count(GridQuery(search: "abc"))))
    }

    @Test func theInspectorShowsTheActiveCellsFullValueAndPrettyJSON() async throws {
        let long = String(repeating: "word ", count: 120)
        let rows: [[SiftValue]] = [
            [.int(1), .int(10), .text(long), .raw("{\"a\": [1, 2], \"b\": {\"c\": null}, \"d\": \"x\"}")],
            [.int(2), .int(11), .null, .null]
        ]
        let columns = [
            ResultColumn(name: "id", typeOID: 20, typeName: "int8"),
            ResultColumn(name: "customer_id", typeOID: 20, typeName: "int8"),
            ResultColumn(name: "status", typeOID: 25, typeName: "text"),
            ResultColumn(name: "meta", typeOID: 3802, typeName: "jsonb")
        ]
        let source = FakeGridSource(columns: columns, rows: rows)
        let (_, window, _) = try await openLoaded(source)
        // Nothing active: the hint.
        #expect(window.hasElement(identifier: "inspector.empty"))
        // Long text: the cell is clipped to 200 characters, the inspector has it all.
        try window.click(cell(window, 0, 2))
        try await window.runUntilIdle()
        #expect(try window.element(identifier: "inspector.column").value == "status")
        #expect(try window.element(identifier: "inspector.type").value == "text")
        #expect(try window.element(identifier: "inspector.value").value == long)
        let shown = try cell(window, 0, 2).value ?? ""
        #expect(shown.count <= CellFormat.characterLimit + 1 && shown.count < long.count, "the cell is clipped")
        // NULL says NULL, and is not the text.
        try window.click(cell(window, 1, 2))
        try await window.runUntilIdle()
        #expect(try window.element(identifier: "inspector.value").value == "null")
        // JSON: the root is open, its containers are closed until clicked.
        try window.click(cell(window, 0, 3))
        try await window.runUntilIdle()
        #expect(try window.element(identifier: "inspector.type").value == "jsonb")
        #expect(try window.element(identifier: "inspector.json.root").value == "{3}")
        // A container is a disclosure button labelled `key:, summary`; a scalar is a line.
        _ = try window.element(label: "a:, [2]")
        _ = try window.element(label: "b:, {1}")
        #expect(try window.element(identifier: "inspector.json.node./d").value == "\"x\"")
        // Closed until clicked: the array's items are not there.
        #expect(!window.hasElement(identifier: "inspector.json.node./a/0"))
        try window.click(window.element(label: "a:, [2]"))
        try await window.runUntilIdle()
        #expect(try window.element(identifier: "inspector.json.node./a/0").value == "1")
        #expect(try window.element(identifier: "inspector.json.node./a/1").value == "2")
        // The object beside it is still closed.
        #expect(!window.hasElement(identifier: "inspector.json.node./b/c"))
    }

    @Test func primaryCCopiesTheActiveCellsRawText() async throws {
        let long = String(repeating: "word ", count: 120)
        let rows: [[SiftValue]] = [[.int(1), .int(10), .text(long), .null], [.int(2), .int(11), .text("two"), .null]]
        let source = FakeGridSource(columns: Self.columns(), rows: rows)
        let (_, window, _) = try await openLoaded(source)
        try window.click(cell(window, 1, 2))
        try await window.runUntilIdle()
        window.typeKey("c", modifierFlags: .primary)
        #expect(window.platformWindow.clipboard == "two")
        // The whole value, not the clipped cell.
        try window.click(cell(window, 0, 2))
        try await window.runUntilIdle()
        window.typeKey("c", modifierFlags: .primary)
        #expect(window.platformWindow.clipboard == long)
    }

    @Test func endJumpsToTheLastRowAndLoadsOnePage() async throws {
        let source = FakeGridSource(columns: Self.columns(), trueCount: 10_000_000)
        let (_, window, model) = try await openLoaded(source)
        try window.click(cell(window, 0, 1))
        try await window.runUntilIdle()
        let before = source.pageCalls.count
        window.typeKey(.downArrow, modifierFlags: .primary)
        try await window.runUntil { model.cachedPages.contains(19_999) }
        try await window.runUntilIdle()
        let jump = Array(source.pageCalls.dropFirst(before))
        #expect(jump.map(\.index) == [19_999], "\(jump.map(\.index))")
        #expect(jump.first?.keyset == false)
        #expect(model.activePosition == GridPosition(row: 9_999_999, column: 1))
        #expect(try cell(window, 9_999_999, 0).value == "9999999")
        #expect(try window.element(identifier: "grid.row.9999999").value == "10000000")
    }

    @Test func nullIsDrawnDistinctly() async throws {
        let rows: [[SiftValue]] = [[.int(1), .null, .text(""), .text("NULL")]]
        let source = FakeGridSource(columns: Self.columns(), rows: rows)
        let (_, window, _) = try await openLoaded(source)
        #expect(try cell(window, 0, 1).value == "null")
        #expect(try cell(window, 0, 2).value == "empty")
        #expect(try cell(window, 0, 3).value == "NULL", "the text NULL is plain text")
        #expect(try cell(window, 0, 0).value == "1")
    }

    @Test func theStatusBarOffersAnExactCountForAnEstimate() async throws {
        let source = FakeGridSource(columns: Self.columns(), trueCount: 3_000_000, count: .estimated(2_500_000))
        let (_, window, model) = try await openLoaded(source)
        #expect(try window.element(identifier: "grid.status.count").value == "\u{2248} 2,500,000 rows")
        try window.click(window.element(identifier: "grid.status.countExactly"))
        try await window.runUntil { model.count == .exact(3_000_000) }
        try await window.runUntilIdle()
        #expect(try window.element(identifier: "grid.status.count").value == "3,000,000 rows")
        #expect(!window.hasElement(identifier: "grid.status.countExactly"))
    }

    @Test func aSearchOverAHugeRelationWarnsOfAFullScan() async throws {
        let source = FakeGridSource(columns: Self.columns(), trueCount: 3_000_000, count: .estimated(2_500_000))
        let (_, window, model) = try await openLoaded(source)
        #expect(!window.hasElement(identifier: "grid.status.fullScan"))
        model.searchText = "x"
        model.submitSearch()
        try await window.runUntilIdle()
        #expect(try window.element(identifier: "grid.status.fullScan").value == "full scan")
    }

    @Test func aRelationWithoutAStableKeySaysSo() async throws {
        let source = FakeGridSource(columns: Self.columns(), trueCount: 10)
        source.setOrderNote("no stable key: rows may shift")
        let (_, window, _) = try await openLoaded(source)
        #expect(try window.element(identifier: "grid.status.note").value == "no stable key: rows may shift")
    }

    @Test func theStructureTabKeepsTheGridsState() async throws {
        let source = FakeGridSource(columns: Self.columns(), trueCount: 2000)
        let (rig, window, model) = try await openLoaded(source)
        model.apply(GridQuery(sort: GridSort(column: 1, ascending: false)))
        try await window.runUntil { model.cachedPages.contains(0) }
        rig.model.relationTab = .structure
        try await window.runUntilIdle()
        #expect(window.shows("customer_id → customers.id"))
        #expect(!window.hasElement(identifier: "grid"))
        rig.model.relationTab = .rows
        try await window.runUntilIdle()
        #expect(window.hasElement(identifier: "grid"))
        #expect(rig.model.sessions[key]?.grid(for: orders) === model)
        #expect(model.query.sort == GridSort(column: 1, ascending: false))
    }
}

extension TestWindow {
    func hasElement(identifier: String) -> Bool { (try? element(identifier: identifier)) != nil }
}

extension GridViewTests {
    @Test func aGridThatLosesItsConnectionStartsTheReconnect() async throws {
        let rig = Rig(sources: [fakeShopSource(), fakeShopSource(oidShift: 500)])
        let first = FakeGridSource(columns: Self.columns(), trueCount: 2000)
        rig.sources[0].setGrid(first, for: orders)
        await rig.model.refreshDiscovery()
        await rig.model.open(key)
        let window = try siftWindow(model: rig.model)
        rig.model.select(orders, in: key)
        let session = try #require(rig.model.sessions[key])
        let grid = try #require(session.grid(for: orders))
        try await window.runUntil { grid.cachedPages.contains(0) }
        // The grid's own connection drops while the session's does not know yet.
        first.failNext([SourceError(.connectionLost, "server closed the connection")])
        grid.apply(GridQuery(sort: GridSort(column: 1, ascending: true)))
        try await window.runUntil { if case .lost = session.state { return true } else { return false } }
        #expect(first.isClosed || rig.sources[0].isClosed, "the old source was closed")
        // The reconnect gives a new source and a new grid.
        await session.reconnectNow()
        try await window.runUntil { session.state == .ready }
        let fresh = try #require(session.grid(for: orders))
        #expect(fresh !== grid)
    }
}
