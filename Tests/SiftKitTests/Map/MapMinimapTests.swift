import MetalUI
import MetalUITesting
import SiftCore
import SiftTestSupport
import Testing

@testable import SiftKit

@MainActor
struct MapMinimapTests {
    @Test func aPanStepDoesNotRebuildTheMinimapCards() async throws {
        let rig = try await MapRig.atTable("t0100")
        // Not vacuous: the minimap is there, with its viewport, and the map has cards.
        _ = try rig.window.element(identifier: "map.minimap")
        let viewport = try rig.window.element(identifier: "map.minimap.viewport")
        #expect(rig.map.culled.nodes.count > 20)
        let before = viewport.frame.origin
        let built = MinimapCards.bodyCount
        rig.map.panBy(400, 300, scale: 1)
        await rig.settle()
        let moved = try rig.window.element(identifier: "map.minimap.viewport").frame.origin
        #expect(moved != before, "the viewport outline moved")
        #expect(MinimapCards.bodyCount == built)
        // Dropping a card is a change of positions: the minimap is rebuilt for it.
        let from = try rig.centre(of: RelationID("s0", "t0100"))
        rig.window.drag(from: from, to: Point(x: from.x + 60, y: from.y + 30), steps: 4)
        #expect(MinimapCards.bodyCount > built)
    }

    @Test func clickingTheMinimapCentresThere() async throws {
        let rig = try await MapRig(schema: MapRig.big)
        let minimap = try rig.window.element(identifier: "map.minimap")
        let bounds = rig.map.layout!.bounds
        let transform = MinimapTransform(bounds: bounds)
        // A point a third of the way across and down the minimap.
        let local = LayoutPoint(x: MinimapTransform.width / 3, y: MinimapTransform.height / 3)
        let target = transform.toCanvas(local)
        rig.window.click(at: Point(x: minimap.frame.origin.x + Pixels(Float(local.x)), y: minimap.frame.origin.y + Pixels(Float(local.y))))
        try await rig.window.runUntilIdle()
        let visible = rig.map.geometry.visibleCanvasRect(rig.map.viewSize!)
        let centre = visible.centre
        // The pan snaps to a whole pixel, which is 1 / zoom canvas units at most.
        let tolerance = max(1, 1 / rig.map.geometry.zoom)
        #expect(abs(centre.x - target.x) <= tolerance, "x \(centre.x) vs \(target.x)")
        #expect(abs(centre.y - target.y) <= tolerance, "y \(centre.y) vs \(target.y)")
        // The click was the minimap's: it selected nothing on the map.
        #expect(rig.map.selected == nil)
    }

    @Test func searchFliesToTheTable() async throws {
        let rig = try await MapRig(schema: FixtureSnapshot.shop())
        #expect(rig.map.geometry.zoom < 1)
        rig.window.typeKey("f", modifierFlags: .primary)
        try await rig.window.runUntilIdle()
        rig.window.typeText("ship")
        try await rig.window.runUntilIdle()
        #expect(rig.map.search == "ship")
        // The matches are listed.
        _ = try rig.window.element(identifier: "map.result.shop.shipments")
        rig.window.typeKey(.return)
        try await rig.window.runUntilIdle()
        let shipments = RelationID("shop", "shipments")
        #expect(rig.map.selected == shipments)
        #expect(rig.map.geometry.zoom >= 0.8)
        let card = try rig.window.element(identifier: "map.card.shop.shipments")
        let map = try rig.window.element(identifier: "map")
        let c = rig.window.centre(of: card), m = rig.window.centre(of: map)
        #expect(abs(c.x.value - m.x.value) <= 2 && abs(c.y.value - m.y.value) <= 2, "card \(c) map \(m)")
        #expect(rig.map.search.isEmpty)
    }

    @Test func clickingAResultFliesToIt() async throws {
        let rig = try await MapRig(schema: FixtureSnapshot.shop())
        rig.map.search = "cust"
        try await rig.window.runUntilIdle()
        try rig.window.click(rig.window.element(identifier: "map.result.shop.customers"))
        try await rig.window.runUntilIdle()
        #expect(rig.map.selected == RelationID("shop", "customers"))
    }
}
