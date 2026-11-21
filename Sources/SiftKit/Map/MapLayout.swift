import SiftCore
import SiftLayout

// MetalUI has types of these names too; the map's are the layout's, canvas units.
typealias LayoutRect = SiftLayout.LayoutRect
typealias LayoutPoint = SiftLayout.LayoutPoint

extension LayoutRect {
    var maxX: Double { x + width }
    var maxY: Double { y + height }
    var centre: LayoutPoint { LayoutPoint(x: x + width / 2, y: y + height / 2) }

    func intersects(_ other: LayoutRect) -> Bool {
        x < other.maxX && other.x < maxX && y < other.maxY && other.y < maxY
    }

    func contains(_ p: LayoutPoint) -> Bool { p.x >= x && p.x < maxX && p.y >= y && p.y < maxY }

    func contains(_ other: LayoutRect) -> Bool {
        other.x >= x && other.y >= y && other.maxX <= maxX && other.maxY <= maxY
    }

    func union(_ other: LayoutRect) -> LayoutRect {
        let minX = min(x, other.x), minY = min(y, other.y)
        return LayoutRect(x: minX, y: minY, width: max(maxX, other.maxX) - minX, height: max(maxY, other.maxY) - minY)
    }

    func inset(by d: Double) -> LayoutRect {
        LayoutRect(x: x + d, y: y + d, width: max(0, width - 2 * d), height: max(0, height - 2 * d))
    }

    func grown(by dx: Double, _ dy: Double) -> LayoutRect {
        LayoutRect(x: x - dx, y: y - dy, width: width + 2 * dx, height: height + 2 * dy)
    }
}

/// Where each table sits and how each foreign key runs between them, in canvas units.
struct MapLayout: Equatable, Sendable {
    var graph: MapGraph
    /// The top-left corner of each card, by node.
    var positions: [LayoutPoint]
    /// The bend points of each edge the layout routed (an edge that touches a moved card has none).
    var routes: [Int: [LayoutPoint]]
    /// Edge indexes that run from a card to itself.
    var selfLoops: Set<Int>
    var bounds: LayoutRect
    /// Cards whose place was set by the user, not by the layout.
    var moved: Set<Int> = []

    init(graph: MapGraph, result: LayoutResult, pins: [RelationID: LayoutPoint] = [:]) {
        self.graph = graph
        positions = graph.graph.nodes.indices.map { result.positions[$0] ?? LayoutPoint(x: 0, y: 0) }
        routes = result.routes
        selfLoops = Set(result.selfLoops)
        bounds = result.bounds
        for (node, id) in graph.ids.enumerated() {
            if let pin = pins[id] { move(node, to: pin) }
        }
    }

    func size(of node: Int) -> (w: Double, h: Double) {
        (graph.graph.nodes[node].width, graph.graph.nodes[node].height)
    }

    func rect(of node: Int) -> LayoutRect {
        let size = size(of: node)
        return LayoutRect(x: positions[node].x, y: positions[node].y, width: size.w, height: size.h)
    }

    var rects: [Int: LayoutRect] {
        Dictionary(uniqueKeysWithValues: positions.indices.map { ($0, rect(of: $0)) })
    }

    /// Sets a card's place; the edges it touches lose their routed bends and run straight between their ports.
    mutating func move(_ node: Int, to point: LayoutPoint) {
        positions[node] = point
        moved.insert(node)
        for (index, edge) in graph.graph.edges.enumerated() where edge.from == node || edge.to == node {
            routes[index] = nil
        }
        bounds = bounds.union(rect(of: node))
    }

    func hasSelfLoop(_ node: Int) -> Bool {
        selfLoops.contains { graph.graph.edges[$0].from == node }
    }

    /// The points an edge runs through, from its port on the referencing card to its port on the
    /// referenced one, with the layout's bends in between. Not for self-loops.
    func path(of edge: Int) -> [LayoutPoint] {
        let e = graph.graph.edges[edge]
        let from = rect(of: e.from), to = rect(of: e.to)
        let fromY = from.y + (MapCardMetrics.portY(column: graph.edgeFromColumn[edge], in: graph.keyColumns[e.from])
            ?? MapCardMetrics.headerHeight / 2)
        let toY = to.y + (MapCardMetrics.portY(column: graph.edgeToColumn[edge], in: graph.keyColumns[e.to])
            ?? MapCardMetrics.headerHeight / 2)
        let start: LayoutPoint, end: LayoutPoint
        if to.x >= from.maxX {
            (start, end) = (LayoutPoint(x: from.maxX, y: fromY), LayoutPoint(x: to.x, y: toY))
        } else if to.maxX <= from.x {
            (start, end) = (LayoutPoint(x: from.x, y: fromY), LayoutPoint(x: to.maxX, y: toY))
        } else {
            (start, end) = (LayoutPoint(x: from.maxX, y: fromY), LayoutPoint(x: to.maxX, y: toY))
        }
        return [start] + (routes[edge] ?? []) + [end]
    }
}
