import Foundation
import SiftCore

/// Postgres type OIDs (from `pg_type.dat`) and their decoding.
public enum PGOID {
    public static let bool: UInt32 = 16
    public static let bytea: UInt32 = 17
    public static let name: UInt32 = 19
    public static let int8: UInt32 = 20
    public static let int2: UInt32 = 21
    public static let int4: UInt32 = 23
    public static let text: UInt32 = 25
    public static let json: UInt32 = 114
    public static let float4: UInt32 = 700
    public static let float8: UInt32 = 701
    public static let bpchar: UInt32 = 1042
    public static let varchar: UInt32 = 1043
    public static let date: UInt32 = 1082
    public static let timestamp: UInt32 = 1114
    public static let timestamptz: UInt32 = 1184
    public static let numeric: UInt32 = 1700
    public static let uuid: UInt32 = 2950
    public static let jsonb: UInt32 = 3802

    private static let names: [UInt32: String] = [
        bool: "bool", bytea: "bytea", name: "name", int8: "int8", int2: "int2", int4: "int4",
        text: "text", json: "json", float4: "float4", float8: "float8", bpchar: "bpchar",
        varchar: "varchar", date: "date", timestamp: "timestamp", timestamptz: "timestamptz",
        numeric: "numeric", uuid: "uuid", jsonb: "jsonb",
        // Common array types.
        1000: "bool[]", 1001: "bytea[]", 1005: "int2[]", 1007: "int4[]", 1009: "text[]",
        1014: "bpchar[]", 1015: "varchar[]", 1016: "int8[]", 1021: "float4[]", 1022: "float8[]",
        1182: "date[]", 1115: "timestamp[]", 1185: "timestamptz[]", 1231: "numeric[]", 2951: "uuid[]", 3807: "jsonb[]",
    ]

    /// The display name of a type OID, or `oid:N` when unknown.
    public static func typeName(for oid: UInt32) -> String {
        names[oid] ?? "oid:\(oid)"
    }

    /// Decodes the text form of a value of the given type; `nil` is SQL NULL.
    public static func decode(_ text: String?, oid: UInt32) -> SiftValue {
        guard let text else { return .null }
        switch oid {
        case bool:
            return .bool(text == "t" || text == "true")
        case int2, int4, int8:
            return Int64(text).map(SiftValue.int) ?? .raw(text)
        case float4, float8:
            return Double(text).map(SiftValue.double) ?? .raw(text)
        case bytea:
            return decodeHexBytes(text).map(SiftValue.bytes) ?? .raw(text)
        case numeric, text_, varchar, bpchar, name, uuid, date, timestamp, timestamptz:
            return .text(text)
        default:
            // jsonb, json, arrays and anything not decoded yet.
            return .raw(text)
        }
    }

    private static let text_ = text

    /// The OID and short name for a type as `format_type` writes it (`bigint`, `timestamp with time zone`,
    /// `numeric(12,2)`, `integer[]`), or OID 0 and the name unchanged for a type Sift does not know (an enum).
    public static func canonical(formatted: String) -> (oid: UInt32, name: String) {
        var base = formatted
        var isArray = false
        if base.hasSuffix("[]") {
            base = String(base.dropLast(2))
            isArray = true
        }
        if let open = base.firstIndex(of: "("), let close = base[open...].firstIndex(of: ")") {
            base = String(base[..<open]) + String(base[base.index(after: close)...])
        }
        base = base.trimmingCharacters(in: .whitespaces)
        let scalars: [String: UInt32] = [
            "boolean": bool, "bytea": bytea, "name": name, "bigint": int8, "smallint": int2, "integer": int4,
            "text": text, "json": json, "real": float4, "double precision": float8, "character": bpchar,
            "character varying": varchar, "date": date, "timestamp without time zone": timestamp,
            "timestamp with time zone": timestamptz, "numeric": numeric, "uuid": uuid, "jsonb": jsonb,
        ]
        guard let oid = scalars[base] else { return (0, formatted) }
        if !isArray { return (oid, typeName(for: oid)) }
        let arrays: [UInt32: UInt32] = [
            bool: 1000, bytea: 1001, int2: 1005, int4: 1007, text: 1009, bpchar: 1014, varchar: 1015, int8: 1016,
            float4: 1021, float8: 1022, date: 1182, timestamp: 1115, timestamptz: 1185, numeric: 1231, uuid: 2951,
            jsonb: 3807,
        ]
        guard let array = arrays[oid] else { return (0, formatted) }
        return (array, typeName(for: array))
    }

    private static func decodeHexBytes(_ s: String) -> [UInt8]? {
        guard s.hasPrefix("\\x") else { return nil }
        let digits = Array(s.utf8.dropFirst(2))
        guard digits.count % 2 == 0 else { return nil }
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 97...102: return c - 87
            case 65...70: return c - 55
            default: return nil
            }
        }
        var out: [UInt8] = []
        out.reserveCapacity(digits.count / 2)
        var i = 0
        while i < digits.count {
            guard let hi = nibble(digits[i]), let lo = nibble(digits[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }
}
