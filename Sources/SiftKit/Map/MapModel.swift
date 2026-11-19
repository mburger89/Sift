import Foundation
import MetalUI
import Observation
import SiftCore
import SiftLayout

/// The cards and edge tiles inside the cull window (decision D21).
struct CulledSet: Equatable {
    var nodes: [Int] = []
    var tiles: [TileID] = []
}

/// One database's map: the layout, the view transform, what is built, and what the pointer and the user chose.
///
/// The layout runs off the main actor. Pan and zoom write `geometry` (and, rarely, `lod`, `cull` and `culled`);
/// only the container that applies the transform reads `geometry`, so a pan rebuilds no card (decision D18).
@Observable @MainActor
final class MapModel {
    // MARK: What is shown
    private(set) var snapshot: SchemaSnapshot?
    private(set) var layout: MapLayout?
    private(set) var geometry = MapGeometry()
    private(set) var lod: MapLOD = .full
    private(set) var cull: CullWindow?
    private(set) var culled = CulledSet()
    private(set) var edgeTiles = EdgeTiles(pieces: [], tileSize: 512)
    /// The edges of the card being dragged, drawn live instead of in the tiles.
    private(set) var liveEdges: [EdgePiece] = []
    private(set) var dragged: RelationID?
    /// Bumped when the cards' places change for good (a load, a drop, a reset): the minimap's key.
    private(set) var positionsVersion = 0
    /// How many layouts have run.
    private(set) var layoutRuns = 0
    /// The map's size in points once it has been laid out.
    private(set) var viewSize: Size<Pixels>?

    // MARK: What the user chose
    var hovered: RelationID?
    var selected: RelationID?
    var selectedEdge: ForeignKeyInfo.ID?
    var search = ""
    private(set) var filter = MapFilter()

    @ObservationIgnored private(set) var index = SpatialIndex(rects: [:])
    @ObservationIgnored private let store: any MapPositionsStoring
    @ObservationIgnored private var identity = ""
    @ObservationIgnored private var pins: [RelationID: LayoutPoint] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var fitPending = true
    @ObservationIgnored private var tileBucket = 1.0
    @ObservationIgnored private var dragEdgeSet: Set<Int> = []
    @ObservationIgnored private var scale: Float = 1

    init(store: any MapPositionsStoring) { self.store = store }

    // MARK: Loading

    /// Lays the schema out (off the main actor) and merges the remembered positions by name.
    func load(snapshot: SchemaSnapshot, identity: String) async {
        if identity != self.identity {
            self.identity = identity
            pins = Self.pins(from: store.load(identity: identity))
        }
        self.snapshot = snapshot
        await relayout()
    }

    func setFilter(_ filter: MapFilter) async {
        guard filter != self.filter else { return }
        self.filter = filter
        fitPending = true
        await relayout()
    }

    private func relayout() async {
        guard let snapshot else { return }
        generation += 1
        let mine = generation
        let graph = MapGraphBuilder.build(snapshot, filter: filter)
        let result = await Task.detached(priority: .userInitiated) { LayeredLayout.layout(graph.graph) }.value
        guard mine == generation else { return }
        layoutRuns += 1
        install(MapLayout(graph: graph, result: result, pins: pins))
        if fitPending, let size = viewSize { fit(size) }
    }

    private func install(_ new: MapLayout) {
        layout = new
        positionsVersion += 1
        dragged = nil
        liveEdges = []
        dragEdgeSet = []
        if let selected, new.graph.node(of: selected) == nil { self.selected = nil }
        if let hovered, new.graph.node(of: hovered) == nil { self.hovered = nil }
        rebuildDerived()
    }

    /// The spatial index, the edge tiles and the culled set, from the layout and the zoom.
    private func rebuildDerived() {
        guard let layout else { return }
        index = SpatialIndex(rects: layout.rects)
        tileBucket = geometry.zoomBucket
        let size = 512 / tileBucket
        edgeTiles = EdgeTiles(pieces: EdgeRouting.pieces(for: layout, tileSize: size, excluding: dragEdgeSet), tileSize: size)
        cull = nil
        refreshView()
    }

    private static func pins(from stored: [String: [Double]]) -> [RelationID: LayoutPoint] {
        var out: [RelationID: LayoutPoint] = [:]
        for (key, value) in stored where value.count == 2 {
            guard let dot = key.firstIndex(of: ".") else { continue }
            out[RelationID(String(key[..<dot]), String(key[key.index(after: dot)...]))] = LayoutPoint(x: value[0], y: value[1])
        }
        return out
    }

    private func storedPins() -> [String: [Double]] {
        Dictionary(uniqueKeysWithValues: pins.map { ($0.key.qualifiedName, [$0.value.x, $0.value.y]) })
    }

    /// The remembered position of a table, if the user moved it.
    func pin(of id: RelationID) -> LayoutPoint? { pins[id] }

    // MARK: Geometry

    /// Tells the model how big the map is. The first size fits the whole schema.
    func setViewSize(_ size: Size<Pixels>, scale: Float) {
        self.scale = scale
        guard size != viewSize else { return }
        viewSize = size
        if fitPending, layout != nil { fit(size) } else { refreshView() }
    }

    func fit() { if let viewSize { fit(viewSize) } }

    func fit(_ size: Size<Pixels>) {
        guard let layout else { return }
        fitPending = false
        geometry = MapGeometry.fit(layout.bounds, in: size, scale: scale)
        refreshView()
    }

    func panBy(_ dx: Float, _ dy: Float, scale: Float) {
        self.scale = scale
        geometry.panBy(dx, dy, scale: scale)
        refreshView()
    }

    func zoom(by factor: Double, about anchor: Point<Pixels>, scale: Float) {
        self.scale = scale
        geometry.zoom(to: geometry.zoom * factor, about: anchor, scale: scale)
        refreshView()
    }

    func zoomIn() { if let viewSize { zoom(by: 1.25, about: Point(x: viewSize.width / 2, y: viewSize.height / 2), scale: scale) } }
    func zoomOut() { if let viewSize { zoom(by: 0.8, about: Point(x: viewSize.width / 2, y: viewSize.height / 2), scale: scale) } }

    /// Centres the map on a canvas point (a click on the minimap).
    func centre(on point: LayoutPoint) {
        guard let viewSize else { return }
        geometry = MapGeometry(
            pan: Point(
                x: Pixels(Float(MapGeometry.snap(Double(viewSize.width.value) / 2 - point.x * geometry.zoom, scale: scale))),
                y: Pixels(Float(MapGeometry.snap(Double(viewSize.height.value) / 2 - point.y * geometry.zoom, scale: scale)))),
            zoom: geometry.zoom)
        refreshView()
    }

    /// Flies to a table and selects it. Zoom is at least 0.8.
    func flyTo(_ id: RelationID, size: Size<Pixels>) {
        guard let layout, let node = layout.graph.node(of: id) else { return }
        geometry = MapGeometry.flyTo(layout.rect(of: node), in: size, scale: scale)
        selected = id
        refreshView()
    }

    func flyToSelection() { if let selected, let viewSize { flyTo(selected, size: viewSize) } }

    /// After any change of the view: the level of detail, the cull window and (when the zoom crosses a power of
    /// two) the edge tiles. A write happens only when the value changed, so a pan inside the window writes none.
    private func refreshView() {
        guard layout != nil, let viewSize else { return }
        let next = MapLOD.forZoom(geometry.zoom, previous: lod)
        if next != lod { lod = next }
        var changed = false
        if geometry.zoomBucket != tileBucket {
            tileBucket = geometry.zoomBucket
            let size = 512 / tileBucket
            edgeTiles = EdgeTiles(
                pieces: EdgeRouting.pieces(for: layout!, tileSize: size, excluding: dragEdgeSet), tileSize: size)
            changed = true
        }
        if let window = CullWindow.updated(cull, viewport: geometry.visibleCanvasRect(viewSize)) {
            cull = window
            changed = true
        }
        if changed { recomputeCulled() }
    }

    private func recomputeCulled() {
        guard let cull else { return }
        let next = CulledSet(nodes: index.query(cull.rect), tiles: edgeTiles.tiles(in: cull.rect))
        if next != culled { culled = next }
    }

    // MARK: Hover and selection

    func hover(at screen: Point<Pixels>) {
        let id = layout.flatMap { layout in index.hit(geometry.toCanvas(screen)).map { layout.graph.ids[$0] } }
        if id != hovered { hovered = id }
    }

    func clearHover() { if hovered != nil { hovered = nil } }

    /// The table under a screen point.
    func table(at screen: Point<Pixels>) -> RelationID? {
        guard let layout else { return nil }
        return index.hit(geometry.toCanvas(screen)).map { layout.graph.ids[$0] }
    }

    /// The foreign key whose line passes within a few points of a screen point.
    func edge(at screen: Point<Pixels>) -> ForeignKeyInfo.ID? {
        guard let layout else { return nil }
        let tolerance = 6 / geometry.zoom
        return edgeTiles.hitEdge(geometry.toCanvas(screen), tolerance: tolerance).map { layout.graph.edgeFK[$0] }
    }

    // MARK: Dragging

    func beginDrag(_ id: RelationID) {
        guard let layout, let node = layout.graph.node(of: id), dragged == nil else { return }
        dragged = id
        dragEdgeSet = Set(layout.graph.graph.edges.indices.filter {
            let edge = layout.graph.graph.edges[$0]
            return (edge.from == node || edge.to == node) && !layout.selfLoops.contains($0)
        })
        let size = edgeTiles.tileSize
        edgeTiles = EdgeTiles(pieces: EdgeRouting.pieces(for: layout, tileSize: size, excluding: dragEdgeSet), tileSize: size)
        recomputeCulled()
    }

    func drag(_ id: RelationID, to point: LayoutPoint) {
        guard dragged == id, var layout, let node = layout.graph.node(of: id) else { return }
        layout.move(node, to: point)
        pins[id] = point
        self.layout = layout
        liveEdges = dragEdgeSet.sorted().flatMap {
            EdgeRouting.pieces(through: layout.path(of: $0), edge: $0, tileSize: edgeTiles.tileSize)
        }
    }

    /// Drops the card: its edges go back into the tiles and the position is saved (once).
    func endDrag() {
        guard dragged != nil else { return }
        dragged = nil
        dragEdgeSet = []
        liveEdges = []
        positionsVersion += 1
        store.save(identity: identity, positions: storedPins())
        rebuildDerived()
    }

    /// Forgets every dragged position and lays the schema out again.
    func resetLayout() async {
        pins = [:]
        store.save(identity: identity, positions: [:])
        fitPending = true
        await relayout()
    }
}
