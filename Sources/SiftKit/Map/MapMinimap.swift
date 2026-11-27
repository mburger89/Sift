import MetalUI
import SiftLayout

/// Where the minimap draws the canvas: `bounds` scaled to fit in the box, centred.
struct MinimapTransform: Equatable {
    static let width = 200.0
    static let height = 140.0
    static let margin = 6.0

    let bounds: LayoutRect
    var scale: Double {
        min((Self.width - 2 * Self.margin) / max(bounds.width, 1), (Self.height - 2 * Self.margin) / max(bounds.height, 1))
    }
    var offsetX: Double { (Self.width - bounds.width * scale) / 2 - bounds.x * scale }
    var offsetY: Double { (Self.height - bounds.height * scale) / 2 - bounds.y * scale }

    func toMinimap(_ p: LayoutPoint) -> LayoutPoint { LayoutPoint(x: p.x * scale + offsetX, y: p.y * scale + offsetY) }
    func toCanvas(_ p: LayoutPoint) -> LayoutPoint { LayoutPoint(x: (p.x - offsetX) / scale, y: (p.y - offsetY) / scale) }
}

/// The whole schema in a corner, with the part the map shows outlined. Click to centre the map there.
struct MapMinimap: Component {
    let map: MapModel

    var content: some ElementGroup {
        if let bounds = map.layout?.bounds, bounds.width > 0 {
            let transform = MinimapTransform(bounds: bounds)
            let shown = map.viewSize.map { map.geometry.visibleCanvasRect($0) }
            ZStack(alignment: .topLeading) {
                MinimapCards(map: map, version: map.positionsVersion).equatable()
                if let shown {
                    let a = transform.toMinimap(LayoutPoint(x: shown.x, y: shown.y))
                    let w = shown.width * transform.scale, h = shown.height * transform.scale
                    Rectangle().stroke(.mapAccent, lineWidth: Pixels(1.5))
                        .frame(width: Pixels(Float(w)), height: Pixels(Float(h)))
                        .offset(x: Pixels(Float(a.x)), y: Pixels(Float(a.y)))
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("map.minimap.viewport")
                }
            }
            .frame(width: Pixels(Float(MinimapTransform.width)), height: Pixels(Float(MinimapTransform.height)), alignment: .topLeading)
            .background(.mapCardFill)
            .clipped()
            .roundedBorder(.mapCardBorder, radius: Pixels(6), width: Pixels(1))
            .gesture(SpatialTapGesture().onEnded { (tap: SpatialTapGesture.Value) in
                map.centre(on: transform.toCanvas(LayoutPoint(x: Double(tap.location.x.value), y: Double(tap.location.y.value))))
            })
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Minimap")
            .accessibilityIdentifier("map.minimap")
        }
    }
}

/// Every card as a rectangle in one `Path`. It is rebuilt only when `version` changes (a load, a drop), never for a
/// pan or a zoom step, so `bodyCount` is what the pin reads.
struct MinimapCards: Component, @MainActor Equatable {
    let map: MapModel
    let version: Int

    @MainActor static var bodyCount = 0

    var content: some ElementGroup {
        let _ = Self.countBody()
        if let layout = map.committedLayout {
            let transform = MinimapTransform(bounds: layout.bounds)
            let path = Path { p in
                for node in layout.positions.indices {
                    let r = layout.rect(of: node)
                    let a = transform.toMinimap(LayoutPoint(x: r.x, y: r.y))
                    p.addRect(Bounds(
                        origin: Point(x: Pixels(Float(a.x)), y: Pixels(Float(a.y))),
                        size: Size(
                            width: Pixels(Float(max(r.width * transform.scale, 1))),
                            height: Pixels(Float(max(r.height * transform.scale, 1))))))
                }
            }
            path.fill(.mapEdge)
                .frame(width: Pixels(Float(MinimapTransform.width)), height: Pixels(Float(MinimapTransform.height)), alignment: .topLeading)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    nonisolated static func == (l: Self, r: Self) -> Bool { l.map === r.map && l.version == r.version }
}

extension MinimapCards {
    @MainActor static func countBody() {
        #if DEBUG
        bodyCount += 1
        #endif
    }
}
