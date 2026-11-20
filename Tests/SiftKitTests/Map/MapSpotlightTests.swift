import MetalUI
import MetalUITesting
import SiftCore
import SiftTestSupport
import Testing

@testable import SiftKit

@MainActor
struct MapSpotlightTests {
    let orders = RelationID("shop", "orders")
    let orderItems = RelationID("shop", "order_items")

    func spotCards(_ window: TestWindow) throws -> [String] {
        try window.elements { ($0.identifier ?? "").hasPrefix("map.spot.") && ($0.identifier ?? "").split(separator: ".").count == 4 }
            .compactMap(\.identifier).sorted()
    }

    @Test func hoverSpotlightsNeighbours() async throws {
        let rig = try await MapRig(schema: FixtureSnapshot.shop())
        #expect(!rig.window.has("map.scrim"))
        #expect(try spotCards(rig.window).isEmpty)
        // order_items references orders and products and is referenced by shipments: itself and three neighbours.
        rig.window.hover(at: try rig.centre(of: orderItems))
        try await rig.window.runUntilIdle()
        #expect(rig.map.hovered == orderItems)
        _ = try rig.window.element(identifier: "map.scrim")
        #expect(try spotCards(rig.window) == [
            "map.spot.shop.order_items", "map.spot.shop.orders", "map.spot.shop.products", "map.spot.shop.shipments",
        ])
        rig.window.hover(at: Point(x: Pixels(5), y: Pixels(5)))  // the sidebar
        try await rig.window.runUntilIdle()
        #expect(rig.map.hovered == nil)
        #expect(!rig.window.has("map.scrim"))
    }

    @Test func hoverSpotlightsNeighboursAtCostOfDegree() async throws {
        let rig = try await MapRig.atTable("t0100")
        // The best-connected table on the map, and the cards that exist around it.
        let layout = rig.map.layout!
        let shown = Set(rig.map.culled.nodes)
        let view = rig.map.geometry.visibleCanvasRect(rig.map.viewSize!).inset(by: 20)
        let hub = shown.filter { view.contains(layout.rect(of: $0).centre) }.max { MapSpotlightLayer.neighbours(of: $0, in: layout).nodes.count < MapSpotlightLayer.neighbours(of: $1, in: layout).nodes.count }!
        let spot = MapSpotlightLayer.neighbours(of: hub, in: layout).nodes
        // Not vacuous: more than 20 cards are visible, and the hub has neighbours.
        #expect(shown.count > 20)
        #expect(spot.count >= 3, "spot \\(spot.count)")
        let point = try rig.centre(of: layout.graph.ids[hub])
        let work = await Work.of(rig) {
            rig.window.hover(at: point)
            rig.window.tick()
        }
        #expect(rig.map.hovered == layout.graph.ids[hub])
        _ = try rig.window.element(identifier: "map.scrim")
        #expect(try spotCards(rig.window).count == spot.count)
        #expect(work.cards <= spot.count, "cards rebuilt: \\(work.cards), spot \\(spot.count)")
        #expect(work.cards > 0)
    }

    @Test func movingWithinACardDrawsNoFrame() async throws {
        let rig = try await MapRig(schema: FixtureSnapshot.shop())
        let centre = try rig.centre(of: orders)
        rig.window.hover(at: centre)
        try await rig.window.runUntilIdle()
        #expect(rig.map.hovered == orders)
        let drawn = rig.window.framesDrawn
        rig.window.hover(at: Point(x: centre.x + 5, y: centre.y + 2))
        rig.window.hover(at: Point(x: centre.x - 7, y: centre.y + 1))
        try await rig.window.runUntilIdle()
        #expect(rig.map.hovered == orders)
        #expect(rig.window.framesDrawn == drawn, "frames drawn by moving inside one card: \\(rig.window.framesDrawn - drawn)")
    }

    @Test func clickSelectsAndDoubleClickOpensTheTable() async throws {
        let rig = try await MapRig(schema: FixtureSnapshot.shop())
        rig.window.click(at: try rig.centre(of: orders))
        try await rig.window.runUntilIdle()
        #expect(rig.map.selected == orders)
        #expect(rig.model.detailMode == .map)
        rig.window.doubleClick(at: try rig.centre(of: orders))
        try await rig.window.runUntilIdle()
        #expect(rig.model.detailMode == .table)
        #expect(rig.model.selection == .relation(rig.key, orders))
        _ = try rig.window.element(identifier: "detail.title")
    }

    @Test func returnOpensTheSelectedTable() async throws {
        let rig = try await MapRig(schema: FixtureSnapshot.shop())
        rig.window.click(at: try rig.centre(of: orders))
        try await rig.window.runUntilIdle()
        rig.window.typeKey(.return)
        try await rig.window.runUntilIdle()
        #expect(rig.model.detailMode == .table)
        #expect(rig.model.selection == .relation(rig.key, orders))
    }

    @Test func clickingEmptyCanvasClearsTheSelection() async throws {
        let rig = try await MapRig(schema: FixtureSnapshot.shop())
        rig.window.click(at: try rig.centre(of: orders))
        #expect(rig.map.selected == orders)
        let origin = try rig.mapOrigin()
        rig.window.click(at: Point(x: origin.x + 3, y: origin.y + 3))
        #expect(rig.map.selected == nil)
    }

    @Test func clickingAnEdgeShowsItsColumnPair() async throws {
        let rig = try await MapRig(schema: FixtureSnapshot.shop())
        let layout = rig.map.layout!
        let edge = layout.graph.edgeFK.firstIndex { $0.hasSuffix("orders_customer_id_fkey") }!
        // A point a little way along the line, clear of both cards.
        let piece = EdgeRouting.pieces(through: layout.path(of: edge), edge: edge, tileSize: EdgeTiles.base)[0]
        let on = piece.point(at: 0.6)
        #expect(rig.map.table(at: rig.map.geometry.toScreen(on)) == nil)
        rig.window.click(at: try rig.windowPoint(on))
        try await rig.window.runUntilIdle()
        #expect(rig.map.selectedEdge == layout.graph.edgeFK[edge])
        let strip = try rig.window.element(identifier: "map.edgeInfo")
        #expect(strip.value == "orders.customer_id → customers.id")
    }
}
