import MetalUI
import MetalUITesting
import SiftCore
import SiftTestSupport
import Testing

@testable import SiftKit

@MainActor
struct RelationDetailTests {
    let key = ConnectionKey.container(name: "shop-db")
    let orders = RelationID("shop", "orders")
    let customers = RelationID("shop", "customers")

    /// A connected rig, a window, and `relation` selected on `tab`, settled. On the rows tab the grid's count is in.
    func open(_ relation: RelationID, rig: Rig? = nil, recordsLayout: Bool = true,
              tab: RelationTab = .structure) async throws -> (Rig, TestWindow) {
        let rig = rig ?? Rig()
        await rig.model.refreshDiscovery()
        await rig.model.open(key)
        rig.model.relationTab = tab
        let window = try siftWindow(model: rig.model, recordsLayout: recordsLayout)
        rig.model.select(relation, in: key)
        try await window.runUntilIdle()
        if tab == .rows {
            let grid = try #require(rig.model.sessions[key]?.grid(for: relation))
            try await window.runUntil { grid.count != .estimated(0) && !grid.isLoading }
            try await window.runUntilIdle()
        }
        return (rig, window)
    }

    @Test func selectingATableShowsColumnsKeysAndIndexes() async throws {
        let (_, window) = try await open(orders)
        #expect(window.shows("customer_id"))
        #expect(window.shows("bigint"))
        #expect(window.shows("customer_id → customers.id"))
        #expect(window.shows("orders_open_idx"))
        #expect(try window.element(identifier: "detail.title").value == "orders")
        #expect(window.shows("Read-only"))
    }

    @Test func incomingForeignKeysAreListed() async throws {
        let (_, window) = try await open(customers)
        #expect(window.shows("orders.customer_id"))
        #expect(window.shows("events.customer_id"))
    }

    @Test func clickingAForeignKeyNavigates() async throws {
        let (rig, window) = try await open(orders)
        try window.click(window.element(label: "customer_id → customers.id"))
        try await window.runUntilIdle()
        #expect(rig.model.selection == .relation(key, customers))
        #expect(try window.element(identifier: "detail.title").value == "customers")
    }

    @Test func nullIsDistinctFromEmpty() async throws {
        let (_, window) = try await open(orders, tab: .rows)
        // `orders` opens newest first (id descending): the preview's first row is the last one.
        let null = try window.element(identifier: "grid.cell.2.2")
        let empty = try window.element(identifier: "grid.cell.1.2")
        #expect(null.value == "null")
        #expect(empty.value == "empty")
        // Not vacuous: ordinary cells are there and read as their values.
        #expect(try window.element(identifier: "grid.cell.0.1").value == "10")
        #expect(try window.element(identifier: "grid.cell.0.2").value == "done")
    }

    @Test func exactCountReplacesTheEstimate() async throws {
        let (_, window) = try await open(orders)
        #expect(try window.element(identifier: "detail.rowCount").value == "≈3 rows")
        try window.click(window.element(label: "Count rows"))
        try await window.runUntil { (try? window.element(identifier: "detail.rowCount").value) == "3 rows (exact)" }
        #expect(try window.element(identifier: "detail.rowCount").value == "3 rows (exact)")
    }

    @Test func cancellingACountCallsCancel() async throws {
        let rig = Rig()
        rig.sources[0].holdCountUntilCancel = true
        let (_, window) = try await open(orders, rig: rig)
        try window.click(window.element(label: "Count rows"))
        try await rig.until("counting") { rig.model.sessions[key]?.exactCounts[orders] == .loading }
        try await window.runUntilIdle()
        #expect(try window.element(identifier: "detail.rowCount").value == "counting…")
        try window.click(window.element(label: "Cancel"))
        #expect(rig.sources[0].cancelCalls == 1)
        try await window.runUntil { (try? window.element(identifier: "detail.rowCount").value) == "≈3 rows" }
        #expect(try window.element(identifier: "detail.rowCount").value == "≈3 rows")
        #expect(rig.model.sessions[key]?.exactCounts[orders] == nil)
    }

    @Test func noEditingUIExists() async throws {
        let (_, window) = try await open(orders, tab: .rows)
        // Not vacuous: the grid's cells are drawn.
        #expect(window.shows("done"))
        // The only text fields are the filter value and the search: nothing edits a cell.
        let fields = try window.elements(role: .textField).compactMap(\.identifier)
        #expect(Set(fields) == ["grid.filter.value", "grid.search"], "\(fields)")
        for word in ["Edit", "Delete row", "Insert", "Delete", "Save"] {
            #expect(!window.shows(word), "\(word) must not exist in a table's detail")
        }
    }

    @Test func aWideRelationRealisesOnlyItsWindowOfColumns() async throws {
        let wide = RelationID("s", "wide")
        let columns = (0..<300).map { ColumnInfo(name: "c\($0)", ordinal: $0 + 1, typeName: "integer") }
        let relation = RelationInfo(id: wide, kind: .table, rowEstimate: .estimated(1), columns: columns)
        let snapshot = SchemaSnapshot(serverVersion: 170_000, schemas: ["s"], relations: [relation], foreignKeys: [])
        let page = ResultPage(
            columns: columns.map { ResultColumn(name: $0.name, typeOID: 23, typeName: "integer") },
            rows: [(0..<300).map { SiftValue.int(Int64($0)) }])
        let rig = Rig(sources: [FakeSource(schema: snapshot, rows: [wide: page])])
        let (_, window) = try await open(wide, rig: rig, tab: .rows)
        try await window.runUntil { rig.model.sessions[key]?.grid(for: wide)?.cachedPages == [0] }
        try await window.runUntilIdle()
        // Every column is in the grid, and only the ones in view are built.
        #expect(rig.model.sessions[key]?.grid(for: wide)?.columns.count == 300)
        #expect(window.shows("c0"))
        #expect(try window.element(identifier: "grid.cell.0.0").value == "0")
        #expect(!window.hasElement(identifier: "grid.cell.0.299"))
        let cells = try window.elements { ($0.identifier ?? "").hasPrefix("grid.cell.0.") }
        #expect(cells.count > 3 && cells.count < 30, "cells in the first row: \(cells.count)")
    }

    @Test func aBigRelationRealisesOnlyItsWindowOfRows() async throws {
        let big = RelationID("s", "big")
        let columns = [ColumnInfo(name: "id", ordinal: 1, typeName: "bigint"), ColumnInfo(name: "label", ordinal: 2, typeName: "text")]
        let relation = RelationInfo(id: big, kind: .table, rowEstimate: .estimated(100), columns: columns)
        let snapshot = SchemaSnapshot(serverVersion: 170_000, schemas: ["s"], relations: [relation], foreignKeys: [])
        let page = ResultPage(
            columns: [
                ResultColumn(name: "id", typeOID: 20, typeName: "bigint"),
                ResultColumn(name: "label", typeOID: 25, typeName: "text")
            ],
            rows: (0..<100).map { [.int(Int64($0)), .text("row \($0)")] })
        let rig = Rig(sources: [FakeSource(schema: snapshot, rows: [big: page])])
        let (_, window) = try await open(big, rig: rig, recordsLayout: false, tab: .rows)
        try await window.runUntil { rig.model.sessions[key]?.grid(for: big)?.cachedPages == [0] }
        try await window.runUntilIdle()
        window.window.setNeedsRedraw()
        window.tick()
        let realized = window.lastFrameWork.tableRowsRealized
        #expect(realized > 5, "rows are built: \(realized)")
        #expect(realized <= 34, "only a window of the 100: \(realized)")
        #expect(window.shows("row 0"))
        #expect(!window.shows("row 99"))
    }
}
