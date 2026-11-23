import MetalUI
import MetalUITesting
import SiftCore
import SiftTestSupport
import Testing

@testable import SiftKit

@MainActor
struct MapChromeTests {
    let orders = RelationID("shop", "orders")

    @Test func cardAccessibilityLabelNamesItsLinks() async throws {
        let rig = try await MapRig(schema: shopSnapshot(ordersEstimate: 4))
        let card = try rig.window.element(identifier: "map.card.shop.orders")
        #expect(card.label == "orders, table, about 4 rows, references customers; referenced by order_items")
        let items = try rig.window.element(identifier: "map.card.shop.order_items")
        #expect(items.label == "order_items, table, about 0 rows, references orders, products; referenced by shipments")
        let view = try rig.window.element(identifier: "map.card.shop.recent_orders")
        #expect(view.label == "recent_orders, view")
        let one = MapCardLabel.make(RelationInfo(id: RelationID("s", "t"), kind: .table, rowEstimate: .estimated(1)), in: shopSnapshot())
        #expect(one == "t, table, about 1 row")
    }

    @Test func selfReferenceIsDrawnAndLabelled() async throws {
        let rig = try await MapRig(schema: FixtureSnapshot.shop())
        let loop = try rig.window.element(identifier: "map.card.shop.employees.selfLoop")
        #expect(loop.label == "references itself")
        #expect(!rig.window.has("map.card.shop.orders.selfLoop"))
        #expect(rig.window.elementsOf(prefix: "map.card.", suffix: ".selfLoop").count == 1)
        // The card says so too, and a self-reference is not an edge in the tiles.
        let layout = rig.map.layout!
        let edge = layout.graph.edgeFK.firstIndex { $0.hasSuffix("employees_manager_id_fkey") }!
        #expect(layout.selfLoops.contains(edge))
        let pieces = EdgeRouting.pieces(for: layout, tileSize: EdgeTiles.base)
        #expect(!pieces.contains { $0.edge == edge })
    }

    @Test func joinTableHasABadge() async throws {
        let rig = try await MapRig(schema: FixtureSnapshot.shop())
        let badges = try rig.window.elements { $0.identifier == "map.badge.join" }
        #expect(badges.count == 1)
        let card = try rig.window.element(identifier: "map.card.shop.product_tags")
        let badge = try #require(badges.first)
        #expect(badge.value == "join table")
        let c = card.frame, b = badge.frame
        #expect(b.origin.x >= c.origin.x && b.origin.x + b.size.width <= c.origin.x + c.size.width)
        #expect(b.origin.y >= c.origin.y && b.origin.y + b.size.height <= c.origin.y + c.size.height)
    }

    @Test func hidingViewsRemovesTheirCards() async throws {
        let rig = try await MapRig(schema: FixtureSnapshot.shop())
        #expect(rig.window.has("map.card.shop.recent_orders"))
        #expect(rig.window.has("map.card.shop.customer_totals"))
        #expect(rig.map.layoutRuns == 1)
        try rig.window.click(rig.window.element(identifier: "map.views"))
        try await rig.window.runUntil { rig.map.layoutRuns == 2 }
        try await rig.window.runUntilIdle()
        #expect(rig.map.filter.showViews == false)
        #expect(!rig.window.has("map.card.shop.recent_orders"))
        #expect(!rig.window.has("map.card.shop.customer_totals"))
        #expect(rig.window.has("map.card.shop.orders"))
        #expect(try rig.cardElements().count == 11)
    }

    @Test func schemaFilterRelayouts() async throws {
        let rig = try await MapRig(schema: FixtureSnapshot.shop())
        #expect(rig.window.has("map.card.tagging.tags"))
        await rig.map.setFilter(MapFilter(schemas: ["shop"]))
        try await rig.window.runUntilIdle()
        #expect(rig.map.layoutRuns == 2)
        #expect(!rig.window.has("map.card.tagging.tags"))
        #expect(rig.window.has("map.card.shop.orders"))
        // The menu is there (its items are native in a headless window, so they are not in the tree).
        let schemas = try rig.window.element(identifier: "map.schemas")
        #expect(schemas.isEnabled)
    }

    @Test func modeSwitchKeepsTheSelection() async throws {
        let rig = try await MapRig(schema: FixtureSnapshot.shop())
        // Select a table from the sidebar's side: its details open.
        rig.model.select(orders, in: rig.key)
        try await rig.window.runUntilIdle()
        #expect(rig.model.detailMode == .table)
        _ = try rig.window.element(identifier: "detail.title")
        // Switch to the map: the same table is the map's selection.
        rig.model.setDetailMode(.map)
        try await rig.window.runUntilIdle()
        _ = try rig.window.element(identifier: "map")
        #expect(rig.map.selected == orders)
        // Select another on the map and switch back: the table detail is that one.
        rig.window.click(at: try rig.centre(of: RelationID("shop", "customers")))
        try await rig.window.runUntilIdle()
        rig.model.setDetailMode(.table)
        try await rig.window.runUntilIdle()
        #expect(rig.model.selection == .relation(rig.key, RelationID("shop", "customers")))
        let title = try rig.window.element(identifier: "detail.title")
        #expect(title.label == "customers" || title.value == "customers")
    }

    @Test func mapThenQueryThenTableLeavesNothingBlank() async throws {
        let rig = try await MapRig(schema: FixtureSnapshot.shop())
        // The connection is selected, a snapshot is loaded, and no table is.
        #expect(rig.model.detailMode == .map)
        #expect(rig.model.selectedRelation == nil)
        rig.model.setDetailMode(.query)
        try await rig.window.runUntilIdle()
        rig.model.setDetailMode(.table)
        try await rig.window.runUntilIdle()
        #expect(rig.model.detailMode == .table)
        // With no table selected the Table tab is the connection's own detail, never an empty area.
        #expect(rig.model.selection == .container(name: "shop-db"))
        _ = try rig.window.element(identifier: "detail.title")
        _ = try rig.window.element(identifier: "discovered.password")
    }

    @Test func thePickerSwitchesModes() async throws {
        let rig = try await MapRig(schema: FixtureSnapshot.shop())
        #expect(rig.model.detailMode == .map)
        rig.model.select(orders, in: rig.key)
        try await rig.window.runUntilIdle()
        // The table detail has no toolbar; go to the map by the model, then use the picker to leave it.
        rig.model.setDetailMode(.map)
        try await rig.window.runUntilIdle()
        try rig.window.click(rig.window.element(identifier: "map.mode.table"))
        try await rig.window.runUntilIdle()
        #expect(rig.model.detailMode == .table)
        #expect(rig.model.selection == .relation(rig.key, orders))
    }

    @Test func aResizeKeepsTheCentre() async throws {
        let rig = try await MapRig(schema: FixtureSnapshot.shop())
        rig.map.flyTo(orders, size: rig.map.viewSize!)
        await rig.settle()
        let before = try rig.window.element(identifier: "map.card.shop.orders")
        let mapBefore = try rig.window.element(identifier: "map")
        let offsetBefore = rig.window.centre(of: before).x - rig.window.centre(of: mapBefore).x
        rig.window.resize(to: Size(width: Pixels(1000), height: Pixels(640)))
        try await rig.window.runUntilIdle()
        let after = try rig.window.element(identifier: "map.card.shop.orders")
        let mapAfter = try rig.window.element(identifier: "map")
        #expect(abs((rig.window.centre(of: after).x - rig.window.centre(of: mapAfter).x - offsetBefore).value) <= 1)
        #expect(abs((rig.window.centre(of: after).y - rig.window.centre(of: mapAfter).y).value) <= 1)
    }

    @Test func showNeighboursSpotlightsWithoutThePointer() async throws {
        let rig = try await MapRig(schema: FixtureSnapshot.shop())
        rig.map.showNeighbours(of: orders)
        try await rig.window.runUntilIdle()
        _ = try rig.window.element(identifier: "map.scrim")
        #expect(rig.window.has("map.spot.shop.orders"))
        #expect(rig.window.has("map.spot.shop.customers"))
    }

    @Test func fitAndZoomButtonsWork() async throws {
        let rig = try await MapRig(schema: FixtureSnapshot.shop())
        let fit = rig.map.geometry
        try rig.window.click(rig.window.element(identifier: "map.zoomIn"))
        #expect(rig.map.geometry.zoom > fit.zoom)
        try rig.window.click(rig.window.element(identifier: "map.zoomOut"))
        try rig.window.click(rig.window.element(identifier: "map.zoomOut"))
        #expect(rig.map.geometry.zoom < fit.zoom)
        rig.window.typeKey("0", modifierFlags: .primary)
        #expect(rig.map.geometry == fit)
        #expect(try rig.window.element(identifier: "map.zoom").value == "\(Int((fit.zoom * 100).rounded()))%")
    }
}

/// The whole budget in one run (plan task M8): load, fit, pan, zoom, hover, drag and fly-to on 500 tables.
@MainActor
struct MapEndToEndTests {
    @Test func endToEndAt500Tables() async throws {
        let rig = try await MapRig.atAQuietPlace(pans: 5)
        let culled = rig.map.culled.nodes.count
        // Not vacuous: a loaded 500-table map, with more than 20 cards and 10 tiles on screen.
        #expect(rig.map.layout!.graph.ids.count == 500)
        #expect(rig.map.layout!.graph.edgeFK.count == 1000)
        #expect(culled > 20)
        #expect(rig.map.culled.tiles.count > 10)
        var allFrames: [Work] = []

        // Pan ×5.
        var panRasterized = 0
        for _ in 0..<5 {
            let work = await Work.of(rig) { rig.map.panBy(7, 3, scale: 1); rig.window.tick() }
            panRasterized += work.rasterized
            allFrames.append(work)
        }
        #expect(panRasterized == 0, "pan frames rasterized \(panRasterized) pixels")

        // Zoom ×3.
        for _ in 0..<3 {
            allFrames.append(await Work.of(rig) {
                rig.map.zoom(by: 1.08, about: MapRig.screen, scale: 1)
                rig.window.tick()
            })
        }

        // Hover a card.
        let hubless = rig.map.culled.nodes.first { node in
            let c = rig.map.layout!.rect(of: node).centre
            return rig.map.geometry.visibleCanvasRect(rig.map.viewSize!).inset(by: 30).contains(c)
        }!
        let hovered = rig.map.layout!.graph.ids[hubless]
        allFrames.append(await Work.of(rig) {
            rig.window.hover(at: try! rig.centre(of: hovered))
            rig.window.tick()
        })
        #expect(rig.map.hovered == hovered)

        // Drag one card.
        let from = try rig.centre(of: hovered)
        allFrames.append(await Work.of(rig) { rig.window.drag(from: from, to: Point(x: from.x + 50, y: from.y + 25), steps: 4) })
        #expect(rig.rig.mapPositions.saves == 1)

        // Fly to another table.
        let other = RelationID("s3", "t0233")
        allFrames.append(await Work.of(rig) {
            rig.map.flyTo(other, size: rig.map.viewSize!)
            rig.window.tick()
        })
        #expect(rig.map.selected == other)

        // No frame rebuilt more cards than the cull window holds (the spotlight copies and a LOD change are each
        // at most the window), and the work is counted for every frame.
        let most = allFrames.map(\.cards).max()!
        let window = rig.map.culled.nodes.count
        #expect(most <= max(culled, window) * 2, "the busiest step rebuilt \(most) cards; the window holds \(culled) and \(window)")
        #expect(allFrames.allSatisfy { $0.cards <= 2 * max(culled, window) })
    }
}

extension TestWindow {
    /// Elements whose identifier starts and ends with the given text.
    func elementsOf(prefix: String, suffix: String) -> [TestElement] {
        ((try? elements { ($0.identifier ?? "").hasPrefix(prefix) && ($0.identifier ?? "").hasSuffix(suffix) }) ?? [])
    }
}
