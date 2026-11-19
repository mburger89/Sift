import Foundation
import SiftCore
import Testing

@testable import SiftPG

@Suite struct OIDMappingTests {
    @Test func decodesScalars() {
        #expect(PGOID.decode("t", oid: PGOID.bool) == .bool(true))
        #expect(PGOID.decode("f", oid: PGOID.bool) == .bool(false))
        #expect(PGOID.decode("-42", oid: PGOID.int4) == .int(-42))
        #expect(PGOID.decode("7", oid: PGOID.int2) == .int(7))
        #expect(PGOID.decode("9007199254740993", oid: PGOID.int8) == .int(9_007_199_254_740_993))
        #expect(PGOID.decode("1.5", oid: PGOID.float4) == .double(1.5))
        #expect(PGOID.decode("2.25", oid: PGOID.float8) == .double(2.25))
    }

    @Test func textLikeTypesStayText() {
        for oid in [PGOID.numeric, PGOID.text, PGOID.varchar, PGOID.uuid, PGOID.timestamptz] {
            #expect(PGOID.decode("x", oid: oid) == .text("x"))
        }
    }

    @Test func jsonbArraysAndUnknownTypesAreRaw() {
        #expect(PGOID.decode("{\"a\": 1}", oid: PGOID.jsonb) == .raw("{\"a\": 1}"))
        #expect(PGOID.decode("{1,2}", oid: 1007) == .raw("{1,2}"))
        #expect(PGOID.decode("x", oid: 99999) == .raw("x"))
    }

    @Test func nullIsNullForEveryType() {
        for oid in [PGOID.bool, PGOID.int4, PGOID.text, PGOID.jsonb, 99999] {
            #expect(PGOID.decode(nil, oid: oid) == .null)
        }
    }

    @Test func byteaDecodesHex() {
        #expect(PGOID.decode("\\xdeadBEEF", oid: PGOID.bytea) == .bytes([0xde, 0xad, 0xbe, 0xef]))
        #expect(PGOID.decode("\\xzz", oid: PGOID.bytea) == .raw("\\xzz"))
    }

    @Test func typeNames() {
        #expect(PGOID.typeName(for: PGOID.jsonb) == "jsonb")
        #expect(PGOID.typeName(for: 1007) == "int4[]")
        #expect(PGOID.typeName(for: 4242) == "oid:4242")
    }
}

private let pgURL = ProcessInfo.processInfo.environment["SIFT_PG_URL"]

@Suite struct IntegrationTests {
    @Test(.enabled(if: pgURL != nil, "SIFT_PG_URL is not set"))
    func roundTripOfEveryType() throws {
        let pg = try PGConnection(conninfo: try #require(pgURL))
        let outcome = try PGSelfCheck.run(pg)
        #expect(outcome.mismatches.isEmpty, "\(outcome.mismatches)")
        #expect(outcome.serverVersion >= 90000)
    }

    @Test(.enabled(if: pgURL != nil, "SIFT_PG_URL is not set"))
    func errorsCarryTheServerMessage() throws {
        let pg = try PGConnection(conninfo: try #require(pgURL))
        #expect(throws: PGError.self) { try pg.query("SELECT * FROM no_such_table_sift") }
    }
}
