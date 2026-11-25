import Foundation
import SiftCore
import SiftTestSupport
import Testing

@testable import SiftPG

/// The pager against a real server. Skipped when `SIFT_PG_URL` is not set, as the other integration tests are.
@Suite struct PGRelationPagerTests {
    /// Opens a source, reads the schema, and builds a pager over `table` of the grid fixture.
    static func withPager<T>(
        _ table: String, kind: RelationKind? = nil,
        _ body: (PGRelationPager, RelationInfo, String, PGConnectionParameters) async throws -> T
    ) async throws -> T {
        try await PGFixture.withGridSchema { schema, params in
            let source = try await PGSource.connect(params)
            defer { source.close() }
            let snapshot = try await source.snapshot()
            var relation = try #require(snapshot.relation(RelationID(schema, table)))
            if let kind { relation.kind = kind }
            let pager = PGRelationPager(connection: try PGConnection(parameters: params), relation: relation)
            defer { pager.close() }
            return try await body(pager, relation, schema, params)
        }
    }

    static func ids(_ rows: [[SiftValue]]) -> [Int64] {
        rows.compactMap { if case .int(let n)? = $0.first { return n } else { return nil } }
    }

    @Test(.enabled(if: PGFixture.url != nil, gate))
    func pagingThroughAllRowsReturnsEachRowOnceInKeyOrder() async throws {
        try await Self.withPager("big") { pager, _, _, _ in
            var seen: [Int64] = []
            var previous: [SiftValue]?
            // Pages 0...19 walk by keyset (each follows the last), then 20 and 21 are empty and short.
            for index in 0..<40 {
                let rows = try await pager.page(index, size: 500, query: GridQuery(), after: index.isMultiple(of: 3) ? nil : previous)
                seen += Self.ids(rows)
                previous = rows.last
            }
            #expect(seen == Array(1...20000))
        }
    }

    @Test(.enabled(if: PGFixture.url != nil, gate))
    func keysetAndOffsetAgreeOnTheSamePage() async throws {
        try await Self.withPager("big") { pager, _, _, _ in
            let first = try await pager.page(6, size: 500, query: GridQuery(), after: nil)
            let viaOffset = try await pager.page(7, size: 500, query: GridQuery(), after: nil)
            let viaKeyset = try await pager.page(7, size: 500, query: GridQuery(), after: first.last)
            #expect(viaOffset == viaKeyset)
            #expect(Self.ids(viaKeyset).first == 3501)
        }
    }

    @Test(.enabled(if: PGFixture.url != nil, gate))
    func aSortedPageIsOrderedWithTheKeyAsTieBreaker() async throws {
        try await Self.withPager("big") { pager, relation, _, _ in
            let n = try #require(relation.columns.firstIndex { $0.name == "n" })
            let query = GridQuery(sort: GridSort(column: n, ascending: false))
            let page0 = try await pager.page(0, size: 500, query: query, after: nil)
            let keys = page0.map { row -> (Int64, Int64) in
                guard case .int(let id) = row[0], case .int(let nn) = row[n] else { return (0, 0) }
                return (nn, id)
            }
            #expect(keys.first?.0 == 6)
            // n descending, then id descending within one n.
            for (a, b) in zip(keys, keys.dropFirst()) { #expect(a.0 > b.0 || (a.0 == b.0 && a.1 > b.1)) }
            // Keyset on the next page agrees with offset.
            let viaKeyset = try await pager.page(1, size: 500, query: query, after: page0.last)
            let viaOffset = try await pager.page(1, size: 500, query: query, after: nil)
            #expect(viaKeyset == viaOffset)
        }
    }

    @Test(.enabled(if: PGFixture.url != nil, gate))
    func aNullableSortColumnPagesByOffsetAndPutsNullsLast() async throws {
        try await Self.withPager("sparse") { pager, relation, _, _ in
            let k = try #require(relation.columns.firstIndex { $0.name == "k" })
            let query = GridQuery(sort: GridSort(column: k, ascending: true))
            var all: [[SiftValue]] = []
            var previous: [SiftValue]?
            for index in 0..<2 {
                let rows = try await pager.page(index, size: 500, query: query, after: previous)
                all += rows
                previous = rows.last
            }
            #expect(all.count == 1000)
            #expect(Set(Self.ids(all)).count == 1000)
            let nulls = all.filter { $0[k] == .null }
            #expect(nulls.count == 100)
            #expect(all.suffix(100).allSatisfy { $0[k] == .null })
        }
    }

    @Test(.enabled(if: PGFixture.url != nil, gate))
    func filtersMatchLiterallyIncludingPercentAndQuote() async throws {
        try await Self.withPager("special") { pager, _, _, _ in
            func matches(_ op: FilterOp, _ value: String) async throws -> [Int64] {
                Self.ids(try await pager.page(
                    0, size: 500, query: GridQuery(filters: [GridFilter(column: 1, op: op, value: value)]), after: nil))
            }
            let v1 = try await matches(.contains, "%")
            #expect(v1 == [1, 5])
            let v2 = try await matches(.contains, "_")
            #expect(v2 == [2])
            let v3 = try await matches(.contains, "\\")
            #expect(v3 == [6])
            let v4 = try await matches(.contains, "'")
            #expect(v4 == [4])
            let v5 = try await matches(.eq, "it's")
            #expect(v5 == [4])
            let v6 = try await matches(.eq, "$1")
            #expect(v6 == [7])
            let v7 = try await matches(.startsWith, "a_")
            #expect(v7 == [2])
            let v8 = try await matches(.contains, "A%B")
            #expect(v8 == [1])
            let v9 = try await matches(.eq, "'; drop table special; --").isEmpty
            #expect(v9)
            // The table is still there.
            let v10 = try await pager.count(for: GridQuery())
            #expect(v10 == .exact(7))
            let search = GridQuery(search: "a_b")
            let v11 = Self.ids(try await pager.page(0, size: 500, query: search, after: nil))
            #expect(v11 == [2])
        }
    }

    @Test(.enabled(if: PGFixture.url != nil, gate))
    func aBadFilterValueThrowsInvalidTextRepresentation() async throws {
        try await Self.withPager("big") { pager, _, _, _ in
            let query = GridQuery(filters: [GridFilter(column: 0, op: .eq, value: "abc")])
            do {
                _ = try await pager.page(0, size: 500, query: query, after: nil)
                Issue.record("expected an error")
            } catch let e as SourceError {
                #expect(e.kind == .server(sqlState: "22P02"), "\(e)")
            }
            // The connection is still good after the failed statement.
            let v12 = try await pager.count(for: GridQuery())
            #expect(v12 == .exact(20000))
        }
    }

    @Test(.enabled(if: PGFixture.url != nil, gate))
    func aCountUnderTheThresholdIsExact() async throws {
        try await Self.withPager("big") { pager, _, _, _ in
            let v13 = try await pager.count(for: GridQuery())
            #expect(v13 == .exact(20000))
            let filtered = GridQuery(filters: [GridFilter(column: 2, op: .eq, value: "3")])
            let count = try await pager.count(for: filtered)
            #expect(count.isExact && abs(count.value - 20000 / 7) <= 1, "\(count)")
            let v14 = try await pager.exactCount(for: GridQuery())
            #expect(v14 == 20000)
        }
    }

    @Test(.enabled(if: PGFixture.url != nil, gate))
    func aHugeEstimateIsNotCounted() async throws {
        try await Self.withPager("big") { _, relation, _, params in
            var huge = relation
            huge.rowEstimate = .estimated(5_000_000)
            let pager = PGRelationPager(parameters: params, relation: huge)
            defer { pager.close() }
            let v15 = try await pager.count(for: GridQuery())
            #expect(v15 == .estimated(5_000_000))
            // A filter makes the estimate meaningless: it is counted.
            let filtered = GridQuery(filters: [GridFilter(column: 0, op: .le, value: "10")])
            let v16 = try await pager.count(for: filtered)
            #expect(v16 == .exact(10))
        }
    }

    @Test(.enabled(if: PGFixture.url != nil, gate))
    func cancelStopsTheServerQuery() async throws {
        try await PGFixture.withGridSchema { schema, params in
            let source = try await PGSource.connect(params)
            defer { source.close() }
            let relation = try #require(try await source.snapshot().relation(RelationID(schema, "sleepy")))
            let connection = try PGConnection(parameters: params)
            let pager = PGRelationPager(connection: connection, relation: relation)
            defer { pager.close() }
            let observer = try PGConnection(parameters: params)
            let pid = connection.backendPID

            func isActive() throws -> Bool {
                let rows = try observer.query(
                    "SELECT state, query FROM pg_stat_activity WHERE pid = $1", params: [String(pid)]).rows
                guard case .text(let state)? = rows.first?.first, case .text(let sql)? = rows.first?.last else { return false }
                return state == "active" && sql.contains("sleepy")
            }
            func waitFor(_ wanted: Bool) async throws -> Bool {
                for _ in 0..<80 {
                    if try isActive() == wanted { return true }
                    try await Task.sleep(nanoseconds: 25_000_000)
                }
                return false
            }

            let read = Task { try await pager.page(0, size: 500, query: GridQuery(), after: nil) }
            #expect(try await waitFor(true), "the server never started the page")
            pager.cancelCurrent()
            do {
                _ = try await read.value
                Issue.record("the sleeping page was not cancelled")
            } catch let e as SourceError {
                #expect(e.kind == .cancelled, "\(e)")
            }
            #expect(try await waitFor(false), "the backend is still running the query")
        }
    }

    @Test(.enabled(if: PGFixture.url != nil, gate))
    func aCtidTableStillPagesAllRows() async throws {
        try await Self.withPager("nokey") { pager, relation, _, _ in
            #expect(PGRelationQuery.orderKey(for: relation).kind == .ctid)
            #expect(pager.orderNote == "no stable key: rows may shift")
            var seen = Set<String>()
            var previous: [SiftValue]?
            var total = 0
            for index in 0..<3 {
                let rows = try await pager.page(index, size: 500, query: GridQuery(), after: previous)
                for row in rows {
                    guard case .text(let b) = row[1] else { continue }
                    seen.insert(b)
                }
                total += rows.count
                previous = rows.last
                if index == 1 { #expect(previous?.count == 3, "the hidden ctid rides along") }
            }
            #expect(total == 1300 && seen.count == 1300, "total \(total) seen \(seen.count)")
        }
    }

    @Test(.enabled(if: PGFixture.url != nil, gate))
    func typedColumnsDecodeAndTheColumnsCarryTheirTypes() async throws {
        try await Self.withPager("typed") { pager, _, _, _ in
            let names = pager.columns.map(\.typeName)
            #expect(names == ["int4", "jsonb", "\(pager.columns[2].typeName)", "uuid", "timestamptz", "int4[]", "numeric"])
            #expect(pager.columns[2].isEnum)
            let rows = try await pager.page(0, size: 500, query: GridQuery(), after: nil)
            #expect(rows.count == 2)
            #expect(rows[0][2] == .raw("ok"))
            #expect(rows[0][5] == .raw("{1,2,3}"))
            #expect(rows[0][6] == .text("12345678901234.5678"))
            #expect(rows[1][1] == .null)
            if case .raw(let json) = rows[0][1] { #expect(json.contains("\"b\": null")) } else { Issue.record("jsonb is not raw") }
        }
    }

    @Test(.enabled(if: PGFixture.url != nil, gate))
    func theSourceOpensAGridOnASecondConnection() async throws {
        try await PGFixture.withGridSchema { schema, params in
            let source = try await PGSource.connect(params)
            let relation = try #require(try await source.snapshot().relation(RelationID(schema, "big")))
            let grid = try #require(source.gridSource(for: relation) as? PGRelationPager)
            #expect(grid.backendPID == nil)
            let v17 = try await grid.count(for: GridQuery())
            #expect(v17 == .exact(20000))
            #expect(grid.backendPID != nil && grid.backendPID != source.connection.backendPID)
            source.close()
            do {
                _ = try await grid.page(0, size: 10, query: GridQuery(), after: nil)
                Issue.record("a closed source still pages")
            } catch let e as SourceError {
                #expect(e.kind == .connectionLost)
            }
        }
    }
}
