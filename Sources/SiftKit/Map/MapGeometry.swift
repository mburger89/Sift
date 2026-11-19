import Foundation
import MetalUI
import SiftLayout

/// The view transform of the map: `screen = canvas * zoom + pan` (decision D18).
///
/// Cards and edges sit in canvas units inside one container drawn with
/// `.scaleEffect(zoom, anchor: .topLeading).offset(pan)`. The pan is a whole number of device pixels.
struct MapGeometry: Equatable {
    var pan: Point<Pixels>
    var zoom: Double

    static let minZoom = 0.05
    static let maxZoom = 2.0
    static let fitMargin = 40.0

    init(pan: Point<Pixels> = Point(x: Pixels(0), y: Pixels(0)), zoom: Double = 1) {
        self.pan = pan
        self.zoom = min(max(zoom, Self.minZoom), Self.maxZoom)
    }

    private var panX: Double { Double(pan.x.value) }
    private var panY: Double { Double(pan.y.value) }

    /// `v` rounded to a whole device pixel (1/scale of a point).
    static func snap(_ v: Double, scale: Float) -> Double {
        let s = Double(max(scale, 1))
        return (v * s).rounded() / s
    }

    func toScreen(_ p: LayoutPoint) -> Point<Pixels> {
        Point(x: Pixels(Float(p.x * zoom + panX)), y: Pixels(Float(p.y * zoom + panY)))
    }

    func toCanvas(_ p: Point<Pixels>) -> LayoutPoint {
        LayoutPoint(x: (Double(p.x.value) - panX) / zoom, y: (Double(p.y.value) - panY) / zoom)
    }

    /// Sets the zoom (clamped) so the canvas point under `anchor` stays under it, then snaps the pan to
    /// whole device pixels (the point moves by at most half a device pixel).
    mutating func zoom(to newZoom: Double, about anchor: Point<Pixels>, scale: Float) {
        let clamped = min(max(newZoom, Self.minZoom), Self.maxZoom)
        let factor = clamped / zoom
        let ax = Double(anchor.x.value), ay = Double(anchor.y.value)
        pan = Point(
            x: Pixels(Float(Self.snap(ax - (ax - panX) * factor, scale: scale))),
            y: Pixels(Float(Self.snap(ay - (ay - panY) * factor, scale: scale))))
        zoom = clamped
    }

    mutating func panBy(_ dx: Float, _ dy: Float, scale: Float) {
        pan = Point(
            x: Pixels(Float(Self.snap(panX + Double(dx), scale: scale))),
            y: Pixels(Float(Self.snap(panY + Double(dy), scale: scale))))
    }

    /// The view that shows all of `bounds` with a margin, centred.
    static func fit(_ bounds: LayoutRect, in size: Size<Pixels>, scale: Float) -> MapGeometry {
        let w = Double(size.width.value), h = Double(size.height.value)
        guard bounds.width > 0, bounds.height > 0, w > 0, h > 0 else { return MapGeometry() }
        let zoom = min(
            max(min((w - 2 * fitMargin) / bounds.width, (h - 2 * fitMargin) / bounds.height), minZoom), maxZoom)
        return centred(on: bounds.centre, zoom: zoom, in: size, scale: scale)
    }

    /// The view that centres `rect` at a zoom of at least `minZoom` (and at most 1, so a table is not blown up).
    static func flyTo(_ rect: LayoutRect, in size: Size<Pixels>, minZoom: Double = 0.8, scale: Float) -> MapGeometry {
        let w = Double(size.width.value), h = Double(size.height.value)
        let fitZoom = min((w - 2 * fitMargin) / max(rect.width, 1), (h - 2 * fitMargin) / max(rect.height, 1))
        return centred(on: rect.centre, zoom: max(minZoom, min(1, fitZoom)), in: size, scale: scale)
    }

    private static func centred(on centre: LayoutPoint, zoom: Double, in size: Size<Pixels>, scale: Float) -> MapGeometry {
        let z = min(max(zoom, minZoom), maxZoom)
        return MapGeometry(
            pan: Point(
                x: Pixels(Float(snap(Double(size.width.value) / 2 - centre.x * z, scale: scale))),
                y: Pixels(Float(snap(Double(size.height.value) / 2 - centre.y * z, scale: scale)))),
            zoom: z)
    }

    /// The canvas rectangle the view shows.
    func visibleCanvasRect(_ size: Size<Pixels>) -> LayoutRect {
        let origin = toCanvas(Point(x: Pixels(0), y: Pixels(0)))
        return LayoutRect(
            x: origin.x, y: origin.y, width: Double(size.width.value) / zoom, height: Double(size.height.value) / zoom)
    }

    /// The largest power of two not above the zoom: edge tiles change size only when this changes (decision D19).
    var zoomBucket: Double { pow(2, floor(log2(zoom))) }
}

/// The canvas region whose cards and edge tiles are built: the viewport grown by half of it on each side
/// (decision D21). It is recomputed only once the viewport leaves the window's inner half, so most pans and
/// zoom steps change nothing that is built.
struct CullWindow: Equatable {
    var rect: LayoutRect

    /// The window for a viewport.
    static func around(_ viewport: LayoutRect) -> CullWindow {
        CullWindow(rect: viewport.grown(by: viewport.width / 2, viewport.height / 2))
    }

    /// A new window when the viewport has left `current`'s inner half (its rectangle less half the margin on each
    /// side), else nil.
    static func updated(_ current: CullWindow?, viewport: LayoutRect) -> CullWindow? {
        guard let current else { return around(viewport) }
        let inner = current.rect.grown(by: -current.rect.width / 8, -current.rect.height / 8)
        return inner.contains(viewport) ? nil : around(viewport)
    }
}

/// A grid of cells over the cards: point and rectangle queries without touching every card.
struct SpatialIndex {
    private struct Cell: Hashable { var x: Int; var y: Int }
    private let cell: Double
    private let rects: [Int: LayoutRect]
    private var cells: [Cell: [Int]] = [:]

    init(cell: Double = 512, rects: [Int: LayoutRect]) {
        self.cell = cell
        self.rects = rects
        for id in rects.keys.sorted() {
            for c in cellRange(rects[id]!) { cells[c, default: []].append(id) }
        }
    }

    private func cellRange(_ r: LayoutRect) -> [Cell] {
        let x0 = Int(floor(r.x / cell)), x1 = Int(floor(r.maxX / cell))
        let y0 = Int(floor(r.y / cell)), y1 = Int(floor(r.maxY / cell))
        var out: [Cell] = []
        for x in x0...max(x0, x1) { for y in y0...max(y0, y1) { out.append(Cell(x: x, y: y)) } }
        return out
    }

    /// The card under the point; the highest id wins where cards overlap (it is drawn last).
    func hit(_ p: LayoutPoint) -> Int? {
        let c = Cell(x: Int(floor(p.x / cell)), y: Int(floor(p.y / cell)))
        return cells[c]?.last { rects[$0]!.contains(p) }
    }

    /// The ids whose rectangle overlaps `r`, sorted.
    func query(_ r: LayoutRect) -> [Int] {
        var found = Set<Int>()
        for c in cellRange(r) {
            for id in cells[c] ?? [] where rects[id]!.intersects(r) { found.insert(id) }
        }
        return found.sorted()
    }
}
