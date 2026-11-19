import MetalUI
import SiftCore

/// The one container that applies the pan and the zoom (decision D18): everything inside is in canvas units, and
/// `.scaleEffect(zoom, anchor: .topLeading).offset(pan)` is the only thing a pan or a zoom step changes. It is
/// the only component that reads `geometry`.
struct MapContentLayer: Component {
    let map: MapModel

    var content: some ElementGroup {
        let g = map.geometry
        ZStack(alignment: .topLeading) {
            MapWorld(map: map).equatable()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .scaleEffect(g.zoom, anchor: .topLeading)
            .offset(x: g.pan.x, y: g.pan.y)
    }
}

/// The edge tiles under the cards. Equal while it is the same map: the layers inside read what they need.
struct MapWorld: Component, @MainActor Equatable {
    let map: MapModel

    nonisolated static func == (l: Self, r: Self) -> Bool { l.map === r.map }

    var content: some ElementGroup {
        ZStack(alignment: .topLeading) {
            MapEdgeLayer(map: map)
            MapCardLayer(map: map)
            MapSpotlightLayer(map: map)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The edge tiles inside the cull window.
struct MapEdgeLayer: Component {
    let map: MapModel

    var content: some ElementGroup {
        let tiles = map.edgeTiles
        // The tile size is base / bucket, so the stroke needs no read of the geometry (a pan must not rebuild this layer).
        let stroke = 1.5 * tiles.tileSize / EdgeTiles.base
        ZStack(alignment: .topLeading) {
            ForEach(map.culled.tiles, id: \.self) { tile in
                EdgeTileView(tile: tile, tileSize: tiles.tileSize, pieces: tiles.pieces(of: tile), strokeWidth: stroke)
                    .equatable()
            }
        }
    }
}

/// The cards inside the cull window.
struct MapCardLayer: Component {
    let map: MapModel

    var content: some ElementGroup {
        let layout = map.layout
        let snapshot = map.snapshot
        let lod = map.lod
        let selected = map.selected
        ZStack(alignment: .topLeading) {
            if let layout, let snapshot {
                ForEach(map.culled.nodes, id: \.self) { node in
                    let id = layout.graph.ids[node]
                    if let relation = snapshot.relation(id) {
                        TableCardView(
                            relation: relation, keyColumns: layout.graph.keyColumns[node],
                            origin: layout.positions[node], lod: lod, isJoin: layout.graph.joinTables.contains(id),
                            hasSelfLoop: layout.hasSelfLoop(node), isSelected: id == selected,
                            label: MapCardLabel.make(relation, in: snapshot)
                        )
                        .equatable()
                    }
                }
            }
        }
    }
}
