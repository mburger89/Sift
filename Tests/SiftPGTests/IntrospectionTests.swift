import Foundation
import SiftCore
import SiftTestSupport
import Testing

@testable import SiftPG

let gate = Comment(rawValue: "SIFT_PG_URL is not set")

/// Runs `body` against a live snapshot of the fixture schemas.
func withSnapshot(
    _ body: (SchemaSnapshot, FixtureNames) async throws -> Void
) async throws {
    try await PGFixture.withSchemas { names, params in
        let pg = try PGConnection(parameters: params)
        let snapshot = try await PGIntrospector(connection: pg).snapshot(schemas: [names.a, names.b])
        try await body(snapshot, names)
    }
}

@Suite struct IntrospectionTests {
    @Test(.enabled(if: PGFixture.url != nil, gate))
    func listsTheFixtureSchemasAndNoSystemSchemas() async throws {
        try await PGFixture.withSchemas { names, params in
            let pg = try PGConnection(parameters: params)
            let all = try await PGIntrospector(connection: pg).snapshot()
            #expect(all.schemas.contains(names.a))
            #expect(all.schemas.contains(names.b))
            #expect(!all.schemas.contains("pg_catalog"))
            #expect(!all.schemas.contains("information_schema"))
            #expect(!all.schemas.contains { $0.hasPrefix("pg_toast") })
        }
    }

    @Test(.enabled(if: PGFixture.url != nil, gate))
    func relationsHaveTheirKinds() async throws {
        try await withSnapshot { s, n in
            func kind(_ name: String) -> RelationKind? { s.relation(RelationID(n.a, name))?.kind }
            #expect(kind("customers") == .table)
            #expect(kind("events") == .partitionedTable)
            #expect(kind("recent_orders") == .view)
            #expect(kind("customer_totals") == .materializedView)
            #expect(s.relation(RelationID(n.a, "events_2025")) == nil)
            #expect(s.relations.count == 16)
        }
    }

    @Test(.enabled(if: PGFixture.url != nil, gate))
    func columnsUseFormatTypeAndSkipDroppedColumns() async throws {
        try await withSnapshot { s, n in
            func column(_ table: String, _ name: String) throws -> ColumnInfo {
                try #require(s.relation(RelationID(n.a, table))?.columns.first { $0.name == name })
            }
            let customers = try #require(s.relation(RelationID(n.a, "customers")))
            #expect(customers.columns.map(\.name) == ["id", "email", "created_at"])
            #expect(customers.columns.map(\.ordinal) == [1, 2, 3])
            #expect(try column("products", "name").typeName == "character varying(200)")
            #expect(try column("products", "price").typeName == "numeric(12,2)")
            #expect(try column("products", "tags").typeName == "text[]")
            let status = try column("orders", "status")
            #expect(status.isEnum)
            #expect(status.typeName.hasSuffix("order_status"))
            #expect(try column("orders", "id").identity == .always)
            let cents = try column("orders", "total_cents")
            #expect(cents.isGenerated)
            #expect(cents.defaultExpression == nil)
            #expect(try column("customers", "created_at").defaultExpression == "now()")
        }
    }

    @Test(.enabled(if: PGFixture.url != nil, gate))
    func keysKeepTheirDeclaredColumnOrder() async throws {
        try await withSnapshot { s, n in
            #expect(s.relation(RelationID(n.a, "order_items"))?.primaryKey?.columns == ["product_id", "order_id"])
            #expect(s.relation(RelationID(n.a, "events"))?.primaryKey?.columns == ["id", "at"])
        }
    }

    @Test(.enabled(if: PGFixture.url != nil, gate))
    func foreignKeysAreListedOnceInBothDirections() async throws {
        try await withSnapshot { s, n in
            // The plan said 9; its DDL (and FixtureSnapshot) has 8.
            #expect(s.foreignKeys.count == 10)
            let customers = RelationID(n.a, "customers")
            #expect(s.incoming(of: customers).map(\.from.name).sorted() == ["events", "orders"])
            let toCustomers = try #require(s.outgoing(of: RelationID(n.a, "orders")).first)
            #expect(toCustomers.toColumns == ["id"])
            #expect(toCustomers.onDelete == .cascade)
        }
    }

    @Test(.enabled(if: PGFixture.url != nil, gate))
    func compositeSelfAndCrossSchemaForeignKeys() async throws {
        try await withSnapshot { s, n in
            let shipment = try #require(s.outgoing(of: RelationID(n.a, "shipments")).first)
            #expect(shipment.fromColumns == ["product_id", "order_id"])
            #expect(shipment.to == RelationID(n.a, "order_items"))
            #expect(shipment.toColumns == ["product_id", "order_id"])
            let employees = RelationID(n.a, "employees")
            #expect(s.outgoing(of: employees).map(\.to) == [employees])
            #expect(s.outgoing(of: RelationID(n.a, "product_tags")).map(\.to).contains(RelationID(n.b, "tags")))
        }
    }

    @Test(.enabled(if: PGFixture.url != nil, gate))
    func indexesIncludePartialAndExpressionColumns() async throws {
        try await withSnapshot { s, n in
            func index(_ table: String, _ name: String) throws -> IndexInfo {
                try #require(s.relation(RelationID(n.a, table))?.indexes.first { $0.name == name })
            }
            let open = try index("orders", "orders_open_idx")
            let lower = try index("products", "products_lower_name_idx")
            let email = try index("customers", "customers_email_key")
            let pkey = try index("customers", "customers_pkey")
            #expect(open.predicate?.contains("done") == true)
            #expect(lower.columns[0].contains("lower("))
            #expect(email.isUnique)
            #expect(pkey.isPrimary)
        }
    }

    @Test(.enabled(if: PGFixture.url != nil, gate))
    func rowEstimatesComeFromReltuples() async throws {
        try await withSnapshot { s, n in
            #expect(s.relation(RelationID(n.a, "customers"))?.rowEstimate == .estimated(3))
            #expect(s.relation(RelationID(n.a, "never_analyzed"))?.rowEstimate == .unknown)
        }
    }
}

@Suite struct CatalogLiteralTests {
    @Test func arrayLiteralEscapesQuotesAndBackslashes() {
        #expect(PGCatalog.arrayLiteral(["a", "b c"]) == "{\"a\",\"b c\"}")
        #expect(PGCatalog.arrayLiteral(["we\"ird\\"]) == "{\"we\\\"ird\\\\\"}")
        #expect(PGCatalog.arrayLiteral([]) == "{}")
    }
}
