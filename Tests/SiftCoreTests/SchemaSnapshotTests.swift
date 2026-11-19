import SiftCore
import Testing

@Suite struct SchemaSnapshotTests {
    private func relation(_ schema: String, _ name: String) -> RelationInfo {
        RelationInfo(id: RelationID(schema, name), kind: .table)
    }

    private func fk(_ name: String, _ from: String, _ to: String) -> ForeignKeyInfo {
        ForeignKeyInfo(
            name: name, from: RelationID("a", from), fromColumns: ["x"], to: RelationID("a", to), toColumns: ["id"])
    }

    @Test func relationsAreSortedBySchemaThenName() {
        let s = SchemaSnapshot(
            serverVersion: 170000, schemas: ["b", "a"],
            relations: [relation("b", "z"), relation("a", "y"), relation("a", "x")], foreignKeys: [])
        #expect(s.relations.map(\.id) == [RelationID("a", "x"), RelationID("a", "y"), RelationID("b", "z")])
        #expect(s.schemas == ["a", "b"])
    }

    @Test func outgoingAndIncomingAreIndexed() {
        let orders = RelationID("a", "orders")
        let s = SchemaSnapshot(
            serverVersion: 170000, schemas: ["a"],
            relations: [relation("a", "orders"), relation("a", "customers"), relation("a", "order_items")],
            foreignKeys: [fk("oi_o", "order_items", "orders"), fk("o_c", "orders", "customers")])
        #expect(s.outgoing(of: orders).map(\.to) == [RelationID("a", "customers")])
        #expect(s.incoming(of: orders).map(\.from) == [RelationID("a", "order_items")])
        #expect(s.incoming(of: RelationID("a", "order_items")).isEmpty)
    }

    @Test func relationLookupByID() {
        let s = SchemaSnapshot(
            serverVersion: 170000, schemas: ["a"], relations: [relation("a", "x")], foreignKeys: [])
        #expect(s.relation(RelationID("a", "x"))?.id == RelationID("a", "x"))
        #expect(s.relation(RelationID("a", "missing")) == nil)
    }
}
