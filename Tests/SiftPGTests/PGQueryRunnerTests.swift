import Foundation
import SiftCore
import SiftTestSupport
import Testing

@testable import SiftPG

/// The editor's runner against a real server. Skipped when `SIFT_PG_URL` is not set.
///
/// Every run must leave the runner's connection `idle`, never `idle in transaction`: each test that ends a run in a
/// special way (cancel, error, the cap) checks it through a second connection.
@Suite struct PGQueryRunnerTests {
    /// A runner over its own connection, an observer connection, and the fixture schema; both close afterwards.
    static func withRunner<T>(
        _ body: @escaping (PGQueryRunner, Observer, String, PGConnectionParameters) async throws -> T
    ) async throws -> T {
        try await PGFixture.withGridSchema { schema, params in
            let runner = PGQueryRunner(connection: try PGConnection(parameters: params))
            defer { runner.close() }
            let observer = Observer(connection: try PGConnection(parameters: params))
            defer { observer.connection.close() }
            return try await body(runner, observer, schema, params)
        }
    }

    struct Observer {
        let connection: PGConnection

        /// The `state` of a backend, polled briefly: `pg_stat_activity` can trail the reply by a moment.
        func state(of pid: Int32?, expecting wanted: String = "idle") async throws -> String {
            guard let pid else { return "no connection" }
            var last = ""
            for _ in 0..<40 {
                let rows = try connection.query("SELECT state FROM pg_stat_activity WHERE pid = $1", params: [String(pid)]).rows
                if case .text(let s)? = rows.first?.first { last = s }
                if last == wanted { return last }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            return last
        }
    }

    static func rows(_ outcome: QueryOutcome) -> (columns: [ResultColumn], rows: [[SiftValue]], truncated: Bool)? {
        if case .rows(let c, let r, let t) = outcome.kind { return (c, r, t) }
        return nil
    }

    static func failure(_ outcome: QueryOutcome) -> QueryFailure? {
        if case .failed(let f) = outcome.kind { return f }
        return nil
    }

    @Test(.enabled(if: PGFixture.url != nil, gate))
    func aSelectReturnsRowsThroughACursorAndCommits() async throws {
        try await Self.withRunner { runner, observer, _, _ in
            let outcome = await runner.run("SELECT 1 AS a, 'x' AS b UNION ALL SELECT 2, 'y';", statementTimeout: "60s")
            let got = try #require(Self.rows(outcome))
            #expect(got.columns.map(\.name) == ["a", "b"])
            #expect(got.rows == [[.int(1), .text("x")], [.int(2), .text("y")]])
            #expect(!got.truncated)
            #expect(outcome.duration >= 0)
            #expect(try await observer.state(of: runner.backendPID) == "idle")
        }
    }

    @Test(.enabled(if: PGFixture.url != nil, gate))
    func aValuesAndAWithStatementAlsoRunThroughTheCursor() async throws {
        try await Self.withRunner { runner, _, _, _ in
            let values = Self.rows(await runner.run("(VALUES (1), (2))", statementTimeout: "60s"))
            #expect(values?.rows.count == 2)
            let with = Self.rows(await runner.run("/* c */ with t as (select 7 as n) select n from t", statementTimeout: "60s"))
            #expect(with?.rows == [[.int(7)]])
            let empty = Self.rows(await runner.run("SELECT 1 WHERE false", statementTimeout: "60s"))
            #expect(empty?.rows.isEmpty == true && empty?.columns.map(\.name) == ["?column?"])
        }
    }

    @Test(.enabled(if: PGFixture.url != nil, gate))
    func theCapTruncatesAt100000AndCloses() async throws {
        try await Self.withRunner { runner, observer, _, _ in
            let over = await runner.run("SELECT g FROM generate_series(1, 100005) g", statementTimeout: "60s")
            let got = try #require(Self.rows(over))
            #expect(got.truncated)
            #expect(got.rows.count == PGQueryRunner.rowCap)
            #expect(got.rows.last == [.int(100_000)])
            #expect(try await observer.state(of: runner.backendPID) == "idle")
            // Exactly the cap is not truncated.
            let exact = Self.rows(await runner.run("SELECT g FROM generate_series(1, 100000) g", statementTimeout: "60s"))
            #expect(exact?.truncated == false && exact?.rows.count == 100_000)
        }
    }

    @Test(.enabled(if: PGFixture.url != nil, gate))
    func aWriteIsRefusedAsReadOnly() async throws {
        try await Self.withRunner { runner, observer, schema, params in
            for sql in [
                "CREATE TABLE \(schema).sift_sql_nope (x int)",
                "INSERT INTO \(schema).sparse VALUES (5000, 1)",
                "DELETE FROM \(schema).sparse",
                // A data-modifying WITH is refused as a cursor (0A000), then runs plainly and meets the read-only rule.
                "WITH d AS (DELETE FROM \(schema).sparse RETURNING id) SELECT * FROM d",
            ] {
                let f = try #require(Self.failure(await runner.run(sql, statementTimeout: "60s")), "\(sql)")
                #expect(f.sqlState == QueryFailure.readOnlyViolation, "\(sql) gave \(f.sqlState ?? "nil")")
            }
            #expect(try await observer.state(of: runner.backendPID) == "idle")
            // Nothing changed.
            let check = try PGConnection(parameters: params)
            defer { check.close() }
            #expect(try check.query("SELECT count(*) FROM \(schema).sparse").rows == [[.int(1000)]])
        }
    }

    @Test(.enabled(if: PGFixture.url != nil, gate))
    func showFallsBackToAPlainRun() async throws {
        try await Self.withRunner { runner, observer, _, _ in
            let got = try #require(Self.rows(await runner.run("SHOW server_version_num", statementTimeout: "60s")))
            #expect(got.columns.map(\.name) == ["server_version_num"])
            #expect(got.rows.count == 1 && !got.truncated)
            #expect(try await observer.state(of: runner.backendPID) == "idle")
        }
    }

    @Test(.enabled(if: PGFixture.url != nil, gate))
    func anotherStatementRunsPlainlyAndReportsItsCommandTag() async throws {
        try await Self.withRunner { runner, _, _, _ in
            let set = await runner.run("SET LOCAL work_mem = '4MB'", statementTimeout: "60s")
            #expect(set.kind == .command(tag: "SET", affected: nil))
            let explain = Self.rows(await runner.run("EXPLAIN SELECT 1", statementTimeout: "60s"))
            #expect(explain?.rows.isEmpty == false)
        }
    }

    @Test(.enabled(if: PGFixture.url != nil, gate))
    func aSyntaxErrorCarriesItsPosition() async throws {
        try await Self.withRunner { runner, observer, _, _ in
            // `SELECT 1 ,, 2`: the first comma is fine; the server points at the second, character 11.
            let f = try #require(Self.failure(await runner.run("SELECT 1 ,, 2", statementTimeout: "60s")))
            #expect(f.sqlState == "42601")
            #expect(f.position == 11)
            #expect(!f.message.contains("LINE 1"), "the message is the one line, not the server's context")
            #expect(try await observer.state(of: runner.backendPID) == "idle")
        }
    }

    @Test(.enabled(if: PGFixture.url != nil, gate))
    func thePositionCountsCharactersNotBytes() async throws {
        try await Self.withRunner { runner, _, _, _ in
            // 'héllo' is 6 characters but 7 bytes: the second comma is character 17, byte 18.
            let f = try #require(Self.failure(await runner.run("SELECT 'héllo' ,, 1", statementTimeout: "60s")))
            #expect(f.position == 17)
            // The position is relative to the text as given, also for a statement that goes through the cursor
            // (the DECLARE prefix is not counted): an unknown column.
            let c = try #require(Self.failure(await runner.run("SELECT 'é', nope", statementTimeout: "60s")))
            #expect(c.sqlState == "42703")
            #expect(c.position == 13)
            #expect(c.hint == nil || c.hint?.isEmpty == false)
        }
    }

    @Test(.enabled(if: PGFixture.url != nil, gate))
    func cancelReturnsCancelledAndLeavesNoOpenTransaction() async throws {
        try await Self.withRunner { runner, observer, _, _ in
            // The pid is read while the connection is idle: asking a busy connection for it waits for the statement.
            _ = await runner.run("SELECT 1", statementTimeout: "60s")
            let pid = try #require(runner.backendPID)
            let started = Date()
            let run = Task { await runner.run("SELECT pg_sleep(30)", statementTimeout: "60s") }
            try await Task.sleep(nanoseconds: 200_000_000)
            #expect(try await observer.state(of: pid, expecting: "active") == "active")
            runner.cancel()
            let outcome = await run.value
            #expect(outcome.kind == .cancelled)
            #expect(Date().timeIntervalSince(started) < 10, "the sleep was not interrupted")
            #expect(try await observer.state(of: pid) == "idle")
            // The runner is usable afterwards, and a cancel with nothing running does nothing.
            runner.cancel()
            #expect(Self.rows(await runner.run("SELECT 1", statementTimeout: "60s"))?.rows == [[.int(1)]])
        }
    }

    @Test(.enabled(if: PGFixture.url != nil, gate))
    func copyIsRefusedWithAMessageAndTheConnectionStaysUsable() async throws {
        try await Self.withRunner { runner, observer, _, _ in
            let f = try #require(Self.failure(await runner.run("COPY (SELECT 1) TO STDOUT", statementTimeout: "60s")))
            #expect(f.message == "COPY is not supported in the editor")
            // The connection is idle again, not stuck mid-COPY.
            #expect(try await observer.state(of: runner.backendPID) == "idle")
            #expect(Self.rows(await runner.run("SELECT 1", statementTimeout: "60s"))?.rows == [[.int(1)]])
        }
    }

    @Test(.enabled(if: PGFixture.url != nil, gate))
    func anErrorMidFetchRollsBack() async throws {
        try await Self.withRunner { runner, observer, _, _ in
            let f = try #require(Self.failure(await runner.run(
                "SELECT 1/(g-50000) FROM generate_series(1,100000) g", statementTimeout: "60s")))
            #expect(f.sqlState == "22012")
            #expect(try await observer.state(of: runner.backendPID) == "idle")
            #expect(Self.rows(await runner.run("SELECT 2", statementTimeout: "60s"))?.rows == [[.int(2)]])
        }
    }

    @Test(.enabled(if: PGFixture.url != nil, gate))
    func theTimeoutIsApplied() async throws {
        try await Self.withRunner { runner, observer, _, _ in
            let outcome = await runner.run("SELECT pg_sleep(3)", statementTimeout: "1s")
            // A timeout is a failure, not a cancel: nobody asked.
            let f = try #require(Self.failure(outcome))
            #expect(f.sqlState == QueryFailure.queryCanceled)
            #expect(outcome.duration < 3)
            #expect(try await observer.state(of: runner.backendPID) == "idle")
            // "No timeout" is `0`.
            #expect(Self.rows(await runner.run("SELECT pg_sleep(1.2), 1", statementTimeout: "0"))?.rows.count == 1)
        }
    }

    @Test(.enabled(if: PGFixture.url != nil, gate))
    func theRunnersConnectionIsItsOwn() async throws {
        try await PGFixture.withGridSchema { _, params in
            let source = try await PGSource.connect(params)
            defer { source.close() }
            let runner = try #require(source.queryRunner() as? PGQueryRunner)
            #expect(runner === (source.queryRunner() as? PGQueryRunner))
            #expect(runner.backendPID == nil, "the connection opens at the first run")
            #expect(Self.rows(await runner.run("SELECT 1", statementTimeout: "60s")) != nil)
            let pid = try #require(runner.backendPID)
            #expect(pid != source.connection.backendPID)
        }
    }
}

/// The in-memory source answers as the pager does over the same rows.
@Suite struct QueryResultSourceAgreementTests {
    @Test(.enabled(if: PGFixture.url != nil, gate))
    func sortFilterAndSearchMatchThePagerOnTheSameFixture() async throws {
        try await PGFixture.withGridSchema { schema, params in
            let source = try await PGSource.connect(params)
            defer { source.close() }
            let snapshot = try await source.snapshot()
            let runner = PGQueryRunner(connection: try PGConnection(parameters: params))
            defer { runner.close() }
            for table in ["sparse", "special"] {
                let relation = try #require(snapshot.relation(RelationID(schema, table)))
                let pager = PGRelationPager(connection: try PGConnection(parameters: params), relation: relation)
                defer { pager.close() }
                let outcome = await runner.run("SELECT * FROM \(schema).\(table) ORDER BY id", statementTimeout: "60s")
                let got = try #require(PGQueryRunnerTests.rows(outcome))
                let memory = QueryResultSource(columns: got.columns, rows: got.rows)
                let k = table == "sparse" ? 1 : 1
                let queries: [GridQuery] = table == "sparse"
                    ? [
                        GridQuery(),
                        GridQuery(sort: GridSort(column: k, ascending: true)),
                        GridQuery(sort: GridSort(column: k, ascending: false)),
                        GridQuery(filters: [GridFilter(column: k, op: .gt, value: "90")]),
                        GridQuery(filters: [GridFilter(column: k, op: .isNull)]),
                        GridQuery(filters: [GridFilter(column: k, op: .le, value: "3"), GridFilter(column: 0, op: .ge, value: "100")]),
                        GridQuery(sort: GridSort(column: k, ascending: false), search: "99"),
                    ]
                    : [
                        GridQuery(),
                        GridQuery(filters: [GridFilter(column: 1, op: .contains, value: "%")]),
                        GridQuery(filters: [GridFilter(column: 1, op: .contains, value: "_")]),
                        GridQuery(filters: [GridFilter(column: 1, op: .startsWith, value: "A")]),
                        GridQuery(filters: [GridFilter(column: 1, op: .contains, value: "\\")]),
                        GridQuery(filters: [GridFilter(column: 1, op: .contains, value: "'")]),
                        GridQuery(search: "$1"),
                        GridQuery(sort: GridSort(column: 1, ascending: true)),
                    ]
                for query in queries {
                    let want = try await pager.page(0, size: 500, query: query, after: nil)
                    let have = try await memory.page(0, size: 500, query: query, after: nil)
                    // Text order depends on the server's collation: compare as sets when the query sorts text.
                    let textSort = table == "special" && query.sort != nil
                    if textSort {
                        #expect(Set(want.map { "\($0)" }) == Set(have.map { "\($0)" }), "\(table) \(query)")
                    } else {
                        #expect(want == have, "\(table) \(query)")
                    }
                    let wantCount = try await pager.count(for: query)
                    let haveCount = try await memory.count(for: query)
                    #expect(wantCount.value == haveCount.value, "\(table) \(query) count")
                }
            }
        }
    }
}
