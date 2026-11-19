import Foundation
import SiftCore
import SiftTestSupport
import Testing

@testable import SiftPG

@Suite struct ConnectionParameterTests {
    @Test func quoteDoublesEmbeddedQuotes() {
        #expect(PGIdentifier.quote("Weird \"Name\"") == "\"Weird \"\"Name\"\"\"")
        #expect(PGIdentifier.qualified(RelationID("a b", "c")) == "\"a b\".\"c\"")
    }

    @Test func readOnlyAddsTheStartupOption() {
        let p = PGConnectionParameters(host: "h", database: "d", user: "u")
        let pairs = p.keywordValues()
        #expect(pairs.contains { $0.0 == "options" && $0.1 == "-c default_transaction_read_only=on" })
        var writable = p
        writable.readOnly = false
        #expect(!writable.keywordValues().contains { $0.0 == "options" })
    }

    @Test func parametersDescriptionHidesThePassword() {
        let p = PGConnectionParameters(host: "h", database: "d", user: "u", password: Secret("s3cret"))
        #expect(!String(describing: p).contains("s3cret"))
        #expect(!String(reflecting: p).contains("s3cret"))
        #expect(p.keywordValues().contains { $0.0 == "password" && $0.1 == "s3cret" })
    }

    @Test func urlParsing() throws {
        let p = try PGConnectionParameters(url: "postgresql://u:p%40ss@h:6543/db?sslmode=require")
        #expect(p.user == "u")
        #expect(p.password?.reveal() == "p@ss")
        #expect(p.host == "h")
        #expect(p.port == 6543)
        #expect(p.database == "db")
        #expect(p.sslMode == .require)
    }
}

@Suite struct ConnectionIntegrationTests {
    private static let gate = "SIFT_PG_URL is not set"

    @Test(.enabled(if: PGFixture.url != nil, Comment(rawValue: gate)))
    func connectsWithParameters() async throws {
        let pg = try PGConnection(parameters: try PGConnectionParameters(url: try #require(PGFixture.url)))
        let page = try await pg.execute("SELECT $1::int + 1", params: ["41"])
        #expect(page.rows == [[.int(42)]])
        #expect(!pg.isBroken)
        #expect(pg.backendPID > 0)
    }

    @Test(.enabled(if: PGFixture.url != nil, Comment(rawValue: gate)))
    func aTerminatedBackendIsConnectionLost() async throws {
        let params = try PGConnectionParameters(url: try #require(PGFixture.url))
        let victim = try PGConnection(parameters: params)
        let killer = try PGConnection(parameters: params)
        _ = try await victim.execute("SELECT 1")
        _ = try await killer.execute("SELECT pg_terminate_backend($1::int)", params: [String(victim.backendPID)])
        // The server closes the socket asynchronously; the first statement after that fails.
        var error: PGError?
        for _ in 0..<50 {
            do { _ = try await victim.execute("SELECT 1") } catch let e as PGError { error = e; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let e = try #require(error)
        #expect(e.isConnectionLost)
        #expect(victim.isBroken)
    }

    @Test(.enabled(if: PGFixture.url != nil, Comment(rawValue: gate)))
    func serverErrorsCarrySQLSTATE() async throws {
        let pg = try PGConnection(parameters: try PGConnectionParameters(url: try #require(PGFixture.url)))
        do {
            _ = try await pg.execute("SELECT * FROM no_such_table_sift")
            Issue.record("expected an error")
        } catch let e as PGError {
            #expect(e.sqlState == "42P01")
            #expect(!e.isConnectionLost)
        }
    }
}
