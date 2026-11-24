import MetalUI
import MetalUITesting
import SiftCore
import SiftTestSupport
import Testing

@testable import SiftKit

/// Back and forward through the relations visited, in the real app window over fake grid sources.
@MainActor
struct BackForwardTests {
    let key = ConnectionKey.container(name: "shop-db")
    let customers = RelationID("shop", "customers")
    let orders = RelationID("shop", "orders")
    let items = RelationID("shop", "order_items")
    let products = RelationID("shop", "products")
    let employees = RelationID("shop", "employees")

    static func itemColumns() -> [ResultColumn] {
        [
            ResultColumn(name: "order_id", typeOID: 20, typeName: "int8"),
            ResultColumn(name: "product_id", typeOID: 2950, typeName: "uuid"),
            ResultColumn(name: "qty", typeOID: 23, typeName: "int4"),
        ]
    }

    static func productColumns() -> [ResultColumn] {
        [
            ResultColumn(name: "id", typeOID: 2950, typeName: "uuid"),
            ResultColumn(name: "name", typeOID: 1043, typeName: "varchar"),
            ResultColumn(name: "tags", typeOID: 1009, typeName: "text[]"),
            ResultColumn(name: "price", typeOID: 1700, typeName: "numeric"),
        ]
    }

    static func employeeColumns() -> [ResultColumn] {
        [
            ResultColumn(name: "id", typeOID: 23, typeName: "int4"),
            ResultColumn(name: "manager_id", typeOID: 23, typeName: "int4"),
        ]
    }

    struct Opened {
        let rig: Rig
        let window: TestWindow
        var model: AppModel { rig.model }
    }

    /// The window over fakes for the shop's tables: customers has 400 rows so that row 300 needs a scroll.
    func open(ordersRows: Int = 5) async throws -> Opened {
        let rig = Rig()
        let src = rig.sources[0]
        src.setGrid(FakeGridSource(columns: FollowTests.customerColumns(), trueCount: 400), for: customers)
        src.setGrid(FakeGridSource(columns: GridViewTests.columns(), trueCount: ordersRows), for: orders)
        src.setGrid(FakeGridSource(columns: Self.itemColumns(), trueCount: 4), for: items)
        src.setGrid(FakeGridSource(columns: Self.productColumns(), trueCount: 2), for: products)
        src.setGrid(FakeGridSource(columns: Self.employeeColumns(), trueCount: 400), for: employees)
        await rig.model.refreshDiscovery()
        await rig.model.open(key)
        return Opened(rig: rig, window: try siftWindow(model: rig.model))
    }

    func grid(_ o: Opened, _ id: RelationID) throws -> GridModel {
        try #require(o.model.sessions[key]?.grid(for: id))
    }

    func settle(_ o: Opened, _ g: GridModel) async throws {
        try await o.window.runUntil { g.cachedPages.contains(0) && !g.isLoading }
        try await o.window.runUntilIdle()
    }

    /// Follows the first link of `row` that points at (or from) `target`.
    func follow(_ o: Opened, from: RelationID, row: Int, to target: RelationID) throws {
        let g = try grid(o, from)
        let link = try #require(g.links?.links(row: row) { _ in .int(Int64(row)) }.first { $0.follow?.target == target })
        o.model.follow(try #require(link.follow), in: key)
    }

    @Test func aSidebarClickAndAFollowBothPush() async throws {
        let o = try await open()
        #expect(!o.model.canGoBack && !o.model.canGoForward)
        o.model.select(orders, in: key)
        #expect(!o.model.canGoBack, "the first place has nothing behind it")
        o.model.select(customers, in: key)
        #expect(o.model.canGoBack, "a sidebar click pushed orders")
        try follow(o, from: customers, row: 3, to: orders)
        #expect(o.model.selection == .relation(key, orders))
        o.model.goBack()
        #expect(o.model.selection == .relation(key, customers))
        o.model.goBack()
        #expect(o.model.selection == .relation(key, orders))
        #expect(!o.model.canGoBack && o.model.canGoForward)
    }

    @Test func backRestoresTheGridsQueryAndActiveCellAndReveals() async throws {
        let o = try await open()
        o.model.navigate(to: key, relation: customers, query: GridQuery(), active: GridPosition(row: 300, column: 0))
        let customerGrid = try grid(o, customers)
        try await o.window.runUntil { customerGrid.count == .exact(400) }
        try await settle(o, customerGrid)
        let stop1 = customerGrid.query

        try follow(o, from: customers, row: 300, to: orders)
        let ordersGrid = try grid(o, orders)
        try await settle(o, ordersGrid)
        let stop2 = ordersGrid.query
        let active2 = try #require(ordersGrid.activePosition)
        #expect(stop2.filters.count == 1 && stop2 != stop1)

        try follow(o, from: orders, row: 0, to: items)
        let itemsGrid = try grid(o, items)
        try await settle(o, itemsGrid)
        let stop3 = itemsGrid.query
        let active3 = try #require(itemsGrid.activePosition)
        #expect(stop3 != stop2)

        try follow(o, from: items, row: 0, to: products)
        try await settle(o, try grid(o, products))
        #expect(o.model.selection == .relation(key, products))

        o.model.goBack()
        #expect(o.model.selection == .relation(key, items))
        try await settle(o, itemsGrid)
        #expect(itemsGrid.query == stop3)
        #expect(itemsGrid.activePosition == active3)

        o.model.goBack()
        #expect(o.model.selection == .relation(key, orders))
        try await settle(o, ordersGrid)
        #expect(ordersGrid.query == stop2)
        #expect(ordersGrid.activePosition == active2)

        o.model.goBack()
        #expect(o.model.selection == .relation(key, customers))
        #expect(customerGrid.query == stop1)
        #expect(customerGrid.activePosition == GridPosition(row: 300, column: 0))
        try await o.window.runUntil { o.window.hasElement(identifier: "grid.cell.300.0") }
        try await o.window.runUntilIdle()
        let frame = try o.window.element(identifier: "grid.cell.300.0").visibleFrame
        #expect(frame.size.height.value > 0, "row 300 is on screen")
    }

    @Test func backAfterASelfReferenceRestoresTheUnfilteredGrid() async throws {
        let o = try await open()
        o.model.navigate(to: key, relation: employees, query: GridQuery(), active: GridPosition(row: 17, column: 0))
        let g = try grid(o, employees)
        try await settle(o, g)
        let before = g.query
        try follow(o, from: employees, row: 17, to: employees)
        try await settle(o, g)
        #expect(g.query != before && g.query.filters.count == 1)
        #expect(o.model.canGoBack)
        o.model.goBack()
        try await settle(o, g)
        #expect(g.query == before)
        #expect(g.activePosition == GridPosition(row: 17, column: 0))
        #expect(!o.model.canGoBack && o.model.canGoForward)
    }

    @Test func primaryBracketsGoBackAndForward() async throws {
        let o = try await open()
        let (_, window) = try siftApp(model: o.model)
        o.model.select(orders, in: key)
        o.model.select(customers, in: key)
        try await window.runUntilIdle()
        window.typeKey("[", modifierFlags: .primary)
        try await window.runUntilIdle()
        #expect(o.model.selection == .relation(key, orders))
        window.typeKey("]", modifierFlags: .primary)
        try await window.runUntilIdle()
        #expect(o.model.selection == .relation(key, customers))
    }

    @Test func theButtonsAreDisabledAtTheEnds() async throws {
        let o = try await open()
        o.model.select(orders, in: key)
        try await o.window.runUntilIdle()
        #expect(try !o.window.element(identifier: "detail.back").isEnabled)
        #expect(try !o.window.element(identifier: "detail.forward").isEnabled)
        #expect(try o.window.element(identifier: "detail.back").label == "Back")
        o.model.select(customers, in: key)
        try await o.window.runUntilIdle()
        #expect(try o.window.element(identifier: "detail.back").isEnabled)
        try o.window.click(o.window.element(identifier: "detail.back"))
        try await o.window.runUntilIdle()
        #expect(o.model.selection == .relation(key, orders))
        #expect(try !o.window.element(identifier: "detail.back").isEnabled)
        #expect(try o.window.element(identifier: "detail.forward").isEnabled)
        #expect(try o.window.element(identifier: "detail.forward").label == "Forward")
        try o.window.click(o.window.element(identifier: "detail.forward"))
        try await o.window.runUntilIdle()
        #expect(o.model.selection == .relation(key, customers))
    }

    @Test func anEntryWhoseSessionClosedShowsNotInTheSchema() async throws {
        let o = try await open()
        let gone = RelationID("shop", "dropped")
        o.model.select(gone, in: key)
        o.model.select(orders, in: key)
        let elsewhere = ConnectionKey.container(name: "elsewhere")
        o.model.selection = .relation(elsewhere, orders)
        o.model.select(orders, in: key)
        try await o.window.runUntilIdle()
        // Back to the other connection (no session), then to the dropped table: both are selected, neither crashes.
        o.model.goBack()
        #expect(o.model.selection == .relation(elsewhere, orders))
        try await o.window.runUntilIdle()
        #expect(try o.window.element(identifier: "detail.notice").value == "Not connected.")
        o.model.goBack()
        o.model.goBack()
        #expect(o.model.selection == .relation(key, gone))
        try await o.window.runUntilIdle()
        #expect(try o.window.element(identifier: "detail.notice").value == "This table is not in the current schema.")
    }

    @Test func backAndForwardDoNotPush() async throws {
        let o = try await open()
        o.model.select(orders, in: key)
        o.model.select(customers, in: key)
        o.model.select(items, in: key)
        o.model.goBack()
        o.model.goBack()
        #expect(o.model.selection == .relation(key, orders))
        #expect(!o.model.canGoBack, "restoring pushed nothing behind orders")
        o.model.goForward()
        o.model.goForward()
        #expect(o.model.selection == .relation(key, items))
        #expect(!o.model.canGoForward)
        o.model.goBack()
        o.model.goBack()
        o.model.goForward()
        #expect(o.model.canGoForward && o.model.canGoBack)
        o.model.goForward()
        #expect(!o.model.canGoForward)
    }

    @Test func aSwitchToTheMapAndBackDoesNotPushTwice() async throws {
        let o = try await open()
        o.model.select(orders, in: key)
        o.model.setDetailMode(.map)
        o.model.setDetailMode(.table)
        #expect(o.model.selection == .relation(key, orders))
        #expect(!o.model.canGoBack, "map and back to the same table pushes nothing")
    }

    // MARK: Binding carry-overs from Task 5's review

    /// Orders (1000 rows) navigated to with a new filter while its count is held at the 500 placeholder.
    func holdCountAndNavigate(_ o: Opened) async throws -> (GridModel, FakeGridSource) {
        let big = FakeGridSource(columns: GridViewTests.columns(), trueCount: 1000)
        o.rig.sources[0].setGrid(big, for: orders)
        o.model.select(orders, in: key)
        let g = try grid(o, orders)
        g.apply(GridQuery())
        try await o.window.runUntil { g.count == .exact(1000) && g.cachedPages.contains(0) }
        try await o.window.runUntilIdle()
        big.holdsCounts = true
        let countsBefore = big.calls.filter { if case .count = $0 { true } else { false } }.count
        let query = GridQuery(filters: [GridFilter(column: 1, op: .eq, value: "7")])
        o.model.navigate(to: key, relation: orders, query: query, active: GridPosition(row: 600, column: 0))
        try await o.window.runUntil { big.calls.filter { if case .count = $0 { true } else { false } }.count > countsBefore }
        try await o.window.runUntilIdle()
        return (g, big)
    }

    @Test func anEstimateNeverDropsTheCursor() async throws {
        let o = try await open()
        let (g, big) = try await holdCountAndNavigate(o)
        #expect(!g.count.isExact)
        #expect(g.activePosition == GridPosition(row: 600, column: 0))
        #expect(g.selectedRow == 600)
        // The count that lands is itself only an estimate (500, below the cursor): the cursor still stays.
        big.countAnswer = .estimated(500)
        big.releaseAll()
        try await o.window.runUntil { !g.isLoading }
        try await o.window.runUntilIdle()
        #expect(!g.count.isExact)
        #expect(g.activePosition == GridPosition(row: 600, column: 0))
        #expect(g.selectedRow == 600)
    }

    @Test func theRevealRetriesWhenTheCountLands() async throws {
        let o = try await open()
        let (g, big) = try await holdCountAndNavigate(o)
        #expect(!o.window.hasElement(identifier: "grid.cell.600.0"), "row 600 is past the placeholder count")
        big.releaseAll()
        try await o.window.runUntil { g.count == .exact(1000) }
        try await o.window.runUntil { o.window.hasElement(identifier: "grid.cell.600.0") }
        try await o.window.runUntilIdle()
        #expect(try o.window.element(identifier: "grid.cell.600.0").visibleFrame.size.height.value > 0)
    }
}
