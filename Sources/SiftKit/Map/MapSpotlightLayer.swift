import MetalUI
import SiftCore

/// The hover spotlight (decision D20): one scrim over the cards and edges, with copies of the hovered table, its
/// neighbours and their edges above it. A hover builds O(degree) cards, not one dimmed flag per card.
///
/// It also draws the selected edge above the tiles.
struct MapSpotlightLayer: Component {
    let map: MapModel

    var content: some ElementGroup {
        let layout = map.layout
        let snapshot = map.snapshot
        ZStack(alignment: .topLeading) {
            if let layout, let snapshot, let hovered = map.hovered, let node = layout.graph.node(of: hovered), let window = map.cull?.rect {
                let neighbours = Self.neighbours(of: node, in: layout)
                Color.mapScrim
                    .frame(width: Pixels(Float(window.width)), height: Pixels(Float(window.height)))
                    .offset(x: Pixels(Float(window.x)), y: Pixels(Float(window.y)))
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("map.scrim")
                SpotEdgesView(pieces: Self.pieces(of: neighbours.edges, in: layout, tileSize: map.edgeTiles.tileSize), width: 2.5 * map.edgeTiles.tileSize / EdgeTiles.base)
                    .equatable()
                ForEach(neighbours.nodes, id: \.self) { n in
                    let id = layout.graph.ids[n]
                    if let relation = snapshot.relation(id) {
                        TableCardView(
                            relation: relation, keyColumns: layout.graph.keyColumns[n], origin: layout.positions[n],
                            lod: map.lod, isJoin: layout.graph.joinTables.contains(id), hasSelfLoop: layout.hasSelfLoop(n),
                            isSelected: id == map.selected, label: MapCardLabel.make(relation, in: snapshot),
                            idPrefix: "map.spot"
                        )
                        .equatable()
                    }
                }
            }
            if let layout, let edgeID = map.selectedEdge, let edge = layout.graph.edgeFK.firstIndex(of: edgeID),
               !layout.selfLoops.contains(edge) {
                SpotEdgesView(pieces: Self.pieces(of: [edge], in: layout, tileSize: map.edgeTiles.tileSize), width: 3.5 * map.edgeTiles.tileSize / EdgeTiles.base)
                    .equatable()
            }
        }
    }

    /// The hovered node and the nodes it shares an edge with, and those edges, in sorted order.
    static func neighbours(of node: Int, in layout: MapLayout) -> (nodes: [Int], edges: [Int]) {
        var nodes: Set<Int> = [node]
        var edges: [Int] = []
        for (index, edge) in layout.graph.graph.edges.enumerated() where edge.from == node || edge.to == node {
            nodes.insert(edge.from)
            nodes.insert(edge.to)
            edges.append(index)
        }
        return (nodes.sorted(), edges)
    }

    static func pieces(of edges: [Int], in layout: MapLayout, tileSize: Double) -> [EdgePiece] {
        edges.filter { !layout.selfLoops.contains($0) }.flatMap {
            EdgeRouting.pieces(through: layout.path(of: $0), edge: $0, tileSize: tileSize)
        }
    }
}

/// Some edges drawn in the accent colour above the scrim, as one `Path` in canvas units.
struct SpotEdgesView: Component, @MainActor Equatable {
    let pieces: [EdgePiece]
    let width: Double

    var content: some ElementGroup {
        if let first = pieces.first {
            let box = pieces.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }.grown(by: 4, 4)
            let path = Path { p in
                var last: LayoutPoint?
                func point(_ q: LayoutPoint) -> Point<Pixels> { Point(x: Pixels(Float(q.x - box.x)), y: Pixels(Float(q.y - box.y))) }
                for piece in pieces {
                    if last != piece.p0 { p.move(to: point(piece.p0)) }
                    p.addCurve(to: point(piece.p1), control1: point(piece.c1), control2: point(piece.c2))
                    last = piece.p1
                }
            }
            path.stroke(.mapAccent, lineWidth: Pixels(Float(width)))
                .frame(width: Pixels(Float(box.width)), height: Pixels(Float(box.height)), alignment: .topLeading)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .offset(x: Pixels(Float(box.x)), y: Pixels(Float(box.y)))
        }
    }

    nonisolated static func == (l: Self, r: Self) -> Bool { l.pieces == r.pieces && l.width == r.width }
}
