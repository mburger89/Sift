import Foundation
import SiftLayout

/// One cubic Bézier of an edge, small enough to fit in half a tile.
struct EdgePiece: Equatable, Sendable {
    var edge: Int
    var p0: LayoutPoint
    var c1: LayoutPoint
    var c2: LayoutPoint
    var p1: LayoutPoint

    var minX: Double { min(p0.x, c1.x, c2.x, p1.x) }
    var maxX: Double { max(p0.x, c1.x, c2.x, p1.x) }
    var minY: Double { min(p0.y, c1.y, c2.y, p1.y) }
    var maxY: Double { max(p0.y, c1.y, c2.y, p1.y) }
    var bounds: LayoutRect { LayoutRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY) }

    func point(at t: Double) -> LayoutPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return LayoutPoint(
            x: a * p0.x + b * c1.x + c * c2.x + d * p1.x, y: a * p0.y + b * c1.y + c * c2.y + d * p1.y)
    }

    /// De Casteljau at one half.
    func split() -> (EdgePiece, EdgePiece) {
        func mid(_ a: LayoutPoint, _ b: LayoutPoint) -> LayoutPoint { LayoutPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        let p01 = mid(p0, c1), p12 = mid(c1, c2), p23 = mid(c2, p1)
        let p012 = mid(p01, p12), p123 = mid(p12, p23)
        let m = mid(p012, p123)
        return (
            EdgePiece(edge: edge, p0: p0, c1: p01, c2: p012, p1: m),
            EdgePiece(edge: edge, p0: m, c1: p123, c2: p23, p1: p1)
        )
    }
}

enum EdgeRouting {
    /// Every edge of the layout (but self-loops and those in `excluding`) as pieces that fit in half a tile.
    static func pieces(
        for layout: MapLayout, tileSize: Double, excluding: Set<Int> = []
    ) -> [EdgePiece] {
        var out: [EdgePiece] = []
        for edge in layout.graph.graph.edges.indices where !layout.selfLoops.contains(edge) && !excluding.contains(edge) {
            out += pieces(through: layout.path(of: edge), edge: edge, tileSize: tileSize)
        }
        return out
    }

    /// A smooth curve through the points, with horizontal tangents, cut into pieces.
    static func pieces(through points: [LayoutPoint], edge: Int, tileSize: Double) -> [EdgePiece] {
        var out: [EdgePiece] = []
        for (a, b) in zip(points, points.dropFirst()) {
            let dx = (b.x - a.x) / 2
            let curve = EdgePiece(
                edge: edge, p0: a, c1: LayoutPoint(x: a.x + dx, y: a.y), c2: LayoutPoint(x: b.x - dx, y: b.y), p1: b)
            subdivide(curve, limit: tileSize / 2, depth: 0, into: &out)
        }
        return out
    }

    private static func subdivide(_ piece: EdgePiece, limit: Double, depth: Int, into out: inout [EdgePiece]) {
        let b = piece.bounds
        if (b.width <= limit && b.height <= limit) || depth >= 12 {
            out.append(piece)
        } else {
            let (l, r) = piece.split()
            subdivide(l, limit: limit, depth: depth + 1, into: &out)
            subdivide(r, limit: limit, depth: depth + 1, into: &out)
        }
    }
}

/// A tile of the canvas, `tileSize` canvas units on a side.
struct TileID: Hashable, Comparable, Sendable {
    var x: Int
    var y: Int
    static func < (l: TileID, r: TileID) -> Bool { (l.y, l.x) < (r.y, r.x) }
}

/// The pieces of every edge, bucketed by the tile their centre lies in. Each tile is one `Path`.
struct EdgeTiles {
    /// A tile is `base / zoomBucket` canvas units on a side, so it is between `base` and `2 * base` points on
    /// screen. MetalUI rasterizes a stroked path once, and a whole-pixel pan then costs nothing, only while the
    /// path reaches no more than half the window beyond the clip (`PN-A`); a tile's strokes reach up to 1.5 tiles
    /// (a piece is at most half a tile and is filed by its centre), so the tile has to be small next to the window.
    static let base = 128.0

    let tileSize: Double
    private var buckets: [TileID: [EdgePiece]] = [:]

    init(pieces: [EdgePiece], tileSize: Double) {
        self.tileSize = tileSize
        for piece in pieces {
            let b = piece.bounds
            let id = TileID(
                x: Int(floor((b.x + b.width / 2) / tileSize)), y: Int(floor((b.y + b.height / 2) / tileSize)))
            buckets[id, default: []].append(piece)
        }
    }

    /// The canvas rectangle of a tile (its pieces may reach a quarter tile beyond it).
    func rect(of tile: TileID) -> LayoutRect {
        LayoutRect(x: Double(tile.x) * tileSize, y: Double(tile.y) * tileSize, width: tileSize, height: tileSize)
    }

    /// The non-empty tiles that may have a piece inside `rect`, sorted.
    func tiles(in rect: LayoutRect) -> [TileID] {
        let pad = tileSize / 4
        let x0 = Int(floor((rect.x - pad) / tileSize)), x1 = Int(floor((rect.maxX + pad) / tileSize))
        let y0 = Int(floor((rect.y - pad) / tileSize)), y1 = Int(floor((rect.maxY + pad) / tileSize))
        guard x0 <= x1, y0 <= y1 else { return [] }
        var out: [TileID] = []
        for y in y0...y1 { for x in x0...x1 where buckets[TileID(x: x, y: y)] != nil { out.append(TileID(x: x, y: y)) } }
        return out
    }

    func pieces(of tile: TileID) -> [EdgePiece] { buckets[tile] ?? [] }

    var tileCount: Int { buckets.count }

    /// The edge nearest `p` within `tolerance` canvas units, if any.
    func hitEdge(_ p: LayoutPoint, tolerance: Double) -> Int? {
        let probe = LayoutRect(x: p.x - tolerance, y: p.y - tolerance, width: 2 * tolerance, height: 2 * tolerance)
        var best: (edge: Int, distance: Double)?
        for tile in tiles(in: probe) {
            for piece in buckets[tile]! where piece.bounds.grown(by: tolerance, tolerance).contains(p) {
                var previous = piece.p0
                for step in 1...8 {
                    let next = piece.point(at: Double(step) / 8)
                    let d = Self.distance(from: p, toSegment: previous, next)
                    if d <= tolerance, best == nil || (d, piece.edge) < (best!.distance, best!.edge) {
                        best = (piece.edge, d)
                    }
                    previous = next
                }
            }
        }
        return best?.edge
    }

    private static func distance(from p: LayoutPoint, toSegment a: LayoutPoint, _ b: LayoutPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        let t = lengthSquared == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}
