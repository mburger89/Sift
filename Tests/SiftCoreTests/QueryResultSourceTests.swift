import SiftCore
import Testing

@Suite struct QueryResultSourceTests {
    static let columns = [
        ResultColumn(name: "id", typeOID: 20, typeName: "int8"),
        ResultColumn(name: "name", typeOID: 25, typeName: "text"),
        ResultColumn(name: "price", typeOID: 1700, typeName: "numeric"),
        ResultColumn(name: "ok", typeOID: 16, typeName: "bool"),
    ]
    static let rows: [[SiftValue]] = [
        [.int(1), .text("pear"), .text("9.50"), .bool(true)],
        [.int(2), .text("apple"), .text("10.25"), .bool(false)],
        [.int(3), .null, .null, .null],
        [.int(4), .text("Apple pie"), .text("10.25"), .bool(true)],
        [.int(5), .text("50%_off"), .text("-3"), .bool(false)],
        [.int(10), .text("fig"), .text("100"), .bool(true)],
    ]

    func ids(_ source: QueryResultSource, _ query: GridQuery) async throws -> [Int64] {
        try await source.page(0, size: 500, query: query, after: nil).compactMap {
            if case .int(let n)? = $0.first { return n } else { return nil }
        }
    }

    func source() -> QueryResultSource { QueryResultSource(columns: Self.columns, rows: Self.rows) }

    @Test func anUnsortedQueryAnswersTheRowsInCaptureOrder() async throws {
        #expect(try await ids(source(), GridQuery()) == [1, 2, 3, 4, 5, 10])
        #expect(try await source().count(for: GridQuery()) == .exact(6))
        #expect(try await source().exactCount(for: GridQuery()) == 6)
    }

    @Test func pagesSliceTheRows() async throws {
        let s = source()
        #expect(try await s.page(1, size: 4, query: GridQuery(), after: nil).count == 2)
        #expect(try await s.page(2, size: 4, query: GridQuery(), after: nil).isEmpty)
    }

    @Test func aNumberSortsByValueNotByText() async throws {
        // Text order would put 10 before 2.
        #expect(try await ids(source(), GridQuery(sort: GridSort(column: 0))) == [1, 2, 3, 4, 5, 10])
        #expect(try await ids(source(), GridQuery(sort: GridSort(column: 0, ascending: false))) == [10, 5, 4, 3, 2, 1])
        // numeric: -3, 9.50, 10.25, 10.25, 100, then NULL last; ties keep capture order.
        #expect(try await ids(source(), GridQuery(sort: GridSort(column: 2))) == [5, 1, 2, 4, 10, 3])
    }

    @Test func nullsSortLastAscendingAndFirstDescending() async throws {
        #expect(try await ids(source(), GridQuery(sort: GridSort(column: 1, ascending: true))).last == 3)
        #expect(try await ids(source(), GridQuery(sort: GridSort(column: 1, ascending: false))).first == 3)
        // Descending ties run the key descending too, as the pager's `ORDER BY price DESC, id DESC` does.
        #expect(try await ids(source(), GridQuery(sort: GridSort(column: 2, ascending: false))) == [3, 10, 4, 2, 1, 5])
    }

    @Test func nullsLastHonouredInMemory() async throws {
        #expect(try await ids(source(), GridQuery(sort: GridSort(column: 1, ascending: false, nullsLast: true))).last == 3)
        #expect(try await ids(source(), GridQuery(sort: GridSort(column: 1, ascending: true, nullsLast: false))).first == 3)
        // numeric descending with NULLs last: 100, then the 10.25 pair (key descending), 9.50, -3, NULL.
        #expect(try await ids(source(), GridQuery(sort: GridSort(column: 2, ascending: false, nullsLast: true))) == [10, 4, 2, 1, 5, 3])
    }

    @Test func aBooleanSortsFalseBeforeTrue() async throws {
        #expect(try await ids(source(), GridQuery(sort: GridSort(column: 3))) == [2, 5, 1, 4, 10, 3])
    }

    @Test func comparisonsAgainstNullNeverMatch() async throws {
        let eq = GridFilter(column: 1, op: .eq, value: "pear")
        #expect(try await ids(source(), GridQuery(filters: [eq])) == [1])
        let ne = GridFilter(column: 1, op: .ne, value: "pear")
        #expect(try await ids(source(), GridQuery(filters: [ne])) == [2, 4, 5, 10])   // not the NULL row
        #expect(try await ids(source(), GridQuery(filters: [GridFilter(column: 1, op: .isNull)])) == [3])
        #expect(try await ids(source(), GridQuery(filters: [GridFilter(column: 1, op: .isNotNull)])) == [1, 2, 4, 5, 10])
    }

    @Test func numericFiltersCompareByValue() async throws {
        func q(_ op: FilterOp, _ v: String) -> GridQuery { GridQuery(filters: [GridFilter(column: 2, op: op, value: v)]) }
        let s = source()
        #expect(try await ids(s, q(.gt, "10")) == [2, 4, 10])
        #expect(try await ids(s, q(.ge, "10.25")) == [2, 4, 10])
        #expect(try await ids(s, q(.lt, "9.5")) == [5])
        #expect(try await ids(s, q(.le, "9.5")) == [1, 5])
        #expect(try await ids(s, q(.eq, "10.250")) == [2, 4])
        #expect(try await ids(s, GridQuery(filters: [GridFilter(column: 0, op: .eq, value: "10")])) == [10])
    }

    @Test func containsAndStartsWithIgnoreCaseAndMatchLiterally() async throws {
        let s = source()
        #expect(try await ids(s, GridQuery(filters: [GridFilter(column: 1, op: .contains, value: "APPLE")])) == [2, 4])
        #expect(try await ids(s, GridQuery(filters: [GridFilter(column: 1, op: .startsWith, value: "apple")])) == [2, 4])
        #expect(try await ids(s, GridQuery(filters: [GridFilter(column: 1, op: .contains, value: "%_")])) == [5])
        #expect(try await ids(s, GridQuery(filters: [GridFilter(column: 1, op: .contains, value: "%")])) == [5])
    }

    @Test func filtersAreAnded() async throws {
        let query = GridQuery(filters: [
            GridFilter(column: 1, op: .contains, value: "apple"), GridFilter(column: 3, op: .eq, value: "true"),
        ])
        #expect(try await ids(source(), query) == [4])
    }

    @Test func aBadOperandIsRefusedLikeTheServerWould() async throws {
        let s = source()
        for filter in [GridFilter(column: 0, op: .eq, value: "abc"), GridFilter(column: 3, op: .eq, value: "maybe")] {
            do {
                _ = try await s.page(0, size: 10, query: GridQuery(filters: [filter]), after: nil)
                Issue.record("a bad operand was accepted")
            } catch let e as SourceError {
                #expect(e.kind == .server(sqlState: "22P02"))
            }
        }
    }

    @Test func searchLooksAtEveryColumnsText() async throws {
        let s = source()
        #expect(try await ids(s, GridQuery(search: "10.25")) == [2, 4])
        #expect(try await ids(s, GridQuery(search: "FIG")) == [10])
        #expect(try await ids(s, GridQuery(search: "true")) == [1, 4, 10])
        #expect(try await ids(s, GridQuery(search: "nothing like this")).isEmpty)
        // Narrowing, then sorting, composes.
        #expect(try await ids(s, GridQuery(sort: GridSort(column: 0, ascending: false), search: "apple")) == [4, 2])
    }

    @Test func aCountFollowsTheFilters() async throws {
        let q = GridQuery(filters: [GridFilter(column: 1, op: .contains, value: "apple")])
        #expect(try await source().count(for: q) == .exact(2))
    }

    @Test func theSameQueryTwiceAnswersTheSame() async throws {
        let s = source()
        let q = GridQuery(sort: GridSort(column: 2))
        #expect(try await ids(s, q) == ids(s, q))
    }
}
