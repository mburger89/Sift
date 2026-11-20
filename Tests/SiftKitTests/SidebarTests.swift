import MetalUI
import MetalUITesting
import SiftCore
import SiftTestSupport
import Testing

@testable import SiftKit

@MainActor
struct SidebarTests {
    let key = ConnectionKey.container(name: "shop-db")

    func openWindow(rig: Rig, recordsLayout: Bool = true) async throws -> TestWindow {
        await rig.model.refreshDiscovery()
        let window = try siftWindow(model: rig.model, recordsLayout: recordsLayout)
        try await window.runUntilIdle()
        return window
    }

    @Test func sidebarListsSavedAndDiscoveredDatabases() async throws {
        let saved = SavedConnection(name: "Local dev", host: "127.0.0.1", database: "shop", user: "app")
        let rig = Rig(saved: [saved])
        let window = try await openWindow(rig: rig)
        // The two roots start collapsed (the outline's expansion is its own: gap G4).
        #expect(try window.element(label: "Saved").role == .staticText)
        #expect(!window.hasRow(ConnectionKey.saved(saved.id).token))
        try window.toggleRow("saved-root")
        try window.toggleRow("containers-root")
        try await window.runUntilIdle()
        _ = try window.element(label: "Local dev")
        _ = try window.element(label: "shop-db")
    }

    @Test func connectingShowsTheSchemaTree() async throws {
        let rig = Rig()
        let window = try await openWindow(rig: rig)
        try window.toggleRow("containers-root")
        try await window.runUntilIdle()
        let container = try window.sidebarRow("container:shop-db")
        try window.click(container)
        #expect(rig.model.selection == .container(name: "shop-db"))

        await rig.model.open(key)
        try await window.runUntilIdle()
        try window.toggleRow("container:shop-db")
        try await window.runUntilIdle()
        try window.toggleRow("schema:container:shop-db:shop")
        try await window.runUntilIdle()
        #expect(rig.connector.targets.count == 1)
        // The database is selected, so the map is open and names the tables too: the rows are the sidebar's.
        _ = try window.sidebarRow("relation:container:shop-db:shop.customers")
        _ = try window.sidebarRow("relation:container:shop-db:shop.recent_orders")
    }

    @Test func anOutlineOf500TablesRealizesOnlyVisibleRows() async throws {
        let big = FakeSource(schema: SyntheticSchema.make(tables: 500, foreignKeys: 800, seed: 7))
        let rig = Rig(sources: [big])
        let window = try await openWindow(rig: rig, recordsLayout: false)
        await rig.model.open(key)
        try await window.runUntilIdle()
        try window.toggleRow("containers-root")
        try await window.runUntilIdle()
        try window.toggleRow("container:shop-db")
        try await window.runUntilIdle()
        try window.toggleRow("schema:container:shop-db:s0")
        try await window.runUntilIdle()

        // Not vacuous: s0 really holds 100 tables, and it is expanded.
        let s0 = try #require(rig.model.sidebarTree.last?.children?.first?.children?.first)
        #expect(s0.children?.count == 100)
        _ = try window.element(label: "t0000")

        window.window.setNeedsRedraw()
        window.tick()
        let realized = window.lastFrameWork.lazyUnitsRealized
        #expect(realized > 20, "a window of rows is built: \(realized)")
        #expect(realized <= 40, "and only a window: \(realized)")
    }

    @Test func hoverWithinOneRowDrawsNoFrame() async throws {
        let rig = Rig()
        let window = try await openWindow(rig: rig)
        await rig.model.open(key)
        try window.toggleRow("containers-root")
        try await window.runUntilIdle()
        try window.toggleRow("container:shop-db")
        try await window.runUntilIdle()
        try window.toggleRow("schema:container:shop-db:shop")
        try await window.runUntilIdle()
        let row = try window.sidebarRow("relation:container:shop-db:shop.customers")
        let centre = window.centre(of: row)
        window.hover(at: centre)  // enters the row
        let frames = window.framesDrawn
        window.hover(at: Point(x: centre.x + 3, y: centre.y))
        window.hover(at: Point(x: centre.x + 6, y: centre.y + 2))
        #expect(window.framesDrawn == frames, "moving inside one row draws nothing")
        // Not vacuous: the row is really there, and a click on it still works afterwards.
        try window.click(row)
        #expect(rig.model.selection == .relation(key, RelationID("shop", "customers")))
    }

    @Test func selectingAnotherTableRebuildsAtMostTwoRows() async throws {
        let rig = Rig()
        let window = try await openWindow(rig: rig)
        await rig.model.open(key)
        try window.toggleRow("containers-root")
        try await window.runUntilIdle()
        try window.toggleRow("container:shop-db")
        try await window.runUntilIdle()
        try window.toggleRow("schema:container:shop-db:shop")
        try await window.runUntilIdle()
        try window.click(window.sidebarRow("relation:container:shop-db:shop.customers"))
        try await window.runUntilIdle()
        let visibleRows = try window.elements(role: .row).count
        #expect(visibleRows >= 10, "many rows are on screen: \(visibleRows)")

        let before = SidebarRow.bodyCount
        try window.click(window.sidebarRow("relation:container:shop-db:shop.orders"))
        try await window.runUntilIdle()
        #expect(rig.model.selection == .relation(key, RelationID("shop", "orders")))
        let rebuilt = SidebarRow.bodyCount - before
        #expect(rebuilt <= 2, "selection rebuilt \(rebuilt) rows")
    }
}
