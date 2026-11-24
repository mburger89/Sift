import Foundation
import SiftCore
import SiftPG
import SiftTestSupport
import Testing

@testable import SiftKit

/// Followed values against a real server. Skipped when `SIFT_PG_URL` is not set.
///
/// It lives in SiftKitTests because `GridLinks` is SiftKit's and SiftPGTests does not depend on SiftKit: the smaller
/// change was one more dependency on this target, not a second copy of the link code.
@Suite struct FollowIntegrationTests {
    static let gate = Comment(rawValue: "SIFT_PG_URL is not set")

    /// One followed key: the table that holds it, its constraint name, and what the test inserted for it (nothing for
    /// the keys the fixture already has rows for).
    struct Case {
        var label: String
        var table: String
        var constraint: String
        /// A value long and odd enough that finding it in SQL text would mean it was spliced in.
        var distinctive: Bool = true
    }

    static func extraDDL(_ a: String) -> [String] {
        [
            // A bigint key no row of the fixture has.
            "INSERT INTO \(a).customers (id, email) VALUES (7000123, 'follow@x.test')",
            "INSERT INTO \(a).orders (id, customer_id, total) OVERRIDING SYSTEM VALUE VALUES (9000321, 7000123, 5)",
            // Text with a quote, LIKE wildcards and a backslash.
            "CREATE TABLE \(a).follow_text (k text PRIMARY KEY)",
            "CREATE TABLE \(a).follow_text_ref (id serial PRIMARY KEY, k text REFERENCES \(a).follow_text)",
            "INSERT INTO \(a).follow_text VALUES ('O''Brien 100% _x\\'), ('O''Brien 100% yx\\')",
            "INSERT INTO \(a).follow_text_ref (k) VALUES ('O''Brien 100% _x\\')",
            // A timestamptz with microseconds, shown in a zone that is not UTC.
            "CREATE TABLE \(a).follow_ts (at timestamptz PRIMARY KEY)",
            "CREATE TABLE \(a).follow_ts_ref (id serial PRIMARY KEY, at timestamptz REFERENCES \(a).follow_ts)",
            "INSERT INTO \(a).follow_ts VALUES ('2026-03-01 09:00:00.123456+05'), ('2026-03-01 09:00:00.123457+05')",
            "INSERT INTO \(a).follow_ts_ref (at) VALUES ('2026-03-01 09:00:00.123456+05')",
        ]
    }

    @Test(.enabled(if: PGFixture.url != nil, gate))
    func followedValuesMatchTheirRow() async throws {
        try await PGFixture.withSchemas { names, params in
            var writable = params
            writable.readOnly = false
            let admin = try PGConnection(parameters: writable)
            defer { admin.close() }
            for statement in Self.extraDDL(names.a) { _ = try admin.query(statement) }

            let source = try await PGSource.connect(params)
            defer { source.close() }
            let snapshot = try await source.snapshot()
            let a = names.a

            let cases = [
                Case(label: "bigint", table: "orders", constraint: "orders_customer_id_fkey"),
                Case(label: "uuid", table: "order_items", constraint: "order_items_product_id_fkey"),
                Case(label: "composite", table: "shipments", constraint: "shipments_product_id_order_id_fkey"),
                Case(label: "text", table: "follow_text_ref", constraint: "follow_text_ref_k_fkey"),
                Case(label: "timestamptz", table: "follow_ts_ref", constraint: "follow_ts_ref_at_fkey"),
                Case(label: "numeric", table: "code_uses", constraint: "code_uses_amount_fkey"),
                Case(label: "bytea", table: "code_uses", constraint: "code_uses_code_fkey"),
            ]
            for c in cases {
                let relation = try #require(snapshot.relation(RelationID(a, c.table)), "\(c.label)")
                let links = GridLinks(snapshot: snapshot, relation: relation.id)
                let pager = PGRelationPager(connection: try PGConnection(parameters: params), relation: relation)
                defer { pager.close() }
                let rows = try await pager.page(0, size: 50, query: GridQuery(), after: nil)
                // The row the key belongs to: the first whose keys are all set.
                var checked = 0
                for (index, row) in rows.enumerated() {
                    let all = links.links(row: index) { row.indices.contains($0) ? row[$0] : nil }
                    guard let link = all.first(where: { $0.outgoing && $0.foreignKey.name == c.constraint }),
                        let follow = link.follow
                    else { continue }
                    checked += 1
                    try await Self.expectRow(c, follow: follow, from: row, link: link, relation: relation, snapshot: snapshot, params: params)
                    // And back: the referenced row's incoming link finds the row it came from.
                    let target = try #require(snapshot.relation(follow.target))
                    let targetPager = PGRelationPager(connection: try PGConnection(parameters: params), relation: target)
                    defer { targetPager.close() }
                    let targetRows = try await targetPager.page(0, size: 50, query: GridQuery(filters: follow.filters), after: nil)
                    let targetRow = try #require(targetRows.first, "\(c.label)")
                    let back = GridLinks(snapshot: snapshot, relation: target.id)
                        .links(row: 0) { targetRow.indices.contains($0) ? targetRow[$0] : nil }
                        .first { !$0.outgoing && $0.foreignKey.name == c.constraint }
                    let backFollow = try #require(back?.follow, "\(c.label): incoming link")
                    let referencing = try await pager.page(0, size: 50, query: GridQuery(filters: backFollow.filters), after: nil)
                    #expect(
                        referencing.contains { Self.texts($0) == Self.texts(row) }, "\(c.label): the incoming link finds the row")
                }
                #expect(checked > 0, "\(c.label): a row with the key set was found")
            }
        }
    }

    static func texts(_ row: [SiftValue]) -> [String] { row.map(CellFormat.rawText) }

    /// Following `follow` from `row` pages exactly the referenced row, with the value as a parameter.
    static func expectRow(
        _ c: Case, follow: GridFollow, from row: [SiftValue], link: ReferenceLink, relation: RelationInfo,
        snapshot: SchemaSnapshot, params: PGConnectionParameters
    ) async throws {
        let target = try #require(snapshot.relation(follow.target), "\(c.label)")
        let query = GridQuery(filters: follow.filters)
        let pager = PGRelationPager(connection: try PGConnection(parameters: params), relation: target)
        defer { pager.close() }
        let found = try await pager.page(0, size: 50, query: query, after: nil)
        #expect(found.count == 1, "\(c.label): exactly the referenced row, got \(found.count)")
        // The row's key columns hold what the source row held.
        for (filter, name) in zip(follow.filters, link.foreignKey.fromColumns) {
            let sourceIndex = try #require(relation.columns.firstIndex { $0.name == name })
            guard let hit = found.first else { continue }
            #expect(
                CellFormat.rawText(hit[filter.column]) == CellFormat.rawText(row[sourceIndex]),
                "\(c.label): \(name) round-trips")
        }
        // The values are parameters, never SQL text.
        let order = PGRelationQuery.orderKey(for: target)
        let built = PGRelationQuery(relation: target, orderKey: order.columns, keyKind: order.kind)
            .pageSQL(index: 0, size: 50, query: query, after: nil)
        for filter in follow.filters {
            let value = try #require(filter.value)
            #expect(built.params.contains(value), "\(c.label): \(value) is a parameter")
            if value.count >= 5 {
                #expect(!built.sql.contains(value), "\(c.label): \(value) is not in the SQL text")
            }
        }
        #expect(built.sql.contains("$1"), "\(c.label)")
    }
}
