import SiftCore

/// The phase-0 round trip, shared by `siftpg-probe` and the integration test:
/// one row of every supported type (plus NULL) goes into a temp table and is read back.
public enum PGSelfCheck {
    public struct Mismatch: Sendable, CustomStringConvertible {
        public var column: String
        public var expected: SiftValue
        public var actual: SiftValue
        public var description: String { "\(column): expected \(expected), got \(actual)" }
    }

    public struct Outcome: Sendable {
        public var serverVersion: Int
        public var page: ResultPage
        public var mismatches: [Mismatch]
    }

    public static let expected: [(column: String, value: SiftValue)] = [
        ("b", .bool(true)),
        ("i2", .int(7)),
        ("i4", .int(-42)),
        ("i8", .int(9_007_199_254_740_993)),
        ("f4", .double(1.5)),
        ("f8", .double(2.25)),
        ("n", .text("12345.6789")),
        ("t", .text("héllo")),
        ("v", .text("vc")),
        ("u", .text("123e4567-e89b-12d3-a456-426614174000")),
        ("ts", .text("2024-01-02 03:04:05+00")),
        ("j", .raw("{\"a\": 1, \"b\": [true, null]}")),
        ("arr", .raw("{1,2,3}")),
        ("by", .bytes([0xde, 0xad, 0xbe, 0xef])),
        ("nul", .null),
        ("p", .text("param")),
    ]

    public static func run(_ pg: PGConnection) throws -> Outcome {
        _ = try pg.query("SET TIME ZONE 'UTC'")
        _ = try pg.query("""
            CREATE TEMP TABLE sift_probe (
              b bool, i2 int2, i4 int4, i8 int8, f4 float4, f8 float8, n numeric,
              t text, v varchar, u uuid, ts timestamptz, j jsonb, arr int4[], by bytea,
              nul text, p text)
            """)
        _ = try pg.query("""
            INSERT INTO sift_probe VALUES (
              true, 7, -42, 9007199254740993, 1.5, 2.25, 12345.6789,
              'héllo', 'vc', '123e4567-e89b-12d3-a456-426614174000',
              '2024-01-02 03:04:05+00', '{"a":1,"b":[true,null]}', '{1,2,3}', '\\xdeadbeef',
              NULL, $1)
            """, params: ["param"])
        let page = try pg.query("SELECT * FROM sift_probe")
        var mismatches: [Mismatch] = []
        guard page.rows.count == 1, page.columns.count == expected.count else {
            throw PGError("expected 1 row of \(expected.count) columns, got \(page.rows.count) rows of \(page.columns.count) columns")
        }
        for (i, exp) in expected.enumerated() {
            let name = page.columns[i].name
            let actual = page.rows[0][i]
            if name != exp.column || actual != exp.value {
                mismatches.append(Mismatch(column: exp.column, expected: exp.value, actual: actual))
            }
        }
        return Outcome(serverVersion: pg.serverVersion, page: page, mismatches: mismatches)
    }
}
