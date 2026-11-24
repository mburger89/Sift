import MetalUI
import MetalUITesting
import SiftCore
import SiftTestSupport
import Testing

@testable import SiftKit

/// Following foreign keys in the real app window, over fake grid sources.
@MainActor
struct FollowTests {
    let key = ConnectionKey.container(name: "shop-db")
    let orders = RelationID("shop", "orders")
    let customers = RelationID("shop", "customers")

    static func orderRows() -> [[SiftValue]] {
        [
            [.int(1), .int(42), .text("new"), .null],
            [.int(2), .null, .text("new"), .null],
            [.int(3), .int(43), .text("done"), .null],
        ]
    }

    static func customerColumns() -> [ResultColumn] {
        [
            ResultColumn(name: "id", typeOID: 20, typeName: "int8"),
            ResultColumn(name: "email", typeOID: 25, typeName: "text"),
            ResultColumn(name: "created_at", typeOID: 1184, typeName: "timestamptz"),
        ]
    }

    struct Opened {
        let rig: Rig
        let window: TestWindow
        let grid: GridModel
        let customerSource: FakeGridSource
    }

    /// The window on `orders` (three rows), with `customers` ready to be followed to.
    func open() async throws -> Opened {
        let rig = Rig()
        let ordersSource = FakeGridSource(columns: GridViewTests.columns(), rows: Self.orderRows())
        let customerSource = FakeGridSource(
            columns: Self.customerColumns(),
            rows: [[.int(42), .text("a@x.test"), .text("2026-01-01 00:00:00+00")]])
        rig.sources[0].setGrid(ordersSource, for: orders)
        rig.sources[0].setGrid(customerSource, for: customers)
        await rig.model.refreshDiscovery()
        await rig.model.open(key)
        let session = try #require(rig.model.sessions[key])
        let grid = try #require(session.grid(for: orders))
        grid.apply(GridQuery())
        let window = try siftWindow(model: rig.model)
        rig.model.select(orders, in: key)
        try await window.runUntilIdle()
        try await window.runUntil { grid.count != .estimated(0) && grid.cachedPages.contains(0) }
        try await window.runUntilIdle()
        return Opened(rig: rig, window: window, grid: grid, customerSource: customerSource)
    }

    func cell(_ window: TestWindow, _ row: Int, _ column: Int) throws -> TestElement {
        try window.element(identifier: "grid.cell.\(row).\(column)")
    }

    /// Waits until the followed relation's grid shows its filtered page.
    func landed(_ o: Opened) async throws -> GridModel {
        try await o.window.runUntil { o.rig.model.selection == .relation(key, customers) }
        let target = try #require(o.rig.model.sessions[key]?.grid(for: customers))
        try await o.window.runUntil { target.cachedPages.contains(0) && !target.isLoading }
        try await o.window.runUntilIdle()
        return target
    }

    func expectFollowedToCustomer42(_ o: Opened, _ target: GridModel) {
        #expect(o.rig.model.selection == .relation(key, customers))
        #expect(o.rig.model.relationTab == .rows)
        #expect(target.query.filters == [GridFilter(column: 0, op: .eq, value: "42")])
        #expect(target.activePosition == GridPosition(row: 0, column: 0))
        #expect(target.selectedRow == 0)
        #expect(target.revealRequest == GridPosition(row: 0, column: 0))
        #expect(o.customerSource.pageCalls.last?.query.filters == target.query.filters)
    }

    @Test func theInspectorListsLinksAndClickingOneOpensTheFilteredTarget() async throws {
        let o = try await open()
        try o.window.click(cell(o.window, 0, 1))
        try await o.window.runUntilIdle()
        let link = try o.window.element(identifier: "inspector.link.out.shop.orders.orders_customer_id_fkey")
        #expect(link.label == "customer_id → customers (id = 42)")
        #expect(link.isEnabled)
        // Referenced by: order_items and nothing else for orders... the incoming list follows.
        #expect(o.window.hasElement(identifier: "inspector.link.in.shop.order_items.order_items_order_id_fkey"))
        try o.window.click(link)
        let target = try await landed(o)
        expectFollowedToCustomer42(o, target)
        // The chip says what was followed.
        try await o.window.runUntilIdle()
        #expect(try o.window.element(identifier: "grid.chip.0").value == "id = 42")
    }

    @Test func aNullKeyShowsADisabledLink() async throws {
        let o = try await open()
        try o.window.click(cell(o.window, 1, 1))
        try await o.window.runUntilIdle()
        let link = try o.window.element(identifier: "inspector.link.out.shop.orders.orders_customer_id_fkey")
        #expect(link.label == "customer_id is NULL")
        #expect(!link.isEnabled)
    }

    @Test func returnOnAnFKCellFollowsIt() async throws {
        let o = try await open()
        try o.window.click(cell(o.window, 0, 1))
        try await o.window.runUntilIdle()
        o.window.typeKey(.return)
        let target = try await landed(o)
        expectFollowedToCustomer42(o, target)
    }

    @Test func returnOnACellWithoutAKeyDoesNothing() async throws {
        let o = try await open()
        try o.window.click(cell(o.window, 0, 2))
        try await o.window.runUntilIdle()
        o.window.typeKey(.return)
        try await o.window.runUntilIdle()
        #expect(o.rig.model.selection == .relation(key, orders))
        // A NULL key follows nowhere either.
        try o.window.click(cell(o.window, 1, 1))
        try await o.window.runUntilIdle()
        o.window.typeKey(.return)
        try await o.window.runUntilIdle()
        #expect(o.rig.model.selection == .relation(key, orders))
    }

    @Test func doubleClickOnAnFKCellFollowsIt() async throws {
        let o = try await open()
        try o.window.doubleClick(cell(o.window, 0, 1))
        let target = try await landed(o)
        expectFollowedToCustomer42(o, target)
    }

    @Test func aSingleClickOnAnFKCellOnlySelects() async throws {
        let o = try await open()
        try o.window.click(cell(o.window, 0, 1))
        try await o.window.runUntilIdle()
        #expect(o.rig.model.selection == .relation(key, orders))
        #expect(o.grid.activePosition == GridPosition(row: 0, column: 1))
    }

    @Test func theRowMenuOffersEveryLinkOfOneRowAndNoneForSeveral() async throws {
        let o = try await open()
        try o.window.rightClick(cell(o.window, 0, 1))
        let menu = try #require(o.window.presentedMenu)
        let out = try #require(menu.item(accessibilityIdentifier: "grid.menu.link.out.shop.orders.orders_customer_id_fkey"))
        #expect(out.title == "customer_id → customers (id = 42)" && out.isEnabled)
        #expect(menu.item(accessibilityIdentifier: "grid.menu.link.in.shop.order_items.order_items_order_id_fkey") != nil)
        try o.window.dismissMenu()
        // A NULL key: its item is there, disabled, and says why.
        try o.window.rightClick(cell(o.window, 1, 1))
        let nullMenu = try #require(o.window.presentedMenu)
        let disabled = try #require(nullMenu.item(accessibilityIdentifier: "grid.menu.link.out.shop.orders.orders_customer_id_fkey"))
        #expect(disabled.title == "customer_id is NULL" && !disabled.isEnabled)
        try o.window.dismissMenu()
        // Choosing the item follows it.
        try o.window.rightClick(cell(o.window, 0, 1))
        try o.window.chooseMenuItem(accessibilityIdentifier: "grid.menu.link.out.shop.orders.orders_customer_id_fkey")
        let target = try await landed(o)
        #expect(target.query.filters == [GridFilter(column: 0, op: .eq, value: "42")])
        // Several rows: no items.
        #expect(GridTable.menuLinks(o.grid, [0, 1]).isEmpty)
        #expect(GridTable.menuLinks(o.grid, []).isEmpty)
        #expect(GridTable.menuLinks(o.grid, [0]).count == o.grid.links?.links(row: 0, value: { _ in .int(1) }).count)
    }

    @Test func fkColumnsDrawInTheLinkColour() async throws {
        let o = try await open()
        #expect(GridTable.linkColumns(o.grid) == [1])
        let columns = o.grid.columns
        let row = GridRowRef(ordinal: 0)
        #expect(GridTable.cell(o.grid, columns, row, 1, .current, true).isLink)
        #expect(GridTable.cell(o.grid, columns, row, 1, .current, true) != GridTable.cell(o.grid, columns, row, 1, .current, false))
        // Query results have no links, so no column is tinted.
        let plain = GridModel(source: FakeGridSource(columns: columns, trueCount: 1), clock: ManualClock())
        #expect(GridTable.linkColumns(plain).isEmpty)
    }

    @Test func aFollowIntoACheapRecencyTargetKeepsItsNewestFirstSort() async throws {
        let o = try await open()
        let relation = try #require(o.rig.model.sessions[key]?.snapshot?.relation(customers))
        let sort = try #require(RecencyColumns.defaultSort(for: relation))
        try o.window.click(cell(o.window, 0, 1))
        try await o.window.runUntilIdle()
        try o.window.click(o.window.element(identifier: "inspector.link.out.shop.orders.orders_customer_id_fkey"))
        let target = try await landed(o)
        #expect(target.query.sort == sort)
        #expect(o.customerSource.pageCalls.last?.query.sort == sort)
        #expect(target.query.filters == [GridFilter(column: 0, op: .eq, value: "42")])
    }

    @Test func followingTheSameKeyTwiceReadsAgainAndRevealsAgain() async throws {
        let o = try await open()
        let follow = try #require(o.grid.links?.primaryFollow(row: 0, column: 1) { Self.orderRows()[0][$0] })
        o.rig.model.follow(follow, in: key)
        let target = try await landed(o)
        let reads = o.customerSource.pageCalls.count
        let reveals = target.revealCount
        o.rig.model.follow(follow, in: key)
        try await o.window.runUntil { o.customerSource.pageCalls.count > reads && target.cachedPages.contains(0) }
        #expect(target.revealCount == reveals + 1)
        #expect(target.activePosition == GridPosition(row: 0, column: 0))
        #expect(target.selectedRow == 0)
    }
}
