import SiftCore
import SiftTestSupport
import Testing

@testable import SiftPG

@Suite struct SourceTests {
    @Test(.enabled(if: PGFixture.url != nil, gate))
    func writesAreRefusedByDefault() async throws {
        try await PGFixture.withSchemas { names, params in
            let source = try await PGSource.connect(params)
            defer { source.close() }
            do {
                _ = try await source.rawQuery("CREATE TABLE \(names.a).x()")
                Issue.record("expected the write to be refused")
            } catch let e as SourceError {
                #expect(e.kind == .server(sqlState: "25006"))
            }
            let shown = try await source.rawQuery("SHOW default_transaction_read_only")
            #expect(shown.rows == [[.text("on")]])
        }
    }

    @Test(.enabled(if: PGFixture.url != nil, gate))
    func noQueryRunnerIsMadeAfterClose() async throws {
        try await PGFixture.withSchemas { _, params in
            let source = try await PGSource.connect(params)
            let before = try #require(source.queryRunner() as? PGQueryRunner)
            source.close()
            #expect(source.queryRunner() == nil)
            // The runner it had was closed with the source, and nothing was opened for the call.
            #expect(await before.run("SELECT 1", statementTimeout: "60s").kind != .cancelled)
            #expect(before.backendPID == nil)
        }
    }

    @Test(.enabled(if: PGFixture.url != nil, gate))
    func firstRowsHonoursTheLimit() async throws {
        try await PGFixture.withSchemas { names, params in
            let source = try await PGSource.connect(params)
            defer { source.close() }
            let page = try await source.firstRows(of: RelationID(names.a, "customers"), limit: 2)
            #expect(page.rows.count == 2)
            #expect(page.columns.prefix(2).map(\.name) == ["id", "email"])
        }
    }

    @Test(.enabled(if: PGFixture.url != nil, gate))
    func exactCountQuotesNames() async throws {
        try await PGFixture.withSchemas { names, params in
            let source = try await PGSource.connect(params)
            defer { source.close() }
            #expect(try await source.exactRowCount(of: RelationID(names.a, "Weird \"Name\"")) == 0)
            #expect(try await source.exactRowCount(of: RelationID(names.a, "customers")) == 3)
            // The count transaction always ends, so the session is usable afterwards.
            #expect(try await source.firstRows(of: RelationID(names.a, "customers"), limit: 1).rows.count == 1)
        }
    }

    @Test(.enabled(if: PGFixture.url != nil, gate), .timeLimit(.minutes(1)))
    func cancelStopsALongStatement() async throws {
        let params = try PGConnectionParameters(url: try #require(PGFixture.url))
        let source = try await PGSource.connect(params)
        defer { source.close() }
        let observer = try PGConnection(parameters: params)
        let pid = String(source.connection.backendPID)

        let sleeper = Task { try await source.rawQuery("SELECT pg_sleep(30)") }
        var active = false
        for _ in 0..<100 {
            let page = try await observer.execute(
                "SELECT 1 FROM pg_stat_activity WHERE pid = $1::int AND state = 'active' AND query LIKE '%pg_sleep%'",
                params: [pid])
            if !page.rows.isEmpty { active = true; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(active, "the statement never became active")
        source.cancelCurrent()
        do {
            _ = try await sleeper.value
            Issue.record("expected the statement to be cancelled")
        } catch let e as SourceError {
            #expect(e.kind == .cancelled)
        }
    }

    @Test func connectionLostMapsToSourceError() {
        #expect(PGSource.map(PGError("x", isConnectionLost: true)).kind == .connectionLost)
        #expect(PGSource.map(PGError("x", sqlState: "57014")).kind == .cancelled)
        #expect(PGSource.map(PGError("x", sqlState: "42P01")).kind == .server(sqlState: "42P01"))
    }
}
