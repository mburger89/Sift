import SiftCore
import SiftTestSupport
import Testing

@testable import SiftKit

/// Which links a row has, over the fixture shop: pure, no UI.
struct ReferenceLinksTests {
    let snapshot = FixtureSnapshot.shop(withPagerTables: true)
    func id(_ name: String) -> RelationID { RelationID("shop", name) }
    func links(_ relation: String) -> GridLinks { GridLinks(snapshot: snapshot, relation: id(relation)) }
    func column(_ relation: String, _ name: String) -> Int {
        snapshot.relation(id(relation))!.columns.firstIndex { $0.name == name }!
    }

    @Test func outgoingLinkFiltersTheTargetsKey() throws {
        // orders (id, customer_id, ...): row 7 belongs to customer 42.
        let row: [SiftValue] = [.int(7), .int(42), .text("new"), .raw("1.00"), .int(100)]
        let all = links("orders").links(row: 0) { row[$0] }
        let link = try #require(all.first { $0.outgoing })
        #expect(link.title == "customer_id → customers (id = 42)")
        let follow = try #require(link.follow)
        #expect(follow.target == id("customers"))
        #expect(follow.filters == [GridFilter(column: column("customers", "id"), op: .eq, value: "42")])
        #expect(follow.targetColumn == column("customers", "id"))
    }

    @Test func incomingLinkFiltersTheReferencingColumns() throws {
        let row: [SiftValue] = [.int(42), .text("a@x.test"), .text("2026-01-01")]
        let all = links("customers").links(row: 0) { row[$0] }
        let incoming = all.filter { !$0.outgoing }
        let orders = try #require(incoming.first { $0.foreignKey.from == id("orders") })
        #expect(orders.title == "orders.customer_id (= 42)")
        let follow = try #require(orders.follow)
        #expect(follow.target == id("orders"))
        #expect(follow.filters == [GridFilter(column: column("orders", "customer_id"), op: .eq, value: "42")])
        #expect(follow.targetColumn == column("orders", "customer_id"))
        #expect(incoming.count == 2, "orders and events")
        // Outgoing links come first.
        #expect(all.prefix { $0.outgoing }.count == 0)
    }

    @Test func aCompositeKeyPairsByPosition() throws {
        // shipments (id, order_id, product_id) -> order_items (product_id, order_id)
        let row: [SiftValue] = [.int(1), .int(5), .text("p-1")]
        let all = links("shipments").links(row: 0) { row[$0] }
        let link = try #require(all.first { $0.outgoing })
        #expect(link.title == "product_id, order_id → order_items (product_id = p-1, order_id = 5)")
        let follow = try #require(link.follow)
        #expect(
            follow.filters == [
                GridFilter(column: column("order_items", "product_id"), op: .eq, value: "p-1"),
                GridFilter(column: column("order_items", "order_id"), op: .eq, value: "5")
            ])
    }

    @Test func aNullValueDisablesTheLinkAndSaysSo() throws {
        let row: [SiftValue] = [.int(2), .null]
        let link = try #require(links("employees").links(row: 0) { row[$0] }.first { $0.outgoing })
        #expect(link.follow == nil)
        #expect(link.title == "manager_id is NULL")
        // An incoming link whose referenced column is NULL is disabled too.
        let codes: [SiftValue] = [.null, .raw("1.00")]
        let incoming = links("codes").links(row: 0) { codes[$0] }.filter { !$0.outgoing }
        #expect(incoming.count == 2)
        #expect(incoming.first { $0.foreignKey.fromColumns == ["code"] }?.follow == nil)
        #expect(incoming.first { $0.foreignKey.fromColumns == ["amount"] }?.follow != nil)
    }

    @Test func anUnloadedValueDisablesTheLink() throws {
        let link = try #require(links("orders").links(row: 0) { _ in nil }.first { $0.outgoing })
        #expect(link.follow == nil)
        #expect(link.title.hasPrefix("customer_id → customers.id"))
    }

    @Test func aSelfReferenceTargetsTheSameRelation() throws {
        let row: [SiftValue] = [.int(2), .int(1)]
        let all = links("employees").links(row: 0) { row[$0] }
        let out = try #require(all.first { $0.outgoing })
        #expect(out.follow?.target == id("employees"))
        #expect(out.follow?.filters == [GridFilter(column: 0, op: .eq, value: "1")])
        let back = try #require(all.first { !$0.outgoing })
        #expect(back.follow?.target == id("employees"))
        #expect(back.follow?.filters == [GridFilter(column: 1, op: .eq, value: "2")])
    }

    @Test func primaryFollowNeedsExactlyOneOutgoingFKOnTheColumn() throws {
        let row: [SiftValue] = [.int(7), .int(42), .text("new"), .raw("1.00"), .int(100)]
        let orders = links("orders")
        #expect(orders.primaryFollow(row: 0, column: 1) { row[$0] }?.target == id("customers"))
        #expect(orders.primaryFollow(row: 0, column: 0) { row[$0] } == nil, "id has no outgoing key")
        #expect(orders.primaryFollow(row: 0, column: 99) { row[$0] } == nil)
        // code_uses.code and amount each carry one key; a NULL there follows nowhere.
        let uses = links("code_uses")
        let useRow: [SiftValue] = [.int(1), .null, .raw("10.50")]
        #expect(uses.primaryFollow(row: 0, column: 1) { useRow[$0] } == nil)
        #expect(uses.primaryFollow(row: 0, column: 2) { useRow[$0] }?.target == id("codes"))
        // A column in two outgoing keys is ambiguous.
        let two = SchemaSnapshot(
            serverVersion: 170000, schemas: ["shop"],
            relations: [
                RelationInfo(id: id("a"), kind: .table, columns: [ColumnInfo(name: "x", ordinal: 1, typeName: "integer")]),
                RelationInfo(id: id("b"), kind: .table, columns: [ColumnInfo(name: "x", ordinal: 1, typeName: "integer")]),
                RelationInfo(id: id("c"), kind: .table, columns: [ColumnInfo(name: "x", ordinal: 1, typeName: "integer")])
            ],
            foreignKeys: [
                ForeignKeyInfo(name: "ab", from: id("a"), fromColumns: ["x"], to: id("b"), toColumns: ["x"]),
                ForeignKeyInfo(name: "ac", from: id("a"), fromColumns: ["x"], to: id("c"), toColumns: ["x"])
            ])
        #expect(GridLinks(snapshot: two, relation: id("a")).primaryFollow(row: 0, column: 0) { _ in .int(1) } == nil)
    }

    @Test func outgoingColumnsAreTheForeignKeyColumns() {
        #expect(links("orders").outgoingColumns == [column("orders", "customer_id")])
        #expect(links("shipments").outgoingColumns == [column("shipments", "order_id"), column("shipments", "product_id")])
        #expect(links("customers").outgoingColumns.isEmpty)
    }

    @Test func aCompositeKeyNamesOnlyItsNullColumns() throws {
        // shipments (id, order_id, product_id): only product_id is NULL.
        let row: [SiftValue] = [.int(1), .int(5), .null]
        let link = try #require(links("shipments").links(row: 0) { row[$0] }.first { $0.outgoing })
        #expect(link.follow == nil)
        #expect(link.title == "product_id is NULL")
        let both: [SiftValue] = [.int(1), .null, .null]
        let two = try #require(links("shipments").links(row: 0) { both[$0] }.first { $0.outgoing })
        #expect(two.title == "product_id, order_id is NULL")
    }

    @Test func outgoingLinksComeFirstOnARelationWithBothDirections() throws {
        let row: [SiftValue] = [.int(7), .int(42), .text("new"), .raw("1.00"), .int(100)]
        for (name, values) in [("orders", row), ("employees", [.int(2), .int(1)] as [SiftValue])] {
            let all = links(name).links(row: 0) { values[$0] }
            let outCount = all.filter(\.outgoing).count
            #expect(outCount > 0 && outCount < all.count, Comment(rawValue: name))
            #expect(all.prefix(outCount).allSatisfy(\.outgoing) && all.dropFirst(outCount).allSatisfy { !$0.outgoing }, Comment(rawValue: name))
        }
    }
}
