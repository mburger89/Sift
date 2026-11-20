import SiftCore
import SiftLayout
import SiftTestSupport
import Testing

@testable import SiftKit

struct MapGraphTests {
    let shop = FixtureSnapshot.shop()

    @Test func nodeIDsFollowSortedRelationIDs() {
        let map = MapGraphBuilder.build(shop, filter: MapFilter())
        #expect(map.ids == shop.relations.map(\.id))
        #expect(map.ids == map.ids.sorted())
        #expect(map.graph.nodes.map(\.id) == Array(0..<13))
        #expect(map.graph.edges.count == 8)
        #expect(map.edgeFK.count == 8)
        // Edge j is the foreign key edgeFK[j]: its ends are the nodes of that key's relations.
        for (edge, key) in zip(map.graph.edges, map.edgeFK) {
            let fk = shop.foreignKeys.first { $0.id == key }!
            #expect(map.ids[edge.from] == fk.from)
            #expect(map.ids[edge.to] == fk.to)
        }
    }

    @Test func joinTablesAreDetected() {
        let map = MapGraphBuilder.build(shop, filter: MapFilter())
        #expect(map.joinTables == [RelationID("shop", "product_tags")])
        // order_items has two keys but also a `qty` column.
        #expect(!map.joinTables.contains(RelationID("shop", "order_items")))
    }

    @Test func edgesToFilteredSchemasAreDropped() {
        let all = MapGraphBuilder.build(shop, filter: MapFilter())
        let filtered = MapGraphBuilder.build(shop, filter: MapFilter(schemas: ["shop"]))
        #expect(all.edgeFK.count == 8)
        #expect(filtered.ids.allSatisfy { $0.schema == "shop" })
        #expect(filtered.edgeFK.count == 7)
        let tags = RelationID("tagging", "tags")
        #expect(filtered.graph.edges.allSatisfy { filtered.ids[$0.to] != tags })
        #expect(!filtered.edgeFK.contains { $0.hasSuffix("product_tags_tag_id_fkey") })
    }

    @Test func viewsHiddenWhenAsked() {
        let map = MapGraphBuilder.build(shop, filter: MapFilter(showViews: false))
        #expect(!map.ids.contains(RelationID("shop", "recent_orders")))
        #expect(!map.ids.contains(RelationID("shop", "customer_totals")))
        #expect(map.ids.count == 11)
    }

    @Test func keyColumnsAreKeysInColumnOrder() {
        let orderItems = shop.relation(RelationID("shop", "order_items"))!
        // The primary key is (product_id, order_id); the table's column order is order_id, product_id, qty.
        #expect(MapCardMetrics.keyColumns(of: orderItems, in: shop) == ["order_id", "product_id"])
        let keys = MapCardMetrics.keyColumns(of: orderItems, in: shop)
        #expect(MapCardMetrics.portY(column: "product_id", in: keys) == 36 + 1.5 * 20)
        #expect(MapCardMetrics.portY(column: "qty", in: keys) == nil)
        #expect(MapCardMetrics.size(keyColumns: keys).h == 36 + 2 * 20 + 8)
    }

    @Test func keyColumnsAreCappedAtEight() {
        let columns = (1...12).map { ColumnInfo(name: "c\($0)", ordinal: $0, typeName: "int") }
        let wide = RelationInfo(
            id: RelationID("s", "wide"), kind: .table, columns: columns,
            primaryKey: KeyConstraint(name: "wide_pkey", columns: columns.map(\.name)))
        let snapshot = SchemaSnapshot(serverVersion: 170000, schemas: ["s"], relations: [wide], foreignKeys: [])
        #expect(MapCardMetrics.keyColumns(of: wide, in: snapshot).count == 8)
    }

    @Test func searchRanksPrefixFirst() {
        let ids = MapGraphBuilder.build(shop, filter: MapFilter()).ids
        let found = MapSearch.matches("or", in: ids)
        #expect(Array(found.prefix(2)) == [RelationID("shop", "orders"), RelationID("shop", "order_items")])
        let recent = found.firstIndex(of: RelationID("shop", "recent_orders"))!
        #expect(recent >= 2)
        #expect(MapSearch.matches("SHIP", in: ids) == [RelationID("shop", "shipments")])
        #expect(MapSearch.matches("", in: ids).isEmpty)
        #expect(MapSearch.matches("o", in: ids, limit: 3).count == 3)
    }

    @Test func lodHysteresis() {
        #expect(MapLOD.forZoom(0.54, previous: .full) == .full)
        #expect(MapLOD.forZoom(0.51, previous: .full) == .compact)
        // Coming back up needs more than the boundary.
        #expect(MapLOD.forZoom(0.56, previous: .compact) == .compact)
        #expect(MapLOD.forZoom(0.59, previous: .compact) == .full)
        #expect(MapLOD.forZoom(0.24, previous: .compact) == .compact)
        #expect(MapLOD.forZoom(0.21, previous: .compact) == .nameOnly)
        #expect(MapLOD.forZoom(0.27, previous: .nameOnly) == .nameOnly)
        #expect(MapLOD.forZoom(0.29, previous: .nameOnly) == .compact)
        #expect(MapLOD.forZoom(1.0, previous: .nameOnly) == .full)
    }
}
