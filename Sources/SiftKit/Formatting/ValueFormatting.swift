import SiftCore

/// How values and estimates read in the UI. Pure, so the rules are testable without a window.
extension SiftValue {
    /// The text a cell shows. NULL is handled by the caller (it is drawn differently), but gets "NULL" here.
    /// Bytes are `\x` hex truncated to 32 bytes; raw and text are truncated to 200 characters.
    public var displayText: String {
        switch self {
        case .null: return "NULL"
        case .bool(let value): return value ? "true" : "false"
        case .int(let value): return String(value)
        case .double(let value): return Self.shortest(value)
        case .text(let value): return Self.truncated(value, characters: 200)
        case .raw(let value): return Self.truncated(value, characters: 200)
        case .bytes(let bytes):
            let hex = bytes.prefix(32).map { Self.hexByte($0) }.joined()
            return "\\x" + hex + (bytes.count > 32 ? "…" : "")
        }
    }

    private static func hexByte(_ byte: UInt8) -> String {
        let digits = Array("0123456789abcdef")
        return String([digits[Int(byte >> 4)], digits[Int(byte & 0xF)]])
    }

    /// The shortest form that reads back as the same double: `2.25`, not `2.2500000000`.
    static func shortest(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return "\(value)"
    }

    static func truncated(_ text: String, characters limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }
}

extension RowEstimate {
    /// `≈3 rows`, `≈1 row`, or `rows unknown`.
    public var displayText: String {
        switch self {
        case .unknown: return "rows unknown"
        case .estimated(let n): return "≈\(Self.grouped(n)) \(n == 1 ? "row" : "rows")"
        }
    }

    /// An exact count: `3 rows (exact)`.
    public static func exactText(_ n: Int64) -> String { "\(grouped(n)) \(n == 1 ? "row" : "rows") (exact)" }

    /// Digits in groups of three, so a million reads as `1,000,000`.
    static func grouped(_ n: Int64) -> String {
        let digits = Array(String(n.magnitude))
        var out = ""
        for (i, digit) in digits.enumerated() {
            if i > 0, (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(digit)
        }
        return (n < 0 ? "-" : "") + out
    }
}

extension RelationKind {
    /// The word for a relation's kind.
    public var displayName: String {
        switch self {
        case .table: return "Table"
        case .partitionedTable: return "Partitioned table"
        case .view: return "View"
        case .materializedView: return "Materialized view"
        case .foreignTable: return "Foreign table"
        }
    }
}

extension ForeignKeyAction {
    var displayName: String {
        switch self {
        case .noAction: return "no action"
        case .restrict: return "restrict"
        case .cascade: return "cascade"
        case .setNull: return "set null"
        case .setDefault: return "set default"
        }
    }
}
