import MetalUI
import MetalUITesting
import SiftCore
import SiftTestSupport
import Testing

@testable import SiftKit

/// The cost pins of the map at 500 tables and 1000 links (plan task M4). Each first asserts that it is not vacuous.
@MainActor
struct MapRenderTests {
    @Test func theShopMapShowsItsCards() async throws {
        let rig = try await MapRig(schema: FixtureSnapshot.shop(), recordsLayout: true)
        _ = try rig.window.element(identifier: "map")
        let card = try rig.window.element(identifier: "map.card.shop.orders")
        #expect(card.label == "orders, table, about 0 rows, references customers; referenced by order_items")
        // Every card is inside the map, and the map is what is right of the sidebar.
        let map = try rig.window.element(identifier: "map")
        for element in try rig.cardElements() {
            #expect(element.frame.origin.x.value >= map.frame.origin.x.value - 1)
        }
        #expect(try rig.cardElements().count == 13)
    }

    @Test func aSteadyFrameDoesNoWork() async throws {
        let rig = try await MapRig.atTable("t0100")
        // Not vacuous: more than 20 cards and more than 10 tiles are on the map.
        #expect(rig.map.culled.nodes.count > 20, "cards: \(rig.map.culled.nodes.count)")
        #expect(rig.map.culled.tiles.count > 10, "tiles: \(rig.map.culled.tiles.count)")
        #expect(try rig.cardElements().count == rig.map.culled.nodes.count)
        #expect(rig.window.lastFrameWork.rects > 0)

        let work = Work.of(rig) {
            for _ in 0..<5 {
                rig.window.window.setNeedsRedraw()
                rig.window.tick()
            }
        }
        #expect(work.frames.count == 5)
        #expect(work.cards == 0)
        #expect(work.tiles == 0)
        #expect(work.rasterized == 0)
        #expect(work.atlas == 0)
        #expect(work.textures == 0)
        // Bounded, not zero (lane 2-C): MetalUI's lazy containers measure once on a forced redraw, and so does
        // each stroked `Path` leaf (an edge tile; a `Color` leaf is not measured). Cards measure nothing, so the
        // number is a fixed budget plus the tiles in the cull window, whatever the number of tables.
        let bound = Self.steadyMeasureBudget + rig.map.culled.tiles.count
        #expect(work.measures.allSatisfy { $0 <= bound }, "measures: \(work.measures), bound \(bound)")
    }

    /// What one forced redraw measures with the map open, besides the edge tiles.
    static let steadyMeasureBudget = 12

    @Test func aPanStepRebuildsNothingAndRasterizesNothing() async throws {
        let rig = try await MapRig.atAQuietPlace()
        #expect(rig.map.culled.nodes.count > 20)
        #expect(rig.map.culled.tiles.count > 10)
        let before = rig.map.cull
        let tilesBefore = rig.tilesMeetingTheViewport()
        let start = rig.map.geometry.pan
        let work = Work.of(rig) {
            rig.map.panBy(7, 3, scale: 1)
            rig.window.tick()
        }
        // Not vacuous: the map moved, and what it moved over is what was built already.
        #expect(rig.map.geometry.pan != start)
        #expect(rig.map.cull == before, "the pan stayed inside the cull window")
        #expect(rig.tilesMeetingTheViewport() == tilesBefore, "no tile came into view")
        #expect(work.frames.count == 1, "builds == 1")
        #expect(work.cards == 0)
        #expect(work.tiles == 0)
        #expect(work.rasterized == 0)
        #expect(work.atlas == 0)
        #expect(work.textures == 0)
    }

    @Test func aZoomStepRebuildsNoCard() async throws {
        let rig = try await MapRig.atTable("t0100")
        rig.map.zoom(by: 0.6, about: MapRig.screen, scale: 1)
        for _ in 0..<3 { rig.window.tick() }
        #expect(rig.map.lod == .full)
        #expect(rig.map.geometry.zoomBucket == 0.5)
        #expect(rig.map.culled.nodes.count > 20)
        #expect(rig.map.culled.tiles.count > 10)
        let cullBefore = rig.map.cull
        let zoomBefore = rig.map.geometry.zoom
        let work = Work.of(rig) {
            rig.map.zoom(by: 1.08, about: MapRig.screen, scale: 1)
            rig.window.tick()
        }
        #expect(abs(rig.map.geometry.zoom / zoomBefore - 1.08) < 1e-9)
        #expect(rig.map.geometry.zoomBucket == 0.5 && rig.map.lod == .full)
        #expect(rig.map.cull == cullBefore)
        #expect(work.cards == 0)
        #expect(work.tiles == 0)
        #expect(work.rasterized > 0, "a zoom step re-rasterizes the visible tiles (RZ-C)")
        #expect(work.rasterized <= 2 * 1280 * 800, "rasterized \(work.rasterized)")
    }

    @Test func crossingALevelOfDetailRebuildsEachVisibleCardOnce() async throws {
        let rig = try await MapRig.atTable("t0100")
        rig.map.zoom(by: 0.6, about: MapRig.screen, scale: 1)
        for _ in 0..<3 { rig.window.tick() }
        #expect(rig.map.lod == .full)
        let visible = rig.map.culled.nodes.count
        #expect(visible > 20)
        let crossing = Work.of(rig) {
            rig.map.zoom(by: 0.5 / rig.map.geometry.zoom, about: MapRig.screen, scale: 1)
            rig.window.tick()
        }
        #expect(rig.map.lod == .compact)
        #expect(rig.map.geometry.zoom == 0.5)
        #expect(crossing.cards == rig.map.culled.nodes.count)
        // The next step inside the band rebuilds none.
        let within = Work.of(rig) {
            rig.map.zoom(by: 1.08, about: MapRig.screen, scale: 1)
            rig.window.tick()
        }
        #expect(rig.map.lod == .compact)
        #expect(within.cards == 0)
    }

    @Test func cullingDrawsOnlyNearbyCards() async throws {
        let rig = try await MapRig.atTable("t0100")
        let layout = rig.map.layout!
        let centre = rig.map.geometry.toCanvas(Point(x: rig.map.viewSize!.width / 2, y: rig.map.viewSize!.height / 2))
        func distance(_ node: Int) -> Double {
            let c = layout.rect(of: node).centre
            return (c.x - centre.x) * (c.x - centre.x) + (c.y - centre.y) * (c.y - centre.y)
        }
        let nearest = layout.graph.ids[layout.positions.indices.min { distance($0) < distance($1) }!]
        let farthest = layout.graph.ids[layout.positions.indices.max { distance($0) < distance($1) }!]
        let cards = try rig.cardElements()
        #expect(cards.count <= 160)
        #expect(cards.count == rig.map.culled.nodes.count)
        #expect(cards.count > 20)
        #expect(rig.window.has("map.card.\(nearest.schema).\(nearest.name)"))
        #expect(!rig.window.has("map.card.\(farthest.schema).\(farthest.name)"))
    }

    @Test func atLowZoomCardsShowOnlyTheirName() async throws {
        let rig = try await MapRig(schema: MapRig.big)
        // After the fit the zoom is below 0.25.
        #expect(rig.map.geometry.zoom < 0.25)
        #expect(rig.map.lod == .nameOnly)
        _ = try rig.window.element(identifier: "map.card.s0.t0000")
        #expect(!rig.window.has("map.card.s0.t0000.rows"))
        #expect(!rig.window.has("map.card.s0.t0000.count"))
        // At a zoom of 1 the same card has its rows.
        rig.map.flyTo(RelationID("s0", "t0000"), size: rig.map.viewSize!)
        for _ in 0..<3 { rig.window.tick() }
        #expect(rig.window.has("map.card.s0.t0000.rows"))
    }
}

extension TestWindow {
    /// Whether an element with this identifier exists.
    func has(_ identifier: String) -> Bool { ((try? elements { $0.identifier == identifier }) ?? []).isEmpty == false }
}
