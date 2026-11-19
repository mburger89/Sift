import MetalUI

/// The caption of the selected foreign key: `orders.customer_id → customers.id`.
struct MapEdgeInfoStrip: Component {
    let map: MapModel

    var content: some ElementGroup {
        if let layout = map.layout, let id = map.selectedEdge, let edge = layout.graph.edgeFK.firstIndex(of: id) {
            let caption = layout.graph.edgeLabel[edge]
            HStack(spacing: 0) {
                Text(verbatim: caption).font(size: 12)
            }
                .padding(inset(10, 5))
                .background(.mapCardFill)
                .roundedBorder(.mapCardBorder, radius: Pixels(6), width: Pixels(1))
                .padding(Edges(all: Pixels(10)))
                .accessibilityLabel(caption)
                .accessibilityIdentifier("map.edgeInfo")
        }
    }
}
