import Foundation

/// A `GridSource` over the rows a query run captured, so the editor's results use the same grid as a table.
///
/// Sort, filter and search run in memory and mean what they mean in `PGRelationPager`: `NULLS LAST` ascending and
/// `NULLS FIRST` descending, ties in the order the rows came (reversed when descending, as the pager's key tie-break is), a comparison with NULL never matches, `contains` and
/// `starts with` ignore case, the search looks at every column's text, and a value that is not valid for the column's
/// type is refused with `22P02`. The ordering is built off the main actor and kept for the query it was built for.
public final class QueryResultSource: GridSource, @unchecked Sendable {
    public let columns: [ResultColumn]
    public let rows: [[SiftValue]]

    private let lock = NSLock()
    private var cachedQuery: GridQuery?
    private var cachedOrder: [Int] = []

    public init(columns: [ResultColumn], rows: [[SiftValue]]) {
        self.columns = columns
        self.rows = rows
    }

    // MARK: GridSource

    public func count(for query: GridQuery) async throws -> RowCount {
        .exact(try await order(for: query).count)
    }

    public func exactCount(for query: GridQuery) async throws -> Int {
        try await order(for: query).count
    }

    public func page(_ index: Int, size: Int, query: GridQuery, after: [SiftValue]?) async throws -> [[SiftValue]] {
        let order = try await order(for: query)
        let from = index * size
        guard from < order.count else { return [] }
        return order[from..<min(order.count, from + size)].map { rows[$0] }
    }

    /// There is nothing on a server to cancel.
    public func cancelCurrent() {}

    // MARK: Ordering

    /// The indexes of the rows that pass the query, in its order.
    private func order(for query: GridQuery) async throws -> [Int] {
        if let hit = lock.withLock({ cachedQuery == query ? cachedOrder : nil }) { return hit }
        let built: [Int] = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try self.build(query)) } catch { continuation.resume(throwing: error) }
            }
        }
        lock.withLock {
            cachedQuery = query
            cachedOrder = built
        }
        return built
    }

    private func build(_ query: GridQuery) throws -> [Int] {
        var indexes = Array(rows.indices)
        if !query.filters.isEmpty || !(query.search ?? "").isEmpty {
            let tests = try query.filters.map { try FilterTest($0, column: columns[safe: $0.column]) }
            let needle = (query.search ?? "").lowercased()
            indexes = indexes.filter { i in
                let row = rows[i]
                for test in tests where !test.matches(row[safe: test.column] ?? .null) { return false }
                if !needle.isEmpty, !row.contains(where: { Self.text($0).lowercased().contains(needle) }) { return false }
                return true
            }
        }
        if let sort = query.sort, columns.indices.contains(sort.column) {
            let type = ValueOrder(columns[sort.column])
            let column = sort.column
            indexes.sort { a, b in
                let l = rows[a][safe: column] ?? .null, r = rows[b][safe: column] ?? .null
                switch (l, r) {
                case (.null, .null): return sort.ascending ? a < b : a > b
                case (.null, _): return !sort.nullsLast      // by default NULLS LAST ascending, NULLS FIRST descending
                case (_, .null): return sort.nullsLast
                default:
                    let c = type.compare(l, r)
                    if c == 0 { return sort.ascending ? a < b : a > b }
                    return sort.ascending ? c < 0 : c > 0
                }
            }
        }
        return indexes
    }

    static func text(_ value: SiftValue) -> String {
        switch value {
        case .null: return ""
        case .bool(let b): return b ? "true" : "false"
        case .int(let n): return String(n)
        case .double(let d): return "\(d)"
        case .text(let s), .raw(let s): return s
        case .bytes(let bytes): return "\\x" + bytes.map { String(format: "%02x", $0) }.joined()
        }
    }

    /// How values of one column compare: numbers by value, everything else by its text.
    struct ValueOrder {
        enum Kind { case number, boolean, text }
        var kind: Kind

        init(_ column: ResultColumn) {
            switch column.typeName.lowercased() {
            case "int2", "int4", "int8", "float4", "float8", "numeric", "smallint", "integer", "bigint", "real", "double precision", "oid":
                kind = .number
            case "bool", "boolean": kind = .boolean
            default: kind = .text
            }
        }

        /// Negative, zero or positive: `l` against `r`, neither NULL.
        func compare(_ l: SiftValue, _ r: SiftValue) -> Int {
            switch kind {
            case .number:
                if case .int(let a) = l, case .int(let b) = r { return a < b ? -1 : (a > b ? 1 : 0) }
                if let a = Self.number(l), let b = Self.number(r) { return a < b ? -1 : (a > b ? 1 : 0) }
            case .boolean:
                if case .bool(let a) = l, case .bool(let b) = r { return a == b ? 0 : (!a ? -1 : 1) }
            case .text: break
            }
            let a = QueryResultSource.text(l), b = QueryResultSource.text(r)
            return a == b ? 0 : (a < b ? -1 : 1)
        }

        static func number(_ v: SiftValue) -> Decimal? {
            switch v {
            case .int(let n): return Decimal(n)
            case .double(let d): return d.isFinite ? Decimal(d) : nil
            case .text(let s), .raw(let s): return Decimal(string: s)
            default: return nil
            }
        }
    }

    /// One filter chip, with its operand read as the column's type (a bad operand is refused here, as the server would).
    private struct FilterTest {
        let column: Int
        let op: FilterOp
        let operand: String
        let order: ValueOrder
        let bound: SiftValue

        init(_ filter: GridFilter, column meta: ResultColumn?) throws {
            column = filter.column
            op = filter.op
            operand = filter.value ?? ""
            let type = meta.map(ValueOrder.init) ?? ValueOrder(ResultColumn(name: "", typeOID: 0, typeName: "text"))
            order = type
            switch type.kind {
            case .number where op.isComparison:
                guard let number = Decimal(string: operand.trimmingCharacters(in: .whitespaces)) else {
                    throw SourceError(.server(sqlState: "22P02"), "invalid input syntax for type \(meta?.typeName ?? "number"): \"\(operand)\"")
                }
                bound = .raw("\(number)")
            case .boolean where op.isComparison:
                switch operand.lowercased() {
                case "t", "true", "yes", "on", "1": bound = .bool(true)
                case "f", "false", "no", "off", "0": bound = .bool(false)
                default: throw SourceError(.server(sqlState: "22P02"), "invalid input syntax for type boolean: \"\(operand)\"")
                }
            default:
                bound = .text(operand)
            }
        }

        func matches(_ value: SiftValue) -> Bool {
            switch op {
            case .isNull: return value == .null
            case .isNotNull: return value != .null
            default: break
            }
            if value == .null { return false }
            switch op {
            case .contains: return QueryResultSource.text(value).lowercased().contains(operand.lowercased())
            case .startsWith: return QueryResultSource.text(value).lowercased().hasPrefix(operand.lowercased())
            default: break
            }
            let c = order.compare(value, bound)
            switch op {
            case .eq: return c == 0
            case .ne: return c != 0
            case .lt: return c < 0
            case .le: return c <= 0
            case .gt: return c > 0
            case .ge: return c >= 0
            default: return false
            }
        }
    }
}

extension FilterOp {
    fileprivate var isComparison: Bool {
        switch self {
        case .eq, .ne, .lt, .le, .gt, .ge: return true
        default: return false
        }
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
