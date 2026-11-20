import MetalUI
import MetalUITesting
import SiftCore
import SiftKit
import SiftTestSupport
import Testing

@testable import SiftKit

/// A window on a map of a fake database: the real root element, the container selected, the layout done.
@MainActor
struct MapRig {
    let rig: Rig
    let window: TestWindow
    let map: MapModel
    let key = ConnectionKey.container(name: "shop-db")

    var model: AppModel { rig.model }

    /// `schema` is what the fake server reports; `size` the window (the map is what is left of it).
    init(schema: SchemaSnapshot, size: Size<Pixels> = Size(width: Pixels(1280), height: Pixels(800)),
         recordsLayout: Bool = false) async throws {
        let source = FakeSource(schema: schema)
        rig = Rig(sources: [source])
        await rig.model.refreshDiscovery()
        await rig.model.open(key)
        window = try siftWindow(model: rig.model, size: size, recordsLayout: recordsLayout)
        rig.model.selection = .container(name: "shop-db")
        map = rig.model.map(for: key)
        try await window.runUntil { map.layout != nil && !map.culled.nodes.isEmpty }
        try await window.runUntilIdle()
        window.advance(by: 1)
        for _ in 0..<3 { window.tick() }
        // The map's size settles over the first frames (the toolbar finds its height, and on the portable text system a
        // forced redraw lays it out once more); redraw until it has held for three frames.
        var last = map.viewSize
        var steady = 0
        for _ in 0..<40 where steady < 3 {
            window.window.setNeedsRedraw()
            window.tick()
            if map.viewSize == last { steady += 1 } else { steady = 0 }
            last = map.viewSize
        }
    }

    /// Frames drawn by `body`: the work counters of each.
    func frames(_ body: () -> Void) -> [FrameWork] {
        window.resetFrameWork()
        body()
        return window.frameWork
    }
}

extension MapRig {
    static let big = SyntheticSchema.make(tables: 500, foreignKeys: 1000, seed: 42)
    static let screen = Point(x: Pixels(500), y: Pixels(400))

    /// A rig on the 500-table, 1000-link schema, flown to `table` at zoom 1.
    static func atTable(_ name: String, in schema: SchemaSnapshot = big) async throws -> MapRig {
        let rig = try await MapRig(schema: schema)
        let target = schema.relations.first { $0.id.name == name }!.id
        rig.map.flyTo(target, size: rig.map.viewSize!)
        for _ in 0..<3 { rig.window.tick() }
        return rig
    }

    /// A rig flown to the first table (every 13th from `t0100`) with more than 20 cards and 10 tiles around it where
    /// `pans` pans by (7, 3) bring no tile into view, so a
    /// pin on that pan can say 0 pixels: a tile that meets the clip for the first time is rasterized, legitimately.
    static func atAQuietPlace(pans: Int = 1) async throws -> MapRig {
        let rig = try await MapRig(schema: big)
        for n in stride(from: 100, to: 480, by: 13) {
            let id = RelationID("s\(n % 5)", "t" + String(repeating: "0", count: 4 - String(n).count) + String(n))
            rig.map.flyTo(id, size: rig.map.viewSize!)
            rig.window.tick()
            rig.window.tick()
            var panned = rig.map.geometry
            for _ in 0..<pans { panned.panBy(7, 3, scale: 1) }
            if rig.map.culled.nodes.count > 20, rig.map.culled.tiles.count > 10,
               rig.tilesMeetingTheViewport(panned) == rig.tilesMeetingTheViewport() {
                for _ in 0..<3 { rig.window.tick() }
                return rig
            }
        }
        throw RigError.timedOut("a quiet place on the map")
    }

    /// The map's top-left corner in the window.
    func mapOrigin() throws -> Point<Pixels> { try window.element(identifier: "map").frame.origin }

    /// Where a canvas point is in the window.
    func windowPoint(_ canvas: LayoutPoint) throws -> Point<Pixels> {
        let screen = map.geometry.toScreen(canvas)
        let origin = try mapOrigin()
        return Point(x: origin.x + screen.x, y: origin.y + screen.y)
    }

    /// The centre of a table's card in the window.
    func centre(of id: RelationID) throws -> Point<Pixels> {
        let node = map.layout!.graph.node(of: id)!
        return try windowPoint(map.layout!.rect(of: node).centre)
    }

    /// The cards that exist in the accessibility tree (not their `.rows`, `.count` or `.selfLoop` children).
    func cardElements() throws -> [TestElement] {
        try window.elements {
            guard let id = $0.identifier, id.hasPrefix("map.card.") else { return false }
            return !id.hasSuffix(".rows") && !id.hasSuffix(".count") && !id.hasSuffix(".selfLoop")
        }
    }

    /// The tiles whose strokes reach into the visible map (the raster cache's "meets the clip").
    func tilesMeetingTheViewport(_ geometry: MapGeometry? = nil) -> Set<TileID> {
        let visible = (geometry ?? map.geometry).visibleCanvasRect(map.viewSize!).grown(by: 4, 4)
        return Set(map.culled.tiles.filter { tile in
            let pieces = map.edgeTiles.pieces(of: tile)
            guard var box = pieces.first?.bounds else { return false }
            for piece in pieces { box = box.union(piece.bounds) }
            return box.grown(by: 4, 4).intersects(visible)
        })
    }
}

/// What a frame (or several) cost, as counters.
struct Work {
    var cards: Int
    var tiles: Int
    var frames: [FrameWork]

    var rasterized: Int { frames.map(\.rasterizedPixels).reduce(0, +) }
    var atlas: Int { frames.map(\.atlasUploadPixels).reduce(0, +) }
    var textures: Int { frames.map(\.newTextures).reduce(0, +) }
    var measures: [Int] { frames.map(\.layoutMeasureCalls) }

    /// Runs `body` and reports the card and tile bodies that ran and the frames it drew.
    @MainActor
    static func of(_ rig: MapRig, _ body: () -> Void) -> Work {
        let c = TableCardView.bodyCount, t = EdgeTileView.bodyCount
        let frames = rig.frames(body)
        return Work(cards: TableCardView.bodyCount - c, tiles: EdgeTileView.bodyCount - t, frames: frames)
    }
}
