import SiftCore

/// What a relation is ordered by, so a page can be fetched by key rather than by offset.
public enum OrderKeyKind: Sendable, Equatable {
    case primaryKey
    case uniqueNotNull
    /// No key: the row's physical address. Rows may shift while the relation changes.
    case ctid
    /// A view or foreign table has no key and no `ctid`: no `ORDER BY`, offset paging only.
    case unordered
}

/// The SQL of a grid over one relation, as pure functions of its inputs: text plus bound parameters, no I/O.
///
/// Identifiers go through `PGIdentifier.quote`. Values are only ever parameters (`$n`): a filter value, a
/// search text and a keyset position never appear in the SQL text. Operators come from `FilterOp`, a closed enum.
public struct PGRelationQuery: Sendable {
    public let relation: RelationInfo
    /// Indexes into `relation.columns` of the key columns, in order. Empty for `ctid` and `unordered`.
    public let orderKey: [Int]
    public let keyKind: OrderKeyKind

    public init(relation: RelationInfo, orderKey: [Int], keyKind: OrderKeyKind) {
        self.relation = relation
        self.orderKey = orderKey
        self.keyKind = keyKind
    }

    /// The key for a relation: the primary key, else the first unique index or constraint whose columns are all
    /// NOT NULL, else `ctid` (tables and materialized views), else nothing (views, foreign tables, partitioned
    /// tables, whose `ctid` is not unique).
    public static func orderKey(for relation: RelationInfo) -> (columns: [Int], kind: OrderKeyKind) {
        func indexes(of names: [String]) -> [Int]? {
            var found: [Int] = []
            for name in names {
                guard let i = relation.columns.firstIndex(where: { $0.name == name }) else { return nil }
                found.append(i)
            }
            return found.isEmpty ? nil : found
        }
        func allNotNull(_ columns: [Int]) -> Bool { columns.allSatisfy { !relation.columns[$0].isNullable } }

        if let pk = relation.primaryKey, let columns = indexes(of: pk.columns) { return (columns, .primaryKey) }
        for index in relation.indexes where index.isUnique && index.predicate == nil && index.method == "btree" {
            if let columns = indexes(of: index.columns), allNotNull(columns) { return (columns, .uniqueNotNull) }
        }
        for unique in relation.uniqueConstraints {
            if let columns = indexes(of: unique.columns), allNotNull(columns) { return (columns, .uniqueNotNull) }
        }
        switch relation.kind {
        case .table, .materializedView: return ([], .ctid)
        case .view, .foreignTable, .partitionedTable: return ([], .unordered)
        }
    }

    /// The columns the select list names: every column, then `ctid::text` for a `ctid` key, kept for the keyset.
    public var selectedColumnCount: Int { relation.columns.count + (keyKind == .ctid ? 1 : 0) }

    // MARK: Pages

    public func pageSQL(index: Int, size: Int, query: GridQuery, after: [SiftValue]?) -> (sql: String, params: [String?]) {
        var params: [String?] = []
        var sql = "SELECT " + selectList() + " FROM " + PGIdentifier.qualified(relation.id)
        var conditions = whereConditions(for: query, params: &params)

        let order = orderTerms(for: query)
        var offset = index * size
        if let after, index > 0, let keyset = keysetCondition(query: query, order: order, after: after, params: &params) {
            conditions.append(keyset)
            offset = 0
        }
        if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
        if !order.isEmpty { sql += " ORDER BY " + order.map(\.sql).joined(separator: ", ") }
        sql += " LIMIT \(max(size, 0))"
        if offset > 0 { sql += " OFFSET \(offset)" }
        return (sql, params)
    }

    public func countSQL(query: GridQuery) -> (sql: String, params: [String?]) {
        var params: [String?] = []
        var sql = "SELECT count(*) FROM " + PGIdentifier.qualified(relation.id)
        let conditions = whereConditions(for: query, params: &params)
        if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
        return (sql, params)
    }

    // MARK: Pieces

    private func selectList() -> String {
        var items = relation.columns.map { PGIdentifier.quote($0.name) }
        if keyKind == .ctid { items.append("ctid::text") }
        return items.isEmpty ? "1" : items.joined(separator: ", ")
    }

    /// One `ORDER BY` term and what the keyset needs to compare it.
    private struct Term {
        var sql: String
        var expression: String
        /// The column's index in a result row (`ctid` is the last, hidden one), and a cast for its parameter.
        var rowIndex: Int
        var parameterCast: String
        var nullable: Bool
    }

    private func orderTerms(for query: GridQuery) -> [Term] {
        let ascending = query.sort?.ascending ?? true
        var terms: [Term] = []
        func suffix(_ nulls: Bool) -> String {
            guard query.sort != nil else { return "" }
            if nulls { return ascending ? " ASC NULLS LAST" : " DESC NULLS FIRST" }
            return ascending ? "" : " DESC"
        }
        var used = Set<Int>()
        if let sort = query.sort, relation.columns.indices.contains(sort.column) {
            let column = relation.columns[sort.column]
            let expression = PGIdentifier.quote(column.name)
            terms.append(Term(sql: expression + suffix(true), expression: expression, rowIndex: sort.column, parameterCast: "", nullable: column.isNullable))
            used.insert(sort.column)
        }
        for key in orderKey where !used.contains(key) {
            let expression = PGIdentifier.quote(relation.columns[key].name)
            terms.append(Term(sql: expression + suffix(false), expression: expression, rowIndex: key, parameterCast: "", nullable: false))
        }
        if keyKind == .ctid {
            terms.append(Term(sql: "ctid" + suffix(false), expression: "ctid", rowIndex: relation.columns.count, parameterCast: "::tid", nullable: false))
        }
        return terms
    }

    /// `WHERE (k1, k2) > ($1, $2)`, or nil when keyset cannot be used: no key, a nullable sort column, or a
    /// key value that is missing from the previous page's last row.
    private func keysetCondition(query: GridQuery, order: [Term], after: [SiftValue], params: inout [String?]) -> String? {
        guard keyKind != .unordered, !order.isEmpty, !order.contains(where: \.nullable) else { return nil }
        var values: [String] = []
        for term in order {
            guard after.indices.contains(term.rowIndex), let text = Self.parameterText(after[term.rowIndex]) else { return nil }
            values.append(text)
        }
        let comparison = (query.sort?.ascending ?? true) ? ">" : "<"
        var placeholders: [String] = []
        for (term, value) in zip(order, values) {
            params.append(value)
            placeholders.append("$\(params.count)" + term.parameterCast)
        }
        if order.count == 1 { return "\(order[0].expression) \(comparison) \(placeholders[0])" }
        return "(" + order.map(\.expression).joined(separator: ",") + ") \(comparison) (" + placeholders.joined(separator: ",") + ")"
    }

    private func whereConditions(for query: GridQuery, params: inout [String?]) -> [String] {
        var conditions: [String] = []
        for filter in query.filters {
            guard relation.columns.indices.contains(filter.column) else { continue }
            let column = relation.columns[filter.column]
            let name = PGIdentifier.quote(column.name)
            switch filter.op {
            case .isNull:
                conditions.append("\(name) IS NULL")
            case .isNotNull:
                conditions.append("\(name) IS NOT NULL")
            case .eq, .ne, .lt, .le, .gt, .ge:
                guard let value = filter.value else { continue }
                params.append(value)
                let cast = Self.safeTypeName(column.typeName).map { "::" + $0 } ?? ""
                conditions.append("\(name) \(Self.comparison(filter.op)) $\(params.count)\(cast)")
            case .contains:
                guard let value = filter.value else { continue }
                params.append("%" + Self.escapeLike(value) + "%")
                conditions.append("\(name)::text ILIKE $\(params.count) ESCAPE '\\'")
            case .startsWith:
                guard let value = filter.value else { continue }
                params.append(Self.escapeLike(value) + "%")
                conditions.append("\(name)::text ILIKE $\(params.count) ESCAPE '\\'")
            }
        }
        if let search = query.search, !search.isEmpty, !relation.columns.isEmpty {
            params.append("%" + Self.escapeLike(search) + "%")
            let n = params.count
            let any = relation.columns.map { "\(PGIdentifier.quote($0.name))::text ILIKE $\(n) ESCAPE '\\'" }
            conditions.append("(" + any.joined(separator: " OR ") + ")")
        }
        return conditions
    }

    // MARK: Helpers

    static func comparison(_ op: FilterOp) -> String {
        switch op {
        case .eq: return "="
        case .ne: return "<>"
        case .lt: return "<"
        case .le: return "<="
        case .gt: return ">"
        case .ge: return ">="
        default: return "="
        }
    }

    /// Escapes `\`, `%` and `_` so a LIKE pattern matches the text literally (with `ESCAPE '\'`).
    static func escapeLike(_ text: String) -> String {
        var out = ""
        for ch in text {
            if ch == "\\" || ch == "%" || ch == "_" { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// A type name from the catalog (`format_type`) that is safe to write after `::`, or nil. The catalog quotes
    /// odd names itself; this refuses anything that could end a statement or open a comment or a string.
    static func safeTypeName(_ name: String) -> String? {
        guard !name.isEmpty, name.count <= 128 else { return nil }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_ ,.()[]\"")
        guard name.allSatisfy({ allowed.contains($0) || $0.isLetter || $0.isNumber }) else { return nil }
        guard name.filter({ $0 == "\"" }).count % 2 == 0 else { return nil }
        return name
    }

    /// The text a keyset parameter is bound as.
    static func parameterText(_ value: SiftValue) -> String? {
        switch value {
        case .null: return nil
        case .bool(let b): return b ? "true" : "false"
        case .int(let n): return String(n)
        case .double(let d): return "\(d)"
        case .text(let s), .raw(let s): return s
        case .bytes(let bytes):
            let digits = Array("0123456789abcdef")
            var out = "\\x"
            for byte in bytes {
                out.append(digits[Int(byte >> 4)])
                out.append(digits[Int(byte & 0xF)])
            }
            return out
        }
    }
}
