import MetalUI
import SiftCore
import SiftLayout
import SiftTestSupport
import Testing

@testable import SiftKit

struct MapGeometryTests {
    static func point(_ x: Float, _ y: Float) -> Point<Pixels> { Point(x: Pixels(x), y: Pixels(y)) }
    static let view = Size(width: Pixels(1280), height: Pixels(800))

    @Test func panIsSnappedToDevicePixels() {
        var geometry = MapGeometry()
        geometry.panBy(0.3, 0.6, scale: 2)
        #expect(geometry.pan == Self.point(0.5, 0.5))
        var one = MapGeometry()
        one.panBy(0.3, 0.6, scale: 1)
        #expect(one.pan == Self.point(0, 1))
    }

    @Test func zoomKeepsThePointUnderTheAnchor() {
        let anchor = Self.point(400, 300)
        for target in [2.0, 1.5, 0.5] {
            var geometry = MapGeometry(pan: Self.point(-120, 40), zoom: 1)
            let before = geometry.toCanvas(anchor)
            geometry.zoom(to: target, about: anchor, scale: 1)
            let after = geometry.toCanvas(anchor)
            // Snapping to whole pixels moves the point by at most half a device pixel (at this zoom).
            #expect(abs(after.x - before.x) <= 0.5 / geometry.zoom + 1e-6)
            #expect(abs(after.y - before.y) <= 0.5 / geometry.zoom + 1e-6)
        }
        // Where the arithmetic is exact the point does not move at all.
        var exact = MapGeometry()
        let before = exact.toCanvas(anchor)
        exact.zoom(to: 2, about: anchor, scale: 1)
        #expect(abs(exact.toCanvas(anchor).x - before.x) < 1e-6)
        #expect(abs(exact.toCanvas(anchor).y - before.y) < 1e-6)
        #expect(exact.zoom == 2)
    }

    @Test func zoomIsClamped() {
        var geometry = MapGeometry()
        geometry.zoom(to: 50, about: Self.point(0, 0), scale: 1)
        #expect(geometry.zoom == MapGeometry.maxZoom)
        geometry.zoom(to: 0.0001, about: Self.point(0, 0), scale: 1)
        #expect(geometry.zoom == MapGeometry.minZoom)
    }

    @Test func fitEnclosesTheBounds() {
        let bounds = LayoutRect(x: 100, y: -50, width: 5000, height: 3000)
        let geometry = MapGeometry.fit(bounds, in: Self.view, scale: 2)
        let visible = geometry.visibleCanvasRect(Self.view)
        #expect(visible.contains(bounds))
        #expect(abs(geometry.zoom - 0.24) < 1e-9)
    }

    @Test func flyToCentresTheRect() {
        let rect = LayoutRect(x: 3000, y: 2000, width: 220, height: 150)
        let geometry = MapGeometry.flyTo(rect, in: Self.view, scale: 1)
        let centre = geometry.toScreen(rect.centre)
        #expect(abs(centre.x.value - 640) <= 1)
        #expect(abs(centre.y.value - 400) <= 1)
        #expect(geometry.zoom >= 0.8)
    }

    @Test func zoomBucketIsAPowerOfTwo() {
        #expect(MapGeometry(zoom: 0.6).zoomBucket == 0.5)
        #expect(MapGeometry(zoom: 1.9).zoomBucket == 1)
        #expect(MapGeometry(zoom: 0.07).zoomBucket == 0.0625)
    }

    @Test func cullWindowHoldsWhileTheViewportStaysInsideItsInnerHalf() {
        let viewport = LayoutRect(x: 0, y: 0, width: 1000, height: 800)
        let window = CullWindow.around(viewport)
        #expect(window.rect == LayoutRect(x: -500, y: -400, width: 2000, height: 1600))
        #expect(CullWindow.updated(window, viewport: LayoutRect(x: 100, y: 0, width: 1000, height: 800)) == nil)
        let far = CullWindow.updated(window, viewport: LayoutRect(x: 600, y: 0, width: 1000, height: 800))
        #expect(far == CullWindow.around(LayoutRect(x: 600, y: 0, width: 1000, height: 800)))
        #expect(CullWindow.updated(nil, viewport: viewport) == window)
        // Zooming out grows the viewport past the window.
        #expect(CullWindow.updated(window, viewport: LayoutRect(x: -100, y: -100, width: 1500, height: 1200)) != nil)
    }

    @Test func spatialIndexMatchesBruteForce() {
        var rng = TestRandom(seed: 7)
        var rects: [Int: LayoutRect] = [:]
        for id in 0..<200 {
            rects[id] = LayoutRect(
                x: rng.unit() * 6000 - 500, y: rng.unit() * 6000 - 500, width: 20 + rng.unit() * 600, height: 20 + rng.unit() * 400)
        }
        let index = SpatialIndex(rects: rects)
        for _ in 0..<200 {
            let p = LayoutPoint(x: rng.unit() * 6000 - 500, y: rng.unit() * 6000 - 500)
            #expect(index.hit(p) == rects.filter { $0.value.contains(p) }.keys.max())
            let q = LayoutRect(x: p.x, y: p.y, width: rng.unit() * 900, height: rng.unit() * 900)
            #expect(index.query(q) == rects.filter { $0.value.intersects(q) }.keys.sorted())
        }
    }

    @Test func piecesFitTheirTiles() {
        let layout = Self.layout(of: FixtureSnapshot.shop())
        let tile = 512.0
        let pieces = EdgeRouting.pieces(for: layout, tileSize: tile)
        #expect(pieces.count > layout.graph.graph.edges.count)  // a long edge is cut
        for piece in pieces {
            #expect(piece.bounds.width <= tile / 2 && piece.bounds.height <= tile / 2)
        }
        // A smaller tile gives more pieces.
        #expect(EdgeRouting.pieces(for: layout, tileSize: 128).count > pieces.count)
    }

    @Test func edgesStartAndEndAtTheirPorts() {
        let layout = Self.layout(of: FixtureSnapshot.shop())
        let graph = layout.graph
        let edge = graph.edgeFK.firstIndex { $0.hasSuffix("orders_customer_id_fkey") }!
        let path = layout.path(of: edge)
        let from = layout.rect(of: graph.graph.edges[edge].from)
        let to = layout.rect(of: graph.graph.edges[edge].to)
        #expect(path.first!.x == from.maxX)  // the referencing card is on the left
        #expect(path.last!.x == to.x)
        let orders = graph.keyColumns[graph.graph.edges[edge].from]
        #expect(path.first!.y == from.y + MapCardMetrics.portY(column: "customer_id", in: orders)!)
    }

    @Test func edgeHitFindsTheNearestWithinTolerance() {
        let layout = Self.layout(of: FixtureSnapshot.shop())
        let tiles = EdgeTiles(pieces: EdgeRouting.pieces(for: layout, tileSize: 512), tileSize: 512)
        for edge in layout.graph.graph.edges.indices where !layout.selfLoops.contains(edge) {
            let path = layout.path(of: edge)
            // The curve's start is on it; a point 3 units off it is within a tolerance of 6.
            let start = path[0]
            #expect(tiles.hitEdge(LayoutPoint(x: start.x + 3, y: start.y + 3), tolerance: 6) != nil)
        }
        let straight = layout.graph.graph.edges.indices.first { !layout.selfLoops.contains($0) }!
        let first = layout.path(of: straight)[0]
        #expect(tiles.hitEdge(LayoutPoint(x: first.x + 3, y: first.y), tolerance: 6) == straight)
        #expect(tiles.hitEdge(LayoutPoint(x: -9000, y: -9000), tolerance: 6) == nil)
        // Two edges meeting at one port: the nearer wins.
        let nearer = layout.path(of: straight)
        let mid = EdgeRouting.pieces(through: nearer, edge: straight, tileSize: 512)[0].point(at: 0.5)
        #expect(tiles.hitEdge(LayoutPoint(x: mid.x, y: mid.y + 4), tolerance: 6) == straight)
        #expect(tiles.hitEdge(LayoutPoint(x: mid.x, y: mid.y + 40), tolerance: 6) != straight)
    }

    @Test func tilesCoverTheEdgesOfAWindow() {
        let layout = Self.layout(of: FixtureSnapshot.shop())
        let tiles = EdgeTiles(pieces: EdgeRouting.pieces(for: layout, tileSize: 512), tileSize: 512)
        let everything = layout.bounds.grown(by: 600, 600)
        let listed = tiles.tiles(in: everything)
        #expect(listed.count == tiles.tileCount)
        #expect(listed == listed.sorted())
        #expect(tiles.tiles(in: LayoutRect(x: 1e6, y: 1e6, width: 10, height: 10)).isEmpty)
    }

    static func layout(of snapshot: SchemaSnapshot, filter: MapFilter = MapFilter()) -> MapLayout {
        let graph = MapGraphBuilder.build(snapshot, filter: filter)
        return MapLayout(graph: graph, result: LayeredLayout.layout(graph.graph))
    }
}

/// SplitMix64, so a test's random numbers are the same on every run.
struct TestRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
