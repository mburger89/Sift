import Foundation
import SiftCore
import SiftTestSupport
import Testing

@testable import SiftPG

/// The pager's change markers against a real server. Skipped when `SIFT_PG_URL` is not set.
@Suite struct PGRelationPagerChangesTests {
    /// Opens the shop fixture, reads its schema, and builds a read-only pager over table `name` of schema `a`.
    /// `admin` is a writable test-only connection, the only way these tests write.
    static func withPager<T>(
        _ name: String,
        _ body: (PGRelationPager, RelationInfo, FixtureNames, PGConnection) async throws -> T
    ) async throws -> T {
        try await PGFixture.withSchemas { names, params in
            var writable = params
            writable.readOnly = false
            let admin = try PGConnection(parameters: writable)
            defer { admin.close() }
            let source = try await PGSource.connect(params)
            defer { source.close() }
            let snapshot = try await source.snapshot()
            let relation = try #require(snapshot.relation(RelationID(names.a, name)))
            let pager = PGRelationPager(connection: try PGConnection(parameters: params), relation: relation)
            defer { pager.close() }
            return try await body(pager, relation, names, admin)
        }
    }

    /// The trailing flag of each row, and its first value.
    static func flags(_ rows: [[SiftValue]]) -> [(id: Int64, changed: Bool)] {
        rows.compactMap { row in
            guard case .int(let id)? = row.first, case .bool(let changed)? = row.last else { return nil }
            return (id, changed)
        }
    }

    @Test(.enabled(if: PGFixture.url != nil, gate))
    func aRowInsertedAfterTheMarkerIsFlaggedAndOldRowsAreNot() async throws {
        try await Self.withPager("customers") { pager, relation, names, admin in
            let marker = try await pager.changeMarker()
            _ = try admin.query("INSERT INTO \(names.a).customers (email) VALUES ('new@x.test')")
            let rows = try await pager.page(
                0, size: 50, query: GridQuery(changes: ChangeFilter(since: marker, only: false)), after: nil)
            #expect(rows.allSatisfy { $0.count == relation.columns.count + 1 })
            let flagged = Self.flags(rows)
            #expect(flagged.count == 4)
            #expect(flagged.filter(\.changed).map(\.id) == [4])
            #expect(flagged.filter { !$0.changed }.map(\.id) == [1, 2, 3])
        }
    }

    @Test(.enabled(if: PGFixture.url != nil, gate))
    func anUpdatedRowIsFlagged() async throws {
        try await Self.withPager("customers") { pager, _, names, admin in
            let marker = try await pager.changeMarker()
            _ = try admin.query("UPDATE \(names.a).customers SET email = 'changed@x.test' WHERE id = 1")
            let rows = try await pager.page(
                0, size: 50, query: GridQuery(changes: ChangeFilter(since: marker, only: false)), after: nil)
            #expect(Self.flags(rows).filter(\.changed).map(\.id) == [1])
            #expect(Self.flags(rows).filter { !$0.changed }.map(\.id) == [2, 3])
        }
    }

    @Test(.enabled(if: PGFixture.url != nil, gate))
    func aRowHeldByForUpdateIsNotFlaggedAndTheReadDoesNotBlock() async throws {
        try await Self.withPager("customers") { pager, _, names, _ in
            var writable = try PGConnectionParameters(url: try #require(PGFixture.url))
            writable.readOnly = false
            let locker = try PGConnection(parameters: writable)
            defer { locker.close() }
            let marker = try await pager.changeMarker()
            _ = try locker.query("BEGIN")
            do {
                // A row lock writes xmax, not xmin: it is not a change, and a reader does not wait for it.
                _ = try locker.query("SELECT * FROM \(names.a).customers WHERE id = 2 FOR UPDATE")
                let rows = try await pager.page(
                    0, size: 50, query: GridQuery(changes: ChangeFilter(since: marker, only: false)), after: nil)
                #expect(Self.flags(rows).map(\.id) == [1, 2, 3])
                #expect(Self.flags(rows).filter(\.changed).isEmpty)
                _ = try locker.query("ROLLBACK")
            } catch {
                _ = try? locker.query("ROLLBACK")
                throw error
            }
        }
    }

    /// Review focus 1: a transaction open at the marker that commits afterwards is never missed.
    @Test(.enabled(if: PGFixture.url != nil, gate))
    func aTransactionOpenAtTheMarkerThatCommitsLaterIsFlagged() async throws {
        try await Self.withPager("orders") { pager, _, names, _ in
            var writable = try PGConnectionParameters(url: try #require(PGFixture.url))
            writable.readOnly = false
            let other = try PGConnection(parameters: writable)
            defer { other.close() }
            _ = try other.query("BEGIN")
            do {
                // The insert assigns the transaction its xid, which is below the next one to be handed out.
                _ = try other.query("INSERT INTO \(names.a).orders (customer_id, total) VALUES (1, 99)")
                let marker = try await pager.changeMarker()
                _ = try other.query("COMMIT")
                let rows = try await pager.page(
                    0, size: 50, query: GridQuery(changes: ChangeFilter(since: marker, only: false)), after: nil)
                let flagged = Self.flags(rows)
                #expect(flagged.count == 5)
                #expect(flagged.last?.id == 5)
                #expect(flagged.last?.changed == true)
            } catch {
                _ = try? other.query("ROLLBACK")
                throw error
            }
        }
    }

    @Test(.enabled(if: PGFixture.url != nil, gate))
    func onlyChangesReturnsExactlyTheFlaggedRowsAndCountsThem() async throws {
        try await Self.withPager("customers") { pager, _, names, admin in
            let marker = try await pager.changeMarker()
            _ = try admin.query("INSERT INTO \(names.a).customers (email) VALUES ('n1@x.test'), ('n2@x.test')")
            _ = try admin.query("UPDATE \(names.a).customers SET email = 'u@x.test' WHERE id = 3")
            let only = GridQuery(changes: ChangeFilter(since: marker, only: true))
            let rows = try await pager.page(0, size: 50, query: only, after: nil)
            #expect(Self.flags(rows).map(\.id) == [3, 4, 5])
            #expect(Self.flags(rows).allSatisfy { $0.changed })
            let counted = try await pager.count(for: only)
            let exact = try await pager.exactCount(for: only)
            // Without `only` the count is every row.
            let all = try await pager.count(for: GridQuery(changes: ChangeFilter(since: marker, only: false)))
            #expect(counted == .exact(3))
            #expect(exact == 3)
            #expect(all == .exact(5))
        }
    }

    @Test(.enabled(if: PGFixture.url != nil, gate))
    func aPartitionedTableSupportsChanges() async throws {
        try await Self.withPager("events") { pager, relation, names, admin in
            #expect(relation.kind == .partitionedTable)
            #expect(pager.supportsChanges)
            let marker = try await pager.changeMarker()
            _ = try admin.query("INSERT INTO \(names.a).events VALUES (1, 1, '2026-03-01'), (2, 1, '2025-03-01')")
            let rows = try await pager.page(0, size: 50, query: GridQuery(changes: ChangeFilter(since: marker, only: true)), after: nil)
            #expect(rows.count == 2)
            #expect(rows.allSatisfy { $0.last == .bool(true) && $0.count == relation.columns.count + 1 })
            let counted = try await pager.count(for: GridQuery(changes: ChangeFilter(since: marker, only: true)))
            #expect(counted == .exact(2))
        }
    }

    @Test(.enabled(if: PGFixture.url != nil, gate))
    func aViewDoesNotSupportChanges() async throws {
        try await Self.withPager("recent_orders") { pager, relation, _, _ in
            #expect(!pager.supportsChanges)
            // The query's `changes` is ignored: rows have no trailing flag.
            let rows = try await pager.page(0, size: 50, query: GridQuery(changes: ChangeFilter(since: "1", only: true)), after: nil)
            #expect(rows.count == 4)
            #expect(rows.allSatisfy { $0.count == relation.columns.count })
        }
        try await Self.withPager("customer_totals") { pager, _, _, _ in
            #expect(pager.supportsChanges)
        }
    }

    @Test(.enabled(if: PGFixture.url != nil, gate))
    func keyColumnsAreTheOrderKeyOrEmpty() async throws {
        try await Self.withPager("order_items") { pager, relation, _, _ in
            let expected = ["product_id", "order_id"].compactMap { name in relation.columns.firstIndex { $0.name == name } }
            #expect(pager.keyColumns == expected)
        }
        try await Self.withPager("customers") { pager, _, _, _ in #expect(pager.keyColumns == [0]) }
        try await Self.withPager("never_analyzed") { pager, _, _, _ in #expect(pager.keyColumns.isEmpty) }
        try await Self.withPager("events") { pager, _, _, _ in #expect(pager.keyColumns == [0, 2]) }
        try await Self.withPager("recent_orders") { pager, _, _, _ in #expect(pager.keyColumns.isEmpty) }
    }

    @Test(.enabled(if: PGFixture.url != nil, gate))
    func newestFirstPutsNullTimestampsLast() async throws {
        try await Self.withPager("notes") { pager, relation, _, _ in
            let created = try #require(relation.columns.firstIndex { $0.name == "created_at" })
            #expect(relation.columns[created].isNullable)
            let sort = RecencyColumns.newestSort(column: created, in: relation)
            #expect(sort.nullsLast)
            let rows = try await pager.page(0, size: 50, query: GridQuery(sort: sort), after: nil)
            #expect(rows.count == 6)
            let isNull = rows.map { $0[created] == .null }
            #expect(isNull == [false, false, false, true, true, true])
            let ids = Self.ids(rows)
            // Newest first among the dated rows, then the undated ones in descending key order.
            #expect(ids == [3, 1, 2, 6, 5, 4])
        }
    }

    static func ids(_ rows: [[SiftValue]]) -> [Int64] {
        rows.compactMap { if case .int(let n)? = $0.first { return n } else { return nil } }
    }

    @Test(.enabled(if: PGFixture.url != nil, gate))
    func theMarkerLeavesTheConnectionIdleAndUsable() async throws {
        try await Self.withPager("customers") { pager, _, _, admin in
            let first = try await pager.changeMarker()
            let second = try await pager.changeMarker()
            #expect(UInt32(first) != nil)
            #expect(UInt32(second) != nil)
            // The next transaction id never goes backwards between two looks (no wrap in a fresh server).
            let a = try #require(UInt32(first))
            let b = try #require(UInt32(second))
            #expect(b >= a)
            let pid = try #require(pager.backendPID)
            let activity = try admin.query("SELECT state FROM pg_stat_activity WHERE pid = \(pid)")
            #expect(activity.rows.first?.first == .text("idle"))
            // The pager is still usable.
            let rows = try await pager.page(0, size: 5, query: GridQuery(), after: nil)
            #expect(rows.count == 3)
        }
    }
}
