/// Which columns say "newest", for the "Newest first" toggle. Pure: decided from the catalog alone.
public enum RecencyColumns {
    /// A relation with at least this many estimated rows opens in key order unless the candidate is indexed.
    public static let cheapRowLimit = 100_000

    private static let createdNames = ["created_at", "inserted_at", "created", "created_on", "creation_time", "createdat"]
    private static let updatedNames = ["updated_at", "modified_at", "updated", "modified", "last_modified", "updatedat"]
    private static let timestampTypes: Set<String> = [
        "timestamp with time zone", "timestamp without time zone", "timestamptz", "timestamp", "date",
    ]
    private static let integerTypes: Set<String> = ["smallint", "integer", "bigint", "int2", "int4", "int8", "int"]
    private static let clockDefaults = ["now()", "current_timestamp", "clock_timestamp()"]

    /// Column indexes, best first: created-like names, updated-like names, other timestamps defaulting to the
    /// clock, then identity or `nextval` integers (the primary key first).
    public static func candidates(for relation: RelationInfo) -> [Int] {
        let columns = relation.columns
        var result: [Int] = []
        func add(_ i: Int) { if !result.contains(i) { result.append(i) } }
        func isTimestamp(_ column: ColumnInfo) -> Bool { timestampTypes.contains(baseType(column.typeName)) }

        for name in createdNames + updatedNames {
            for (i, column) in columns.enumerated() where isTimestamp(column) && column.name.lowercased() == name { add(i) }
        }
        for (i, column) in columns.enumerated() where isTimestamp(column) {
            let expression = (column.defaultExpression ?? "").lowercased()
            if clockDefaults.contains(where: { expression.contains($0) }) { add(i) }
        }
        let serial = columns.indices.filter { i in
            let column = columns[i]
            guard integerTypes.contains(baseType(column.typeName)) else { return false }
            return column.identity != nil || (column.defaultExpression ?? "").lowercased().hasPrefix("nextval(")
        }
        let primary = Set(relation.primaryKey?.columns ?? [])
        for i in serial where primary.contains(columns[i].name) { add(i) }
        for i in serial { add(i) }
        return result
    }

    /// Newest first on the first candidate, or nil when none exists or sorting on it would be a big sort
    /// (not the lead of a btree index, over a relation estimated at `cheapRowLimit` rows or more).
    public static func defaultSort(for relation: RelationInfo) -> GridSort? {
        guard let first = candidates(for: relation).first else { return nil }
        let name = relation.columns[first].name
        let indexed =
            relation.primaryKey?.columns.first == name
            || relation.indexes.contains { $0.method == "btree" && $0.predicate == nil && $0.columns.first == name }
        var small = true
        if case .estimated(let n) = relation.rowEstimate { small = n < Int64(cheapRowLimit) }
        guard indexed || small else { return nil }
        return GridSort(column: first, ascending: false, nullsLast: true)
    }

    /// `format_type` output without a precision: `timestamp(3) with time zone` becomes `timestamp with time zone`.
    private static func baseType(_ name: String) -> String {
        var out = ""
        var depth = 0
        for ch in name.lowercased() {
            if ch == "(" { depth += 1 } else if ch == ")" { depth = max(0, depth - 1) } else if depth == 0 { out.append(ch) }
        }
        return out.split(separator: " ").joined(separator: " ")
    }
}
