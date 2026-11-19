import MetalUI

/// One tile of edges: every piece whose centre lies in a `tileSize` square, as one stroked `Path`.
///
/// The path is in tile-local canvas units and the tile is placed by `.offset`, so the same tile has the same
/// raster wherever the map is panned (decisions D18, D19). **`.equatable()`**; `bodyCount` is what the pins read.
struct EdgeTileView: Component, @MainActor Equatable {
    let tile: TileID
    let tileSize: Double
    let pieces: [EdgePiece]
    let strokeWidth: Double

    @MainActor static var bodyCount = 0

    var content: some ElementGroup {
        let _ = Self.countBody()
        let ox = Double(tile.x) * tileSize, oy = Double(tile.y) * tileSize
        let path = Path { p in
            var last: LayoutPoint?
            func point(_ q: LayoutPoint) -> Point<Pixels> { Point(x: Pixels(Float(q.x - ox)), y: Pixels(Float(q.y - oy))) }
            for piece in pieces {
                if last != piece.p0 { p.move(to: point(piece.p0)) }
                p.addCurve(to: point(piece.p1), control1: point(piece.c1), control2: point(piece.c2))
                last = piece.p1
            }
        }
        path.stroke(.mapEdge, lineWidth: Pixels(Float(strokeWidth)))
            .frame(width: Pixels(Float(tileSize)), height: Pixels(Float(tileSize)), alignment: .topLeading)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .offset(x: Pixels(Float(ox)), y: Pixels(Float(oy)))
    }

    nonisolated static func == (l: Self, r: Self) -> Bool {
        l.tile == r.tile && l.tileSize == r.tileSize && l.strokeWidth == r.strokeWidth && l.pieces == r.pieces
    }
}

extension EdgeTileView {
    @MainActor static func countBody() {
        #if DEBUG
        bodyCount += 1
        #endif
    }
}
